// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../src/Box.sol";
import {FundingEuler} from "../src/FundingEuler.sol";
import {FundingEulerFactory} from "../src/factories/FundingEulerFactory.sol";
import {IOracleCallback} from "../src/interfaces/IFunding.sol";
import {IEVault} from "../src/interfaces/euler/IEVault.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import {MockEVault, MockEulerRouter} from "./mocks/MockEVault.sol";
import {MockEVC} from "./mocks/MockEVC.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockOracleProvider} from "./mocks/MockOracleProvider.sol";

/// @dev Fixture: the module attached to a real Box (asset WETH) on a mock EVC with mock EVK vaults.
///      Facilities: fdWeth = (cvWsteth, bvWeth) registered; fdUsdc = (cvWsteth, bvUsdc), fdWeth2 = (cvWsteth2, bvWeth)
///      and fdCbbtc = (cvCbbtc, bvUsdc) configured but not registered. bvWeth prices in WETH (its unit of account is
///      its asset), bvUsdc prices in USD.
contract FundingEulerTest is Test {
    using BoxLib for Box;

    address internal constant USD = address(840);
    uint256 internal constant LTV_CAP = 0.95e18;
    uint256 internal constant WETH_CAP = 0.8835e18; // 9300 * 1e14 * 0.95
    uint256 internal constant WSTETH_WETH_QUOTE = 1.2e18;
    uint256 internal constant WSTETH_USD_QUOTE = 4_800e18;
    uint256 internal constant USDC_USD_QUOTE = 1e30; // 1 USDC unit (1e-6) = 1e12 USD wei
    uint256 internal constant CBBTC_USD_QUOTE = 1e33; // 1 cbBTC unit (1e-8) = 1e15 USD wei
    uint256 internal constant WSTETH_BOX_PRICE = 1210885760000000000000000000000000001; // 1.21 WETH, odd
    uint256 internal constant USDC_BOX_PRICE = 250000000000000000000000000000000000000000003; // 1/4000 WETH, odd
    uint256 internal constant CBBTC_BOX_PRICE = 2.5e47; // 25 WETH per cbBTC

    MockEVC internal evc;
    MockEulerRouter internal router;
    ERC20MockDecimals internal weth;
    ERC20MockDecimals internal wsteth;
    ERC20MockDecimals internal usdc;
    ERC20MockDecimals internal cbbtc;
    ERC20MockDecimals internal stranger;
    MockEVault internal cvWsteth;
    MockEVault internal cvWsteth2;
    MockEVault internal cvCbbtc;
    MockEVault internal bvWeth;
    MockEVault internal bvUsdc;
    MockOracle internal boxWstethOracle;
    MockOracle internal boxUsdcOracle;
    MockOracle internal boxCbbtcOracle;
    MockOracleProvider internal provider;

    Box internal box;
    FundingEuler internal module;

    address internal boxOwner = makeAddr("boxOwner");
    address internal curator = makeAddr("curator");
    address internal guardian = makeAddr("guardian");
    address internal allocator = makeAddr("allocator");
    address internal anyone = makeAddr("anyone");
    address internal lender = makeAddr("lender");
    address internal liquidator = makeAddr("liquidator");

    bytes internal fdWeth;
    bytes internal fdUsdc;
    bytes internal fdWeth2;
    bytes internal fdCbbtc;

    function setUp() public virtual {
        evc = new MockEVC();
        router = new MockEulerRouter();
        weth = new ERC20MockDecimals(18);
        wsteth = new ERC20MockDecimals(18);
        usdc = new ERC20MockDecimals(6);
        cbbtc = new ERC20MockDecimals(8);
        stranger = new ERC20MockDecimals(18);

        cvWsteth = new MockEVault(address(evc), address(wsteth), address(router), USD);
        cvWsteth2 = new MockEVault(address(evc), address(wsteth), address(router), USD);
        cvCbbtc = new MockEVault(address(evc), address(cbbtc), address(router), USD);
        bvWeth = new MockEVault(address(evc), address(weth), address(router), address(weth));
        bvUsdc = new MockEVault(address(evc), address(usdc), address(router), USD);

        bvWeth.setLTV(address(cvWsteth), 9300, 9500);
        bvWeth.setLTV(address(cvWsteth2), 9300, 9500);
        bvUsdc.setLTV(address(cvWsteth), 8100, 8300);
        bvUsdc.setLTV(address(cvWsteth2), 8100, 8300);
        bvUsdc.setLTV(address(cvCbbtc), 7800, 8000);

        router.setResolvedVault(address(cvWsteth), true);
        router.setResolvedVault(address(cvWsteth2), true);
        router.setResolvedVault(address(cvCbbtc), true);
        router.setPrice(address(wsteth), address(weth), WSTETH_WETH_QUOTE);
        router.setPrice(address(wsteth), USD, WSTETH_USD_QUOTE);
        router.setPrice(address(usdc), USD, USDC_USD_QUOTE);
        router.setPrice(address(cbbtc), USD, CBBTC_USD_QUOTE);

        _seed(bvWeth, weth, 100_000e18);
        _seed(bvUsdc, usdc, 100_000_000e6);

        fdWeth = abi.encode(address(cvWsteth), address(bvWeth));
        fdUsdc = abi.encode(address(cvWsteth), address(bvUsdc));
        fdWeth2 = abi.encode(address(cvWsteth2), address(bvWeth));
        fdCbbtc = abi.encode(address(cvCbbtc), address(bvUsdc));

        boxWstethOracle = new MockOracle(WSTETH_BOX_PRICE);
        boxUsdcOracle = new MockOracle(USDC_BOX_PRICE);
        boxCbbtcOracle = new MockOracle(CBBTC_BOX_PRICE);
        provider = new MockOracleProvider(address(weth));
        provider.setOracle(wsteth, boxWstethOracle);
        provider.setOracle(usdc, boxUsdcOracle);
        provider.setOracle(cbbtc, boxCbbtcOracle);

        box = new Box(address(weth), boxOwner, curator, "Box", "BOX", 0.01 ether, 7 days, 10 days, 1 days);
        module = new FundingEulerFactory().createFundingEuler(address(box), address(evc), LTV_CAP);

        vm.startPrank(curator);
        box.setGuardianInstant(guardian);
        box.addTokenInstant(wsteth, boxWstethOracle);
        box.addTokenInstant(usdc, boxUsdcOracle);
        box.addTokenInstant(cbbtc, boxCbbtcOracle);
        box.setIsAllocator(allocator, true);
        box.addFeederInstant(address(this));
        box.addFundingInstant(module);
        box.addFundingCollateralInstant(module, wsteth);
        box.addFundingCollateralInstant(module, cbbtc);
        box.addFundingDebtInstant(module, weth);
        box.addFundingDebtInstant(module, usdc);
        box.addFundingFacilityInstant(module, fdWeth);
        vm.stopPrank();

        weth.mint(address(this), 10_000e18);
        weth.approve(address(box), 10_000e18);
        box.deposit(10_000e18, address(this));
        wsteth.mint(address(box), 10_000e18);
        usdc.mint(address(box), 1_000_000e6);
        cbbtc.mint(address(box), 100e8);
    }

    // ========== HELPERS ==========

    function _seed(MockEVault vault, ERC20MockDecimals token, uint256 amount) internal {
        token.mint(lender, amount);
        vm.startPrank(lender);
        token.approve(address(vault), amount);
        vault.deposit(amount, lender);
        vm.stopPrank();
    }

    /// @dev Lender deposits and a yield donation so that the collateral vault share price is not 1
    function _skewSharePrice(MockEVault vault, ERC20MockDecimals token) internal {
        token.mint(lender, 60e18);
        vm.startPrank(lender);
        token.approve(address(vault), 60e18);
        vault.deposit(50e18, lender);
        vault.addYield(1e18 + 1);
        vm.stopPrank();
    }

    function _add(bytes memory facilityData) internal {
        vm.prank(address(box));
        module.addFacility(facilityData);
    }

    function _remove(bytes memory facilityData) internal {
        vm.prank(address(box));
        module.removeFacility(facilityData);
    }

    function _pledge(bytes memory facilityData, IERC20 token, uint256 amount) internal {
        vm.prank(allocator);
        box.pledge(module, facilityData, token, amount);
    }

    function _depledge(bytes memory facilityData, IERC20 token, uint256 amount) internal {
        vm.prank(allocator);
        box.depledge(module, facilityData, token, amount);
    }

    function _borrow(bytes memory facilityData, IERC20 token, uint256 amount) internal {
        vm.prank(allocator);
        box.borrow(module, facilityData, token, amount);
    }

    function _repay(bytes memory facilityData, IERC20 token, uint256 amount) internal {
        vm.prank(allocator);
        box.repay(module, facilityData, token, amount);
    }

    function _subOf(address account, uint256 id) internal pure returns (address) {
        return address(uint160(account) ^ uint160(id));
    }

    function _value(IOracleCallback p, address token, uint256 amount, Math.Rounding rounding) internal view returns (uint256) {
        if (token == p.asset()) return amount;
        return Math.mulDiv(amount, p.oracles(IERC20(token)).price(), 1e36, rounding);
    }

    /// @dev Independent evaluation of the nav formula over the registered facilities
    function _expectedNav(IOracleCallback p) internal view returns (uint256 total) {
        uint256 length = module.facilitiesLength();
        for (uint256 i; i < length; i++) {
            bytes memory fd = module.facilities(i);
            (address cv, address bv) = abi.decode(fd, (address, address));
            address sub = module.subAccount(fd);
            uint256 shares = MockEVault(cv).balanceOf(sub);
            if (shares == 0) continue;
            uint256 c = _value(p, MockEVault(cv).asset(), MockEVault(cv).convertToAssets(shares), Math.Rounding.Floor);
            uint256 d = _value(p, MockEVault(bv).asset(), MockEVault(bv).debtOf(sub), Math.Rounding.Ceil);
            total += c > d ? c - d : 0;
        }
    }

    function _collateralOf(bytes memory facilityData) internal view returns (uint256) {
        (address cv, ) = abi.decode(facilityData, (address, address));
        return MockEVault(cv).convertToAssets(MockEVault(cv).balanceOf(module.subAccount(facilityData)));
    }

    // ========== constructor ==========

    function testConstructorStoresArguments() public {
        assertEq(module.owner(), address(box));
        assertEq(address(module.evc()), address(evc));
        assertEq(module.ltvCap(), LTV_CAP);

        FundingEuler full = new FundingEuler(address(box), address(evc), 1e18);
        assertEq(full.ltvCap(), 1e18);
        assertEq(full.facilitiesLength(), 0);
        assertEq(full.collateralTokensLength(), 0);
        assertEq(full.debtTokensLength(), 0);
    }

    function testConstructorRejectsInvalidArguments() public {
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        new FundingEuler(address(0), address(evc), LTV_CAP);

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        new FundingEuler(address(box), address(0), LTV_CAP);

        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        new FundingEuler(address(box), address(evc), 0);

        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        new FundingEuler(address(box), address(evc), 1e18 + 1);
    }

    // ========== canonical facilityData ==========

    function testCanonicalFacilityDataRegisters() public {
        uint256 before = module.facilitiesLength();
        assertFalse(module.isFacility(fdUsdc));
        _add(fdUsdc);
        assertTrue(module.isFacility(fdUsdc));
        assertEq(module.facilitiesLength(), before + 1);
        assertEq(module.facilities(before), fdUsdc);
        assertEq(module.facilities(0), fdWeth);
        assertEq(module.encodeFacilityData(address(cvWsteth), address(bvUsdc)), fdUsdc);
        (address cv, address bv) = module.decodeFacilityData(fdUsdc);
        assertEq(cv, address(cvWsteth));
        assertEq(bv, address(bvUsdc));
    }

    function testMalformedFacilityDataRejected() public {
        bytes[] memory badLengths = new bytes[](6);
        badLengths[0] = "";
        badLengths[1] = abi.encode(address(cvWsteth));
        badLengths[2] = new bytes(63);
        badLengths[3] = abi.encodePacked(fdUsdc, bytes1(0));
        badLengths[4] = abi.encode(address(cvWsteth), address(bvUsdc), uint256(0));
        badLengths[5] = new bytes(65);
        for (uint256 i; i < badLengths.length; i++) {
            vm.prank(address(box));
            vm.expectRevert(ErrorsLib.InvalidFacilityData.selector);
            module.addFacility(badLengths[i]);
        }

        // A non-zero bit above bit 159 in either word
        bytes memory dirtyFirst = bytes.concat(fdUsdc);
        dirtyFirst[0] = 0x01;
        vm.prank(address(box));
        vm.expectRevert();
        module.addFacility(dirtyFirst);

        bytes memory dirtySecond = bytes.concat(fdUsdc);
        dirtySecond[43] = 0x80; // lowest byte of the upper 96 bits of the second word
        vm.prank(address(box));
        vm.expectRevert();
        module.addFacility(dirtySecond);

        // No second encoding of the registered fdWeth pair
        bytes memory dirtyRegistered = bytes.concat(fdWeth);
        dirtyRegistered[11] = 0x01;
        vm.prank(address(box));
        vm.expectRevert();
        module.addFacility(dirtyRegistered);

        bytes[] memory badValues = new bytes[](4);
        badValues[0] = abi.encode(address(0), address(bvUsdc));
        badValues[1] = abi.encode(address(cvWsteth), address(0));
        badValues[2] = abi.encode(address(bvWeth), address(bvWeth));
        badValues[3] = abi.encode(address(cvWsteth), address(cvWsteth));
        for (uint256 i; i < badValues.length; i++) {
            vm.prank(address(box));
            vm.expectRevert(ErrorsLib.InvalidFacilityData.selector);
            module.addFacility(badValues[i]);
        }

        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        module.addFacility(fdWeth);

        assertEq(module.facilitiesLength(), 1);
    }

    // ========== addFacility preconditions ==========

    function testAddFacilityRequiresMatchingEvc() public {
        MockEVC otherEvc = new MockEVC();
        MockEVault foreignCollateral = new MockEVault(address(otherEvc), address(wsteth), address(router), USD);
        MockEVault foreignBorrow = new MockEVault(address(otherEvc), address(weth), address(router), address(weth));
        bvWeth.setLTV(address(foreignCollateral), 9300, 9500);
        foreignBorrow.setLTV(address(cvWsteth), 9300, 9500);

        bytes memory badCollateral = abi.encode(address(foreignCollateral), address(bvWeth));
        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.InvalidFacilityData.selector);
        module.addFacility(badCollateral);

        bytes memory badBorrow = abi.encode(address(cvWsteth), address(foreignBorrow));
        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.InvalidFacilityData.selector);
        module.addFacility(badBorrow);
    }

    function testAddFacilityRequiresBorrowLtv() public {
        MockEVault unconfigured = new MockEVault(address(evc), address(wsteth), address(router), USD);
        bytes memory fd = abi.encode(address(unconfigured), address(bvWeth));
        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.InvalidFacilityData.selector);
        module.addFacility(fd);

        bvWeth.setLTV(address(unconfigured), 1, 2);
        _add(fd);
        assertTrue(module.isFacility(fd));
    }

    function testAddFacilityRequiresRegisteredTokens() public {
        MockEVault strangerCollateral = new MockEVault(address(evc), address(stranger), address(router), USD);
        MockEVault debtAsCollateral = new MockEVault(address(evc), address(usdc), address(router), USD);
        MockEVault strangerBorrow = new MockEVault(address(evc), address(stranger), address(router), USD);
        MockEVault collateralAsBorrow = new MockEVault(address(evc), address(wsteth), address(router), USD);
        bvWeth.setLTV(address(strangerCollateral), 9000, 9100);
        bvWeth.setLTV(address(debtAsCollateral), 9000, 9100);
        strangerBorrow.setLTV(address(cvWsteth), 9000, 9100);
        collateralAsBorrow.setLTV(address(cvWsteth), 9000, 9100);

        bytes[] memory fds = new bytes[](4);
        fds[0] = abi.encode(address(strangerCollateral), address(bvWeth));
        fds[1] = abi.encode(address(debtAsCollateral), address(bvWeth));
        fds[2] = abi.encode(address(cvWsteth), address(strangerBorrow));
        fds[3] = abi.encode(address(cvWsteth), address(collateralAsBorrow));
        for (uint256 i; i < fds.length; i++) {
            vm.prank(address(box));
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.addFacility(fds[i]);
        }
        assertEq(module.facilitiesLength(), 1);
    }

    function testFacilityTokensComeFromVaults() public {
        _add(fdUsdc);
        vm.startPrank(address(box));
        wsteth.transfer(address(module), 1e18);
        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        module.pledge(fdUsdc, weth, 1e18);
        module.pledge(fdUsdc, wsteth, 1e18);
        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        module.borrow(fdUsdc, weth, 1e18);
        module.borrow(fdUsdc, usdc, 100e6);
        vm.stopPrank();
        assertEq(module.collateralBalance(fdUsdc, wsteth), 1e18);
        assertEq(module.debtBalance(fdUsdc, usdc), 100e6);
    }

    // ========== sub-accounts ==========

    function testSubAccountsLowestFreeFirst() public {
        assertEq(module.subAccountId(fdWeth), 1);
        assertEq(module.subAccount(fdWeth), _subOf(address(module), 1));
        assertEq(module.subAccountId(fdUsdc), 0, "unregistered");
        assertEq(module.subAccount(fdUsdc), address(0), "unregistered");

        _add(fdUsdc);
        _add(fdWeth2);
        assertEq(module.subAccountId(fdUsdc), 2);
        assertEq(module.subAccountId(fdWeth2), 3);

        _remove(fdUsdc);
        assertEq(module.subAccountId(fdUsdc), 0);
        _add(fdCbbtc);
        assertEq(module.subAccountId(fdCbbtc), 2, "freed id reused by another pair");

        _remove(fdWeth);
        _add(fdWeth);
        assertEq(module.subAccountId(fdWeth), 1, "freed id reused by the same pair");
        _add(fdUsdc);
        assertEq(module.subAccountId(fdUsdc), 4);
        assertEq(module.subAccount(fdUsdc), _subOf(address(module), 4));
    }

    function testPositionsLiveOnDistinctSubAccounts() public {
        _add(fdUsdc);
        _add(fdWeth2);
        _pledge(fdWeth, wsteth, 10e18);
        _pledge(fdUsdc, wsteth, 20e18);
        _pledge(fdWeth2, wsteth, 30e18);
        _borrow(fdWeth, weth, 1e18);
        _borrow(fdUsdc, usdc, 1_000e6);
        _borrow(fdWeth2, weth, 3e18);

        address sub1 = _subOf(address(module), 1);
        address sub2 = _subOf(address(module), 2);
        address sub3 = _subOf(address(module), 3);
        assertEq(cvWsteth.balanceOf(sub1), 10e18);
        assertEq(cvWsteth.balanceOf(sub2), 20e18);
        assertEq(cvWsteth2.balanceOf(sub3), 30e18);
        assertEq(bvWeth.debtOf(sub1), 1e18);
        assertEq(bvUsdc.debtOf(sub2), 1_000e6);
        assertEq(bvWeth.debtOf(sub3), 3e18);

        assertEq(cvWsteth.balanceOf(address(module)), 0);
        assertEq(cvWsteth2.balanceOf(address(module)), 0);
        assertEq(bvWeth.debtOf(address(module)), 0);
        assertEq(bvUsdc.debtOf(address(module)), 0);
        assertEq(evc.getCollaterals(address(module)).length, 0);
        assertEq(evc.getControllers(address(module)).length, 0);
        assertEq(evc.getAccountOwner(sub1), address(module));
    }

    function testSubAccountLimitAndReuse() public {
        FundingEuler m = new FundingEuler(address(this), address(evc), LTV_CAP);
        m.addCollateralToken(wsteth);
        m.addDebtToken(weth);

        MockEVault[16] memory cvs;
        MockEVault[16] memory bvs;
        for (uint256 i; i < 16; i++) {
            cvs[i] = new MockEVault(address(evc), address(wsteth), address(router), USD);
            bvs[i] = new MockEVault(address(evc), address(weth), address(router), address(weth));
        }
        for (uint256 i; i < 16; i++) {
            for (uint256 j; j < 16; j++) {
                bvs[j].setLTV(address(cvs[i]), 9000, 9100);
            }
        }

        for (uint256 k; k < 255; k++) {
            bytes memory fd = abi.encode(address(cvs[k / 16]), address(bvs[k % 16]));
            m.addFacility(fd);
            assertEq(m.subAccountId(fd), k + 1);
        }
        assertEq(m.facilitiesLength(), 255);

        bytes memory last = abi.encode(address(cvs[15]), address(bvs[15]));
        vm.expectRevert(ErrorsLib.TooManyFacilities.selector);
        m.addFacility(last);

        bytes memory hundredth = abi.encode(address(cvs[6]), address(bvs[3])); // k = 99 = 6 * 16 + 3
        assertEq(m.subAccountId(hundredth), 100);
        m.removeFacility(hundredth);
        m.addFacility(last);
        assertEq(m.subAccountId(last), 100);
        assertEq(m.facilitiesLength(), 255);
    }

    // ========== access control and no authorisations ==========

    function _ownerGatedCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](11);
        calls[0] = abi.encodeCall(FundingEuler.addFacility, (fdUsdc));
        calls[1] = abi.encodeCall(FundingEuler.removeFacility, (fdWeth));
        calls[2] = abi.encodeWithSignature("addCollateralToken(address)", address(stranger));
        calls[3] = abi.encodeCall(FundingEuler.removeCollateralToken, (IERC20(address(cbbtc))));
        calls[4] = abi.encodeWithSignature("addDebtToken(address)", address(stranger));
        calls[5] = abi.encodeCall(FundingEuler.removeDebtToken, (IERC20(address(usdc))));
        calls[6] = abi.encodeCall(FundingEuler.pledge, (fdWeth, IERC20(address(wsteth)), 1e18));
        calls[7] = abi.encodeCall(FundingEuler.depledge, (fdWeth, IERC20(address(wsteth)), 1e18));
        calls[8] = abi.encodeCall(FundingEuler.borrow, (fdWeth, IERC20(address(weth)), 1e18));
        calls[9] = abi.encodeCall(FundingEuler.repay, (fdWeth, IERC20(address(weth)), 1e18));
        calls[10] = abi.encodeWithSignature("skim(address)", address(wsteth));
    }

    function testNonOwnerCannotCallGatedFunctions(address caller) public {
        vm.assume(caller != address(box) && caller != address(vm));
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 2e18);
        wsteth.mint(address(module), 1e18);
        weth.mint(address(module), 1e18);

        bytes[] memory calls = _ownerGatedCalls();
        bytes memory expected = abi.encodeWithSelector(ErrorsLib.OnlyOwner.selector);
        for (uint256 i; i < calls.length; i++) {
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(module).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, expected);

            bytes[] memory wrapped = new bytes[](1);
            wrapped[0] = calls[i];
            vm.prank(caller);
            (ok, ret) = address(module).call(abi.encodeWithSignature("multicall(bytes[])", wrapped));
            assertFalse(ok);
            assertEq(ret, expected);
        }
        assertEq(module.collateralBalance(fdWeth, wsteth), 10e18);
        assertEq(module.debtBalance(fdWeth, weth), 2e18);
        assertEq(module.facilitiesLength(), 1);
        assertEq(module.collateralTokensLength(), 2);
        assertEq(module.debtTokensLength(), 2);
        assertEq(wsteth.balanceOf(address(module)), 1e18);
    }

    function testFullLifecycleWithoutAuthorisations() public {
        vm.expectRevert(MockEVC.AuthorisationsNotSupported.selector);
        evc.setOperator(bytes19(0), address(this), 1);
        vm.expectRevert(MockEVC.AuthorisationsNotSupported.selector);
        evc.setAccountOperator(address(this), address(module), true);
        vm.expectRevert(MockEVC.AuthorisationsNotSupported.selector);
        evc.permit(address(this), address(this), 0, 0, 0, 0, "", "");

        uint256 wstethBefore = wsteth.balanceOf(address(box));
        uint256 wethBefore = weth.balanceOf(address(box));
        address sub = module.subAccount(fdWeth);

        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 5e18);
        bvWeth.accrue(sub, 0.01e18 * 1e9);
        _repay(fdWeth, weth, type(uint256).max);
        _depledge(fdWeth, wsteth, type(uint256).max);

        assertEq(cvWsteth.balanceOf(sub), 0);
        assertEq(bvWeth.debtOfExact(sub), 0);
        assertEq(wsteth.balanceOf(address(box)), wstethBefore);
        assertEq(weth.balanceOf(address(box)), wethBefore - 0.01e18);

        vm.startPrank(curator);
        box.removeFundingFacility(module, fdWeth);
        box.removeFundingCollateral(module, wsteth);
        box.removeFundingCollateral(module, cbbtc);
        box.removeFundingDebt(module, weth);
        box.removeFundingDebt(module, usdc);
        box.removeFunding(module);
        vm.stopPrank();
        assertFalse(box.isFunding(module));

        // Every EVC call of the module is one of the vault operations acting as the sub-account
        uint256 count = evc.callCount();
        assertGt(count, 0);
        for (uint256 i; i < count; i++) {
            MockEVC.CallRecord memory rec = evc.callAt(i);
            bytes4 selector = bytes4(rec.data);
            assertEq(rec.caller, address(module));
            assertEq(rec.onBehalfOf, sub);
            assertTrue(rec.target == address(cvWsteth) || rec.target == address(bvWeth));
            assertTrue(
                selector == IEVault.borrow.selector ||
                    selector == IEVault.withdraw.selector ||
                    selector == IEVault.redeem.selector ||
                    selector == IEVault.disableController.selector
            );
        }
    }

    // ========== facility and token checks on actions ==========

    function testActionsRejectUnregisteredFacility() public {
        bytes[] memory fds = new bytes[](5);
        fds[0] = fdUsdc;
        fds[1] = "";
        fds[2] = new bytes(32);
        fds[3] = abi.encodePacked(fdWeth, bytes1(0));
        fds[4] = abi.encode(address(cvWsteth), address(bvWeth), uint256(0));

        vm.startPrank(address(box));
        for (uint256 i; i < fds.length; i++) {
            vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
            module.pledge(fds[i], wsteth, 1e18);
            vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
            module.depledge(fds[i], wsteth, 1e18);
            vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
            module.borrow(fds[i], weth, 1e18);
            vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
            module.repay(fds[i], weth, 1e18);
        }
        vm.stopPrank();
    }

    function testActionsRejectMismatchedTokens() public {
        _add(fdCbbtc);
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 1e18);

        vm.startPrank(address(box));
        cbbtc.transfer(address(module), 1e8);
        usdc.transfer(address(module), 1e6);
        IERC20[3] memory wrongCollateral = [IERC20(address(cbbtc)), IERC20(address(weth)), IERC20(address(stranger))];
        IERC20[3] memory wrongDebt = [IERC20(address(usdc)), IERC20(address(wsteth)), IERC20(address(stranger))];
        for (uint256 i; i < 3; i++) {
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.pledge(fdWeth, wrongCollateral[i], 1);
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.depledge(fdWeth, wrongCollateral[i], 1);
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.borrow(fdWeth, wrongDebt[i], 1);
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.repay(fdWeth, wrongDebt[i], 1);
        }
        vm.stopPrank();
    }

    // ========== pledge ==========

    function testPledgeDepositsToSubAccount() public {
        _skewSharePrice(cvWsteth, wsteth);
        address sub = module.subAccount(fdWeth);
        uint256 amount = 10e18;
        uint256 expectedShares = Math.mulDiv(amount, cvWsteth.totalSupply() + 1e6, cvWsteth.totalAssets() + 1e6);
        uint256 collateralBefore = module.collateralBalance(fdWeth, wsteth);

        _pledge(fdWeth, wsteth, amount);

        assertEq(cvWsteth.balanceOf(sub), expectedShares);
        assertTrue(expectedShares != amount, "share price is not 1");
        assertEq(cvWsteth.balanceOf(address(module)), 0);
        assertTrue(evc.isCollateralEnabled(sub, address(cvWsteth)));
        assertEq(wsteth.balanceOf(address(module)), 0);
        assertEq(wsteth.allowance(address(module), address(cvWsteth)), 0);
        uint256 delta = module.collateralBalance(fdWeth, wsteth) - collateralBefore;
        assertLe(delta, amount);
        assertApproxEqAbs(delta, amount, 2, "collateral rises by the amount minus rounding");
        assertEq(evc.getControllers(sub).length, 0, "no controller");

        uint256 enables = evc.enableCollateralCount();
        _pledge(fdWeth, wsteth, 5e18);
        assertEq(evc.getCollaterals(sub).length, 1);
        assertEq(evc.enableCollateralCount(), enables, "collateral not re-enabled");
        assertEq(evc.getControllers(sub).length, 0, "no controller");
        assertApproxEqAbs(module.collateralBalance(fdWeth, wsteth), 15e18, 3, "both pledges counted");
    }

    // ========== borrow ==========

    function testBorrowRunsAsSubAccountAndDeliversExactly() public {
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 100e18);
        uint256 boxBefore = weth.balanceOf(address(box));

        _borrow(fdWeth, weth, 50e18);

        MockEVC.CallRecord memory rec = evc.lastCall();
        assertEq(rec.caller, address(module));
        assertEq(rec.target, address(bvWeth));
        assertEq(rec.onBehalfOf, sub);
        assertEq(rec.data, abi.encodeCall(IEVault.borrow, (50e18, address(box))));
        assertTrue(evc.isControllerEnabled(sub, address(bvWeth)));
        assertEq(weth.balanceOf(address(box)) - boxBefore, 50e18);
        assertEq(weth.balanceOf(address(module)), 0);
        assertEq(module.debtBalance(fdWeth, weth), 50e18);

        bvWeth.accrue(sub, 123_456_789_123); // debt with a sub-wei remainder
        uint256 debtBefore = module.debtBalance(fdWeth, weth);
        uint256 controllerEnables = evc.enableControllerCount();
        _borrow(fdWeth, weth, 10e18);
        assertEq(evc.enableControllerCount(), controllerEnables, "controller reused");
        assertEq(evc.getControllers(sub).length, 1);
        assertEq(module.debtBalance(fdWeth, weth), debtBefore + 10e18);
        assertEq(weth.balanceOf(address(box)) - boxBefore, 60e18);
    }

    function testBorrowMaxReverts() public {
        _pledge(fdWeth, wsteth, 100e18);
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        _borrow(fdWeth, weth, type(uint256).max);

        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        module.borrow(fdWeth, weth, type(uint256).max);
        assertEq(module.debtBalance(fdWeth, weth), 0);
    }

    // ========== LTV guard ==========

    function testGuardCapValue() public pure {
        assertEq((uint256(9300) * 1e14 * LTV_CAP) / 1e18, WETH_CAP);
    }

    function testBorrowGuardAtCapBoundary() public {
        _pledge(fdWeth, wsteth, 100e18); // 120 WETH at the Euler quote
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        _borrow(fdWeth, weth, 106.02e18 + 1);

        _borrow(fdWeth, weth, 106.02e18);
        assertEq(module.ltv(fdWeth), WETH_CAP, "exactly at the cap");
    }

    function testDepledgeGuardAtCapBoundary() public {
        _pledge(fdWeth, wsteth, 200e18);
        _borrow(fdWeth, weth, 106.02e18);

        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        _depledge(fdWeth, wsteth, 100e18 + 1);

        _depledge(fdWeth, wsteth, 100e18);
        assertEq(module.ltv(fdWeth), WETH_CAP, "exactly at the cap");
    }

    function testGuardUsesCurrentLtvBorrow() public {
        _pledge(fdWeth, wsteth, 200e18);
        _borrow(fdWeth, weth, 100e18);

        // Leaves 120 wstETH = 144 WETH: ltv 0.6944, above 0.7 * 0.95 but within Euler's 70%
        bvWeth.setLTV(address(cvWsteth), 7000, 9500);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        _depledge(fdWeth, wsteth, 80e18);

        bvWeth.setLTV(address(cvWsteth), 9300, 9500);
        _depledge(fdWeth, wsteth, 80e18);
        assertEq(module.collateralBalance(fdWeth, wsteth), 120e18);
    }

    function testPledgeAndRepayIgnoreGuard() public {
        _pledge(fdWeth, wsteth, 100e18);
        _borrow(fdWeth, weth, 100e18);
        router.setPrice(address(wsteth), address(weth), 1.12e18);
        assertGt(module.ltv(fdWeth), WETH_CAP);

        _repay(fdWeth, weth, 0.1e18);
        assertGt(module.ltv(fdWeth), WETH_CAP, "still above the cap after repay");
        assertEq(module.debtBalance(fdWeth, weth), 99.9e18);

        _pledge(fdWeth, wsteth, 0.5e18);
        assertGt(module.ltv(fdWeth), WETH_CAP, "still above the cap after pledge");
        assertEq(module.collateralBalance(fdWeth, wsteth), 100.5e18);
    }

    function testDepledgeWithoutDebtIgnoresOracle() public {
        _pledge(fdWeth, wsteth, 10e18);
        router.setReverts(true);
        _depledge(fdWeth, wsteth, 4e18);
        _depledge(fdWeth, wsteth, type(uint256).max);
        assertEq(module.collateralBalance(fdWeth, wsteth), 0);
    }

    function testDepledgeGuardAppliesInWinddown() public {
        _pledge(fdWeth, wsteth, 200e18);
        _borrow(fdWeth, weth, 106.02e18);
        vm.prank(guardian);
        box.shutdown();
        vm.warp(block.timestamp + box.shutdownWarmup() + 1);
        assertTrue(box.isWinddown());

        vm.prank(anyone);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.depledge(module, fdWeth, wsteth, 100e18 + 1);

        vm.startPrank(anyone);
        box.repay(module, fdWeth, weth, type(uint256).max);
        box.depledge(module, fdWeth, wsteth, type(uint256).max);
        vm.stopPrank();
        assertEq(module.debtBalance(fdWeth, weth), 0);
        assertEq(module.collateralBalance(fdWeth, wsteth), 0);
        assertFalse(evc.isControllerEnabled(module.subAccount(fdWeth), address(bvWeth)));
    }

    // ========== repay ==========

    function testRepayExactDebtClosesAndReleasesController() public {
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 100e18);
        _borrow(fdWeth, weth, 50e18);
        bvWeth.accrue(sub, 1_234_567); // sub-wei interest
        uint256 debt = module.debtBalance(fdWeth, weth);
        assertEq(debt, 50e18 + 1);
        uint256 boxBefore = weth.balanceOf(address(box));

        _repay(fdWeth, weth, debt);

        assertEq(bvWeth.debtOfExact(sub), 0);
        assertEq(module.debtBalance(fdWeth, weth), 0);
        assertFalse(evc.isControllerEnabled(sub, address(bvWeth)));
        assertEq(evc.getControllers(sub).length, 0);
        assertEq(weth.balanceOf(address(module)), 0);
        assertEq(weth.allowance(address(module), address(bvWeth)), 0);
        assertEq(boxBefore - weth.balanceOf(address(box)), debt);
    }

    function testPartialRepayKeepsController() public {
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 100e18);
        _borrow(fdWeth, weth, 50e18);
        bvWeth.accrue(sub, 7_000_000_001);
        uint256 debt = module.debtBalance(fdWeth, weth);

        _repay(fdWeth, weth, 10e18);

        assertEq(module.debtBalance(fdWeth, weth), debt - 10e18);
        assertTrue(evc.isControllerEnabled(sub, address(bvWeth)));
        assertEq(weth.balanceOf(address(module)), 0);
    }

    function testRepayAboveDebtRefundsOwner() public {
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 100e18);
        _borrow(fdWeth, weth, 50e18);
        bvWeth.accrue(sub, 999);
        uint256 debt = module.debtBalance(fdWeth, weth);
        uint256 boxBefore = weth.balanceOf(address(box));

        vm.startPrank(address(box));
        weth.transfer(address(module), debt + 5e18);
        module.repay(fdWeth, weth, debt + 5e18);
        vm.stopPrank();

        assertEq(bvWeth.debtOfExact(sub), 0);
        assertFalse(evc.isControllerEnabled(sub, address(bvWeth)));
        assertEq(weth.balanceOf(address(module)), 0);
        assertEq(boxBefore - weth.balanceOf(address(box)), debt, "the excess came back");
    }

    function testRepayWithRevertingOracle() public {
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 100e18);
        _borrow(fdWeth, weth, 50e18);
        router.setReverts(true);

        _repay(fdWeth, weth, 20e18);
        assertEq(module.debtBalance(fdWeth, weth), 30e18);
        _repay(fdWeth, weth, type(uint256).max);
        assertEq(module.debtBalance(fdWeth, weth), 0);
        assertFalse(evc.isControllerEnabled(sub, address(bvWeth)));
    }

    function testRepayWithoutDebtRefundsAndReleasesController() public {
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 100e18);
        _borrow(fdWeth, weth, 5e18);

        // A third party repays the whole debt: the controller stays until the module's next repay
        weth.mint(anyone, 5e18);
        vm.startPrank(anyone);
        weth.approve(address(bvWeth), 5e18);
        bvWeth.repay(type(uint256).max, sub);
        vm.stopPrank();
        assertTrue(evc.isControllerEnabled(sub, address(bvWeth)));

        uint256 boxBefore = weth.balanceOf(address(box));
        vm.startPrank(address(box));
        weth.transfer(address(module), 1e18);
        module.repay(fdWeth, weth, 1e18);
        vm.stopPrank();
        assertEq(weth.balanceOf(address(box)), boxBefore, "everything refunded");
        assertEq(weth.balanceOf(address(module)), 0);
        assertFalse(evc.isControllerEnabled(sub, address(bvWeth)));

        _repay(fdWeth, weth, type(uint256).max); // Box sends 0 when there is no debt
        assertEq(weth.balanceOf(address(box)), boxBefore);
    }

    // ========== depledge ==========

    function testDepledgeDeliversExactAmount() public {
        _skewSharePrice(cvWsteth, wsteth);
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 10e18);
        uint256 boxBefore = wsteth.balanceOf(address(box));

        _depledge(fdWeth, wsteth, 3e18);

        assertEq(wsteth.balanceOf(address(box)) - boxBefore, 3e18);
        assertEq(wsteth.balanceOf(address(module)), 0);
        MockEVC.CallRecord memory rec = evc.lastCall();
        assertEq(rec.target, address(cvWsteth));
        assertEq(rec.onBehalfOf, sub);
        assertEq(rec.data, abi.encodeCall(IEVault.withdraw, (3e18, address(box), sub)));
    }

    function testDepledgeFullBalanceLeavesNoShares() public {
        _skewSharePrice(cvWsteth, wsteth);
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 10e18);
        uint256 balance = module.collateralBalance(fdWeth, wsteth);
        assertTrue(balance < 10e18, "rounding left the balance below the pledge");
        uint256 boxBefore = wsteth.balanceOf(address(box));

        _depledge(fdWeth, wsteth, type(uint256).max);

        assertEq(cvWsteth.balanceOf(sub), 0, "no share dust");
        assertEq(wsteth.balanceOf(address(box)) - boxBefore, balance);
        assertEq(wsteth.balanceOf(address(module)), 0);
        assertEq(evc.lastCall().data, abi.encodeCall(IEVault.redeem, (type(uint256).max, address(box), sub)));
    }

    function testDepledgeAboveBalanceReverts() public {
        _skewSharePrice(cvWsteth, wsteth);
        _pledge(fdWeth, wsteth, 10e18);
        uint256 balance = module.collateralBalance(fdWeth, wsteth);

        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        module.depledge(fdWeth, wsteth, balance + 1);

        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        module.depledge(fdWeth, wsteth, 10e18);
        assertEq(module.collateralBalance(fdWeth, wsteth), balance);
    }

    // ========== views for unknown tokens and facilities ==========

    function testUnknownTokenViewsReturnZero(address token) public {
        vm.assume(token != address(wsteth) && token != address(weth));
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 1e18);

        assertEq(module.debtBalance(IERC20(token)), 0);
        assertEq(module.collateralBalance(IERC20(token)), 0);
        assertEq(module.debtBalance(IERC20(address(0))), 0);
        assertEq(module.collateralBalance(IERC20(address(0))), 0);
        assertEq(module.debtBalance(usdc), 0, "registered debt token without facility");
        assertEq(module.collateralBalance(cbbtc), 0, "registered collateral token without facility");
        assertEq(module.debtBalance(weth), 1e18);
        assertEq(module.collateralBalance(wsteth), 10e18);
    }

    function testUnregisteredFacilityViewsReturnZero() public {
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 1e18);

        bytes[] memory fds = new bytes[](6);
        fds[0] = fdUsdc;
        fds[1] = fdWeth2;
        fds[2] = "";
        fds[3] = new bytes(32);
        fds[4] = abi.encodePacked(fdWeth, bytes1(0));
        fds[5] = abi.encode(address(cvWsteth), address(bvWeth), uint256(0));
        IERC20[4] memory tokens = [IERC20(address(wsteth)), IERC20(address(weth)), IERC20(address(usdc)), IERC20(address(0))];
        for (uint256 i; i < fds.length; i++) {
            for (uint256 j; j < tokens.length; j++) {
                assertEq(module.debtBalance(fds[i], tokens[j]), 0);
                assertEq(module.collateralBalance(fds[i], tokens[j]), 0);
            }
            assertEq(module.ltv(fds[i]), 0);
            assertEq(module.subAccountId(fds[i]), 0);
        }
    }

    function testPerFacilityViewsZeroForOtherTokens() public {
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 1e18);

        assertEq(module.debtBalance(fdWeth, wsteth), 0);
        assertEq(module.debtBalance(fdWeth, usdc), 0);
        assertEq(module.debtBalance(fdWeth, stranger), 0);
        assertEq(module.collateralBalance(fdWeth, weth), 0);
        assertEq(module.collateralBalance(fdWeth, cbbtc), 0);
        assertEq(module.collateralBalance(fdWeth, stranger), 0);
        assertEq(module.debtBalance(fdWeth, weth), 1e18);
        assertEq(module.collateralBalance(fdWeth, wsteth), 10e18);
    }

    // ========== token balances aggregate facilities ==========

    function _fds() internal view returns (bytes[] memory fds) {
        fds = new bytes[](3);
        fds[0] = fdWeth;
        fds[1] = fdUsdc;
        fds[2] = fdWeth2;
    }

    function _snapshot() internal view returns (uint256[3] memory coll, uint256[3] memory debt) {
        bytes[] memory fds = _fds();
        IERC20[3] memory debtTokens = [IERC20(address(weth)), IERC20(address(usdc)), IERC20(address(weth))];
        for (uint256 i; i < 3; i++) {
            coll[i] = module.collateralBalance(fds[i], wsteth);
            debt[i] = module.debtBalance(fds[i], debtTokens[i]);
        }
    }

    function _checkStep(uint256 acted, uint256[3] memory collBefore, uint256[3] memory debtBefore) internal view {
        (uint256[3] memory coll, uint256[3] memory debt) = _snapshot();
        assertEq(module.collateralBalance(wsteth), coll[0] + coll[1] + coll[2], "collateral sum");
        assertEq(module.debtBalance(weth), debt[0] + debt[2], "weth debt sum");
        assertEq(module.debtBalance(usdc), debt[1], "usdc debt sum");
        assertEq(module.collateralBalance(cbbtc), 0);
        for (uint256 i; i < 3; i++) {
            if (i == acted) continue;
            assertEq(coll[i], collBefore[i], "other facility collateral unchanged");
            assertEq(debt[i], debtBefore[i], "other facility debt unchanged");
        }
    }

    function testTokenBalancesSumOverFacilities() public {
        _add(fdUsdc);
        _add(fdWeth2);
        address subA = module.subAccount(fdWeth);

        (uint256[3] memory c, uint256[3] memory d) = _snapshot();
        _pledge(fdWeth, wsteth, 10e18);
        _checkStep(0, c, d);
        (c, d) = _snapshot();
        _pledge(fdUsdc, wsteth, 20e18);
        _checkStep(1, c, d);
        (c, d) = _snapshot();
        _pledge(fdWeth2, wsteth, 30e18);
        _checkStep(2, c, d);
        (c, d) = _snapshot();
        _borrow(fdWeth, weth, 3e18);
        _checkStep(0, c, d);
        (c, d) = _snapshot();
        _borrow(fdUsdc, usdc, 10_000e6);
        _checkStep(1, c, d);
        (c, d) = _snapshot();
        _borrow(fdWeth2, weth, 5e18);
        _checkStep(2, c, d);
        (c, d) = _snapshot();
        bvWeth.accrue(subA, 1e15 * 1e9 + 7);
        _checkStep(0, c, d);
        (c, d) = _snapshot();
        _repay(fdWeth, weth, 1e18);
        _checkStep(0, c, d);
        (c, d) = _snapshot();
        _repay(fdUsdc, usdc, 2_000e6);
        _checkStep(1, c, d);
        (c, d) = _snapshot();
        _depledge(fdWeth2, wsteth, 5e18);
        _checkStep(2, c, d);
        (c, d) = _snapshot();
        _repay(fdWeth2, weth, type(uint256).max);
        _checkStep(2, c, d);

        assertEq(module.debtBalance(weth), 2e18 + 1e15 + 1);
        assertEq(module.debtBalance(usdc), 8_000e6);
        assertEq(module.collateralBalance(wsteth), 55e18);
    }

    // ========== nav ==========

    function _openTwoFacilities() internal returns (address subA, address subB) {
        _skewSharePrice(cvWsteth, wsteth);
        _add(fdUsdc);
        subA = module.subAccount(fdWeth);
        subB = module.subAccount(fdUsdc);
        _pledge(fdWeth, wsteth, 10e18 + 7);
        _borrow(fdWeth, weth, 3e18);
        bvWeth.accrue(subA, 5_555_555_555);
        _pledge(fdUsdc, wsteth, 5e18);
        _borrow(fdUsdc, usdc, 1_234_567_891);
    }

    function testNavMatchesFormulaWithRounding() public {
        (address subA, address subB) = _openTwoFacilities();

        uint256 collA = cvWsteth.convertToAssets(cvWsteth.balanceOf(subA));
        uint256 debtA = bvWeth.debtOf(subA);
        uint256 collB = cvWsteth.convertToAssets(cvWsteth.balanceOf(subB));
        uint256 debtB = bvUsdc.debtOf(subB);
        assertTrue(mulmod(collA, WSTETH_BOX_PRICE, 1e36) != 0, "collateral rounding matters");
        assertTrue(mulmod(collB, WSTETH_BOX_PRICE, 1e36) != 0, "collateral rounding matters");
        assertTrue(mulmod(debtB, USDC_BOX_PRICE, 1e36) != 0, "debt rounding matters");

        uint256 navA = (collA * WSTETH_BOX_PRICE) / 1e36 - debtA; // WETH debt is the Box asset: 1:1
        uint256 navB = (collB * WSTETH_BOX_PRICE) / 1e36 - Math.mulDiv(debtB, USDC_BOX_PRICE, 1e36, Math.Rounding.Ceil);
        assertEq(module.nav(provider), navA + navB);
        assertEq(module.nav(provider), _expectedNav(provider));
        assertEq(module.nav(IOracleCallback(address(box))), navA + navB, "same value with the Box oracles");
    }

    function testNavFloorsEachFacility() public {
        (address subA, ) = _openTwoFacilities();
        uint256 collA = cvWsteth.convertToAssets(cvWsteth.balanceOf(subA));
        uint256 navA = (collA * WSTETH_BOX_PRICE) / 1e36 - bvWeth.debtOf(subA);

        boxUsdcOracle.setPrice(USDC_BOX_PRICE * 10_000); // fdUsdc debt now worth far more than its collateral
        assertEq(module.nav(provider), navA, "underwater facility adds 0 and does not reduce the other");
    }

    function testNavIgnoresEulerQuotes() public {
        _openTwoFacilities();
        uint256 navBefore = module.nav(provider);
        router.setPrice(address(wsteth), address(weth), 0.5e18);
        router.setPrice(address(wsteth), USD, 1e18);
        assertEq(module.nav(provider), navBefore);
        router.setReverts(true);
        assertEq(module.nav(provider), navBefore);
    }

    function testNavExcludesIdleBalancesAndSkim() public {
        _openTwoFacilities();
        uint256 navBefore = module.nav(IOracleCallback(address(box)));
        uint256 totalBefore = box.totalAssets();

        ERC20MockDecimals[4] memory tokens = [wsteth, weth, usdc, stranger];
        uint256[4] memory amounts = [uint256(1e18), 2e18, 3e6, 4e18];
        for (uint256 i; i < 4; i++) {
            tokens[i].mint(address(module), amounts[i]);
        }
        assertEq(module.nav(IOracleCallback(address(box))), navBefore, "idle balances excluded");

        for (uint256 i; i < 4; i++) {
            uint256 boxBefore = tokens[i].balanceOf(address(box));
            vm.prank(allocator);
            box.skimFunding(module, tokens[i]);
            assertEq(tokens[i].balanceOf(address(module)), 0);
            assertEq(tokens[i].balanceOf(address(box)) - boxBefore, amounts[i]);
        }
        assertEq(module.nav(IOracleCallback(address(box))), navBefore);
        assertGt(box.totalAssets(), totalBefore, "skimmed Box tokens now count at the Box");
    }

    // ========== nav reverts only while a vault is locked ==========

    function testNavNeverRevertsInListedStates() public {
        FundingEuler empty = new FundingEuler(address(box), address(evc), LTV_CAP);
        assertEq(empty.nav(provider), 0, "no facilities");
        assertEq(module.nav(provider), 0, "registered facility without position");

        _add(fdUsdc);
        _add(fdWeth2);
        assertEq(module.nav(provider), 0);

        // fdWeth: debt without collateral
        address subA = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 5e18);
        cvWsteth.seize(subA, liquidator, cvWsteth.balanceOf(subA));
        assertEq(module.nav(provider), 0, "debt without collateral adds 0");

        // fdUsdc: underwater
        _pledge(fdUsdc, wsteth, 1e18);
        _borrow(fdUsdc, usdc, 3_000e6);
        boxUsdcOracle.setPrice(USDC_BOX_PRICE * 100);
        assertEq(module.nav(provider), 0, "underwater adds 0");

        // fdWeth2: healthy, and a reverting Euler oracle
        _pledge(fdWeth2, wsteth, 10e18);
        _borrow(fdWeth2, weth, 2e18);
        router.setReverts(true);
        uint256 expected = (10e18 * WSTETH_BOX_PRICE) / 1e36 - 2e18;
        assertEq(module.nav(provider), expected);
        assertEq(module.nav(provider), _expectedNav(provider));
    }

    function testNavRevertsWhileVaultLocked() public {
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 5e18);
        uint256 navBefore = module.nav(provider);

        cvWsteth.setLocked(true);
        vm.expectRevert(MockEVault.E_Reentrancy.selector);
        module.nav(provider);
        vm.expectRevert(MockEVault.E_Reentrancy.selector);
        box.totalAssets();
        cvWsteth.setLocked(false);

        bvWeth.setLocked(true);
        vm.expectRevert(MockEVault.E_Reentrancy.selector);
        module.nav(provider);
        bvWeth.setLocked(false);

        assertEq(module.nav(provider), navBefore);
    }

    // ========== ltv ==========

    function testLtvZeroWithoutDebtWithoutOracle() public {
        assertEq(module.ltv(fdWeth), 0, "no position");
        _pledge(fdWeth, wsteth, 10e18);
        router.setReverts(true);
        assertEq(module.ltv(fdWeth), 0, "no debt, oracle not called");
    }

    function testLtvMaxWhenCollateralValueZero() public {
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 1e18);

        cvWsteth.seize(sub, liquidator, 10e18 - 5);
        router.setPrice(address(wsteth), address(weth), 0.1e18); // 5 wei of shares quote to 0
        assertEq(router.getQuote(5, address(cvWsteth), address(weth)), 0);
        assertEq(module.ltv(fdWeth), type(uint256).max, "collateral worth 0");

        cvWsteth.seize(sub, liquidator, 5);
        assertEq(module.ltv(fdWeth), type(uint256).max, "no collateral shares");
    }

    function testLtvRawQuoteRatioInDebtUnitOfAccount() public {
        _skewSharePrice(cvWsteth, wsteth);
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 100e18 + 7);
        _borrow(fdWeth, weth, 3e18);
        bvWeth.accrue(sub, 3_333_333_333);

        uint256 collateralValue = router.getQuote(cvWsteth.balanceOf(sub), address(cvWsteth), address(weth));
        uint256 debt = bvWeth.debtOf(sub);
        assertTrue(mulmod(debt, 1e18, collateralValue) != 0, "rounding up adds 1");
        assertEq(module.ltv(fdWeth), (debt * 1e18) / collateralValue + 1);
    }

    function testLtvRawQuoteRatioInUsd() public {
        _add(fdUsdc);
        address sub = module.subAccount(fdUsdc);
        _pledge(fdUsdc, wsteth, 10e18);
        _borrow(fdUsdc, usdc, 12_345_678_901);

        uint256 collateralValue = router.getQuote(cvWsteth.balanceOf(sub), address(cvWsteth), USD);
        uint256 debtValue = router.getQuote(bvUsdc.debtOf(sub), address(usdc), USD);
        uint256 expected = Math.mulDiv(debtValue, 1e18, collateralValue, Math.Rounding.Ceil);
        assertEq(module.ltv(fdUsdc), expected);
        assertEq(expected, 257201643770833334, "12,345.678901 USD over 48,000 USD, rounded up");
    }

    function testLtvIgnoresBoxOracles() public {
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 5e18);
        uint256 ltvBefore = module.ltv(fdWeth);
        boxWstethOracle.setPrice(WSTETH_BOX_PRICE / 2);
        assertEq(module.ltv(fdWeth), ltvBefore);
        router.setPrice(address(wsteth), address(weth), 1e18);
        assertEq(module.ltv(fdWeth), 0.5e18, "follows the Euler quote");
    }

    function testLtvUsesBorrowVaultOracleNotCollateralVaultOracle() public {
        // The collateral vault keeps `router` (USD unit of account); the borrow vault has its own router in WETH
        MockEulerRouter borrowRouter = new MockEulerRouter();
        MockEVault bvWethOwnOracle = new MockEVault(address(evc), address(weth), address(borrowRouter), address(weth));
        bvWethOwnOracle.setLTV(address(cvWsteth), 9300, 9500);
        borrowRouter.setResolvedVault(address(cvWsteth), true);
        borrowRouter.setPrice(address(wsteth), address(weth), 1.1e18);
        _seed(bvWethOwnOracle, weth, 1_000e18);
        assertEq(cvWsteth.oracle(), address(router));

        bytes memory fd = abi.encode(address(cvWsteth), address(bvWethOwnOracle));
        _add(fd);
        address sub = module.subAccount(fd);
        _pledge(fd, wsteth, 10e18);
        _borrow(fd, weth, 5e18);
        bvWethOwnOracle.accrue(sub, 7);

        uint256 shares = cvWsteth.balanceOf(sub);
        uint256 debt = bvWethOwnOracle.debtOf(sub);
        uint256 expected = Math.mulDiv(debt, 1e18, borrowRouter.getQuote(shares, address(cvWsteth), address(weth)), Math.Rounding.Ceil);
        assertEq(expected, 454545454545454546, "5 WETH over 11 WETH, rounded up");

        router.setReverts(true);
        vm.expectCall(address(router), abi.encodeWithSelector(MockEulerRouter.getQuote.selector), 0);
        vm.expectCall(address(borrowRouter), abi.encodeCall(MockEulerRouter.getQuote, (debt, address(weth), address(weth))), 0);
        vm.expectCall(address(borrowRouter), abi.encodeCall(MockEulerRouter.getQuote, (shares, address(cvWsteth), address(weth))), 1);
        assertEq(module.ltv(fd), expected);
    }

    // ========== removal ==========

    function testRemoveFacilityOnlyWhenEmpty() public {
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 1e18);

        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(fdWeth);

        _repay(fdWeth, weth, type(uint256).max);
        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(fdWeth);

        _depledge(fdWeth, wsteth, type(uint256).max);
        assertTrue(evc.isCollateralEnabled(sub, address(cvWsteth)));
        _remove(fdWeth);

        assertFalse(module.isFacility(fdWeth));
        assertEq(module.facilitiesLength(), 0);
        assertEq(module.subAccountId(fdWeth), 0);
        assertEq(evc.getControllers(sub).length, 0);
        assertEq(evc.getCollaterals(sub).length, 0);

        _add(fdUsdc);
        assertEq(module.subAccountId(fdUsdc), 1, "id freed");
    }

    function testRemoveFacilityReleasesControllerLeftByThirdPartyRepay() public {
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 1e18);
        weth.mint(anyone, 1e18);
        vm.startPrank(anyone);
        weth.approve(address(bvWeth), 1e18);
        bvWeth.repay(type(uint256).max, sub);
        vm.stopPrank();
        _depledge(fdWeth, wsteth, type(uint256).max);
        assertTrue(evc.isControllerEnabled(sub, address(bvWeth)));

        _remove(fdWeth);
        assertEq(evc.getControllers(sub).length, 0);
        assertEq(evc.getCollaterals(sub).length, 0);
    }

    function testRemoveFacilityBlockedByDonatedShares() public {
        address sub = module.subAccount(fdWeth);
        wsteth.mint(anyone, 1e18);
        vm.startPrank(anyone);
        wsteth.approve(address(cvWsteth), 1e18);
        cvWsteth.deposit(1e18, sub);
        vm.stopPrank();

        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(fdWeth);

        _depledge(fdWeth, wsteth, type(uint256).max);
        _remove(fdWeth);
        assertFalse(module.isFacility(fdWeth));
    }

    function testRemoveFacilityBlockedByDebtWithoutCollateral() public {
        address sub = module.subAccount(fdWeth);
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 1e18);
        cvWsteth.seize(sub, liquidator, 10e18);

        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(fdWeth);
    }

    function testRemoveUnregisteredFacilityReverts() public {
        bytes[] memory fds = new bytes[](3);
        fds[0] = fdUsdc;
        fds[1] = "";
        fds[2] = abi.encodePacked(fdWeth, bytes1(0));
        for (uint256 i; i < fds.length; i++) {
            vm.prank(address(box));
            vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
            module.removeFacility(fds[i]);
        }
    }

    function testRemoveTokens() public {
        _pledge(fdWeth, wsteth, 10e18);
        _borrow(fdWeth, weth, 1e18);

        vm.startPrank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeCollateralToken(wsteth);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeDebtToken(weth);
        vm.stopPrank();

        _repay(fdWeth, weth, type(uint256).max);
        _depledge(fdWeth, wsteth, type(uint256).max);

        vm.startPrank(address(box));
        // Balances are 0 but the registered facility still uses both tokens
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeCollateralToken(wsteth);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeDebtToken(weth);

        module.removeCollateralToken(cbbtc);
        module.removeDebtToken(usdc);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.removeCollateralToken(stranger);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.removeDebtToken(stranger);

        module.removeFacility(fdWeth);
        module.removeCollateralToken(wsteth);
        module.removeDebtToken(weth);
        vm.stopPrank();
        assertEq(module.collateralTokensLength(), 0);
        assertEq(module.debtTokensLength(), 0);
    }

    // ========== zero-value share dust ==========

    uint256 internal constant DUST_SHARES = 1e6;

    /// @dev fdWeth's sub-account ends with DUST_SHARES collateral-vault shares worth 0 assets and no debt, as after a
    ///      liquidation followed by bad-debt socialisation on both vaults. With `withController`, the borrow vault stays
    ///      enabled as controller (debt written off, never repaid).
    function _setUpZeroValueDust(bool withController) internal returns (address sub) {
        sub = module.subAccount(fdWeth);
        _seed(cvWsteth, wsteth, 1_000e18);
        _pledge(fdWeth, wsteth, 10e18);
        if (withController) {
            _borrow(fdWeth, weth, 5e18);
            bvWeth.accrue(sub, 1);
        }
        cvWsteth.seize(sub, liquidator, 10e18 - DUST_SHARES);
        if (withController) bvWeth.writeOff(sub);
        cvWsteth.socializeLoss(cvWsteth.cash());

        assertEq(cvWsteth.balanceOf(sub), DUST_SHARES, "dust shares");
        assertEq(cvWsteth.convertToAssets(DUST_SHARES), 0, "worth 0");
        assertEq(bvWeth.debtOf(sub), 0, "no debt");
        assertEq(bvWeth.debtOfExact(sub), 0, "no sub-wei debt");
        assertEq(evc.isControllerEnabled(sub, address(bvWeth)), withController, "controller");
        assertTrue(evc.isCollateralEnabled(sub, address(cvWsteth)), "collateral enabled");
    }

    /// @dev Raises the collateral-vault share price so that DUST_SHARES are worth exactly 1 wei
    function _makeDustWorthOneWei() internal {
        uint256 needed = Math.ceilDiv(cvWsteth.totalSupply() + 1e6, DUST_SHARES) - 1e6 - cvWsteth.totalAssets();
        wsteth.mint(address(this), needed);
        wsteth.approve(address(cvWsteth), needed);
        cvWsteth.addYield(needed);
        assertEq(cvWsteth.convertToAssets(DUST_SHARES), 1, "worth 1 wei");
    }

    function _checkRemovalWithZeroValueDust(bool withController) internal {
        address sub = _setUpZeroValueDust(withController);
        uint256 dustId = module.subAccountId(fdWeth);
        assertEq(module.collateralBalance(fdWeth, wsteth), 0);
        assertEq(module.collateralBalance(wsteth), 0);
        assertEq(module.debtBalance(weth), 0);
        assertEq(module.nav(provider), 0);

        // A full depledge cannot clear the dust: Euler refuses to redeem shares for 0 assets
        vm.prank(address(box));
        vm.expectRevert(MockEVault.E_ZeroAssets.selector);
        module.depledge(fdWeth, wsteth, 0);

        _remove(fdWeth);

        assertFalse(module.isFacility(fdWeth));
        assertEq(module.facilitiesLength(), 0);
        assertEq(module.subAccountId(fdWeth), 0);
        assertEq(evc.getControllers(sub).length, 0, "controller released");
        assertEq(evc.getCollaterals(sub).length, 0, "collateral disabled");
        assertEq(cvWsteth.balanceOf(sub), DUST_SHARES, "dust stays on the sub-account");
        assertEq(module.collateralBalance(fdWeth, wsteth), 0);
        assertEq(module.collateralBalance(wsteth), 0);
        assertEq(module.debtBalance(weth), 0);

        // The token registrations can be removed afterwards
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(address(box));
        module.removeCollateralToken(wsteth);
        module.removeDebtToken(weth);
        vm.stopPrank();
        assertFalse(module.isCollateralToken(wsteth));
        assertFalse(module.isDebtToken(weth));
        vm.revertToState(snapshot);

        // The dust becomes worth something again, and is never counted by a later facility
        wsteth.mint(address(this), 10e18);
        wsteth.approve(address(cvWsteth), 10e18);
        cvWsteth.addYield(10e18);
        uint256 dustValue = cvWsteth.convertToAssets(DUST_SHARES);
        assertGt(dustValue, 0, "dust worth more than 0");
        assertEq(module.collateralBalance(wsteth), 0, "removed facility not counted");

        _add(fdWeth);
        uint256 readdedId = module.subAccountId(fdWeth);
        assertTrue(readdedId != dustId, "dust id not reused");
        assertTrue(module.subAccount(fdWeth) != sub);
        assertEq(module.collateralBalance(fdWeth, wsteth), 0, "re-added facility starts empty");
        assertEq(module.collateralBalance(wsteth), 0);

        _add(fdUsdc);
        assertTrue(module.subAccountId(fdUsdc) != dustId && module.subAccountId(fdUsdc) != readdedId);
        assertTrue(module.subAccount(fdUsdc) != sub);
        assertEq(module.collateralBalance(fdUsdc, wsteth), 0);

        _pledge(fdWeth, wsteth, 10e18);
        uint256 readded = module.collateralBalance(fdWeth, wsteth);
        assertApproxEqAbs(readded, 10e18, 2, "share rounding only");
        assertLe(readded, 10e18);
        _pledge(fdUsdc, wsteth, 3e18);
        uint256 other = module.collateralBalance(fdUsdc, wsteth);
        assertApproxEqAbs(other, 3e18, 2, "share rounding only");
        assertLe(other, 3e18);
        assertGt(cvWsteth.convertToAssets(cvWsteth.balanceOf(sub)), 0, "dust still worth more than 0");
        assertEq(module.collateralBalance(wsteth), readded + other, "sum over registered facilities, dust excluded");
        assertEq(module.nav(provider), _expectedNav(provider));
    }

    function testRemoveFacilityWithZeroValueDustAndController() public {
        _checkRemovalWithZeroValueDust(true);
    }

    function testRemoveFacilityWithZeroValueDustWithoutController() public {
        _checkRemovalWithZeroValueDust(false);
    }

    function testRemoveFacilityBlockedByDustWorthOneWei() public {
        _setUpZeroValueDust(false);
        _makeDustWorthOneWei();
        assertEq(module.collateralBalance(fdWeth, wsteth), 1);

        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(fdWeth);
        assertTrue(module.isFacility(fdWeth));
    }

    function testRemoveFacilityBlockedByDustWorthOneWeiWithController() public {
        _setUpZeroValueDust(true);
        _makeDustWorthOneWei();

        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(fdWeth);
        assertTrue(module.isFacility(fdWeth));
    }

    function testRemoveFacilityBlockedByZeroValueDustAndOneWeiDebt() public {
        address sub = _setUpZeroValueDust(true);
        bvWeth.accrue(sub, 1e9);
        assertEq(bvWeth.debtOf(sub), 1);
        assertEq(module.debtBalance(weth), 1);

        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(fdWeth);
        assertTrue(module.isFacility(fdWeth));
    }

    function testRemoveFacilityBlockedByZeroValueDustAndSubWeiDebt() public {
        address sub = _setUpZeroValueDust(true);
        bvWeth.accrue(sub, 1);
        assertEq(bvWeth.debtOf(sub), 1, "rounded up");

        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(fdWeth);
    }
}
