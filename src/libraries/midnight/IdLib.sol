// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association, Steakhouse Financial
pragma solidity 0.8.28;

// Adapted from Morpho Midnight's `IdLib.sol`: only the id derivation is kept.

import {Market} from "../../interfaces/midnight/IMidnight.sol";

/// @title IdLib
/// @notice Midnight market id: the CREATE2 address hash of the market stored as SSTORE2 code, deployed by
/// `market.midnight` with salt 0. Any change to any market field (including `chainId` and `midnight`) changes the id.
library IdLib {
    /// @dev Creation-code prefix that deploys the appended data as runtime bytecode.
    bytes internal constant SSTORE2_PREFIX = hex"600b380380600b5f395ff3";

    function toId(Market memory market) internal pure returns (bytes32) {
        // No encodePacked ambiguity: SSTORE2_PREFIX has a fixed size.
        return
            keccak256(
                abi.encodePacked(uint8(0xff), market.midnight, uint256(0), keccak256(abi.encodePacked(SSTORE2_PREFIX, abi.encode(market))))
            );
    }
}
