// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FundingMidnight} from "../src/FundingMidnight.sol";
import {FundingMidnightFactory} from "../src/factories/FundingMidnightFactory.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {MockMidnight} from "./mocks/MockMidnight.sol";

contract FundingMidnightFactoryTest is Test {
    event CreateFundingMidnight(address indexed owner, address indexed midnight, uint256 lltvCap, FundingMidnight fundingMidnight);

    FundingMidnightFactory internal factory;
    MockMidnight internal midnight;
    address internal owner = makeAddr("box");

    function setUp() public {
        factory = new FundingMidnightFactory();
        midnight = new MockMidnight();
    }

    function testCreateStoresArgumentsAndRecordsModule() public {
        FundingMidnight module = factory.createFundingMidnight(owner, address(midnight), 0.9e18);
        assertEq(module.owner(), owner);
        assertEq(address(module.midnight()), address(midnight));
        assertEq(module.lltvCap(), 0.9e18);
        assertEq(module.facilitiesLength(), 0);
        assertEq(module.collateralTokensLength(), 0);
        assertEq(module.debtTokensLength(), 0);
        assertTrue(factory.isFundingMidnight(address(module)));
    }

    function testCreateEmitsEvent() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectEmit(true, true, false, true, address(factory));
        emit CreateFundingMidnight(owner, address(midnight), 1e18, FundingMidnight(payable(predicted)));
        FundingMidnight module = factory.createFundingMidnight(owner, address(midnight), 1e18);
        assertEq(address(module), predicted);
    }

    function testCreateReturnsDistinctModules() public {
        FundingMidnight a = factory.createFundingMidnight(owner, address(midnight), 0.9e18);
        FundingMidnight b = factory.createFundingMidnight(owner, address(midnight), 0.9e18);
        assertTrue(address(a) != address(b));
        assertTrue(factory.isFundingMidnight(address(a)));
        assertTrue(factory.isFundingMidnight(address(b)));
    }

    function testIsFundingMidnightFalseForOthers() public {
        FundingMidnight direct = new FundingMidnight(owner, address(midnight), 0.9e18);
        assertFalse(factory.isFundingMidnight(address(direct)));
        assertFalse(factory.isFundingMidnight(address(midnight)));
        assertFalse(factory.isFundingMidnight(address(0)));
    }

    function testCreateRejectsInvalidArguments() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        uint256 nonceBefore = vm.getNonce(address(factory));

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        factory.createFundingMidnight(address(0), address(midnight), 0.9e18);

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        factory.createFundingMidnight(owner, address(0), 0.9e18);

        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        factory.createFundingMidnight(owner, address(midnight), 0);

        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        factory.createFundingMidnight(owner, address(midnight), 1e18 + 1);

        assertFalse(factory.isFundingMidnight(predicted));
        assertEq(vm.getNonce(address(factory)), nonceBefore, "no module deployed");
    }
}
