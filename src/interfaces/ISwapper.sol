// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISwapper {
    function sell(IERC20 input, IERC20 output, uint256 amountIn, bytes calldata data) external;
} 