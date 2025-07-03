// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {MorphoVaultV1Adapter} from "@vault-v2/src/adapters/MorphoVaultV1Adapter.sol";

library MorphoVaultV1AdapterLib {
    /// @notice Returns the data to be used in the VaultV2 for the MetaMorpho adapter
    function data(MorphoVaultV1Adapter adapter) internal pure returns (bytes memory) {
        return abi.encode("adapter", adapter);
    }

    /// @notice Returns the id to be used in the VaultV2 for the MetaMorpho adapter
    function id(MorphoVaultV1Adapter adapter) internal pure returns (bytes32) {
        return keccak256(abi.encode("adapter", adapter));
    }
}
