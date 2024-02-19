// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseHook} from "periphery-next/BaseHook.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

contract LimitOrder is BaseHook, ERC1155 {

    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    error DepositFailed();
    error WithdrawalFailed();
    error NoPoisitionsToCancel();

    bytes internal constant ZERO_BYTES = bytes("");

    mapping(PoolId poolId => int24 tickLower) public lastTickLower;
    
    // pool id => lower tick price => trade direction => amount
    // can be created by multiple parties 
    // each party only has claim based on number of tokens they hold
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount))) public limitOrders;

    mapping(uint256 tokenId => bool exists) public existingTokenIds;
    mapping(uint256 tokenId => uint256 claimable) public claimableAmount;
    mapping(uint256 tokenId => uint256 totalSupply) public totalSupply;
    mapping(uint256 tokenId => TokenData tokenData) public tokenIdData;

    struct TokenData {
        PoolKey poolKey;
        int24 tick;
        bool zeroForOne;
    }

    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {}

    function getHooksCalls() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            noOp: false,
            accessLock: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick) 
    external returns (bytes4)
    {
        _setLastTickLower(key.toId(), _getTickLower(tick, key.tickSpacing));
        return LimitOrder.afterInitialize.selector;
    }

    function placeOrder(PoolKey calldata poolKey, int24 tick, uint256 amount, bool zeroForOne) 
    external returns(int24)
    {
        int24 tickLower = _getTickLower(tick, poolKey.tickSpacing);
        limitOrders[poolKey.toId()][tickLower][zeroForOne] += int256(amount);

        uint256 tokenId = getTokenId(poolKey, tickLower, zeroForOne);

        if(!existingTokenIds[tokenId]) {
            existingTokenIds[tokenId] = true;
            tokenIdData[tokenId] = TokenData(poolKey, tickLower, zeroForOne);
        }

        _mint(msg.sender, tokenId, amount, "");
        totalSupply[tokenId] += amount;

        address tokenToSell = _getTokenFromPoolKey(poolKey, zeroForOne);

        bool deposit = IERC20(tokenToSell).transferFrom(msg.sender, address(this), amount);

        if(!deposit) {
            revert DepositFailed();
        }

        return tickLower;
    }

    function cancelOrder(PoolKey calldata poolKey, int24 tick, bool zeroForOne)
    external 
    {
        int24 tickLower = _getTickLower(tick, poolKey.tickSpacing);
        uint256 tokenId = getTokenId(poolKey, tickLower, zeroForOne);

        uint256 amount = balanceOf(msg.sender, tokenId);

        if(amount == 0){
            revert NoPoisitionsToCancel();
        }

        limitOrders[poolKey.toId()][tickLower][zeroForOne] -= int256(amount);

        totalSupply[tokenId] -= amount;
        _burn(msg.sender, tokenId, amount);

        address tokenToSell = _getTokenFromPoolKey(poolKey, zeroForOne);

        bool withdraw = IERC20(tokenToSell).transfer(msg.sender, amount);

        if(!withdraw) {
            revert WithdrawalFailed();
        }
    }

    function handleSwap(PoolKey calldata poolKey, IPoolManager.SwapParams calldata params) 
    external returns(BalanceDelta)
    {
        BalanceDelta delta = poolManager.swap(poolKey, params, ZERO_BYTES);

        //TODO refactor this into a function ...
        if(params.zeroForOne){
            if(delta.amount0() > 0) {
                IERC20(Currency.unwrap(poolKey.currency0)).transfer(address(poolManager), uint128(delta.amount0()));
                poolManager.settle(poolKey.currency0);
            }
            if(delta.amount1() < 0) {
                poolManager.take(poolKey.currency1, address(this), uint128(-delta.amount1()));
            }
        }
        else {
            if(delta.amount1() > 0) {
                IERC20(Currency.unwrap(poolKey.currency1)).transfer(address(poolManager), uint128(delta.amount1()));
                poolManager.settle(poolKey.currency1);
            }
            if(delta.amount0() < 0) {
                poolManager.take(poolKey.currency0, address(this), uint128(-delta.amount0()));
            }
        }
        
        return delta;
    }

    function fillOrder(
        PoolKey calldata poolKey,
        int24 tick,
        bool zeroForOne,
        uint256 amount
    ) internal {
        //TODO optimise slippage calculation / sprtPriceLimitX96 param value 
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: zeroForOne ? 
            TickMath.MIN_SQRT_RATIO + 1 :   // increasing price of token 1, lower ratio
            TickMath.MAX_SQRT_RATIO - 1     // increasing price of token 0, higher ratio
        });

        BalanceDelta delta = abi.decode(
            poolManager.lock(
                address(this),
                abi.encodeCall(this.handleSwap, (poolKey, params))
            ),
            (BalanceDelta)
        );

        limitOrders[poolKey.toId()][tick][zeroForOne] -= int256(amount);

        uint256 tokenId = getTokenId(poolKey, tick, zeroForOne);

        uint256 amountReceivedFromSwap = zeroForOne ?
            uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));
        
        claimableAmount[tokenId] += amountReceivedFromSwap;
    }

    function getTokenId(PoolKey calldata poolKey, int24 tickLower, bool zeroForOne) 
    public pure returns (uint256) 
    {
        return uint256(keccak256(abi.encodePacked(poolKey.toId(), tickLower, zeroForOne)));
    }

    function _getTokenFromPoolKey(PoolKey calldata poolKey, bool zeroForOne) 
    private pure returns(address token)
    {
        token = zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
    }

    function _setLastTickLower(PoolId poolId, int24 tick) private {
        lastTickLower[poolId] = tick;
    }

    function _getTickLower(int24 actualTick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        if(actualTick < 0 && actualTick % tickSpacing != 0) {
            intervals--;
        }
        return intervals * tickSpacing;
    }
}