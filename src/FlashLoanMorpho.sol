// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.13;

import {IFunding} from "./interfaces/IFunding.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IBox} from "./interfaces/IBox.sol";
import {IMorpho, Id, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MathLib} from "../lib/morpho-blue/src/libraries/MathLib.sol";
import {MorphoBalancesLib} from "@morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoLib} from "@morpho-blue/libraries/periphery/MorphoLib.sol";
import "@morpho-blue/libraries/ConstantsLib.sol";

import {ErrorsLib} from "./lib/ErrorsLib.sol";

interface IMorphoFlashLoanCallback {
    /// @notice Callback called when a flash loan occurs.
    /// @dev The callback is called only if data is not empty.
    /// @param assets The amount of assets that was flash loaned.
    /// @param data Arbitrary data passed to the `flashLoan` function.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

contract FlashLoanMorpho is IMorphoFlashLoanCallback {
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
            (operation, box, fundingModule, facilityData, collateralToken,
                loanToken, loanAmount, swapper, swapData) = abi.decode(data,
                (bytes4, IBox, IFunding, bytes, IERC20, IERC20, uint256, ISwapper, bytes));

            // The flash loan is allowed for the box to grab
            loanToken.forceApprove(address(box), assets);
            box.leverage(address(this), fundingModule, facilityData, swapper, swapData, collateralToken, loanToken, loanAmount);

        } else if (operation == FlashLoanMorpho.deleverage.selector) {

            (operation, box, fundingModule, facilityData, collateralToken, collateralAmount,
                loanToken, loanAmount, swapper, swapData) = abi.decode(data,
                (bytes4, IBox, IFunding, bytes, IERC20, uint256, IERC20, uint256, ISwapper, bytes));

            // The flash loan is allowed for the box to grab
            loanToken.forceApprove(address(box), assets);
            box.deleverage(address(this), fundingModule, facilityData, swapper, swapData, collateralToken, collateralAmount,
                loanToken, loanAmount);

        } else if (operation == FlashLoanMorpho.refinance.selector) {

            (operation, box, fundingModule, facilityData, fundingModule2, facilityData2,
                collateralToken, collateralAmount, loanToken, loanAmount) = abi.decode(data,
                (bytes4, IBox, IFunding, bytes, IFunding, bytes, IERC20, uint256, IERC20, uint256));

            // The flash loan is allowed for the box to grab
            loanToken.forceApprove(address(box), assets);
            box.refinance(address(this), fundingModule, facilityData, fundingModule2, facilityData2, collateralToken, collateralAmount,
                loanToken, loanAmount);

        } else {
            revert("Invalid operation");
        }

        // Repay the flash loan
        loanToken.forceApprove(msg.sender, assets);

    }

    function leverage(IBox box, IFunding fundingModule, bytes calldata facilityData, 
        ISwapper swapper, bytes calldata swapData, 
        IERC20 collateralToken, IERC20 loanToken, uint256 loanAmount) external {

        require(box.isAllocator(msg.sender), ErrorsLib.OnlyAllocators());

        bytes4 operation = FlashLoanMorpho.leverage.selector;
        bytes memory data = abi.encode(operation, address(box), fundingModule, facilityData, collateralToken, loanToken,
            loanAmount, swapper, swapData);
        MORPHO.flashLoan(address(loanToken), loanAmount, data);
    }

    function deleverage(IBox box, IFunding fundingModule, bytes calldata facilityData, 
        ISwapper swapper, bytes calldata swapData, 
        IERC20 collateralToken, uint256 collateralAmount, IERC20 loanToken, uint256 loanAmount) external {

        require(box.isAllocator(msg.sender), ErrorsLib.OnlyAllocators());

        if(loanAmount == type(uint256).max) {
            loanAmount = fundingModule.debtBalance(loanToken);
        }

        bytes4 operation = FlashLoanMorpho.deleverage.selector;
        bytes memory data = abi.encode(operation, address(box), fundingModule, facilityData, collateralToken, collateralAmount, 
            loanToken, loanAmount, swapper, swapData);
        MORPHO.flashLoan(address(loanToken), loanAmount, data);
    }

    function refinance(IBox box, 
        IFunding fromFundingModule, bytes calldata fromFacilityData, 
        IFunding toFundingModule, bytes calldata toFacilityData,
        IERC20 collateralToken, uint256 collateralAmount, IERC20 loanToken, uint256 loanAmount) external {

        require(box.isAllocator(msg.sender), ErrorsLib.OnlyAllocators());

        if(loanAmount == type(uint256).max) {
            loanAmount = fromFundingModule.debtBalance(loanToken);
        }
        if(collateralAmount == type(uint256).max) {
            collateralAmount = fromFundingModule.collateralBalance(collateralToken);
        }

        bytes4 operation = FlashLoanMorpho.refinance.selector;
        bytes memory data = abi.encode(operation, address(box), 
            fromFundingModule, fromFacilityData, toFundingModule, toFacilityData,
            collateralToken, collateralAmount, loanToken, loanAmount);
        MORPHO.flashLoan(address(loanToken), loanAmount, data);
    }

}