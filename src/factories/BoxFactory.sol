// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBox} from "../interfaces/IBox.sol";
import {IBoxFactory} from "../interfaces/IBoxFactory.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";
import {Box} from "../Box.sol";

contract BoxFactory is IBoxFactory {

    /* FUNCTIONS */

    /// @dev Returns the address of the deployed BoxAdapter.
    function createBox(
        IERC20 _asset,
        address _owner,
        address _curator,
        string memory _name,
        string memory _symbol,
        uint256 _maxSlippage,
        uint256 _slippageEpochDuration,
        uint256 _shutdownSlippageDuration,
        bytes32 salt
    ) external returns (IBox) {
        IBox _box = new Box{salt: salt}(
            address(_asset),
            _owner,
            _curator,
            _name,
            _symbol,
            _maxSlippage,
            _slippageEpochDuration,
            _shutdownSlippageDuration
        );

        return _box;
    }
}
