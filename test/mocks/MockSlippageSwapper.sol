// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";
import {ERC20MockDecimals} from "./ERC20MockDecimals.sol";

/// @dev Swapper between a Box asset and one Box token, priced with the Box oracle of that token.
/// The quote is rounded up like Box's expected amount, so a zero slippage delivers exactly what Box expects.
/// Output tokens are minted, and `overspend` extra input tokens are burned from the seller to simulate a swapper
/// spending more than it was approved for.
contract MockSlippageSwapper is ISwapper {
    using SafeERC20 for IERC20;
    using Math for uint256;

    address public immutable asset;
    IOracle public immutable oracle;
    uint256 public slippage;
    uint256 public overspend;

    constructor(address asset_, IOracle oracle_) {
        asset = asset_;
        oracle = oracle_;
    }

    function setSlippage(uint256 slippage_) external {
        slippage = slippage_;
    }

    function setOverspend(uint256 overspend_) external {
        overspend = overspend_;
    }

    function quote(address input, uint256 amountIn) public view returns (uint256) {
        uint256 fairOut = input == asset
            ? amountIn.mulDiv(1e36, oracle.price(), Math.Rounding.Ceil)
            : amountIn.mulDiv(oracle.price(), 1e36, Math.Rounding.Ceil);
        return fairOut.mulDiv(1e18 - slippage, 1e18);
    }

    function sell(IERC20 input, IERC20 output, uint256 amountIn, bytes calldata) external {
        input.safeTransferFrom(msg.sender, address(this), amountIn);
        if (overspend > 0) ERC20MockDecimals(address(input)).burn(msg.sender, overspend);
        ERC20MockDecimals(address(output)).mint(msg.sender, quote(address(input), amountIn));
    }
}
