// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @notice Test double for the Reactive system contract; its code is etched at the system address in tests.
contract MockSystem {
    uint256 public subscribeCount;
    uint256 public unsubscribeCount;
    uint256 public callbackCount;
    ISystemContract.CallbackConfiguration_V_1_0 internal _lastCallback;

    receive() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscribeCount++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        unsubscribeCount++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackCount++;
        _lastCallback = config_;
    }

    function lastCallback() external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return _lastCallback;
    }
}
