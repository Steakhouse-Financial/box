// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association, Steakhouse Financial
pragma solidity ^0.8.28;

import {BoxAdapterCached} from "./../BoxAdapterCached.sol";
import {IBox} from "./../interfaces/IBox.sol";
import {IBoxAdapter} from "./../interfaces/IBoxAdapter.sol";
import {IBoxAdapterFactory} from "./../interfaces/IBoxAdapterFactory.sol";

contract BoxAdapterCachedFactory is IBoxAdapterFactory {
    /* STORAGE */

    mapping(address parentVault => mapping(IBox box => IBoxAdapter)) public boxAdapter;
    mapping(address account => bool) public isBoxAdapter;

    /* FUNCTIONS */

    /// @dev Returns the address of the deployed BoxAdapter.
    function createBoxAdapter(address parentVault, IBox box) external returns (IBoxAdapter) {
        BoxAdapterCached _boxAdapter = new BoxAdapterCached(parentVault, box);
        boxAdapter[parentVault][box] = _boxAdapter;
        isBoxAdapter[address(_boxAdapter)] = true;
        emit CreateBoxAdapter(parentVault, address(box), _boxAdapter);
        return _boxAdapter;
    }
}
