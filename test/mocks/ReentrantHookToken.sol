// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20MockDecimals} from "./ERC20MockDecimals.sol";

/// @notice ERC20 with a transfer hook (like ERC-777 style tokens) that makes one external call when a watched account
///         sends or receives tokens, and records the outcome instead of bubbling it up.
contract ReentrantHookToken is ERC20MockDecimals {
    address public watched;
    address public target;
    bytes public callData;

    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryReturnData;

    constructor() ERC20MockDecimals(18) {}

    /// @notice Arms a single call to `target_` with `callData_` on the next transfer from or to `watched_`
    function arm(address watched_, address target_, bytes calldata callData_) external {
        watched = watched_;
        target = target_;
        callData = callData_;
        reentryAttempted = false;
        reentrySucceeded = false;
        delete reentryReturnData;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        address hookTarget = target;
        if (hookTarget == address(0) || (from != watched && to != watched)) return;
        target = address(0);
        (bool success, bytes memory returnData) = hookTarget.call(callData);
        reentryAttempted = true;
        reentrySucceeded = success;
        reentryReturnData = returnData;
    }
}
