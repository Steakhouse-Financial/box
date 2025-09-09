// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBox} from "./../interfaces/IBox.sol";
import {IOracle} from "./../interfaces/IOracle.sol";
import {ISwapper} from "./../interfaces/ISwapper.sol";
import "./Constants.sol";
import {ErrorsLib} from "./ErrorsLib.sol";

library OperationsLib {
    using SafeERC20 for IERC20;
    using Math for uint256;

    function allocate(
        IERC20 asset,
        IERC20 token,
        uint256 assetsAmount,
        ISwapper swapper,
        bytes calldata data,
        IOracle oracle,
        uint256 slippageTolerance
    ) external returns (uint256 tokensReceived, uint256 assetsSpent, int256 slippage, int256 slippagePct) {
        require(address(swapper) != address(0), ErrorsLib.InvalidAddress());
        require(assetsAmount > 0, ErrorsLib.InvalidAmount());

        uint256 tokensBefore = token.balanceOf(address(this));
        uint256 assetsBefore = asset.balanceOf(address(this));

        asset.forceApprove(address(swapper), assetsAmount);
        swapper.sell(asset, token, assetsAmount, data);

        tokensReceived = token.balanceOf(address(this)) - tokensBefore;
        assetsSpent = assetsBefore - asset.balanceOf(address(this));

        require(assetsSpent <= assetsAmount, ErrorsLib.SwapperDidSpendTooMuch());

        // Validate slippage
        uint256 expectedTokens = assetsAmount.mulDiv(ORACLE_PRECISION, oracle.price());
        uint256 minTokens = expectedTokens.mulDiv(PRECISION - slippageTolerance, PRECISION);
        slippage = int256(expectedTokens) - int256(tokensReceived);
        slippagePct = expectedTokens == 0 ? int256(0) : (slippage * int256(PRECISION)) / int256(expectedTokens);

        require(tokensReceived >= minTokens, ErrorsLib.AllocationTooExpensive());

        // Revoke allowance to prevent residual approvals
        asset.forceApprove(address(swapper), 0);
    }

    function deallocate(
        IERC20 asset,
        IERC20 token,
        uint256 tokensAmount,
        ISwapper swapper,
        bytes calldata data,
        IOracle oracle,
        uint256 slippageTolerance
    ) external returns (uint256 assetsReceived, uint256 tokensSpent, int256 slippage, int256 slippagePct) {
        require(tokensAmount > 0, ErrorsLib.InvalidAmount());
        require(address(swapper) != address(0), ErrorsLib.InvalidAddress());
        require(address(oracle) != address(0), ErrorsLib.NoOracleForToken());

        uint256 assetsBefore = asset.balanceOf(address(this));
        uint256 tokensBefore = token.balanceOf(address(this));

        token.forceApprove(address(swapper), tokensAmount);
        swapper.sell(token, asset, tokensAmount, data);

        assetsReceived = asset.balanceOf(address(this)) - assetsBefore;
        tokensSpent = tokensBefore - token.balanceOf(address(this));

        require(tokensSpent <= tokensAmount, ErrorsLib.SwapperDidSpendTooMuch());

        // Revoke allowance to prevent residual approvals
        token.forceApprove(address(swapper), 0);

        // Validate slippage
        uint256 expectedAssets = tokensAmount.mulDiv(oracle.price(), ORACLE_PRECISION);
        uint256 minAssets = expectedAssets.mulDiv(PRECISION - slippageTolerance, PRECISION);
        slippage = int256(expectedAssets) - int256(assetsReceived);
        slippagePct = expectedAssets == 0 ? int256(0) : (slippage * int256(PRECISION)) / int256(expectedAssets);

        require(assetsReceived >= minAssets, ErrorsLib.TokenSaleNotGeneratingEnoughAssets());
    }

    function _swap(IBox box, ISwapper swapper, bytes calldata swapData, IERC20 fromToken, IERC20 toToken, uint256 amount) internal {
        if (address(fromToken) == box.asset()) {
            box.allocate(toToken, amount, swapper, swapData);
        } else if (address(toToken) == box.asset()) {
            box.deallocate(fromToken, amount, swapper, swapData);
        } else {
            box.reallocate(fromToken, toToken, amount, swapper, swapData);
        }
    }
}
