// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association, Steakhouse Financial
pragma solidity >=0.5.0;

import {IBoxAdapter} from "./IBoxAdapter.sol";
import {Box} from "../Box.sol";

interface IBoxAdapterFactory {
    /* EVENTS */

    event CreateBoxAdapter(
        address indexed parentVault, address indexed box, IBoxAdapter indexed boxAdapter
    );

    /* FUNCTIONS */

    function boxAdapter(address parentVault, Box box) external view returns (IBoxAdapter);
    function isBoxAdapter(address account) external view returns (bool);
    function createBoxAdapter(address parentVault, Box box)
        external
        returns (IBoxAdapter boxAdapter);
}
