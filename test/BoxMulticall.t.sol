// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IBox} from "../src/interfaces/IBox.sol";
import {BoxFactory} from "../src/factories/BoxFactory.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";

/// @dev `multicall` runs each entry through `delegatecall` on the Box itself. These tests pin that it keeps
/// the original caller, is atomic, and cannot be used to skip the per-selector timelock.
contract BoxMulticallTest is Test {
    IBox box;
    ERC20MockDecimals asset;

    address owner = makeAddr("owner");
    address curator = makeAddr("curator");
    address nonAuthorized = makeAddr("nonAuthorized");
    address allocator1 = makeAddr("allocator1");
    address allocator2 = makeAddr("allocator2");
    address feeder = makeAddr("feeder");

    function setUp() public {
        asset = new ERC20MockDecimals(18);
        box = new BoxFactory().createBox(
            asset, owner, curator, "Box Shares", "BOX", 0.01 ether, 7 days, 10 days, 7 days, bytes32(0)
        );
    }

    function testMulticallEmptyBatchDoesNothing() public {
        box.multicall(new bytes[](0));
    }

    function testMulticallExecutesAllCallsAsOriginalCaller() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IBox.setIsAllocator, (allocator1, true));
        calls[1] = abi.encodeCall(IBox.setIsAllocator, (allocator2, true));

        vm.prank(curator);
        box.multicall(calls);

        assertTrue(box.isAllocator(allocator1));
        assertTrue(box.isAllocator(allocator2));
    }

    function testMulticallKeepsAuthorizationOfInnerCalls() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(IBox.setIsAllocator, (allocator1, true));

        // The revert of the inner call is bubbled up unchanged.
        vm.prank(nonAuthorized);
        vm.expectRevert(ErrorsLib.OnlyCurator.selector);
        box.multicall(calls);

        assertFalse(box.isAllocator(allocator1));
    }

    function testMulticallRevertsAtomically() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IBox.setIsAllocator, (allocator1, true));
        calls[1] = abi.encodeCall(IBox.setIsAllocator, (allocator1, true)); // Already an allocator.

        vm.prank(curator);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        box.multicall(calls);

        // The first call is rolled back along with the failing one.
        assertFalse(box.isAllocator(allocator1));
    }

    function testMulticallCannotBypassTimelock() public {
        bytes memory inner = abi.encodeCall(IBox.setIsFeeder, (feeder, true));
        bytes[] memory calls = new bytes[](1);
        calls[0] = inner;

        vm.startPrank(curator);
        box.increaseTimelock(IBox.setIsFeeder.selector, 1 days);

        // Not submitted: batching does not skip the timelock.
        vm.expectRevert(ErrorsLib.DataNotTimelocked.selector);
        box.multicall(calls);

        // Submitting the multicall calldata itself (whose selector has no timelock) does not help either,
        // because the timelock is checked against the calldata of the inner call.
        box.submit(abi.encodeCall(IBox.multicall, (calls)));
        vm.expectRevert(ErrorsLib.DataNotTimelocked.selector);
        box.multicall(calls);

        // Submitting the inner call is required, and its delay still applies.
        box.submit(inner);
        vm.expectRevert(ErrorsLib.TimelockNotExpired.selector);
        box.multicall(calls);

        vm.warp(block.timestamp + 1 days);
        box.multicall(calls);
        vm.stopPrank();

        assertTrue(box.isFeeder(feeder));
    }
}
