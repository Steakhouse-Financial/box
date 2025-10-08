// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.28;

import {IVaultV2} from "@vault-v2/src/interfaces/IVaultV2.sol";
import {Revoker} from "./Revoker.sol";

/// @title RevokerFactory
/// @notice Deploy Revoker contracts for a given Vault V2 and sentinel
contract RevokerFactory {
    event RevokerCreated(address vault, address sentinel, address revoker);

    function createRevoker(IVaultV2 vault, address sentinel) external returns (Revoker revoker) {
        revoker = new Revoker(vault, sentinel);

        emit RevokerCreated(address(vault), sentinel, address(revoker));
    }
}
