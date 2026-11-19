// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity 0.8.28;

/// @notice Public Euler v2 deployments, vaults, tokens and Box-side oracles referenced by Euler fork tests.
abstract contract EulerAddresses {
    /// @dev Euler's unit of account on both chains (ISO 4217 code of USD)
    address internal constant EULER_USD = 0x0000000000000000000000000000000000000348;

    // ========== ETHEREUM ==========

    address internal constant ETHEREUM_EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address internal constant ETHEREUM_EULER_ROUTER = 0x83B3b76873D36A28440cF53371dF404c42497136;

    address internal constant ETHEREUM_EWETH_2 = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
    address internal constant ETHEREUM_EWSTETH_2 = 0xbC4B4AC47582c3E38Ce5940B80Da65401F4628f1;
    address internal constant ETHEREUM_EUSDC_2 = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address internal constant ETHEREUM_ESUSDE_4 = 0x6bE9e82B25987Ce66AcD89130fEe494EDd0473AE;

    address internal constant ETHEREUM_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ETHEREUM_WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant ETHEREUM_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ETHEREUM_SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    /// @dev Morpho-style oracles (1e36 scale) used as Box oracles
    address internal constant ETHEREUM_WSTETH_WETH_ORACLE = 0x2a01EB9496094dA03c4E364Def50f5aD1280AD72;
    address internal constant ETHEREUM_SUSDE_USDC_ORACLE = 0x873CD44b860DEDFe139f93e12A4AcCa0926Ffb87;

    // ========== BASE ==========

    address internal constant BASE_EVC = 0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989;
    address internal constant BASE_EULER_ROUTER = 0x6E183458600e66047A0f4D356d9DAa480DA1CA59;

    address internal constant BASE_EUSDC_1 = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
    address internal constant BASE_ECBBTC_1 = 0x882018411Bc4A020A879CEE183441fC9fa5D7f8B;
    address internal constant BASE_EWETH_1 = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
    address internal constant BASE_EWSTETH_1 = 0x7b181d6509DEabfbd1A23aF1E65fD46E89572609;

    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant BASE_WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;

    address internal constant BASE_CBBTC_USDC_ORACLE = 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9;
    address internal constant BASE_WSTETH_WETH_ORACLE = 0xaE10cbdAa587646246c8253E4532A002EE4fa7A4;
}
