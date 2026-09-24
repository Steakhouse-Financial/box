// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity >=0.8.0;

/// @title IPriceOracle
/// @notice Minimal hand-written interface for the Euler price oracle (EulerRouter) quote used by FundingEuler.
/// @dev Signature matches the upstream EVK `IPriceOracle` (GPL-2.0-or-later).
interface IPriceOracle {
    /// @notice Mid-price value of `inAmount` of `base` in units of `quote`
    function getQuote(uint256 inAmount, address base, address quote) external view returns (uint256 outAmount);
}
