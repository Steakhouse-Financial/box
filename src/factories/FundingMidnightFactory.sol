// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity 0.8.28;

import {FundingMidnight} from "../FundingMidnight.sol";

contract FundingMidnightFactory {
    /* STORAGE */

    mapping(address account => bool) public isFundingMidnight;

    /* EVENTS */

    event CreateFundingMidnight(address indexed owner, address indexed midnight, uint256 lltvCap, FundingMidnight fundingMidnight);

    /* FUNCTIONS */

    /// @notice Deploys a FundingMidnight module for `_owner` (a Box) on the Midnight contract `_midnight`
    /// @dev See the FundingMidnight constructor for the validation of the arguments
    function createFundingMidnight(address _owner, address _midnight, uint256 _lltvCap) external returns (FundingMidnight) {
        FundingMidnight _funding = new FundingMidnight(_owner, _midnight, _lltvCap);

        isFundingMidnight[address(_funding)] = true;

        emit CreateFundingMidnight(_owner, _midnight, _lltvCap, _funding);

        return _funding;
    }
}
