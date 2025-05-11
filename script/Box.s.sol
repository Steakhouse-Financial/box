// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Box} from "../src/Box.sol";

contract BoxScript is Script {

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        vm.stopBroadcast();
    }
}
