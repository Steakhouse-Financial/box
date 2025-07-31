// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association, Steakhouse Financial
pragma solidity >=0.5.0;

import {Box} from "../Box.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBoxFactory {
    /* EVENTS */

    event CreateBox(
        IERC20 indexed currency,
        Box indexed vaultAddress,
        address indexed owner,
        address curator,
        string name,
        string symbol,
        uint256 maxSlippage,
        uint256 slippageEpochDuration,
        uint256 shutdownSlippageDuration
    );

    /* FUNCTIONS */

    function isBox(address account) external view returns (bool);
    function createBox(    
        IERC20 _currency,
        address _owner,
        address _curator,
        string memory _name,
        string memory _symbol,
        uint256 _maxSlippage,
        uint256 _slippageEpochDuration,
        uint256 _shutdownSlippageDuration)
        external
        returns (Box box);
}
