// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity ^0.8.0;

// Precision for percentage calculations
uint256 constant PRECISION = 1 ether;
// Maximum timelock duration (2 weeks)
uint256 constant TIMELOCK_CAP = 2 weeks;
// Maximum allowed slippage percentage (10%)
uint256 constant MAX_SLIPPAGE_LIMIT = 0.1 ether;
// Delay from start of a shutdown to possible liquidations
uint256 constant SHUTDOWN_WARMUP = 2 weeks;
// Precision for oracle prices
uint256 constant ORACLE_PRECISION = 1e36;
// Maximum expiration time for total assets memoization (1 day)
uint256 constant MAX_TOTAL_ASSETS_MEMOIZATION_EXPIRATION = 1 days;