// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Steakhouse Financial
pragma solidity 0.8.28;

import {FundingAaveV4} from "../FundingAaveV4.sol";

contract FundingAaveV4Factory {
    /* STORAGE */

    mapping(address account => bool) public isFundingAaveV4;

    /* EVENTS */

    event CreateFundingAaveV4(
        address indexed owner,
        address indexed spoke,
        uint256[] reserveIds,
        uint256 lltvCap,
        FundingAaveV4 fundingAaveV4
    );

    /* FUNCTIONS */

    /// @notice Deploys a FundingAaveV4 module for `_owner` (a Box) on `_spoke`
    /// @dev See the FundingAaveV4 constructor for the validation of the arguments
    function createFundingAaveV4(
        address _owner,
        address _spoke,
        uint256[] calldata _reserveIds,
        uint256 _lltvCap
    ) external returns (FundingAaveV4) {
        FundingAaveV4 _funding = new FundingAaveV4(_owner, _spoke, _reserveIds, _lltvCap);

        isFundingAaveV4[address(_funding)] = true;

        emit CreateFundingAaveV4(_owner, _spoke, _reserveIds, _lltvCap, _funding);

        return _funding;
    }
}
