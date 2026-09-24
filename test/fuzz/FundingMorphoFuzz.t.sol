// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {IMorpho, Market, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {ErrorsLib as MorphoErrorsLib} from "@morpho-blue/libraries/ErrorsLib.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {IrmMock} from "@morpho-blue/mocks/IrmMock.sol";
import {OracleMock} from "@morpho-blue/mocks/OracleMock.sol";
import {Morpho} from "@morpho-blue/Morpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../../src/Box.sol";
import {FundingBase} from "../../src/FundingBase.sol";
import {FundingMorpho} from "../../src/FundingMorpho.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IFunding, IOracleCallback} from "../../src/interfaces/IFunding.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "../mocks/ERC20MockDecimals.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @dev Stateless fuzzing of FundingMorpho on a real local Morpho Blue (IrmMock interest, OracleMock market prices), driven
/// either directly by its owner or through a real Box (allocator actions, Box oracles for nav).
contract FundingMorphoFuzzTest is Test {
    using BoxLib for IBox;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_SCALE = 1e36;
    /// @dev Virtual shares and assets of Morpho Blue's SharesMathLib
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    /// @dev Collateral positions are bounded to this many whole tokens
    uint256 internal constant MAX_WHOLE_COLLATERAL = 1e9;

    address internal moduleOwner = address(0x123);
    address internal boxOwner = address(0x1);
    address internal allocator = address(0x2);
    address internal curator = address(0x3);
    address internal guardian = address(0x4);
    address internal supplier = address(0x9);
    address internal thirdPartyBorrower = address(0xA);

    IMorpho internal morpho;
    address internal irm;

    /// @dev Result of a borrow or depledge predicted by the replica, listed in the order the checks run on-chain
    enum Outcome {
        Ok,
        InsufficientCollateral,
        InsufficientLiquidity,
        ExcessiveLtv,
        Underflow
    }

    /// @dev Everything Morpho's health check and FundingMorpho's guard read, with interest accrued up to the current block
    struct Snapshot {
        uint256 totalSupplyAssets;
        uint256 totalBorrowAssets;
        uint256 totalBorrowShares;
        uint256 borrowShares;
        uint256 collateral;
        uint256 price;
        uint256 lltv;
        uint256 maxLtv;
    }

    struct DebtState {
        uint256 shares;
        uint256 totalBorrowAssets;
        uint256 totalBorrowShares;
        uint256 debt;
    }

    struct PositionCase {
        ERC20MockDecimals loanToken;
        ERC20MockDecimals collateralToken;
        uint256 priceSeed;
        uint256 lltvSeed;
        uint256 collateralSeed;
        uint256 borrowSeed;
    }

    function setUp() public {
        morpho = IMorpho(address(new Morpho(address(this))));
        irm = address(new IrmMock());
        morpho.enableIrm(irm);
    }

    /////////////////////////////
    /// VAL-FUZZ-006: BOX ROUND TRIP
    /////////////////////////////

    struct RoundTripCase {
        uint256 decimalsSeed;
        bool loanIsAsset;
        uint256 morphoPriceSeed;
        uint256 boxPriceSeed;
        uint256 lltvSeed;
        uint256 capSeed;
        uint256 collateral;
        uint256 borrow;
        uint256 thirdPartyBorrow;
        uint256 seedElapsed;
        uint256 elapsed;
    }

    function testFuzz_BoxRoundTripCostsAtMostInterest(RoundTripCase memory rc) public {
        ERC20MockDecimals collateralToken = new ERC20MockDecimals(_decimals(rc.decimalsSeed));
        ERC20MockDecimals loanToken = new ERC20MockDecimals(_decimals(rc.decimalsSeed / 3));
        ERC20MockDecimals asset = rc.loanIsAsset ? loanToken : new ERC20MockDecimals(_decimals(rc.decimalsSeed / 9));

        uint256 price = _price(rc.morphoPriceSeed, collateralToken.decimals(), loanToken.decimals());
        // At least 1e4 loan-token units of collateral value: with lltv >= 30% and lltvCap >= 10%, some borrow is allowed
        uint256 minCollateral = Math.mulDiv(1e4, ORACLE_SCALE, price, Math.Rounding.Ceil);
        uint256 collateral = _boundLog(rc.collateral, minCollateral, _maxCollateral(collateralToken));
        MarketParams memory mp = _createMarket(address(loanToken), address(collateralToken), price, bound(rc.lltvSeed, 0.3e18, 0.98e18));
        uint256 collateralValue = (collateral * price) / ORACLE_SCALE;
        uint256 thirdPartyBorrow = _boundLog(rc.thirdPartyBorrow, 0, collateralValue);
        _seedMarket(mp, thirdPartyBorrow + collateralValue + 1, thirdPartyBorrow, bound(rc.seedElapsed, 0, 30 days));

        (IBox box, FundingMorpho module) = _deployBoxWithModule(asset, bound(rc.capSeed, 0.1e18, WAD));
        vm.startPrank(curator);
        box.addTokenInstant(collateralToken, new MockOracle(_price(rc.boxPriceSeed, collateralToken.decimals(), asset.decimals())));
        if (!rc.loanIsAsset) {
            box.addTokenInstant(loanToken, new MockOracle(_price(rc.boxPriceSeed / 7, loanToken.decimals(), asset.decimals())));
        }
        vm.stopPrank();
        bytes memory fd = _attachFacility(box, module, mp);

        collateralToken.mint(address(box), collateral);
        uint256 boxCollateralStart = collateralToken.balanceOf(address(box));
        vm.prank(allocator);
        box.pledge(module, fd, collateralToken, collateral);
        assertEq(collateralToken.balanceOf(address(box)), boxCollateralStart - collateral, "pledge takes the collateral from the Box");
        assertEq(module.collateralBalance(fd, collateralToken), collateral, "collateral supplied to Morpho");
        _assertModuleHoldsNothing(module, mp, "after pledge");

        uint256 maxBorrow = _maxBorrow(_snapshot(module, mp));
        assertGe(maxBorrow, 1, "bounds leave room to borrow");
        // An eighth of the runs borrow the largest amount the guard and Morpho allow
        uint256 borrowAmount = rc.borrow % 8 == 0 ? maxBorrow : _boundLog(rc.borrow, 1, maxBorrow);
        // A year at up to 100% utilization multiplies a debt by less than 2.67 (IrmMock rate, 3-term Taylor compounding)
        loanToken.mint(address(box), 2 * borrowAmount + 10);
        uint256 boxLoanStart = loanToken.balanceOf(address(box));
        vm.prank(allocator);
        box.borrow(module, fd, loanToken, borrowAmount);
        assertEq(loanToken.balanceOf(address(box)), boxLoanStart + borrowAmount, "Box receives exactly the borrowed amount");
        _assertModuleHoldsNothing(module, mp, "after borrow");
        uint256 debtAfterBorrow = module.debtBalance(fd, loanToken);
        assertGe(debtAfterBorrow, borrowAmount, "debt covers the borrowed amount");
        assertLe(debtAfterBorrow, borrowAmount + 1, "borrow share rounding adds at most 1 wei of debt");

        vm.warp(block.timestamp + bound(rc.elapsed, 0, 365 days));
        uint256 debtBeforeRepay = module.debtBalance(fd, loanToken);
        assertEq(debtBeforeRepay, _debtState(mp, address(module)).debt, "debtBalance matches the independent accrual replica");
        uint256 interest = debtBeforeRepay - debtAfterBorrow;

        vm.prank(allocator);
        box.repay(module, fd, loanToken, type(uint256).max);
        _assertModuleHoldsNothing(module, mp, "after repay");
        assertEq(module.debtBalance(fd, loanToken), 0, "repay(max) closes the debt");
        assertEq(morpho.position(mp.id(), address(module)).borrowShares, 0, "no borrow shares left");
        assertEq(
            loanToken.balanceOf(address(box)),
            boxLoanStart + borrowAmount - debtBeforeRepay,
            "repay(max) takes exactly the debt from the Box"
        );

        vm.prank(allocator);
        box.depledge(module, fd, collateralToken, type(uint256).max);
        _assertModuleHoldsNothing(module, mp, "after depledge");
        assertEq(module.collateralBalance(fd, collateralToken), 0, "depledge(max) withdraws all the collateral");
        assertEq(collateralToken.balanceOf(address(box)), boxCollateralStart, "Box collateral back to its starting balance");

        uint256 netCost = boxLoanStart - loanToken.balanceOf(address(box));
        assertLe(netCost, interest + 1, "net loan-token cost <= accrued interest + 1 wei of borrow rounding");

        vm.startPrank(curator);
        box.removeFundingFacility(module, fd);
        box.removeFundingCollateral(module, collateralToken);
        box.removeFundingDebt(module, loanToken);
        box.removeFunding(module);
        vm.stopPrank();
        assertFalse(module.isFacility(fd), "facility removed");
        assertFalse(box.isFunding(module), "module removed");
    }

    /////////////////////////////
    /// VAL-FUZZ-007: NAV MATCHES THE PER-FACILITY REFERENCE
    /////////////////////////////

    struct NavCase {
        uint256 decimalsSeed;
        bool collateral2IsAsset;
        bool forceUnderwater;
        uint256 morphoPrice1;
        uint256 morphoPrice2;
        uint256 boxPriceCollateral1;
        uint256 boxPriceCollateral2;
        uint256 boxPriceLoan2;
        uint256 lltvSeed;
        uint256 collateral1;
        uint256 collateral2;
        uint256 borrow1;
        uint256 borrow2;
        uint256 elapsed;
    }

    function testFuzz_NavMatchesPerFacilityReference(NavCase memory nc) public {
        ERC20MockDecimals asset = new ERC20MockDecimals(_decimals(nc.decimalsSeed));
        ERC20MockDecimals collateral1 = new ERC20MockDecimals(_decimals(nc.decimalsSeed / 3));
        ERC20MockDecimals collateral2 = nc.collateral2IsAsset ? asset : new ERC20MockDecimals(_decimals(nc.decimalsSeed / 9));
        ERC20MockDecimals loan2 = new ERC20MockDecimals(_decimals(nc.decimalsSeed / 27));

        (IBox box, FundingMorpho module) = _deployBoxWithModule(asset, WAD);
        vm.startPrank(curator);
        box.addTokenInstant(collateral1, new MockOracle(_price(nc.boxPriceCollateral1, collateral1.decimals(), asset.decimals())));
        if (!nc.collateral2IsAsset) {
            box.addTokenInstant(collateral2, new MockOracle(_price(nc.boxPriceCollateral2, collateral2.decimals(), asset.decimals())));
        }
        box.addTokenInstant(loan2, new MockOracle(_price(nc.boxPriceLoan2, loan2.decimals(), asset.decimals())));
        vm.stopPrank();

        // Facility 1 borrows the Box asset (valued 1:1 without an oracle); facility 2 borrows another Box token, possibly
        // against the Box asset. Morpho market prices are drawn independently of the Box oracle prices, so a facility can be
        // healthy on Morpho and underwater in Box terms.
        MarketParams memory market1 = _openBoxPosition(
            box,
            module,
            PositionCase(asset, collateral1, nc.morphoPrice1, nc.lltvSeed, nc.collateral1, nc.borrow1)
        );
        MarketParams memory market2 = _openBoxPosition(
            box,
            module,
            PositionCase(loan2, collateral2, nc.morphoPrice2, nc.lltvSeed / 11, nc.collateral2, nc.borrow2)
        );
        vm.warp(block.timestamp + bound(nc.elapsed, 0, 365 days));
        bool forced = nc.forceUnderwater && !nc.collateral2IsAsset && _forceUnderwater(box, module, market2, nc.boxPriceCollateral2 / 13);

        uint256 nav;
        try module.nav(IOracleCallback(address(box))) returns (uint256 value) {
            nav = value;
        } catch {
            assertTrue(false, "nav must never revert");
        }
        uint256 reference1 = _referenceFacilityNav(box, module, market1);
        uint256 reference2 = _referenceFacilityNav(box, module, market2);
        if (forced) assertEq(reference2, 0, "an underwater facility is floored at zero");
        // Each reference is <= that facility's exact equity floored at zero, hence nav <= the exact unrounded equity
        assertEq(nav, reference1 + reference2, "nav = sum of the per-facility floored values");
        _assertTotalAssetsIncludesNav(box, nav);
    }

    /////////////////////////////
    /// VAL-FUZZ-008: GUARD BOUNDARY IS EXACT
    /////////////////////////////

    struct BoundaryCase {
        uint256 decimalsSeed;
        uint256 priceSeed;
        uint256 lltvSeed;
        uint256 capSeed;
        uint256 collateral;
        uint256 thirdPartyBorrow;
        uint256 elapsed;
        uint256 preBorrow;
        uint256 preElapsed;
    }

    /// @dev Borrow boundary on a position with a fuzzed (possibly zero) accrued debt, then the depledge boundary at the
    /// resulting largest allowed debt
    function testFuzz_GuardBoundaryIsExact(BoundaryCase memory bc) public {
        (FundingMorpho module, MarketParams memory mp, uint256 lltvCap) = _setUpBoundary(bc);
        _checkBorrowBoundary(module, mp, lltvCap);
        _checkDepledgeBoundary(module, mp, lltvCap);
    }

    /// @dev Depledge boundary at a fuzzed partial debt in [0, largest allowed borrow], with interest accrued on it
    function testFuzz_DepledgeBoundaryAtPartialDebtIsExact(BoundaryCase memory bc) public {
        (FundingMorpho module, MarketParams memory mp, uint256 lltvCap) = _setUpBoundary(bc);
        _checkDepledgeBoundary(module, mp, lltvCap);
    }

    /// @dev Fuzzed market (decimals, Morpho price, lltv, third-party debt, accrued interest) and module (lltvCap), a fuzzed
    /// pledge, then a fuzzed borrow in [0, largest allowed] followed by more accrued interest
    function _setUpBoundary(BoundaryCase memory bc) internal returns (FundingMorpho module, MarketParams memory mp, uint256 lltvCap) {
        ERC20MockDecimals collateralToken = new ERC20MockDecimals(_decimals(bc.decimalsSeed));
        ERC20MockDecimals loanToken = new ERC20MockDecimals(_decimals(bc.decimalsSeed / 3));
        uint256 price = _price(bc.priceSeed, collateralToken.decimals(), loanToken.decimals());
        uint256 collateral = _boundLog(bc.collateral, 1, _maxCollateral(collateralToken));
        uint256 collateralValue = (collateral * price) / ORACLE_SCALE;
        // A quarter of the runs use lltvCap = 100%, where Morpho's own LLTV check is the binding one
        lltvCap = bc.capSeed % 4 == 0 ? WAD : bound(bc.capSeed, 1, WAD);

        mp = _createMarket(address(loanToken), address(collateralToken), price, bound(bc.lltvSeed, 0.01e18, WAD - 1));
        module = _directModule(mp, lltvCap);
        uint256 thirdPartyBorrow = _boundLog(bc.thirdPartyBorrow, 0, collateralValue);
        _seedMarket(mp, thirdPartyBorrow + collateralValue + 1, thirdPartyBorrow, bound(bc.elapsed, 0, 365 days));
        _pledgeDirect(module, mp, collateral);

        uint256 preBorrow = _boundLog(bc.preBorrow, 0, _maxBorrow(_snapshot(module, mp)));
        if (preBorrow > 0) {
            vm.prank(moduleOwner);
            module.borrow(abi.encode(mp), loanToken, preBorrow);
            vm.warp(block.timestamp + bound(bc.preElapsed, 0, 30 days));
            morpho.accrueInterest(mp);
        }
    }

    function _checkBorrowBoundary(FundingMorpho module, MarketParams memory mp, uint256 lltvCap) internal {
        bytes memory fd = abi.encode(mp);
        IERC20 loanToken = IERC20(mp.loanToken);
        Snapshot memory s = _snapshot(module, mp);
        uint256 maxBorrow = _maxBorrow(s);
        Outcome beyond = _borrowOutcome(s, maxBorrow + 1);
        if (lltvCap == WAD) assertTrue(beyond != Outcome.ExcessiveLtv, "with a 100% cap Morpho's LLTV check binds first");

        vm.startPrank(moduleOwner);
        _expectRevert(beyond);
        module.borrow(fd, loanToken, maxBorrow + 1);
        if (maxBorrow > 0) {
            uint256 ownerBalance = loanToken.balanceOf(moduleOwner);
            module.borrow(fd, loanToken, maxBorrow);
            assertEq(loanToken.balanceOf(moduleOwner), ownerBalance + maxBorrow, "largest allowed borrow delivered to the owner");
            assertLe(module.ltv(fd), s.maxLtv, "guard holds after the largest allowed borrow");
        }
        vm.stopPrank();

        Snapshot memory afterBorrow = _snapshot(module, mp);
        uint256 borrowed = _toAssetsUp(afterBorrow.borrowShares, afterBorrow.totalBorrowAssets, afterBorrow.totalBorrowShares);
        assertEq(module.ltv(fd), _moduleLtv(borrowed, afterBorrow.collateral, afterBorrow.price), "ltv matches the replica");
    }

    function _checkDepledgeBoundary(FundingMorpho module, MarketParams memory mp, uint256 lltvCap) internal {
        bytes memory fd = abi.encode(mp);
        IERC20 collateralToken = IERC20(mp.collateralToken);
        Snapshot memory s = _snapshot(module, mp);
        uint256 maxDepledge = _maxDepledge(s);
        Outcome beyond = _depledgeOutcome(s, maxDepledge + 1);
        if (lltvCap == WAD) assertTrue(beyond != Outcome.ExcessiveLtv, "with a 100% cap Morpho's LLTV check binds first");
        if (s.borrowShares == 0) assertEq(maxDepledge, s.collateral, "without debt all the collateral can be withdrawn");

        vm.startPrank(moduleOwner);
        _expectRevert(beyond);
        module.depledge(fd, collateralToken, maxDepledge + 1);
        if (maxDepledge > 0) {
            uint256 ownerBalance = collateralToken.balanceOf(moduleOwner);
            module.depledge(fd, collateralToken, maxDepledge);
            assertEq(collateralToken.balanceOf(moduleOwner), ownerBalance + maxDepledge, "largest allowed withdrawal delivered");
            assertEq(module.collateralBalance(fd, collateralToken), s.collateral - maxDepledge, "collateral left");
            assertLe(module.ltv(fd), s.maxLtv, "guard holds after the largest allowed withdrawal");
        }
        vm.stopPrank();
    }

    /////////////////////////////
    /// VAL-FUZZ-009: ONLY CANONICAL FACILITY DATA
    /////////////////////////////

    struct EncodingCase {
        uint256 mode;
        uint256 loanChoice;
        uint256 collateralChoice;
        address randomToken;
        address oracle;
        address irmAddress;
        uint256 lltv;
        uint256 mutation;
        bytes raw;
    }

    function testFuzz_AddFacilityAcceptsOnlyCanonicalEncoding(EncodingCase memory ec) public {
        ERC20MockDecimals collateralToken = new ERC20MockDecimals(18);
        ERC20MockDecimals loanToken = new ERC20MockDecimals(6);
        FundingMorpho module = new FundingMorpho(moduleOwner, address(morpho), 0.9e18);
        vm.startPrank(moduleOwner);
        module.addCollateralToken(collateralToken);
        module.addDebtToken(loanToken);
        vm.stopPrank();

        // Half of the runs use the canonical encoding of a valid facility (registered tokens, arbitrary oracle, IRM and lltv).
        // The other half mix tokens and encodings freely: choice 0 is the valid token, 1 the token registered for the
        // other side, 2 an arbitrary address, 3 address(0).
        bool validFacility = ec.mode % 2 == 0;
        address[4] memory loanCandidates = [address(loanToken), address(collateralToken), ec.randomToken, address(0)];
        address[4] memory collateralCandidates = [address(collateralToken), address(loanToken), ec.randomToken, address(0)];
        MarketParams memory mp = MarketParams(
            validFacility ? address(loanToken) : loanCandidates[ec.loanChoice % 4],
            validFacility ? address(collateralToken) : collateralCandidates[ec.collateralChoice % 4],
            ec.oracle,
            ec.irmAddress,
            ec.lltv
        );
        bytes memory data = validFacility ? abi.encode(mp) : _mutate(abi.encode(mp), ec.mode / 2, ec.mutation, ec.raw);

        (bool expectedSuccess, bytes memory expectedError) = _predictAddFacility(module, data);
        vm.prank(moduleOwner);
        (bool success, bytes memory returned) = address(module).call(abi.encodeCall(IFunding.addFacility, (data)));
        assertEq(success, expectedSuccess, "addFacility accepts exactly the predicted inputs");
        if (validFacility) assertTrue(success, "the canonical encoding of a valid facility is accepted");
        if (!success) {
            assertEq(returned, expectedError, "exact addFacility revert");
            assertFalse(module.isFacility(data), "rejected bytes are not a facility");
            assertEq(module.facilitiesLength(), 0, "nothing registered");
            return;
        }

        assertEq(data.length, 160, "accepted bytes are 160 long");
        assertEq(keccak256(abi.encode(module.decodeFacilityData(data))), keccak256(data), "accepted bytes are the canonical encoding");
        assertTrue(module.isFacility(data), "accepted bytes are a facility");
        assertEq(module.facilitiesLength(), 1, "one facility registered");
        assertEq(module.facilities(0), data, "stored bytes");

        vm.prank(moduleOwner);
        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        module.addFacility(data);

        // Appended bytes, a changed length and dirty address bits of the accepted facility are all rejected
        for (uint256 mode = 1; mode <= 3; mode++) {
            bytes memory variant = _mutate(data, mode, ec.mutation, "");
            assertFalse(module.isFacility(variant), "a non-canonical variant is not a facility");
            (expectedSuccess, expectedError) = _predictAddFacility(module, variant);
            assertFalse(expectedSuccess, "variants are rejected");
            vm.prank(moduleOwner);
            (success, returned) = address(module).call(abi.encodeCall(IFunding.addFacility, (variant)));
            assertFalse(success, "variant rejected");
            assertEq(returned, expectedError, "exact revert for the variant");
        }
        assertEq(module.facilitiesLength(), 1, "variants never registered");
    }

    function testFuzz_NonCanonicalFacilityDataIsNotAFacility(uint256 mode, uint256 mutation, bytes memory raw, uint256 amount) public {
        (FundingMorpho module, MarketParams memory mp) = _liveDirectFacility();
        bytes memory canonical = abi.encode(mp);
        // Mode 0: canonical encoding of another market; 1-4: appended, truncated, dirty address bits, arbitrary bytes
        bytes memory variant = mode % 5 == 0 ? _otherCanonicalEncoding(canonical, mutation) : _mutate(canonical, mode, mutation, raw);
        if (keccak256(variant) == keccak256(canonical)) {
            assertTrue(module.isFacility(variant), "the canonical bytes are the facility");
            return;
        }

        assertFalse(module.isFacility(variant), "only the canonical bytes are a facility");
        IERC20 collateralToken = IERC20(mp.collateralToken);
        IERC20 loanToken = IERC20(mp.loanToken);
        vm.startPrank(moduleOwner);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.pledge(variant, collateralToken, amount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.depledge(variant, collateralToken, amount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.borrow(variant, loanToken, amount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.repay(variant, loanToken, amount);

        (bool decodeFails, bytes memory decodeError) = _decodeError(variant);
        (bool success, bytes memory returned) = address(module).call(abi.encodeCall(IFunding.removeFacility, (variant)));
        vm.stopPrank();
        assertFalse(success, "removeFacility rejects the variant");
        assertEq(returned, decodeFails ? decodeError : abi.encodeWithSelector(ErrorsLib.NotWhitelisted.selector), "exact revert");
        assertEq(module.facilitiesLength(), 1, "facility set unchanged");
        assertEq(module.facilities(0), canonical, "facility unchanged");
    }

    /////////////////////////////
    /// VAL-FUZZ-010: OWNER-GATED FUNCTIONS
    /////////////////////////////

    function testFuzz_NonOwnerCallsRevertOnlyOwner(
        address caller,
        bool validArguments,
        bytes memory fdSeed,
        address tokenSeed,
        uint256 amount
    ) public {
        (FundingMorpho module, MarketParams memory mp) = _liveDirectFacility();
        if (caller == moduleOwner) caller = address(uint160(caller) ^ 0xff);
        caller = _avoidForgeAddresses(caller);
        bytes[] memory calls = validArguments
            ? _ownerGatedCalls(abi.encode(mp), IERC20(mp.collateralToken), IERC20(mp.loanToken), bound(amount, 1, 1e6))
            : _ownerGatedCalls(fdSeed, IERC20(tokenSeed), IERC20(tokenSeed), amount);
        _assertAllRevertOnlyOwner(module, caller, calls);
    }

    function testFuzz_BoxRolesCannotCallModuleDirectly(
        uint256 roleSeed,
        bool validArguments,
        bytes memory fdSeed,
        address tokenSeed,
        uint256 amount
    ) public {
        allocator = _derivedAccount(roleSeed, "allocator");
        curator = _derivedAccount(roleSeed, "curator");
        guardian = _derivedAccount(roleSeed, "guardian");
        ERC20MockDecimals asset = new ERC20MockDecimals(18);
        ERC20MockDecimals collateralToken = new ERC20MockDecimals(18);
        (IBox box, FundingMorpho module) = _deployBoxWithModule(asset, 0.9e18);
        vm.startPrank(curator);
        box.addTokenInstant(collateralToken, new MockOracle(1e36));
        vm.stopPrank();
        MarketParams memory mp = _createMarket(address(asset), address(collateralToken), 1e36, 0.86e18);
        _seedMarket(mp, 1e24, 0, 0);
        bytes memory fd = _attachFacility(box, module, mp);

        collateralToken.mint(address(box), 100e18);
        vm.startPrank(allocator);
        box.pledge(module, fd, collateralToken, 100e18);
        box.borrow(module, fd, asset, 50e18);
        vm.stopPrank();

        assertTrue(box.isAllocator(allocator), "registered allocator");
        assertEq(box.curator(), curator, "curator");
        assertEq(box.guardian(), guardian, "guardian");
        assertEq(module.owner(), address(box), "the Box owns the module");
        assertGt(module.debtBalance(fd, asset), 0, "live position");

        bytes[] memory calls = validArguments
            ? _ownerGatedCalls(fd, collateralToken, asset, bound(amount, 1, 1e18))
            : _ownerGatedCalls(fdSeed, IERC20(tokenSeed), IERC20(tokenSeed), amount);
        _assertAllRevertOnlyOwner(module, allocator, calls);
        _assertAllRevertOnlyOwner(module, curator, calls);
        _assertAllRevertOnlyOwner(module, guardian, calls);
        _assertAllRevertOnlyOwner(module, boxOwner, calls);
    }

    /////////////////////////////
    /// VAL-FUZZ-011: UNKNOWN TOKENS WITH A LIVE POSITION
    /////////////////////////////

    struct UnknownTokenCase {
        address unknown;
        uint256 priceSeed;
        uint256 collateral1;
        uint256 collateral2;
        uint256 borrow1;
        uint256 borrow2;
        uint256 elapsed;
    }

    function testFuzz_UnknownTokenBalancesAreZeroWithLivePosition(UnknownTokenCase memory uc) public {
        ERC20MockDecimals collateral1 = new ERC20MockDecimals(18);
        ERC20MockDecimals loan1 = new ERC20MockDecimals(6);
        ERC20MockDecimals collateral2 = new ERC20MockDecimals(8);
        ERC20MockDecimals loan2 = new ERC20MockDecimals(18);
        MarketParams[2] memory markets;
        markets[0] = _createMarket(address(loan1), address(collateral1), _price(uc.priceSeed, 18, 6), 0.86e18);
        markets[1] = _createMarket(address(loan2), address(collateral2), _price(uc.priceSeed / 7, 8, 18), 0.77e18);
        FundingMorpho module = new FundingMorpho(moduleOwner, address(morpho), 0.95e18);
        _registerDirect(module, markets[0]);
        _registerDirect(module, markets[1]);
        uint256 pledged1 = _openDirectPosition(module, markets[0], uc.collateral1, uc.borrow1);
        uint256 pledged2 = _openDirectPosition(module, markets[1], uc.collateral2, uc.borrow2);
        vm.warp(block.timestamp + bound(uc.elapsed, 0, 365 days));

        assertEq(module.collateralBalance(collateral1), pledged1, "live collateral in facility 1");
        assertEq(module.collateralBalance(collateral2), pledged2, "live collateral in facility 2");
        assertGt(module.debtBalance(loan1), 0, "live debt in facility 1");
        assertGt(module.debtBalance(loan2), 0, "live debt in facility 2");

        ERC20MockDecimals unrelated = new ERC20MockDecimals(18);
        unrelated.mint(address(module), 1e18);
        address eoa = address(0xBEEF);
        assertEq(eoa.code.length, 0, "EOA has no code");
        assertGt(irm.code.length, 0, "IrmMock is a contract");
        (bool hasBalanceOf, ) = irm.staticcall(abi.encodeCall(IERC20.balanceOf, (address(module))));
        assertFalse(hasBalanceOf, "IrmMock has no balanceOf");
        _assertZeroTokenBalances(module, address(0), "address(0)");
        _assertZeroTokenBalances(module, eoa, "EOA");
        _assertZeroTokenBalances(module, irm, "contract without balanceOf");
        _assertZeroTokenBalances(module, address(morpho), "Morpho");
        _assertZeroTokenBalances(module, address(unrelated), "unrelated ERC20 held by the module");

        address unknown = _avoidForgeAddresses(uc.unknown);
        bool isModuleToken = unknown == address(collateral1) ||
            unknown == address(loan1) ||
            unknown == address(collateral2) ||
            unknown == address(loan2);
        if (!isModuleToken) {
            _assertZeroTokenBalances(module, unknown, "fuzzed unregistered token");
        } else {
            (uint256 expectedDebt, uint256 expectedCollateral) = _expectedTokenBalances(module, markets, unknown);
            assertEq(module.debtBalance(IERC20(unknown)), expectedDebt, "registered token debt");
            assertEq(module.collateralBalance(IERC20(unknown)), expectedCollateral, "registered token collateral");
        }
    }

    /////////////////////////////
    /// SETUP HELPERS
    /////////////////////////////

    function _decimals(uint256 seed) internal pure returns (uint8) {
        uint256 choice = seed % 3;
        if (choice == 0) return 6;
        if (choice == 1) return 8;
        return 18;
    }

    function _maxCollateral(ERC20MockDecimals token) internal view returns (uint256) {
        return MAX_WHOLE_COLLATERAL * 10 ** token.decimals();
    }

    /// @dev Oracle price (1e36 scale, Morpho convention) of one base-token unit in quote-token units. One whole base token is
    /// worth between 1e-4 and 1e4 whole quote tokens: a seed-picked power of ten times a non-round mantissa in [1, 10].
    function _price(uint256 seed, uint8 baseDecimals, uint8 quoteDecimals) internal pure returns (uint256) {
        uint256 parity = 10 ** (36 + uint256(quoteDecimals) - uint256(baseDecimals));
        uint256 mantissa = bound(seed >> 8, WAD, 10 * WAD);
        uint256 magnitude = 10 ** ((seed & 0xff) % 8);
        return (parity * mantissa * magnitude) / (1e4 * WAD);
    }

    /// @dev Like bound, but first caps the range at max / 10^k for a seed-picked k, so small values (where rounding matters
    /// most) are drawn about as often as large ones.
    function _boundLog(uint256 seed, uint256 min, uint256 max) internal pure returns (uint256) {
        uint256 digits;
        for (uint256 ratio = max / (min == 0 ? 1 : min); ratio >= 10; ratio /= 10) digits++;
        uint256 upper = max / 10 ** (seed % (digits + 1));
        return bound(seed / (digits + 1), min, upper < min ? min : upper);
    }

    function _derivedAccount(uint256 seed, string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(seed, label)))));
    }

    function _avoidForgeAddresses(address account) internal pure returns (address) {
        if (account == VM_ADDRESS || account == CONSOLE) return address(uint160(account) ^ 0xff);
        return account;
    }

    function _createMarket(
        address loanToken,
        address collateralToken,
        uint256 price,
        uint256 lltv
    ) internal returns (MarketParams memory mp) {
        OracleMock oracle = new OracleMock();
        oracle.setPrice(price);
        if (!morpho.isLltvEnabled(lltv)) morpho.enableLltv(lltv);
        mp = MarketParams(loanToken, collateralToken, address(oracle), irm, lltv);
        morpho.createMarket(mp);
    }

    /// @dev Supplies `liquidity`, opens an over-collateralized third-party borrow of `thirdPartyBorrow`, then accrues
    /// `elapsed` seconds of interest so the borrow share price moves away from its initial value
    function _seedMarket(MarketParams memory mp, uint256 liquidity, uint256 thirdPartyBorrow, uint256 elapsed) internal {
        ERC20MockDecimals(mp.loanToken).mint(supplier, liquidity);
        vm.startPrank(supplier);
        IERC20(mp.loanToken).approve(address(morpho), liquidity);
        morpho.supply(mp, liquidity, 0, supplier, "");
        vm.stopPrank();

        if (thirdPartyBorrow > 0) {
            // Twice the collateral Morpho requires at the market price and LLTV
            uint256 collateralValue = Math.mulDiv(2 * thirdPartyBorrow + 2, WAD, mp.lltv, Math.Rounding.Ceil);
            uint256 collateral = Math.mulDiv(collateralValue, ORACLE_SCALE, OracleMock(mp.oracle).price(), Math.Rounding.Ceil);
            ERC20MockDecimals(mp.collateralToken).mint(thirdPartyBorrower, collateral);
            vm.startPrank(thirdPartyBorrower);
            IERC20(mp.collateralToken).approve(address(morpho), collateral);
            morpho.supplyCollateral(mp, collateral, thirdPartyBorrower, "");
            morpho.borrow(mp, thirdPartyBorrow, 0, thirdPartyBorrower, thirdPartyBorrower);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + elapsed);
        morpho.accrueInterest(mp);
    }

    function _registerDirect(FundingMorpho module, MarketParams memory mp) internal {
        vm.startPrank(moduleOwner);
        if (!module.isCollateralToken(IERC20(mp.collateralToken))) module.addCollateralToken(IERC20(mp.collateralToken));
        if (!module.isDebtToken(IERC20(mp.loanToken))) module.addDebtToken(IERC20(mp.loanToken));
        module.addFacility(abi.encode(mp));
        vm.stopPrank();
    }

    function _directModule(MarketParams memory mp, uint256 lltvCap) internal returns (FundingMorpho module) {
        module = new FundingMorpho(moduleOwner, address(morpho), lltvCap);
        _registerDirect(module, mp);
    }

    /// @dev Mimics Box: the collateral is transferred to the module before pledge
    function _pledgeDirect(FundingMorpho module, MarketParams memory mp, uint256 amount) internal {
        ERC20MockDecimals(mp.collateralToken).mint(address(module), amount);
        vm.prank(moduleOwner);
        module.pledge(abi.encode(mp), IERC20(mp.collateralToken), amount);
    }

    /// @dev Pledges at least 1e4 loan-token units of value (Morpho price) and borrows a non-zero allowed amount
    function _openDirectPosition(
        FundingMorpho module,
        MarketParams memory mp,
        uint256 collateralSeed,
        uint256 borrowSeed
    ) internal returns (uint256 collateral) {
        uint256 price = OracleMock(mp.oracle).price();
        uint256 minCollateral = Math.mulDiv(1e4, ORACLE_SCALE, price, Math.Rounding.Ceil);
        collateral = _boundLog(collateralSeed, minCollateral, _maxCollateral(ERC20MockDecimals(mp.collateralToken)));
        _seedMarket(mp, (collateral * price) / ORACLE_SCALE + 1, 0, 0);
        _pledgeDirect(module, mp, collateral);
        uint256 borrowAmount = _boundLog(borrowSeed, 1, _maxBorrow(_snapshot(module, mp)));
        vm.prank(moduleOwner);
        module.borrow(abi.encode(mp), IERC20(mp.loanToken), borrowAmount);
    }

    /// @dev Fixed live position: 1000 collateral (18 decimals) at parity with the loan token (6 decimals), 500 borrowed
    function _liveDirectFacility() internal returns (FundingMorpho module, MarketParams memory mp) {
        ERC20MockDecimals collateralToken = new ERC20MockDecimals(18);
        ERC20MockDecimals loanToken = new ERC20MockDecimals(6);
        mp = _createMarket(address(loanToken), address(collateralToken), 1e24, 0.86e18);
        module = _directModule(mp, 0.9e18);
        _seedMarket(mp, 1e12, 0, 0);
        _pledgeDirect(module, mp, 1000e18);
        vm.prank(moduleOwner);
        module.borrow(abi.encode(mp), loanToken, 500e6);
    }

    /// @dev Real Box (allocator and guardian from storage) owning a fresh FundingMorpho, attached with the instant helpers
    function _deployBoxWithModule(ERC20MockDecimals asset, uint256 lltvCap) internal returns (IBox box, FundingMorpho module) {
        box = IBox(address(new Box(address(asset), boxOwner, curator, "Box Fuzz", "BOXF", 0.01 ether, 7 days, 10 days, 7 days)));
        module = new FundingMorpho(address(box), address(morpho), lltvCap);
        vm.startPrank(curator);
        box.setIsAllocator(allocator, true);
        box.setGuardianInstant(guardian);
        box.addFundingInstant(module);
        vm.stopPrank();
    }

    function _attachFacility(IBox box, FundingMorpho module, MarketParams memory mp) internal returns (bytes memory fd) {
        fd = abi.encode(mp);
        vm.startPrank(curator);
        if (!module.isCollateralToken(IERC20(mp.collateralToken))) box.addFundingCollateralInstant(module, IERC20(mp.collateralToken));
        if (!module.isDebtToken(IERC20(mp.loanToken))) box.addFundingDebtInstant(module, IERC20(mp.loanToken));
        box.addFundingFacilityInstant(module, fd);
        vm.stopPrank();
    }

    /// @dev Creates a market at a fuzzed Morpho price, attaches it to the module through the Box, then pledges a fuzzed
    /// amount (possibly 0) and borrows a fuzzed allowed amount (possibly 0) through the allocator
    function _openBoxPosition(IBox box, FundingMorpho module, PositionCase memory pc) internal returns (MarketParams memory mp) {
        uint256 price = _price(pc.priceSeed, pc.collateralToken.decimals(), pc.loanToken.decimals());
        uint256 collateral = _boundLog(pc.collateralSeed, 0, _maxCollateral(pc.collateralToken));
        mp = _createMarket(address(pc.loanToken), address(pc.collateralToken), price, bound(pc.lltvSeed, 0.3e18, 0.98e18));
        _seedMarket(mp, (collateral * price) / ORACLE_SCALE + 1, 0, 0);
        bytes memory fd = _attachFacility(box, module, mp);
        if (collateral == 0) return mp;

        pc.collateralToken.mint(address(box), collateral);
        vm.prank(allocator);
        box.pledge(module, fd, pc.collateralToken, collateral);
        uint256 borrowAmount = _boundLog(pc.borrowSeed, 0, _maxBorrow(_snapshot(module, mp)));
        if (borrowAmount > 0) {
            vm.prank(allocator);
            box.borrow(module, fd, pc.loanToken, borrowAmount);
        }
    }

    /// @dev Reprices the collateral on the Box oracle so that the facility's debt is worth at least its collateral
    function _forceUnderwater(IBox box, FundingMorpho module, MarketParams memory mp, uint256 seed) internal returns (bool) {
        uint256 debt = morpho.expectedBorrowAssets(mp, address(module));
        if (debt == 0) return false;
        uint256 collateral = morpho.position(mp.id(), address(module)).collateral;
        // collateral × P_c <= debt × P_l, so floor(collateral × P_c / 1e36) <= ceil(debt × P_l / 1e36)
        uint256 maxPrice = Math.mulDiv(debt, _boxPrice(box, mp.loanToken), collateral);
        MockOracle(address(box.oracles(IERC20(mp.collateralToken)))).setPrice(bound(seed, 0, maxPrice));
        return true;
    }

    /////////////////////////////
    /// MORPHO + FUNDINGMORPHO REPLICA
    /////////////////////////////

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }

    function _toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return _mulDivUp(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function _toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return _mulDivUp(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    function _snapshot(FundingMorpho module, MarketParams memory mp) internal view returns (Snapshot memory s) {
        Market memory m = morpho.market(mp.id());
        assertEq(m.lastUpdate, block.timestamp, "replica assumes interest is accrued up to the current block");
        s.totalSupplyAssets = m.totalSupplyAssets;
        s.totalBorrowAssets = m.totalBorrowAssets;
        s.totalBorrowShares = m.totalBorrowShares;
        s.borrowShares = morpho.position(mp.id(), address(module)).borrowShares;
        s.collateral = morpho.position(mp.id(), address(module)).collateral;
        s.price = OracleMock(mp.oracle).price();
        s.lltv = mp.lltv;
        s.maxLtv = (mp.lltv * module.lltvCap()) / WAD;
    }

    /// @dev Morpho `_isHealthy`: collateral value rounded down, times LLTV rounded down, against the debt rounded up
    function _morphoHealthy(
        uint256 borrowShares,
        uint256 borrowed,
        uint256 collateral,
        uint256 price,
        uint256 lltv
    ) internal pure returns (bool) {
        if (borrowShares == 0) return true;
        return (((collateral * price) / ORACLE_SCALE) * lltv) / WAD >= borrowed;
    }

    /// @dev FundingMorpho `ltv`: 0 without collateral or when the collateral value rounds to 0, else debt / value rounded up
    function _moduleLtv(uint256 borrowed, uint256 collateral, uint256 price) internal pure returns (uint256) {
        if (collateral == 0) return 0;
        uint256 collateralValue = (collateral * price) / ORACLE_SCALE;
        return collateralValue == 0 ? 0 : _mulDivUp(borrowed, WAD, collateralValue);
    }

    /// @dev Morpho `borrow` (shares rounded up, health, liquidity) then the FundingMorpho guard `ltv <= lltv * lltvCap / 1e18`
    function _borrowOutcome(Snapshot memory s, uint256 amount) internal pure returns (Outcome) {
        uint256 shares = _toSharesUp(amount, s.totalBorrowAssets, s.totalBorrowShares);
        uint256 totalBorrowAssets = s.totalBorrowAssets + amount;
        uint256 totalBorrowShares = s.totalBorrowShares + shares;
        uint256 positionShares = s.borrowShares + shares;
        uint256 borrowed = _toAssetsUp(positionShares, totalBorrowAssets, totalBorrowShares);
        if (!_morphoHealthy(positionShares, borrowed, s.collateral, s.price, s.lltv)) return Outcome.InsufficientCollateral;
        if (totalBorrowAssets > s.totalSupplyAssets) return Outcome.InsufficientLiquidity;
        if (_moduleLtv(borrowed, s.collateral, s.price) > s.maxLtv) return Outcome.ExcessiveLtv;
        return Outcome.Ok;
    }

    /// @dev Morpho `withdrawCollateral` (checked subtraction, health) then the FundingMorpho guard
    function _depledgeOutcome(Snapshot memory s, uint256 amount) internal pure returns (Outcome) {
        if (amount > s.collateral) return Outcome.Underflow;
        uint256 collateral = s.collateral - amount;
        uint256 borrowed = _toAssetsUp(s.borrowShares, s.totalBorrowAssets, s.totalBorrowShares);
        if (!_morphoHealthy(s.borrowShares, borrowed, collateral, s.price, s.lltv)) return Outcome.InsufficientCollateral;
        if (_moduleLtv(borrowed, collateral, s.price) > s.maxLtv) return Outcome.ExcessiveLtv;
        return Outcome.Ok;
    }

    /// @dev Largest allowed borrow (0 if none). Every check is monotone in the amount, so the allowed amounts form a prefix;
    /// one unit past the available liquidity always fails.
    function _maxBorrow(Snapshot memory s) internal pure returns (uint256 low) {
        uint256 high = s.totalSupplyAssets - s.totalBorrowAssets + 1;
        while (high - low > 1) {
            uint256 mid = low + (high - low) / 2;
            if (_borrowOutcome(s, mid) == Outcome.Ok) low = mid;
            else high = mid;
        }
    }

    /// @dev Largest allowed withdrawal (0 if none), by the same argument; one unit past the collateral always fails
    function _maxDepledge(Snapshot memory s) internal pure returns (uint256 low) {
        uint256 high = s.collateral + 1;
        while (high - low > 1) {
            uint256 mid = low + (high - low) / 2;
            if (_depledgeOutcome(s, mid) == Outcome.Ok) low = mid;
            else high = mid;
        }
    }

    function _expectRevert(Outcome outcome) internal {
        if (outcome == Outcome.InsufficientCollateral) vm.expectRevert(bytes(MorphoErrorsLib.INSUFFICIENT_COLLATERAL));
        else if (outcome == Outcome.InsufficientLiquidity) vm.expectRevert(bytes(MorphoErrorsLib.INSUFFICIENT_LIQUIDITY));
        else if (outcome == Outcome.ExcessiveLtv) vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        else if (outcome == Outcome.Underflow) vm.expectRevert(stdError.arithmeticError);
        else revert("predicted outcome is not a revert");
    }

    /// @dev Independent replica of the borrow balance FundingMorpho reads (MorphoBalancesLib.expectedBorrowAssets): pending
    /// interest at IrmMock's rate (utilization / 365 days, no fee) with Morpho's 3-term Taylor compounding, then the
    /// borrower's shares converted to assets rounding up
    function _debtState(MarketParams memory mp, address borrower) internal view returns (DebtState memory d) {
        Market memory m = morpho.market(mp.id());
        d.shares = morpho.position(mp.id(), borrower).borrowShares;
        d.totalBorrowAssets = m.totalBorrowAssets;
        d.totalBorrowShares = m.totalBorrowShares;
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed > 0 && d.totalBorrowAssets > 0) {
            uint256 ratePerSecond = ((d.totalBorrowAssets * WAD) / m.totalSupplyAssets) / 365 days;
            uint256 first = ratePerSecond * elapsed;
            uint256 second = (first * first) / (2 * WAD);
            uint256 third = (second * first) / (3 * WAD);
            d.totalBorrowAssets += (d.totalBorrowAssets * (first + second + third)) / WAD;
        }
        d.debt = _toAssetsUp(d.shares, d.totalBorrowAssets, d.totalBorrowShares);
    }

    /////////////////////////////
    /// NAV REFERENCE
    /////////////////////////////

    function _boxPrice(IBox box, address token) internal view returns (uint256) {
        return token == box.asset() ? ORACLE_SCALE : box.oracles(IERC20(token)).price();
    }

    /// @dev Reference value of one facility under the IFunding nav rules, independent of FundingMorpho's code:
    ///
    ///     max(0, floor(collateral × P_collateral / 1e36) − ceil(debt × P_loan / 1e36))
    ///
    /// P is the Box oracle price (1e36 scale), exactly 1e36 for the Box asset (valued 1:1 without an oracle), and debt is
    /// the borrow balance including pending interest, rounded up (`_debtState`). Also checks the value never exceeds the
    /// facility's exact equity.
    function _referenceFacilityNav(IBox box, FundingMorpho module, MarketParams memory mp) internal view returns (uint256 value) {
        uint256 collateral = morpho.position(mp.id(), address(module)).collateral;
        DebtState memory d = _debtState(mp, address(module));
        assertEq(d.debt, morpho.expectedBorrowAssets(mp, address(module)), "debt replica matches MorphoBalancesLib");
        uint256 collateralPrice = _boxPrice(box, mp.collateralToken);
        uint256 loanPrice = _boxPrice(box, mp.loanToken);
        uint256 collateralValue = Math.mulDiv(collateral, collateralPrice, ORACLE_SCALE);
        uint256 debtValue = Math.mulDiv(d.debt, loanPrice, ORACLE_SCALE, Math.Rounding.Ceil);
        value = collateralValue > debtValue ? collateralValue - debtValue : 0;
        _assertAtMostExactEquity(value, collateral, collateralPrice, d, loanPrice);
    }

    /// @dev value <= max(0, E) with the unrounded equity
    ///     E = collateral × P_c / 1e36 − shares × (totalBorrowAssets + 1) / (totalBorrowShares + 1e6) × P_l / 1e36,
    /// compared exactly in 512-bit arithmetic after multiplying both sides by 1e36 × (totalBorrowShares + 1e6)
    function _assertAtMostExactEquity(
        uint256 value,
        uint256 collateral,
        uint256 collateralPrice,
        DebtState memory d,
        uint256 loanPrice
    ) internal pure {
        if (value == 0) return;
        uint256 sharesDenominator = d.totalBorrowShares + VIRTUAL_SHARES;
        (uint256 valueHigh, uint256 valueLow) = Math.mul512(value * ORACLE_SCALE, sharesDenominator);
        (uint256 debtHigh, uint256 debtLow) = Math.mul512(d.shares * (d.totalBorrowAssets + VIRTUAL_ASSETS), loanPrice);
        (uint256 collateralHigh, uint256 collateralLow) = Math.mul512(collateral * collateralPrice, sharesDenominator);
        uint256 lhsLow;
        uint256 lhsHigh;
        unchecked {
            lhsLow = valueLow + debtLow;
            lhsHigh = valueHigh + debtHigh + (lhsLow < valueLow ? 1 : 0);
        }
        assertTrue(
            lhsHigh < collateralHigh || (lhsHigh == collateralHigh && lhsLow <= collateralLow),
            "facility value never exceeds its exact equity"
        );
    }

    function _assertTotalAssetsIncludesNav(IBox box, uint256 nav) internal view {
        uint256 expected = IERC20(box.asset()).balanceOf(address(box)) + nav;
        uint256 length = box.tokensLength();
        for (uint256 i; i < length; i++) {
            IERC20 token = box.tokens(i);
            expected += Math.mulDiv(token.balanceOf(address(box)), box.oracles(token).price(), ORACLE_SCALE);
        }
        assertEq(box.totalAssets(), expected, "Box totalAssets = idle holdings + FundingMorpho nav");
    }

    /////////////////////////////
    /// FACILITY DATA HELPERS
    /////////////////////////////

    /// @dev Mode 0: unchanged; 1: bytes appended; 2: truncated to any shorter length (including empty); 3: dirty high bits in
    /// one of the four address words; 4: replaced by arbitrary bytes
    function _mutate(bytes memory canonical, uint256 mode, uint256 mutation, bytes memory raw) internal pure returns (bytes memory) {
        mode %= 5;
        if (mode == 0) return canonical;
        if (mode == 1) return bytes.concat(canonical, raw.length > 0 ? raw : _pseudoRandomBytes(mutation, 1 + (mutation % 64)));
        if (mode == 2) return _truncate(canonical, mutation % canonical.length);
        if (mode == 3) {
            uint256[5] memory words = abi.decode(canonical, (uint256[5]));
            words[mutation % 4] |= bound(mutation >> 2, 1, type(uint96).max) << 160;
            return abi.encode(words);
        }
        return raw;
    }

    /// @dev Canonical encoding of a different MarketParams: one field replaced by another clean value
    function _otherCanonicalEncoding(bytes memory canonical, uint256 mutation) internal pure returns (bytes memory) {
        uint256[5] memory words = abi.decode(canonical, (uint256[5]));
        uint256 index = mutation % 5;
        uint256 value = uint256(keccak256(abi.encode(mutation)));
        if (index < 4) value = uint160(value);
        if (value == words[index]) value ^= 1;
        words[index] = value;
        return abi.encode(words);
    }

    function _pseudoRandomBytes(uint256 seed, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; i++) out[i] = bytes1(uint8(uint256(keccak256(abi.encode(seed, i)))));
    }

    function _truncate(bytes memory data, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; i++) out[i] = data[i];
    }

    /// @dev FundingMorpho.decodeFacilityData: the length check reverts InvalidFacilityData, then the ABI decoder rejects
    /// dirty address bits with empty revert data
    function _decodeError(bytes memory data) internal pure returns (bool fails, bytes memory err) {
        if (data.length != 160) return (true, abi.encodeWithSelector(ErrorsLib.InvalidFacilityData.selector));
        uint256[5] memory words = abi.decode(data, (uint256[5]));
        for (uint256 i; i < 4; i++) {
            if (words[i] >> 160 != 0) return (true, "");
        }
        return (false, "");
    }

    /// @dev FundingMorpho.addFacility checks in order: decoding, collateral token registered, debt token registered, new
    function _predictAddFacility(FundingMorpho module, bytes memory data) internal view returns (bool success, bytes memory err) {
        (bool decodeFails, bytes memory decodeError) = _decodeError(data);
        if (decodeFails) return (false, decodeError);
        MarketParams memory mp = abi.decode(data, (MarketParams));
        if (!module.isCollateralToken(IERC20(mp.collateralToken)) || !module.isDebtToken(IERC20(mp.loanToken))) {
            return (false, abi.encodeWithSelector(ErrorsLib.TokenNotWhitelisted.selector));
        }
        if (module.isFacility(data)) return (false, abi.encodeWithSelector(ErrorsLib.AlreadyWhitelisted.selector));
        return (true, "");
    }

    /////////////////////////////
    /// ACCESS AND BALANCE HELPERS
    /////////////////////////////

    /// @dev The 11 owner-gated FundingMorpho functions
    function _ownerGatedCalls(
        bytes memory fd,
        IERC20 collateralToken,
        IERC20 debtToken,
        uint256 amount
    ) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](11);
        calls[0] = abi.encodeCall(IFunding.addFacility, (fd));
        calls[1] = abi.encodeCall(IFunding.removeFacility, (fd));
        calls[2] = abi.encodeCall(IFunding.addCollateralToken, (collateralToken));
        calls[3] = abi.encodeCall(IFunding.addDebtToken, (debtToken));
        calls[4] = abi.encodeCall(IFunding.removeCollateralToken, (collateralToken));
        calls[5] = abi.encodeCall(IFunding.removeDebtToken, (debtToken));
        calls[6] = abi.encodeCall(IFunding.skim, (collateralToken));
        calls[7] = abi.encodeCall(IFunding.pledge, (fd, collateralToken, amount));
        calls[8] = abi.encodeCall(IFunding.depledge, (fd, collateralToken, amount));
        calls[9] = abi.encodeCall(IFunding.borrow, (fd, debtToken, amount));
        calls[10] = abi.encodeCall(IFunding.repay, (fd, debtToken, amount));
    }

    /// @dev Each call reverts with exactly OnlyOwner, both directly and wrapped in multicall behind a view call
    function _assertAllRevertOnlyOwner(FundingMorpho module, address caller, bytes[] memory calls) internal {
        bytes memory onlyOwner = abi.encodeWithSelector(ErrorsLib.OnlyOwner.selector);
        for (uint256 i; i < calls.length; i++) {
            vm.prank(caller);
            (bool success, bytes memory returned) = address(module).call(calls[i]);
            assertFalse(success, string.concat("direct call succeeded: ", vm.toString(i)));
            assertEq(returned, onlyOwner, string.concat("direct call must revert OnlyOwner: ", vm.toString(i)));

            bytes[] memory batch = new bytes[](2);
            batch[0] = abi.encodeCall(IFunding.facilitiesLength, ());
            batch[1] = calls[i];
            vm.prank(caller);
            (success, returned) = address(module).call(abi.encodeCall(FundingBase.multicall, (batch)));
            assertFalse(success, string.concat("multicall succeeded: ", vm.toString(i)));
            assertEq(returned, onlyOwner, string.concat("multicall must revert OnlyOwner: ", vm.toString(i)));
        }
    }

    function _assertModuleHoldsNothing(FundingMorpho module, MarketParams memory mp, string memory label) internal view {
        assertEq(IERC20(mp.collateralToken).balanceOf(address(module)), 0, string.concat("module holds collateral tokens ", label));
        assertEq(IERC20(mp.loanToken).balanceOf(address(module)), 0, string.concat("module holds loan tokens ", label));
    }

    function _assertZeroTokenBalances(FundingMorpho module, address token, string memory label) internal view {
        try module.debtBalance(IERC20(token)) returns (uint256 debt) {
            assertEq(debt, 0, string.concat("debtBalance of an unknown token: ", label));
        } catch {
            assertTrue(false, string.concat("debtBalance reverted for an unknown token: ", label));
        }
        try module.collateralBalance(IERC20(token)) returns (uint256 collateral) {
            assertEq(collateral, 0, string.concat("collateralBalance of an unknown token: ", label));
        } catch {
            assertTrue(false, string.concat("collateralBalance reverted for an unknown token: ", label));
        }
    }

    function _expectedTokenBalances(
        FundingMorpho module,
        MarketParams[2] memory markets,
        address token
    ) internal view returns (uint256 debt, uint256 collateral) {
        for (uint256 i; i < 2; i++) {
            if (markets[i].loanToken == token) debt += _debtState(markets[i], address(module)).debt;
            if (markets[i].collateralToken == token) collateral += morpho.position(markets[i].id(), address(module)).collateral;
        }
    }
}
