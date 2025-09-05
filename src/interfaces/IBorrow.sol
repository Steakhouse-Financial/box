// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Steakhouse
pragma solidity >= 0.5.0;

import {IAdapter} from "../../lib/vault-v2/src/interfaces/IAdapter.sol";


struct BorrowPosition {
    uint256 collateral;
    uint256 collateralValue;
    uint256 debt;
    uint256 debtShares;
    uint256 ltv;
    uint256 healthFactor;
}


interface IBorrow {
    /* EVENTS */


    /* ERRORS */


    /* FUNCTIONS */
    function supplyCollateral(bytes calldata data, uint256 assets) external;
    function withdrawCollateral(bytes calldata data, uint256 assets) external;
    function borrow(bytes calldata data, uint256 borrowAmount) external;
    function repay(bytes calldata data, uint256 repayAmount) external;
    function repayShares(bytes calldata data, uint256 shares) external;

    function loanToken(bytes calldata data) external view returns (address);
    function collateralToken(bytes calldata data) external view returns (address);

    function ltv(bytes calldata data, address who) external view returns (uint256);
    function debt(bytes calldata data, address who) external view returns (uint256);
    function debtShares(bytes calldata data, address who) external view returns (uint256);
    function collateral(bytes calldata data, address who) external view returns (uint256);
    
    // Position key functions for NAV deduplication
    function collateralPositionKey(bytes calldata data) external pure returns (bytes32);
    function debtPositionKey(bytes calldata data) external pure returns (bytes32);

}