// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseHook} from "periphery-next/BaseHook.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract LimitOrder is BaseHook, ERC1155 {

    using PoolIdLibrary for PoolKey;

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

    function getTokenId(PoolKey calldata poolKey, int24 tickLower, bool zeroForOne) 
    public pure returns (uint256) 
    {
        return uint256(keccak256(abi.encodePacked(poolKey.toId(), tickLower, zeroForOne)));
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