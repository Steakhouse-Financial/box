// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity 0.8.28;

import {Box} from "./Box.sol";
import {BoxAdapter} from "./BoxAdapter.sol";
import {IBoxAdapter} from "./interfaces/IBoxAdapter.sol";
import {IBoxAdapterFactory} from "./interfaces/IBoxAdapterFactory.sol";

contract BoxAdapterFactory is IBoxAdapterFactory {
    /* STORAGE */

    mapping(address parentVault => mapping(Box box => IBoxAdapter)) public boxAdapter;
    mapping(address account => bool) public isBoxAdapter;

    /* FUNCTIONS */

    /// @dev Returns the address of the deployed BoxAdapter.
    function createBoxAdapter(address parentVault, Box box) external returns (IBoxAdapter) {
        BoxAdapter _boxAdapter = new BoxAdapter{salt: bytes32(0)}(parentVault, box);
        boxAdapter[parentVault][box] = _boxAdapter;
        isBoxAdapter[address(_boxAdapter)] = true;
        emit CreateBoxAdapter(parentVault, address(box), _boxAdapter);
        return _boxAdapter;
    }
}
