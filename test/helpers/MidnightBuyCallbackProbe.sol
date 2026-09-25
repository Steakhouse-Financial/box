// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IFunding} from "../../src/interfaces/IFunding.sol";
import {Market} from "../../src/interfaces/midnight/IMidnight.sol";
import {IBuyCallback} from "./MidnightTestInterfaces.sol";

/**
 * @title Maker callback that observes a Box while a lender bid is being taken
 * @dev Midnight calls the maker callback after the seller's debt has grown and before the proceeds are transferred to
 *      the seller's receiver. The probe pays the proceeds (it is the payer of offers naming it as callback), records
 *      `Box.totalAssets()` at every call, and tries to reenter the Box with a borrow and a repay.
 */
contract MidnightBuyCallbackProbe is IBuyCallback {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    IBox public immutable box;
    IFunding public immutable module;
    IERC20 public immutable loanToken;
    bytes public facilityData;

    uint256[] public observedTotalAssets;
    uint256 public reentryAttempts;
    uint256 public reentrySuccesses;

    constructor(IBox box_, IFunding module_, IERC20 loanToken_, address midnight, bytes memory facilityData_) {
        box = box_;
        module = module_;
        loanToken = loanToken_;
        facilityData = facilityData_;
        loanToken_.approve(midnight, type(uint256).max);
    }

    function onBuy(bytes32, Market memory, uint256, uint256, uint256, address, bytes memory) external returns (bytes32) {
        observedTotalAssets.push(box.totalAssets());

        reentryAttempts += 2;
        try box.borrow(module, facilityData, loanToken, 1) {
            reentrySuccesses++;
        } catch {}
        try box.repay(module, facilityData, loanToken, 1) {
            reentrySuccesses++;
        } catch {}
        return CALLBACK_SUCCESS;
    }

    function observations() external view returns (uint256) {
        return observedTotalAssets.length;
    }
}
