// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

//foundry imports
import {Test, console2} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

//Token imports
import {TestERC20} from "v4-core/test/TestERC20.sol";

//Uniswap Libraries
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

//interfaces
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

//Pool imports
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyPositionTest} from "v4-core/test/PoolModifyPositionTest.sol";

//my contracts
import {LimitOrder} from "../src/LimitOrder.sol";
import {LimitOrderMock} from "./mock/LimitOrderMock.sol";

contract LimitOrderTest is Test, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    //ensure address is valid for given hook permissions
    LimitOrder hook = LimitOrder(
        address(uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
        ))
    );

    PoolManager poolManager;

    PoolModifyPositionTest testModifyPositionRouter;

    PoolSwapTest testSwapRouter;

    TestERC20 token0;
    TestERC20 token1;

    PoolKey poolKey;
    PoolId poolId;

    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    function setUp() public {
        _deployTokens();
        poolManager = new PoolManager(500_000);
        _mockValidateHookAddress();
        _initializePool();
        _addLiquidty();
    }

    function test_placeOrder() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        uint256 startingBalance = token0.balanceOf(address(this));

        token0.approve(address(hook), amount);

        int24 tickLower = hook.placeOrder(poolKey, tick, amount, zeroForOne);

        uint256 endingBalance = token0.balanceOf(address(this));

        assertEq(tickLower, 60);

        assertEq(startingBalance - amount, endingBalance);

        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenId);

        assertTrue(tokenId != 0);
        assertEq(tokenBalance, amount);
    }

    function _initializePool() private {
        testModifyPositionRouter = new PoolModifyPositionTest(
            IPoolManager(address(poolManager))
        );

        testSwapRouter = new PoolSwapTest(
            IPoolManager(address(poolManager))
        ); 

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook) 
        });

        poolId = poolKey.toId();

        //poolManager.lock(address(), bytes(""));

        poolManager.initialize(poolKey, SQRT_RATIO_1_1, bytes("")); // hookdata empty bytes?
    }

    function _addLiquidty() private {
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);

        token0.approve(address(testModifyPositionRouter), 100 ether);
        token1.approve(address(testModifyPositionRouter), 100 ether);

        // +- 60
        poolManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: 60, 
                tickUpper: -60,
                liquidityDelta: 10 ether            
            }),
            bytes("")
        );

        // +- 120
        poolManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: 120, 
                tickUpper: -120,
                liquidityDelta: 10 ether            
            }),
            bytes("")
        );

        // +- max / min
        poolManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: TickMath.minUsableTick(60), 
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 50 ether            
            }),
            bytes("")
        );

        token0.approve(address(testSwapRouter), 100 ether);
        token1.approve(address(testSwapRouter), 100 ether);
    }

    function _deployTokens() private {
        TestERC20 _tokenA = new TestERC20(2 ** 128);
        TestERC20 _tokenB = new TestERC20(2 ** 128);

        if(address(_tokenA) < address(_tokenB)) {
            token0 = _tokenA;
            token1 = _tokenB;
        } else {
            token0 = _tokenB;
            token1 = _tokenA;
        }
    }

    function _mockValidateHookAddress() private {
        LimitOrderMock mock = new LimitOrderMock(
            poolManager,
            hook
        );

        (,bytes32[] memory writes) = vm.accesses(address(mock));

        vm.etch(address(hook), address(mock).code);

        unchecked {
            uint256 length = writes.length; //cache array length, save gas
            for (uint256 i = 0; i < length; i++) {
                bytes32 slot = writes[i];
                //load storage slots from mock, and store them in hook
                vm.store(address(hook), slot, vm.load(address(mock), slot));
            }
        }
    }

    //ERC 1155 tokens
    receive() external payable {}

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}