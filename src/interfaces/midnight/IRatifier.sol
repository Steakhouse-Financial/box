// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association, Steakhouse Financial
pragma solidity >=0.8.0;

// Adapted from Morpho Midnight's `IRatifier.sol`.

import {Offer} from "./IMidnight.sol";

/// @title IRatifier
/// @notice Contract that confirms an offer was approved by its maker (signature, Merkle root registration, ...).
/// @dev Midnight's `take` requires `isRatified(offer, ratifierData, taker)` to return
/// `keccak256("morpho.midnight.callbackSuccess")`; ratifiers revert for offers they do not ratify.
interface IRatifier {
    function isRatified(Offer memory offer, bytes memory ratifierData, address taker) external view returns (bytes32);
}
