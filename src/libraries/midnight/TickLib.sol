// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association, Steakhouse Financial
pragma solidity 0.8.28;

// Adapted from Morpho Midnight's `TickLib.sol`: same arithmetic, constants moved into the library, `priceToTick` removed.
// Uses no Osaka opcode, so it compiles for the prague EVM.

/// @title TickLib
/// @notice Midnight tick to price conversion: `price = 1 / (1 + 1.005^(MAX_TICK / 2 - tick))`, WAD, rounded to 1e-7.
library TickLib {
    /// @dev floor(ln(1.005) * 1e18)
    int256 internal constant LN_ONE_PLUS_DELTA = 0.004987541511039073e18;
    uint256 internal constant MAX_TICK = 6744;
    /// @dev Tick prices are rounded to multiples of this value (1e-7 WAD).
    uint256 internal constant PRICE_ROUNDING_STEP = 1e11;

    error TickOutOfRange();

    /// @dev Returns x / d rounded to the nearest integer with ties rounded down, without checking for overflow.
    function divHalfDownUnchecked(uint256 x, uint256 d) internal pure returns (uint256) {
        unchecked {
            return (x + (d - 1) / 2) / d;
        }
    }

    function wExp(int256 x) internal pure returns (uint256) {
        unchecked {
            if (x < 0) {
                return 1e36 / wExp(-x);
            } else {
                int256 ln2 = 0.693147180559945309e18; // floor(ln(2) * 1e18)
                // offset is chosen such that 2 * expR(-offset) == expR(ln2 - offset - 1), so wExp is non-decreasing.
                int256 offset = 0.32261121498945987e18;
                int256 q = (x + offset) / ln2;
                int256 r = x - q * ln2;
                int256 secondTerm = (r * r) / (2 * 1e18);
                int256 thirdTerm = (secondTerm * r) / (3 * 1e18);
                int256 expR = 1e18 + r + secondTerm + thirdTerm;
                // q is non-negative because x is non-negative in this branch.
                // expR is positive because |r| < ln2 < 1e18 and |secondTerm| > |thirdTerm|.
                return uint256(expR) << uint256(q);
            }
        }
    }

    /// @notice Price (WAD) of `tick`. Tick 0 has price 0 and `MAX_TICK` has price 1e18.
    /// @dev Reverts `TickOutOfRange` if `tick > MAX_TICK`.
    function tickToPrice(uint256 tick) internal pure returns (uint256) {
        require(tick <= MAX_TICK, TickOutOfRange());
        unchecked {
            return
                divHalfDownUnchecked(
                    divHalfDownUnchecked(uint256(1e36), 1e18 + wExp(LN_ONE_PLUS_DELTA * (int256(MAX_TICK / 2) - int256(tick)))),
                    PRICE_ROUNDING_STEP
                ) * PRICE_ROUNDING_STEP;
        }
    }
}
