// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBox} from "../interfaces/IBox.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";
import {IBorrow} from "../interfaces/IBorrow.sol";
import {ErrorsLib} from "./ErrorsLib.sol";
import "./Constants.sol";

library OperationsLib {
    using SafeERC20 for IERC20;
    using Math for uint256;


    function allocate(
        IERC20 asset,
        IERC20 token,
        uint256 assetsAmount,
        uint256 maxSlippage,
        IOracle oracle,
        ISwapper swapper,
        bytes calldata data
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
        uint256 minTokens = expectedTokens.mulDiv(PRECISION - maxSlippage, PRECISION);
        slippage = int256(expectedTokens) - int256(tokensReceived);
        slippagePct = expectedTokens == 0 ? int256(0) : slippage * int256(PRECISION) / int256(expectedTokens);

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
        address boxAddress,
        uint256 slippageTolerance
    ) external returns (uint256 assetsReceived, uint256 tokensSpent, int256 slippage, int256 slippagePct) {
        require(tokensAmount > 0, ErrorsLib.InvalidAmount());
        require(address(swapper) != address(0), ErrorsLib.InvalidAddress());
        require(address(oracle) != address(0), ErrorsLib.NoOracleForToken());

        uint256 assetsBefore = asset.balanceOf(boxAddress);
        uint256 tokensBefore = token.balanceOf(boxAddress);

        token.forceApprove(address(swapper), tokensAmount);
        swapper.sell(token, asset, tokensAmount, data);

        assetsReceived = asset.balanceOf(boxAddress) - assetsBefore;
        tokensSpent = tokensBefore - token.balanceOf(boxAddress);

        require(tokensSpent <= tokensAmount, ErrorsLib.SwapperDidSpendTooMuch());

        // Revoke allowance to prevent residual approvals
        token.forceApprove(address(swapper), 0);

        // Validate slippage
        uint256 expectedAssets = tokensAmount.mulDiv(oracle.price(), ORACLE_PRECISION);
        uint256 minAssets = expectedAssets.mulDiv(PRECISION - slippageTolerance, PRECISION);
        slippage = int256(expectedAssets) - int256(assetsReceived);
        slippagePct = expectedAssets == 0 ? int256(0) : slippage * int256(PRECISION) / int256(expectedAssets);

        require(assetsReceived >= minAssets, ErrorsLib.TokenSaleNotGeneratingEnoughAssets());
    }


    function _swap(IBox box, ISwapper swapper, bytes calldata swapData, IERC20 fromToken, IERC20 toToken, uint256 amount) internal {
        if(address(fromToken) == box.asset()) {
            box.allocate(toToken, amount, swapper, swapData);
        }
        else if(address(toToken) == box.asset()) {
            box.deallocate(fromToken, amount, swapper, swapData);
        }
        else {
            box.reallocate(fromToken, toToken, amount, swapper, swapData);
        }

    }

    function wind(IBox box, address flashloanProvider, 
        IBorrow borrowAdapter, bytes calldata borrowData, 
        ISwapper swapper, bytes calldata swapData, 
        IERC20 collateral, IERC20 loanAsset, uint256 loanAmount) external {

        // To be able to repay the flashloan
        loanAsset.transferFrom(flashloanProvider, address(this), loanAmount);

        uint256 before = collateral.balanceOf(address(this));
        _swap(box, swapper, swapData, loanAsset, collateral, loanAmount);
        uint256 afterBalance = collateral.balanceOf(address(this));
        box.supplyCollateral(borrowAdapter, borrowData, afterBalance - before);
        box.borrow(borrowAdapter, borrowData, loanAmount);

        // So the adapter can repay the flash loan
        loanAsset.safeTransfer(flashloanProvider, loanAmount);
    }


    function unwind(IBox box, address flashloanProvider, 
        IBorrow borrowAdapter, bytes calldata borrowData, 
        ISwapper swapper, bytes calldata swapData, 
        IERC20 collateral, uint256 collateralAmount, IERC20 loanAsset, uint256 loanAmount) external {

        if(loanAmount == type(uint256).max) {
            loanAmount = borrowAdapter.debt(borrowData, address(this));
        }

        // To be able to repay the flashloan
        loanAsset.transferFrom(flashloanProvider, address(this), loanAmount);

        box.repay(borrowAdapter, borrowData, loanAmount);
        box.withdrawCollateral(borrowAdapter, borrowData, collateralAmount);

        _swap(box, swapper, swapData, collateral, loanAsset, collateralAmount);

        // So the adapter can repay the flash loan
        loanAsset.safeTransfer(flashloanProvider, loanAmount);
    }

}