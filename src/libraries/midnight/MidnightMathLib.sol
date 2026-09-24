// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickLib} from "./TickLib.sol";

/// @title MidnightMathLib
/// @notice Price, units and rate helpers for a borrower selling units into Midnight buy offers (lender bids).
/// @dev Written for Box, not copied from Midnight. Midnight's own `UtilsLib` relies on the Osaka `CLZ` opcode and cannot
/// be compiled for prague; nothing here uses it. All functions are pure and never revert on offer data, so a caller can
/// screen arbitrary offers before calling `take`.
library MidnightMathLib {
    uint256 internal constant WAD = 1e18;

    /// @notice Year length of the simple annual rate convention (same as Morpho's rate ratifier).
    uint256 internal constant YEAR = 365 days;

    /// @notice Price per unit (WAD) received by the seller of a buy offer at `tick` when the settlement fee is `fee`.
    /// @dev Midnight computes `tickToPrice(tick) - fee` and reverts on a tick above `MAX_TICK` or a fee above the price.
    /// Returns 0 instead in those cases, and when the result would be 0 (tick 0, or fee equal to the price), so that a
    /// 0 return always means "unusable offer".
    function sellerPrice(uint256 tick, uint256 fee) internal pure returns (uint256) {
        if (tick > TickLib.MAX_TICK) return 0;
        uint256 price = TickLib.tickToPrice(tick);
        return price > fee ? price - fee : 0;
    }

    /// @notice Units to sell at `price` so that the seller receives at least `sellerAssets`.
    /// @dev Rounded up, so `sellerAssetsOf(unitsForSellerAssets(a, p), p) >= a`. Returns 0 when `price` is 0.
    function unitsForSellerAssets(uint256 sellerAssets, uint256 price) internal pure returns (uint256) {
        if (price == 0) return 0;
        return Math.mulDiv(sellerAssets, WAD, price, Math.Rounding.Ceil);
    }

    /// @notice Loan tokens received for selling `units` at `price`, rounded down like Midnight's `take`.
    function sellerAssetsOf(uint256 units, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(units, price, WAD);
    }

    /// @notice Units a buy offer can still absorb given what its maker already consumed in the offer group.
    /// @param maxUnits The offer units cap (0 if the offer is capped in assets).
    /// @param maxAssets The offer buyer-assets cap (0 if the offer is capped in units).
    /// @param consumed `midnight.consumed(offer.maker, offer.group)`.
    /// @param offerPrice The tick price of the offer (the buyer price, before the settlement fee).
    /// @dev Returns 0 for invalid caps (both or neither set, which `take` rejects) and for a 0 price. For an assets cap,
    /// returns the largest `units` whose buyer assets `floor(units * offerPrice / WAD)` (what Midnight adds to
    /// `consumed`) fit in the remaining assets. Never reverts for Midnight's uint128 caps and consumed amounts.
    function consumableUnitsOfBuyOffer(
        uint256 maxUnits,
        uint256 maxAssets,
        uint256 consumed,
        uint256 offerPrice
    ) internal pure returns (uint256) {
        if ((maxUnits == 0) == (maxAssets == 0)) return 0;
        if (maxUnits > 0) return maxUnits > consumed ? maxUnits - consumed : 0;
        if (offerPrice == 0 || maxAssets <= consumed) return 0;
        uint256 remaining = maxAssets - consumed;
        // units * offerPrice <= remaining * WAD + WAD - 1, split to avoid overflow.
        return Math.mulDiv(remaining, WAD, offerPrice) + (mulmod(remaining, WAD, offerPrice) + WAD - 1) / offerPrice;
    }

    /// @notice Lowest seller price (WAD) whose implied simple annual rate over `timeToMaturity` is at most `maxApr`:
    /// `1 / (1 + maxApr * timeToMaturity / YEAR)`.
    /// @dev Strict: the rate term is rounded down and the division up, so the returned floor is never below the exact
    /// value and accepting `price >= minSellerPrice` never accepts a rate above `maxApr`. Equals WAD when
    /// `timeToMaturity` or `maxApr` is 0.
    function minSellerPrice(uint256 maxApr, uint256 timeToMaturity) internal pure returns (uint256) {
        uint256 rateTerm = Math.mulDiv(maxApr, timeToMaturity, YEAR);
        return Math.mulDiv(WAD, WAD, WAD + rateTerm, Math.Rounding.Ceil);
    }
}
