// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Steakhouse
pragma solidity >= 0.5.0;

import {IAdapter} from "../../lib/vault-v2/src/interfaces/IAdapter.sol";
import {Box} from "../Box.sol";

interface IBoxAdapter is IAdapter {
    /* EVENTS */

    event SetSkimRecipient(address indexed newSkimRecipient);
    event Skim(address indexed token, uint256 assets);
    event RecognizeLoss(uint256 loss, address who);

    /* ERRORS */

    error AssetMismatch();
    error CannotSkimBoxShares();
    error InvalidData();
    error NotAuthorized();

    /* FUNCTIONS */

    function factory() external view returns (address);
    function setSkimRecipient(address newSkimRecipient) external;
    function skim(address token) external;
    function parentVault() external view returns (address);
    function box() external view returns (Box);
    function skimRecipient() external view returns (address);
    function allocation() external view returns (uint256);
    function shares() external view returns (uint256);

    // Added for BoxAdapter
    function adapterId() external view returns (bytes32);
    function data() external view returns (bytes memory);
    function recognizeLoss() external;

}
