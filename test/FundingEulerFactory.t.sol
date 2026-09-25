// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Box} from "../src/Box.sol";
import {FundingEuler} from "../src/FundingEuler.sol";
import {FundingEulerFactory} from "../src/factories/FundingEulerFactory.sol";
import {IFunding} from "../src/interfaces/IFunding.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import {MockEVC} from "./mocks/MockEVC.sol";

contract FundingEulerFactoryTest is Test {
    using BoxLib for Box;

    event CreateFundingEuler(address indexed owner, address indexed evc, uint256 ltvCap, FundingEuler fundingEuler);

    FundingEulerFactory internal factory;
    MockEVC internal evc;
    address internal owner = makeAddr("box");

    function setUp() public {
        factory = new FundingEulerFactory();
        evc = new MockEVC();
    }

    function testCreateStoresArgumentsAndRecordsModule() public {
        FundingEuler module = factory.createFundingEuler(owner, address(evc), 0.95e18);
        assertEq(module.owner(), owner);
        assertEq(address(module.evc()), address(evc));
        assertEq(module.ltvCap(), 0.95e18);
        assertEq(module.facilitiesLength(), 0);
        assertEq(module.collateralTokensLength(), 0);
        assertEq(module.debtTokensLength(), 0);
        assertTrue(factory.isFundingEuler(address(module)));
    }

    function testCreateEmitsEvent() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.recordLogs();
        vm.expectEmit(true, true, false, true, address(factory));
        emit CreateFundingEuler(owner, address(evc), 1e18, FundingEuler(payable(predicted)));
        FundingEuler module = factory.createFundingEuler(owner, address(evc), 1e18);
        assertEq(address(module), predicted);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == CreateFundingEuler.selector) {
                count++;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(owner))), "owner indexed");
                (, address emitted) = abi.decode(logs[i].data, (uint256, address));
                assertEq(emitted, predicted, "module in the data");
            }
        }
        assertEq(count, 1, "exactly one creation event");
    }

    function testCreateReturnsDistinctModules() public {
        FundingEuler a = factory.createFundingEuler(owner, address(evc), 0.95e18);
        FundingEuler b = factory.createFundingEuler(owner, address(evc), 0.95e18);
        assertTrue(address(a) != address(b));
        assertTrue(factory.isFundingEuler(address(a)));
        assertTrue(factory.isFundingEuler(address(b)));
    }

    function testIsFundingEulerFalseForOthers() public {
        FundingEuler direct = new FundingEuler(owner, address(evc), 0.95e18);
        assertFalse(factory.isFundingEuler(address(direct)));
        assertFalse(factory.isFundingEuler(address(evc)));
        assertFalse(factory.isFundingEuler(address(0)));
    }

    function testCreateRejectsInvalidArguments() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        uint256 nonceBefore = vm.getNonce(address(factory));

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        factory.createFundingEuler(address(0), address(evc), 0.95e18);

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        factory.createFundingEuler(owner, address(0), 0.95e18);

        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        factory.createFundingEuler(owner, address(evc), 0);

        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        factory.createFundingEuler(owner, address(evc), 1e18 + 1);

        assertFalse(factory.isFundingEuler(predicted));
        assertEq(vm.getNonce(address(factory)), nonceBefore, "no module deployed");
    }

    function testModuleOwnedByBoxPassesAddFunding() public {
        address curator = makeAddr("curator");
        ERC20MockDecimals weth = new ERC20MockDecimals(18);
        Box box = new Box(address(weth), makeAddr("boxOwner"), curator, "Box", "BOX", 0.01 ether, 7 days, 10 days, 1 days);
        FundingEuler module = factory.createFundingEuler(address(box), address(evc), 0.95e18);

        vm.startPrank(curator);
        box.addFundingInstant(module);
        vm.stopPrank();

        assertTrue(box.isFunding(IFunding(address(module))));
        assertEq(box.fundingsLength(), 1);
    }
}
