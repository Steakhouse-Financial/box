// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {FundingAaveV4} from "../src/FundingAaveV4.sol";
import {FundingAaveV4Factory} from "../src/factories/FundingAaveV4Factory.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import {MockAaveV4Spoke} from "./mocks/MockAaveV4Spoke.sol";

contract FundingAaveV4FactoryTest is Test {
    event CreateFundingAaveV4(
        address indexed owner,
        address indexed spoke,
        uint256[] reserveIds,
        uint256 lltvCap,
        FundingAaveV4 fundingAaveV4
    );

    FundingAaveV4Factory factory;
    MockAaveV4Spoke spoke;
    address owner = address(0xB0C5);

    function setUp() public {
        factory = new FundingAaveV4Factory();
        spoke = new MockAaveV4Spoke();
        ERC20MockDecimals a = new ERC20MockDecimals(18);
        ERC20MockDecimals b = new ERC20MockDecimals(6);
        spoke.addReserve(address(a), 18, 8000, false);
        spoke.addReserve(address(b), 6, 0, true);
        spoke.addReserve(address(b), 6, 0, true); // duplicate underlying
    }

    function _ids(uint256 x, uint256 y) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = x;
        ids[1] = y;
    }

    function testCreateFundingAaveV4() public {
        uint256[] memory ids = _ids(0, 1);
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(factory));
        emit CreateFundingAaveV4(owner, address(spoke), ids, 0.9e18, FundingAaveV4(payable(predicted)));
        FundingAaveV4 module = factory.createFundingAaveV4(owner, address(spoke), ids, 0.9e18);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == CreateFundingAaveV4.selector) count++;
        }
        assertEq(count, 1, "exactly one creation event");

        assertEq(address(module), predicted);
        assertEq(module.owner(), owner);
        assertEq(address(module.spoke()), address(spoke));
        assertEq(module.lltvCap(), 0.9e18);
        uint256[] memory stored = module.reserveIdsArray();
        assertEq(stored.length, 2);
        assertEq(stored[0], 0);
        assertEq(stored[1], 1);
        assertTrue(factory.isFundingAaveV4(address(module)));

        FundingAaveV4 second = factory.createFundingAaveV4(owner, address(spoke), ids, 0.9e18);
        assertTrue(address(second) != address(module));
        assertTrue(factory.isFundingAaveV4(address(second)));
    }

    function testIsFundingAaveV4FalseForOthers() public {
        FundingAaveV4 direct = new FundingAaveV4(owner, address(spoke), _ids(0, 1), 0.9e18);
        assertFalse(factory.isFundingAaveV4(address(direct)));
        assertFalse(factory.isFundingAaveV4(address(0xdead)));
        assertFalse(factory.isFundingAaveV4(address(0)));
    }

    function testCreateRejectsInvalidArguments() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        factory.createFundingAaveV4(owner, address(0), _ids(0, 1), 0.9e18);

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        factory.createFundingAaveV4(address(0), address(spoke), _ids(0, 1), 0.9e18);

        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        factory.createFundingAaveV4(owner, address(spoke), _ids(0, 1), 0);

        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        factory.createFundingAaveV4(owner, address(spoke), _ids(0, 1), 1e18 + 1);

        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        factory.createFundingAaveV4(owner, address(spoke), _ids(1, 2), 0.9e18);

        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        factory.createFundingAaveV4(owner, address(spoke), _ids(0, 3), 0.9e18);

        assertFalse(factory.isFundingAaveV4(predicted));
        assertEq(vm.getNonce(address(factory)), 1, "no module deployed");
    }
}
