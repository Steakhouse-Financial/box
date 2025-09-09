// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.13;

import {IMorpho} from "@morpho-blue/interfaces/IMorpho.sol";
import {MathLib} from "@morpho-blue/libraries/MathLib.sol";
import {MorphoLib} from "@morpho-blue/libraries/periphery/MorphoLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBox} from "./interfaces/IBox.sol";
import {IFunding} from "./interfaces/IFunding.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {ErrorsLib} from "./lib/ErrorsLib.sol";

interface IMorphoFlashLoanCallback {
    /// @notice Callback called when a flash loan occurs.
    /// @dev The callback is called only if data is not empty.
    /// @param assets The amount of assets that was flash loaned.
    /// @param data Arbitrary data passed to the `flashLoan` function.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

interface IBoxFlashCallback {
    function onBoxFlash(IERC20 token, uint256 amount, bytes calldata data) external;
}

contract FlashLoanMorpho is IMorphoFlashLoanCallback, IBoxFlashCallback {
    using SafeERC20 for IERC20;
    using MorphoLib for IMorpho;
    using MathLib for uint256;

    IMorpho public immutable MORPHO;

    constructor(IMorpho morpho) {
        MORPHO = morpho;
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        // TODO require morpho only msg.Sender
        require(msg.sender == address(MORPHO), ErrorsLib.OnlyMorpho());

        bytes4 operation = abi.decode(bytes(data), (bytes4));

        IBox box;
        IERC20 loanToken;

        if (operation == FlashLoanMorpho.leverage.selector) {
            (operation, box, , , , loanToken, , , ) = abi.decode(
                data,
                (bytes4, IBox, IFunding, bytes, IERC20, IERC20, uint256, ISwapper, bytes)
            );
        } else if (operation == FlashLoanMorpho.deleverage.selector) {
            (operation, box, , , , , loanToken, , , ) = abi.decode(
                data,
                (bytes4, IBox, IFunding, bytes, IERC20, uint256, IERC20, uint256, ISwapper, bytes)
            );
        } else if (operation == FlashLoanMorpho.refinance.selector) {
            (operation, box, , , , , , , loanToken, ) = abi.decode(
                data,
                (bytes4, IBox, IFunding, bytes, IFunding, bytes, IERC20, uint256, IERC20, uint256)
            );
        } else {
            revert("Invalid operation");
        }

        // Approve the box to pull the flash loan amount
        loanToken.forceApprove(address(box), assets);

        // Call box.flash which will call back to us
        box.flash(loanToken, assets, data);

        // Repay the flash loan to Morpho
        loanToken.forceApprove(msg.sender, assets);
    }

    function onBoxFlash(IERC20 token, uint256 amount, bytes calldata data) external {
        bytes4 operation = abi.decode(bytes(data), (bytes4));

        IBox box = IBox(msg.sender);
        IFunding fundingModule;
        bytes memory facilityData;
        IFunding fundingModule2;
        bytes memory facilityData2;
        IERC20 collateralToken;
        uint256 collateralAmount;
        IERC20 loanToken;
        uint256 loanAmount;
        ISwapper swapper;
        bytes memory swapData;

        if (operation == FlashLoanMorpho.leverage.selector) {
            (operation, , fundingModule, facilityData, collateralToken, loanToken, loanAmount, swapper, swapData) = abi.decode(
                data,
                (bytes4, IBox, IFunding, bytes, IERC20, IERC20, uint256, ISwapper, bytes)
            );

            // At this point, the Box already has the flash loan tokens (transferred by box.flash)

            // Record collateral balance before swap
            uint256 beforeCollateral = collateralToken.balanceOf(address(box));

            // Have Box perform the swap using its allocation functions
            if (address(loanToken) == box.asset()) {
                box.allocate(collateralToken, loanAmount, swapper, swapData);
            } else if (address(collateralToken) == box.asset()) {
                box.deallocate(loanToken, loanAmount, swapper, swapData);
            } else {
                box.reallocate(loanToken, collateralToken, loanAmount, swapper, swapData);
            }

            // Check how much collateral was received in the Box
            uint256 afterCollateral = collateralToken.balanceOf(address(box));
            uint256 collateralReceived = afterCollateral - beforeCollateral;

            // Have the Box pledge its own collateral to the funding module
            box.pledge(fundingModule, facilityData, collateralToken, collateralReceived);

            // Have the Box borrow loan tokens (they go to the Box)
            box.borrow(fundingModule, facilityData, loanToken, loanAmount);

            // The borrowed tokens are now in the Box and will be transferred back by box.flash()
        } else if (operation == FlashLoanMorpho.deleverage.selector) {
            (operation, , fundingModule, facilityData, collateralToken, collateralAmount, loanToken, loanAmount, swapper, swapData) = abi
                .decode(data, (bytes4, IBox, IFunding, bytes, IERC20, uint256, IERC20, uint256, ISwapper, bytes));

            // Deleverage: repay debt, withdraw collateral, swap collateral to loan tokens
            if (loanAmount == type(uint256).max) {
                loanAmount = fundingModule.debtBalance(loanToken);
            }

            // The Box already has the flash loan tokens, use them to repay debt
            box.repay(fundingModule, facilityData, loanToken, loanAmount);

            // Withdraw collateral (goes to the Box)
            box.depledge(fundingModule, facilityData, collateralToken, collateralAmount);

            // Have the Box swap its collateral tokens to loan tokens
            if (address(loanToken) == box.asset()) {
                // Convert collateral tokens to base asset (loan token)
                box.deallocate(collateralToken, collateralAmount, swapper, swapData);
            } else if (address(collateralToken) == box.asset()) {
                // This shouldn't happen in deleverage - collateral should not be base asset
                revert("Invalid deleverage: collateral cannot be base asset");
            } else {
                // Convert from collateral token to loan token
                box.reallocate(collateralToken, loanToken, collateralAmount, swapper, swapData);
            }
        } else if (operation == FlashLoanMorpho.refinance.selector) {
            (
                operation,
                ,
                fundingModule,
                facilityData,
                fundingModule2,
                facilityData2,
                collateralToken,
                collateralAmount,
                loanToken,
                loanAmount
            ) = abi.decode(data, (bytes4, IBox, IFunding, bytes, IFunding, bytes, IERC20, uint256, IERC20, uint256));

            // Refinance: repay old debt, withdraw collateral, pledge to new module, borrow from new module
            if (loanAmount == type(uint256).max) {
                loanAmount = fundingModule.debtBalance(loanToken);
            }
            if (collateralAmount == type(uint256).max) {
                collateralAmount = fundingModule.collateralBalance(collateralToken);
            }

            // Repay the old debt
            loanToken.forceApprove(address(box), loanAmount);
            box.repay(fundingModule, facilityData, loanToken, loanAmount);

            // Withdraw collateral from old module
            box.depledge(fundingModule, facilityData, collateralToken, collateralAmount);

            // Pledge collateral to new module
            collateralToken.forceApprove(address(box), collateralAmount);
            box.pledge(fundingModule2, facilityData2, collateralToken, collateralAmount);

            // Borrow from new module
            box.borrow(fundingModule2, facilityData2, loanToken, loanAmount);
        } else {
            revert("Invalid operation");
        }
    }

    function leverage(
        IBox box,
        IFunding fundingModule,
        bytes calldata facilityData,
        ISwapper swapper,
        bytes calldata swapData,
        IERC20 collateralToken,
        IERC20 loanToken,
        uint256 loanAmount
    ) external {
        require(box.isAllocator(msg.sender), ErrorsLib.OnlyAllocators());

        bytes4 operation = FlashLoanMorpho.leverage.selector;
        bytes memory data = abi.encode(
            operation,
            address(box),
            fundingModule,
            facilityData,
            collateralToken,
            loanToken,
            loanAmount,
            swapper,
            swapData
        );

        MORPHO.flashLoan(address(loanToken), loanAmount, data);
    }

    function deleverage(
        IBox box,
        IFunding fundingModule,
        bytes calldata facilityData,
        ISwapper swapper,
        bytes calldata swapData,
        IERC20 collateralToken,
        uint256 collateralAmount,
        IERC20 loanToken,
        uint256 loanAmount
    ) external {
        require(box.isAllocator(msg.sender), ErrorsLib.OnlyAllocators());

        if (loanAmount == type(uint256).max) {
            loanAmount = fundingModule.debtBalance(loanToken);
        }

        bytes4 operation = FlashLoanMorpho.deleverage.selector;
        bytes memory data = abi.encode(
            operation,
            address(box),
            fundingModule,
            facilityData,
            collateralToken,
            collateralAmount,
            loanToken,
            loanAmount,
            swapper,
            swapData
        );

        MORPHO.flashLoan(address(loanToken), loanAmount, data);
    }

    function refinance(
        IBox box,
        IFunding fromFundingModule,
        bytes calldata fromFacilityData,
        IFunding toFundingModule,
        bytes calldata toFacilityData,
        IERC20 collateralToken,
        uint256 collateralAmount,
        IERC20 loanToken,
        uint256 loanAmount
    ) external {
        require(box.isAllocator(msg.sender), ErrorsLib.OnlyAllocators());

        if (loanAmount == type(uint256).max) {
            loanAmount = fromFundingModule.debtBalance(loanToken);
        }
        if (collateralAmount == type(uint256).max) {
            collateralAmount = fromFundingModule.collateralBalance(collateralToken);
        }

        bytes4 operation = FlashLoanMorpho.refinance.selector;
        bytes memory data = abi.encode(
            operation,
            address(box),
            fromFundingModule,
            fromFacilityData,
            toFundingModule,
            toFacilityData,
            collateralToken,
            collateralAmount,
            loanToken,
            loanAmount
        );

        MORPHO.flashLoan(address(loanToken), loanAmount, data);
    }
}
