// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Offer} from "../../src/interfaces/midnight/IMidnight.sol";
import {IRatifier} from "../../src/interfaces/midnight/IRatifier.sol";
import {MIDNIGHT_CALLBACK_SUCCESS} from "./MockMidnight.sol";

/// @notice Ratifier mock: ratifies individual offers (by full ABI hash) or everything; reverts `NotRatified` otherwise,
/// like the deployed ratifiers do for unknown or cancelled roots. `returnWrongValue` makes Midnight revert `RatifierFailed`.
contract MockMidnightRatifier is IRatifier {
    error NotRatified();

    mapping(bytes32 offerHash => bool) public isOfferRatified;
    bool public acceptAll;
    bool public returnWrongValue;

    function offerHash(Offer memory offer) public pure returns (bytes32) {
        return keccak256(abi.encode(offer));
    }

    function setOfferRatified(Offer memory offer, bool ratified) external {
        isOfferRatified[offerHash(offer)] = ratified;
    }

    function setAcceptAll(bool newAcceptAll) external {
        acceptAll = newAcceptAll;
    }

    function setReturnWrongValue(bool newReturnWrongValue) external {
        returnWrongValue = newReturnWrongValue;
    }

    function isRatified(Offer memory offer, bytes memory, address) external view returns (bytes32) {
        require(acceptAll || isOfferRatified[offerHash(offer)], NotRatified());
        return returnWrongValue ? bytes32(0) : MIDNIGHT_CALLBACK_SUCCESS;
    }
}
