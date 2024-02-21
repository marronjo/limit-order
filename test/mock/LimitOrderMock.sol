// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {LimitOrder} from "../../src/LimitOrder.sol";
import {BaseHook} from "periphery-next/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract LimitOrderMock is LimitOrder {

    constructor(
        IPoolManager poolManager,
        LimitOrder addressToEtch
    ) LimitOrder(poolManager, "uri") {}

    function validateHookAddress(BaseHook _this) internal pure override {}
}