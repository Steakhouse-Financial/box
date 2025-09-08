// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @dev Simpply override the OZ ERC20 Mock and add decimals support
contract ERC20MockDecimals is ERC20Mock {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20Mock() {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
