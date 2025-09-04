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


    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        // require morpho only msg.Sender


        // Decode data to get the operation type and other parameters
        (bytes4 operation, uint256 loanAmount, IBox box, IBorrow borrowAdapter, bytes memory borrowData, 
            IERC20 collateral, IERC20 loanAsset, ISwapper swapper, bytes memory swapData) 
            = abi.decode(data, (bytes4, uint256, IBox, IBorrow, bytes, IERC20, IERC20, ISwapper, bytes));

        if (operation == FlashLoanMorpho.wind.selector) {
            // The flash loan is sent to the box
            loanAsset.forceApprove(address(box), assets);
            box.wind(address(this), borrowAdapter, borrowData, swapper, swapData, collateral, loanAsset, loanAmount);
        } else if (operation == FlashLoanMorpho.unwind.selector) {

        } else {
            revert("Invalid operation");
        }

        // Repay the flash loan
        loanAsset.forceApprove(msg.sender, assets);

    }

    function wind(IBox box, IMorpho morpho, IBorrow borrow, bytes calldata borrowData, 
        ISwapper swapper, bytes calldata swapData, 
        IERC20 collateral, IERC20 loanAsset, uint256 loanAmount) external {

        bytes4 operation = FlashLoanMorpho.wind.selector;
        bytes memory data = abi.encode(operation, loanAmount, address(box), borrow, borrowData, collateral, loanAsset, swapper, swapData);
        morpho.flashLoan(address(loanAsset), loanAmount, data);
    }

    function unwind(IBox box, IMorpho morpho, IBorrow borrow, bytes calldata borrowData, 
        ISwapper swapper, bytes calldata swapData, 
        IERC20 collateral, uint256 collateralAmount, IERC20 loanAsset, uint256 loanAmount) external {

        if(loanAmount == type(uint256).max) {
            loanAmount = borrow.debt(borrowData, address(box));
        }

        bytes4 operation = FlashLoanMorpho.unwind.selector;
        bytes memory data = abi.encode(operation, loanAmount, address(box), borrow, borrowData, collateral, loanAsset, swapper, swapData);
        morpho.flashLoan(address(loanAsset), loanAmount, data);
    }

}