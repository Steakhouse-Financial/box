// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association, Steakhouse Financial
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Box} from "./../Box.sol";

interface IBoxFactory {
    /* EVENTS */

    event CreateBox(
        IERC20 indexed currency,
        address indexed owner,
        address curator,
        string name,
        string symbol,
        uint256 maxSlippage,
        uint256 slippageEpochDuration,
        uint256 shutdownSlippageDuration,
        bytes32 salt,
        Box indexed boxAddress
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
        uint256 _shutdownSlippageDuration,
        bytes32 salt
    ) external returns (Box box);
}
