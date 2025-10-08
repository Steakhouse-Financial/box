// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.28;

import {IVaultV2} from "@vault-v2/src/interfaces/IVaultV2.sol";

/// @title Revoker
/// @notice Make a sentinel only able to call revoke on a Vault V2
/// #dev The sentinel address to add to the Vault V2 is this contract address.
contract Revoker {
    address public sentinel;
    IVaultV2 public vault;

    constructor(IVaultV2 _vault, address _sentinel) {
        sentinel = _sentinel;
        vault = _vault;
    }

    function revoke(bytes memory data) external {
        require(msg.sender == sentinel, "Only sentinel can call");
        vault.revoke(data);
    }
}