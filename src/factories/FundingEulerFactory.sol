// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity 0.8.28;

import {FundingEuler} from "../FundingEuler.sol";

contract FundingEulerFactory {
    /* STORAGE */

    mapping(address account => bool) public isFundingEuler;

    /* EVENTS */

    event CreateFundingEuler(address indexed owner, address indexed evc, uint256 ltvCap, FundingEuler fundingEuler);

    /* FUNCTIONS */

    /// @notice Deploys a FundingEuler module for `_owner` (a Box) on the Ethereum Vault Connector `_evc`
    /// @dev See the FundingEuler constructor for the validation of the arguments
    function createFundingEuler(address _owner, address _evc, uint256 _ltvCap) external returns (FundingEuler) {
        FundingEuler _funding = new FundingEuler(_owner, _evc, _ltvCap);

        isFundingEuler[address(_funding)] = true;

        emit CreateFundingEuler(_owner, _evc, _ltvCap, _funding);

        return _funding;
    }
}
