// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity 0.8.28;

import {Box} from "./Box.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/ISwapper.sol";
import "./interfaces/IBoxFactory.sol";
import "./lib/Errors.sol";
import "./lib/ConstantsLib.sol";

contract BoxFactory is IBoxFactory {
    /* STORAGE */

    mapping(address account => bool) public isBox;

    /* FUNCTIONS */

    /// @dev Returns the address of the deployed BoxAdapter.
    function createBox(      
        IERC20 _currency,
        address _owner,
        address _curator,
        string memory _name,
        string memory _symbol,
        uint256 _maxSlippage,
        uint256 _slippageEpochDuration,
        uint256 _shutdownSlippageDuration,
        bytes32 salt) external returns (Box) {
        Box _box = new Box{salt:salt}(_currency,
            _owner,
            _curator,
            _name,
            _symbol,
            _maxSlippage,
            _slippageEpochDuration,
            _shutdownSlippageDuration);
        emit CreateBox(_currency,
            _owner,
            _curator,
            _name,
            _symbol,
            _maxSlippage,
            _slippageEpochDuration,
            _shutdownSlippageDuration,
            salt,
            _box);
        return _box;
    }
}
