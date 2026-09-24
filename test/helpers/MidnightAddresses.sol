// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity 0.8.28;

/// @notice Public Midnight deployments, tokens and oracles referenced by Midnight tests.
abstract contract MidnightAddresses {
    // ========== BASE ==========

    uint256 internal constant BASE_CHAIN_ID = 8453;
    address internal constant BASE_MIDNIGHT = 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant BASE_CBBTC_USDC_ORACLE = 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9;
    address internal constant BASE_USDC_USDC_ORACLE = 0x4429112b3C00b40Cf295db81cfcdE39d7d5ADC1d;

    // ========== ETHEREUM ==========

    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    address internal constant ETHEREUM_MIDNIGHT = 0x471686c42792F93528B000beF54bC10E3aa2045f;
    address internal constant ETHEREUM_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ETHEREUM_WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant ETHEREUM_WBTC_USDC_ORACLE = 0xDddd770BADd886dF3864029e4B377B5F6a2B6b83;
    address internal constant ETHEREUM_USDC_USDC_ORACLE = 0x8d1A84515B54C58bAc3b18315B6b1f17dA5cf6ca;
}
