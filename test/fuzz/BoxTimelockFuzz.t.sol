// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Box} from "../../src/Box.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {TIMELOCK_CAP, TIMELOCK_DISABLED} from "../../src/libraries/Constants.sol";
import {BoxLib} from "../../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "../mocks/ERC20MockDecimals.sol";

/// @dev Stateless fuzzing of Box timelock arithmetic. Every warp is relative to the current block timestamp.
contract BoxTimelockFuzzTest is Test {
    using BoxLib for IBox;

    address internal owner = address(0x1);
    address internal curator = address(0x3);
    address internal guardian = address(0x4);

    IBox internal box;

    function setUp() public {
        ERC20MockDecimals asset = new ERC20MockDecimals(18);
        box = IBox(address(new Box(address(asset), owner, curator, "Box Fuzz", "BOXF", 0.01 ether, 7 days, 10 days, 7 days)));
        vm.startPrank(curator);
        box.setGuardianInstant(guardian);
        vm.stopPrank();
    }

    function _setTimelock(bytes4 selector, uint256 delay) internal {
        if (delay == 0) return;
        vm.prank(curator);
        box.increaseTimelock(selector, delay);
        assertEq(box.timelock(selector), delay, "timelock set");
    }

    /////////////////////////////
    /// SUBMIT / EXECUTE / REVOKE
    /////////////////////////////

    function testFuzz_ExecutionSucceedsIffDelayElapsed(uint256 delay, uint256 elapsed, address account, address executor) public {
        vm.assume(account != address(0));
        delay = bound(delay, 0, TIMELOCK_CAP);
        elapsed = bound(elapsed, 0, 2 * TIMELOCK_CAP);
        _setTimelock(IBox.setIsFeeder.selector, delay);

        bytes memory data = abi.encodeCall(IBox.setIsFeeder, (account, true));
        uint256 submitTime = vm.getBlockTimestamp();
        vm.prank(curator);
        box.submit(data);
        assertEq(box.executableAt(data), submitTime + delay, "executableAt = submit time + delay");

        vm.prank(curator);
        vm.expectRevert(ErrorsLib.DataAlreadyTimelocked.selector);
        box.submit(data);

        vm.warp(vm.getBlockTimestamp() + elapsed);

        if (vm.getBlockTimestamp() < submitTime + delay) {
            vm.prank(executor);
            vm.expectRevert(ErrorsLib.TimelockNotExpired.selector);
            box.setIsFeeder(account, true);

            // One second before the deadline still reverts, the deadline itself succeeds
            uint256 remaining = submitTime + delay - vm.getBlockTimestamp();
            vm.warp(vm.getBlockTimestamp() + remaining - 1);
            vm.prank(executor);
            vm.expectRevert(ErrorsLib.TimelockNotExpired.selector);
            box.setIsFeeder(account, true);
            vm.warp(vm.getBlockTimestamp() + 1);
        }

        vm.prank(executor);
        box.setIsFeeder(account, true);
        assertTrue(box.isFeeder(account), "timelocked call executed");
        assertEq(box.executableAt(data), 0, "timelocked data consumed");

        vm.prank(executor);
        vm.expectRevert(ErrorsLib.DataNotTimelocked.selector);
        box.setIsFeeder(account, true);
    }

    function testFuzz_RevokedDataCannotExecute(uint256 delay, uint256 elapsed, address account, bool byGuardian) public {
        vm.assume(account != address(0));
        delay = bound(delay, 0, TIMELOCK_CAP);
        elapsed = bound(elapsed, 0, 2 * TIMELOCK_CAP);
        _setTimelock(IBox.setIsFeeder.selector, delay);

        bytes memory data = abi.encodeCall(IBox.setIsFeeder, (account, true));
        vm.prank(curator);
        box.submit(data);

        vm.prank(byGuardian ? guardian : curator);
        box.revoke(data);
        assertEq(box.executableAt(data), 0, "revoked data cleared");

        vm.warp(vm.getBlockTimestamp() + elapsed);
        vm.expectRevert(ErrorsLib.DataNotTimelocked.selector);
        box.setIsFeeder(account, true);

        vm.prank(curator);
        vm.expectRevert(ErrorsLib.DataNotTimelocked.selector);
        box.revoke(data);

        // Revoked data can be submitted again and restarts the full delay
        uint256 resubmitTime = vm.getBlockTimestamp();
        vm.prank(curator);
        box.submit(data);
        assertEq(box.executableAt(data), resubmitTime + delay, "resubmission restarts the delay");
        assertFalse(box.isFeeder(account), "never executed");
    }

    /////////////////////////////
    /// INCREASE / DECREASE / ABDICATE
    /////////////////////////////

    function testFuzz_IncreaseTimelockBounds(bytes4 selector, uint256 current, uint256 newDuration) public {
        current = bound(current, 0, TIMELOCK_CAP);
        _setTimelock(selector, current);
        newDuration = bound(newDuration, 0, 2 * TIMELOCK_CAP);

        vm.prank(curator);
        if (newDuration > TIMELOCK_CAP) {
            vm.expectRevert(ErrorsLib.InvalidTimelock.selector);
            box.increaseTimelock(selector, newDuration);
            assertEq(box.timelock(selector), current, "unchanged");
        } else if (newDuration <= current) {
            vm.expectRevert(ErrorsLib.TimelockNotIncreasing.selector);
            box.increaseTimelock(selector, newDuration);
            assertEq(box.timelock(selector), current, "unchanged");
        } else {
            box.increaseTimelock(selector, newDuration);
            assertEq(box.timelock(selector), newDuration, "increased");
        }

        vm.prank(curator);
        vm.expectRevert(ErrorsLib.InvalidTimelock.selector);
        box.increaseTimelock(selector, type(uint256).max);
    }

    function testFuzz_DecreaseTimelockWaitsForTargetDelay(
        bytes4 selector,
        uint256 current,
        uint256 ownDelay,
        uint256 newDuration,
        uint256 elapsed
    ) public {
        current = bound(current, 1, TIMELOCK_CAP);
        _setTimelock(selector, current);
        // The delay of decreaseTimelock itself must not matter: only the target selector's current delay does
        if (selector != IBox.decreaseTimelock.selector) _setTimelock(IBox.decreaseTimelock.selector, bound(ownDelay, 0, TIMELOCK_CAP));
        newDuration = bound(newDuration, 0, 2 * TIMELOCK_CAP);
        elapsed = bound(elapsed, 0, 2 * TIMELOCK_CAP);

        bytes memory data = abi.encodeCall(IBox.decreaseTimelock, (selector, newDuration));
        uint256 submitTime = vm.getBlockTimestamp();
        vm.prank(curator);
        box.submit(data);
        assertEq(box.executableAt(data), submitTime + current, "delay is the target selector's current timelock");

        vm.warp(vm.getBlockTimestamp() + elapsed);

        vm.prank(curator);
        if (elapsed < current) {
            vm.expectRevert(ErrorsLib.TimelockNotExpired.selector);
            box.decreaseTimelock(selector, newDuration);
            assertEq(box.timelock(selector), current, "unchanged");
        } else if (newDuration >= current) {
            vm.expectRevert(ErrorsLib.TimelockNotDecreasing.selector);
            box.decreaseTimelock(selector, newDuration);
            assertEq(box.timelock(selector), current, "unchanged");
        } else {
            box.decreaseTimelock(selector, newDuration);
            assertEq(box.timelock(selector), newDuration, "decreased");
            assertEq(box.executableAt(data), 0, "timelocked data consumed");
        }
    }

    function testFuzz_AbdicatedSelectorCannotBeSubmitted(bytes4 selector, bytes memory args, uint256 duration) public {
        vm.prank(curator);
        box.abdicateTimelock(selector);
        assertEq(box.timelock(selector), TIMELOCK_DISABLED, "disabled");

        vm.startPrank(curator);
        vm.expectRevert(ErrorsLib.FunctionDisabled.selector);
        box.submit(abi.encodePacked(selector, args));

        vm.expectRevert(ErrorsLib.FunctionDisabled.selector);
        box.submit(abi.encodeCall(IBox.decreaseTimelock, (selector, bound(duration, 0, TIMELOCK_CAP))));

        vm.expectRevert(ErrorsLib.TimelockNotIncreasing.selector);
        box.increaseTimelock(selector, bound(duration, 0, TIMELOCK_CAP));
        vm.stopPrank();
    }
}
