// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOracleCallback} from "../../src/interfaces/IFunding.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";

/// @notice Stand-in for the Box as the `IOracleCallback` of a funding module.
/// @dev Like Box, the asset has no oracle: `oracles(asset)` reverts to prove modules value it 1:1 without asking.
contract MockOracleProvider is IOracleCallback {
    error AssetHasNoOracle();

    address public immutable asset;
    mapping(IERC20 token => IOracle) internal _oracles;

    constructor(address asset_) {
        asset = asset_;
    }

    function setOracle(IERC20 token, IOracle oracle) external {
        _oracles[token] = oracle;
    }

    function oracles(IERC20 token) external view returns (IOracle) {
        if (address(token) == asset) revert AssetHasNoOracle();
        return _oracles[token];
    }
}
