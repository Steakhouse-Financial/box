// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISwapper {
    function swap(IERC20 input, IERC20 output, uint256 amountIn) external;
} 