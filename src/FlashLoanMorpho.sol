// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.13;

import {IBorrow} from "./interfaces/IBorrow.sol";
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
        IBorrow borrowAdapter;
        bytes memory borrowData;
        IBorrow borrowAdapter2;
        bytes memory borrowData2;
        IERC20 collateral;
        uint256 collateralAmount;
        IERC20 loanAsset;
        uint256 loanAmount;
        ISwapper swapper;
        bytes memory swapData;

        if (operation == FlashLoanMorpho.wind.selector) {
            (operation, box, borrowAdapter, borrowData, collateral,
                loanAsset, loanAmount, swapper, swapData) = abi.decode(data,
                (bytes4, IBox, IBorrow, bytes, IERC20, IERC20, uint256, ISwapper, bytes));

            // The flash loan is allowed for the box to grab
            loanAsset.forceApprove(address(box), assets);
            box.wind(address(this), borrowAdapter, borrowData, swapper, swapData, collateral, loanAsset, loanAmount);

        } else if (operation == FlashLoanMorpho.unwind.selector) {

            (operation, box, borrowAdapter, borrowData, collateral, collateralAmount,
                loanAsset, loanAmount, swapper, swapData) = abi.decode(data,
                (bytes4, IBox, IBorrow, bytes, IERC20, uint256, IERC20, uint256, ISwapper, bytes));

            // The flash loan is allowed for the box to grab
            loanAsset.forceApprove(address(box), assets);
            box.unwind(address(this), borrowAdapter, borrowData, swapper, swapData, collateral, collateralAmount, 
                loanAsset, loanAmount);       

        } else if (operation == FlashLoanMorpho.shift.selector) {

            (operation, box, borrowAdapter, borrowData, borrowAdapter2, borrowData2,
                collateral, collateralAmount, loanAsset, loanAmount) = abi.decode(data,
                (bytes4, IBox, IBorrow, bytes, IBorrow, bytes, IERC20, uint256, IERC20, uint256));

            // The flash loan is allowed for the box to grab
            loanAsset.forceApprove(address(box), assets);
            box.shift(address(this), borrowAdapter, borrowData, borrowAdapter2, borrowData2, collateral, collateralAmount, 
                loanAsset, loanAmount);

        } else {
            revert("Invalid operation");
        }

        // Repay the flash loan
        loanAsset.forceApprove(msg.sender, assets);

    }

    function wind(IBox box, IBorrow borrow, bytes calldata borrowData, 
        ISwapper swapper, bytes calldata swapData, 
        IERC20 collateral, IERC20 loanAsset, uint256 loanAmount) external {

        require(box.isAllocator(msg.sender), ErrorsLib.OnlyAllocators());

        bytes4 operation = FlashLoanMorpho.wind.selector;
        bytes memory data = abi.encode(operation, address(box), borrow, borrowData, collateral, loanAsset, 
            loanAmount, swapper, swapData);
        MORPHO.flashLoan(address(loanAsset), loanAmount, data);
    }

    function unwind(IBox box, IBorrow borrow, bytes calldata borrowData, 
        ISwapper swapper, bytes calldata swapData, 
        IERC20 collateral, uint256 collateralAmount, IERC20 loanAsset, uint256 loanAmount) external {

        require(box.isAllocator(msg.sender), ErrorsLib.OnlyAllocators());

        if(loanAmount == type(uint256).max) {
            loanAmount = borrow.debt(borrowData, address(box));
        }

        bytes4 operation = FlashLoanMorpho.unwind.selector;
        bytes memory data = abi.encode(operation, address(box), borrow, borrowData, collateral, collateralAmount, 
            loanAsset, loanAmount, swapper, swapData);
        MORPHO.flashLoan(address(loanAsset), loanAmount, data);
    }

    function shift(IBox box, 
        IBorrow fromBorrow, bytes calldata fromBorrowData, 
        IBorrow toBorrow, bytes calldata toBorrowData,
        IERC20 collateral, uint256 collateralAmount, IERC20 loanAsset, uint256 loanAmount) external {

        require(box.isAllocator(msg.sender), ErrorsLib.OnlyAllocators());

        if(loanAmount == type(uint256).max) {
            loanAmount = fromBorrow.debt(fromBorrowData, address(box));
        }

        bytes4 operation = FlashLoanMorpho.shift.selector;
        bytes memory data = abi.encode(operation, address(box), 
            fromBorrow, fromBorrowData, toBorrow, toBorrowData,
            collateral, collateralAmount, loanAsset, loanAmount);
        MORPHO.flashLoan(address(loanAsset), loanAmount, data);
    }

}