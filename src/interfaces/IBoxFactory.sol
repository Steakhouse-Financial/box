// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Steakhouse Financial
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBox} from "./IBox.sol";

interface IBoxFactory {    
    
    /* FUNCTIONS */

    function createBox(
        IERC20 _currency,
        address _owner,
        address _curator,
        string memory _name,
        string memory _symbol,
        uint256 _maxSlippage,
        uint256 _slippageEpochDuration,
        uint256 _shutdownSlippageDuration,
        bytes32 salt
    ) external returns (IBox box);
}
