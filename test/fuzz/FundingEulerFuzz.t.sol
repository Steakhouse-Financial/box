// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../../src/Box.sol";
import {FundingBase} from "../../src/FundingBase.sol";
import {FundingEuler} from "../../src/FundingEuler.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IFunding} from "../../src/interfaces/IFunding.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "../mocks/ERC20MockDecimals.sol";
import {MockEVault, MockEulerRouter} from "../mocks/MockEVault.sol";
import {MockEVC} from "../mocks/MockEVC.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @dev Shared roles and helpers, plus a pure replica of the FundingEuler ltv/guard math on top of the MockEVault and
///      MockEulerRouter quote math, used to predict exact borrow and depledge boundaries.
abstract contract FundingEulerFuzzBase is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_SCALE = 1e36;
    /// @dev MockEVault share math: 1e6 virtual deposit
    uint256 internal constant VIRTUAL_DEPOSIT = 1e6;
    /// @dev MockEVault keeps debt with 1e9 extra precision
    uint256 internal constant DEBT_PRECISION = 1e9;
    address internal constant USD = address(840);

    address internal boxOwner = makeAddr("boxOwner");
    address internal curator = makeAddr("curator");
    address internal guardian = makeAddr("guardian");
    address internal allocator = makeAddr("allocator");
    address internal lender = makeAddr("lender");

    MockEVC internal evc;
    MockEulerRouter internal router;

    /// @dev What the module guard and the mock account check see for one (collateral vault, borrow vault) pair
    struct Pricing {
        uint256 ltvBorrow; // Euler borrow LTV, 1e4 scale
        uint256 maxLtv; // module bound: ltvBorrow * 1e14 * ltvCap / 1e18
        uint256 collateralPrice; // router price of the collateral asset in the unit of account, 1e18 scale
        uint256 debtPrice; // router price of the debt asset in the unit of account; 0 when the debt asset is the unit of account
    }

    /// @dev Collateral vault totals and the sub-account position before a depledge
    struct VaultState {
        uint256 totalAssets;
        uint256 totalShares;
        uint256 shares;
        uint256 balance;
        uint256 debt;
    }

    /////////////////////////////
    /// HELPERS
    /////////////////////////////

    function _sub(address account, uint256 id) internal pure returns (address) {
        return address(uint160(account) ^ uint160(id));
    }

    function _err(bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }

    function _isForgeAddress(address account) internal pure returns (bool) {
        return
            account == VM_ADDRESS ||
            account == CONSOLE ||
            account == CREATE2_FACTORY ||
            account == DEFAULT_SENDER ||
            account == DEFAULT_TEST_CONTRACT ||
            account == MULTICALL3_ADDRESS;
    }

    function _seed(MockEVault vault, ERC20MockDecimals token, uint256 amount) internal {
        token.mint(lender, amount);
        vm.startPrank(lender);
        token.approve(address(vault), amount);
        vault.deposit(amount, lender);
        vm.stopPrank();
    }

    /// @dev A lender deposit then a yield donation: share price (amount + donation + 1e6) / (amount + 1e6), in [1, 2) when
    ///      donation <= amount
    function _skew(MockEVault vault, ERC20MockDecimals token, uint256 amount, uint256 donation) internal {
        if (amount == 0) return;
        token.mint(lender, amount + donation);
        vm.startPrank(lender);
        token.approve(address(vault), amount + donation);
        vault.deposit(amount, lender);
        if (donation > 0) vault.addYield(donation);
        vm.stopPrank();
    }

    /// @dev A lender deposit then a loss socialised to suppliers: share price (amount - loss + 1e6) / (amount + 1e6), in
    ///      (0.5, 1] when loss <= amount / 2
    function _skewDown(MockEVault vault, ERC20MockDecimals token, uint256 amount, uint256 loss) internal {
        if (amount == 0) return;
        _seed(vault, token, amount);
        if (loss > 0) {
            vm.prank(lender);
            vault.socializeLoss(loss);
        }
    }

    /////////////////////////////
    /// GUARD REPLICA
    /////////////////////////////

    function _debtValue(Pricing memory p, uint256 debt) internal pure returns (uint256) {
        return p.debtPrice == 0 ? debt : Math.mulDiv(debt, p.debtPrice, WAD);
    }

    /// @dev FundingEuler._ltv; the router resolves collateral-vault shares to `assets` (convertToAssets) before pricing
    function _ltvReplica(Pricing memory p, uint256 assets, uint256 shares, uint256 debt) internal pure returns (uint256) {
        if (debt == 0) return 0;
        if (shares == 0) return type(uint256).max;
        uint256 collateralValue = Math.mulDiv(assets, p.collateralPrice, WAD);
        if (collateralValue == 0) return type(uint256).max;
        return Math.mulDiv(_debtValue(p, debt), WAD, collateralValue, Math.Rounding.Ceil);
    }

    /// @dev MockEVault.checkAccountStatus for an account whose only collateral is the pair's collateral vault (strict)
    function _eulerAccepts(Pricing memory p, uint256 assets, uint256 shares, uint256 debt) internal pure returns (bool) {
        if (debt == 0) return true;
        uint256 adjustedCollateral = shares == 0 ? 0 : (Math.mulDiv(assets, p.collateralPrice, WAD) * p.ltvBorrow) / 1e4;
        return adjustedCollateral > _debtValue(p, debt);
    }

    /// @dev Outcome of borrow(amount) from zero debt; borrow(0) schedules no account check, only the module guard runs
    function _borrowAccepted(Pricing memory p, uint256 assets, uint256 shares, uint256 amount) internal pure returns (bool) {
        if (amount == 0) return true;
        return _eulerAccepts(p, assets, shares, amount) && _ltvReplica(p, assets, shares, amount) <= p.maxLtv;
    }

    /// @dev Largest accepted borrow in [0, hi); both checks only tighten as the amount grows, so a binary search is exact
    function _maxBorrow(Pricing memory p, uint256 assets, uint256 shares, uint256 hi) internal pure returns (uint256 lo) {
        require(!_borrowAccepted(p, assets, shares, hi), "borrow search bound too low");
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (_borrowAccepted(p, assets, shares, mid)) lo = mid;
            else hi = mid;
        }
    }

    /// @dev Position left by depledge(amount): redeem(max) when amount is the whole balance, else withdraw burning shares
    ///      rounded up; the collateral vault has no borrows, so its total assets are its cash
    function _afterDepledge(VaultState memory v, uint256 amount) internal pure returns (uint256 shares, uint256 assets) {
        if (amount == v.balance) return (0, 0);
        uint256 burned = Math.mulDiv(amount, v.totalShares + VIRTUAL_DEPOSIT, v.totalAssets + VIRTUAL_DEPOSIT, Math.Rounding.Ceil);
        shares = v.shares - burned;
        assets = Math.mulDiv(shares, v.totalAssets - amount + VIRTUAL_DEPOSIT, v.totalShares - burned + VIRTUAL_DEPOSIT);
    }

    /// @dev withdraw(0) schedules no account check, only the module guard runs
    function _depledgeAccepted(Pricing memory p, VaultState memory v, uint256 amount) internal pure returns (bool) {
        if (amount > v.balance) return false;
        if (amount == 0) return _ltvReplica(p, v.balance, v.shares, v.debt) <= p.maxLtv;
        (uint256 shares, uint256 assets) = _afterDepledge(v, amount);
        return _eulerAccepts(p, assets, shares, v.debt) && _ltvReplica(p, assets, shares, v.debt) <= p.maxLtv;
    }

    /// @dev Largest accepted depledge; the collateral left only shrinks as the amount grows (fewer shares, lower price)
    function _maxDepledge(Pricing memory p, VaultState memory v) internal pure returns (uint256 lo) {
        if (_depledgeAccepted(p, v, v.balance)) return v.balance;
        require(_depledgeAccepted(p, v, 0), "position already outside the guard");
        uint256 hi = v.balance;
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (_depledgeAccepted(p, v, mid)) lo = mid;
            else hi = mid;
        }
    }
}

/// @dev Stateless fuzzing of FundingEuler on the mock EVC and EVK vaults. The module is attached to a real Box (asset WETH)
///      with one registered facility fdMain = (cvWsteth, bvWeth); bvWeth prices in WETH (its asset), bvUsdc in USD.
contract FundingEulerFuzzTest is FundingEulerFuzzBase {
    using BoxLib for IBox;

    uint256 internal constant LTV_CAP = 0.95e18;
    uint256 internal constant MAIN_LTV_BORROW = 9300;
    uint256 internal constant WSTETH_WETH_QUOTE = 1.2e18;
    uint256 internal constant WSTETH_USD_QUOTE = 4_800e18;
    uint256 internal constant USDC_USD_QUOTE = 1e30;
    uint256 internal constant WSTETH_BOX_PRICE = 1210885760000000000000000000000000001;
    /// @dev Cash of each borrow vault, above SEARCH_BOUND so boundary probes never hit E_InsufficientCash
    uint256 internal constant VAULT_CASH = 1e38;
    /// @dev Above any acceptable borrow under the fuzzed bounds (collateral <= 1e30, router prices <= 1e24)
    uint256 internal constant SEARCH_BOUND = 1e37;

    address internal moduleOwner = makeAddr("moduleOwner");

    ERC20MockDecimals internal weth;
    ERC20MockDecimals internal wsteth;
    ERC20MockDecimals internal usdc;
    ERC20MockDecimals internal stranger;
    MockEVC internal foreignEvc;
    MockEVault internal cvWsteth;
    MockEVault internal cvWsteth2;
    MockEVault internal cvForeign;
    MockEVault internal bvWeth;
    MockEVault internal bvUsdc;
    MockOracle internal wstethOracle;

    IBox internal box;
    FundingEuler internal module;
    bytes internal fdMain;

    struct GuardInput {
        uint256 ltvCapSeed;
        uint256 ltvBorrow;
        bool usdQuoted;
        uint256 collateralPrice;
        uint256 debtPrice;
        uint256 collateral;
        uint256 lenderDeposit;
        uint256 priceSeed;
    }

    struct GuardCase {
        FundingEuler module;
        bytes fd;
        address sub;
        ERC20MockDecimals debtToken;
        Pricing pricing;
    }

    function setUp() public {
        evc = new MockEVC();
        foreignEvc = new MockEVC();
        router = new MockEulerRouter();
        weth = new ERC20MockDecimals(18);
        wsteth = new ERC20MockDecimals(18);
        usdc = new ERC20MockDecimals(6);
        stranger = new ERC20MockDecimals(18);

        cvWsteth = new MockEVault(address(evc), address(wsteth), address(router), USD);
        cvWsteth2 = new MockEVault(address(evc), address(wsteth), address(router), USD);
        cvForeign = new MockEVault(address(foreignEvc), address(wsteth), address(router), USD);
        bvWeth = new MockEVault(address(evc), address(weth), address(router), address(weth));
        bvUsdc = new MockEVault(address(evc), address(usdc), address(router), USD);

        bvWeth.setLTV(address(cvWsteth), uint16(MAIN_LTV_BORROW), 9500);
        bvWeth.setLTV(address(cvWsteth2), uint16(MAIN_LTV_BORROW), 9500);
        bvWeth.setLTV(address(cvForeign), uint16(MAIN_LTV_BORROW), 9500);
        bvUsdc.setLTV(address(cvWsteth), 8100, 8300);
        router.setResolvedVault(address(cvWsteth), true);
        router.setResolvedVault(address(cvWsteth2), true);
        router.setPrice(address(wsteth), address(weth), WSTETH_WETH_QUOTE);
        router.setPrice(address(wsteth), USD, WSTETH_USD_QUOTE);
        router.setPrice(address(usdc), USD, USDC_USD_QUOTE);
        _seed(bvWeth, weth, VAULT_CASH);
        _seed(bvUsdc, usdc, VAULT_CASH);

        fdMain = abi.encode(address(cvWsteth), address(bvWeth));
        box = IBox(address(new Box(address(weth), boxOwner, curator, "Box Euler Fuzz", "BOXEF", 0.01 ether, 7 days, 10 days, 7 days)));
        module = new FundingEuler(address(box), address(evc), LTV_CAP);
        wstethOracle = new MockOracle(WSTETH_BOX_PRICE);

        vm.startPrank(curator);
        box.setGuardianInstant(guardian);
        box.addTokenInstant(wsteth, wstethOracle);
        box.setIsAllocator(allocator, true);
        box.addFundingInstant(module);
        box.addFundingCollateralInstant(module, wsteth);
        box.addFundingDebtInstant(module, weth);
        box.addFundingFacilityInstant(module, fdMain);
        vm.stopPrank();
    }

    /////////////////////////////
    /// FIXTURE HELPERS
    /////////////////////////////

    function _mainPricing() internal pure returns (Pricing memory) {
        return
            Pricing({
                ltvBorrow: MAIN_LTV_BORROW,
                maxLtv: (MAIN_LTV_BORROW * 1e14 * LTV_CAP) / WAD,
                collateralPrice: WSTETH_WETH_QUOTE,
                debtPrice: 0
            });
    }

    /// @dev A quarter of the runs at exactly 1e18 (Euler's strict check binds first), a quarter just below it (both bounds
    ///      within a few units), the rest anywhere in (0, 1e18]
    function _ltvCap(uint256 seed) internal pure returns (uint256) {
        uint256 choice = seed % 4;
        if (choice == 0) return WAD;
        if (choice == 1) return WAD - bound(seed >> 2, 1, 1e12);
        return bound(seed, 1, WAD);
    }

    function _nonOwner(address caller) internal returns (address) {
        if (caller == address(box) || _isForgeAddress(caller)) return makeAddr("nonOwner");
        return caller;
    }

    function _assertNoStrayTokens(address sub, string memory step) internal view {
        assertEq(wsteth.balanceOf(address(module)), 0, string.concat(step, ": module holds no collateral token"));
        assertEq(weth.balanceOf(address(module)), 0, string.concat(step, ": module holds no debt token"));
        assertEq(wsteth.balanceOf(sub), 0, string.concat(step, ": sub-account holds no collateral token"));
        assertEq(weth.balanceOf(sub), 0, string.concat(step, ": sub-account holds no debt token"));
        assertEq(wsteth.allowance(address(module), address(cvWsteth)), 0, string.concat(step, ": no collateral allowance left"));
        assertEq(weth.allowance(address(module), address(bvWeth)), 0, string.concat(step, ": no debt allowance left"));
    }

    /// @dev Pledges and borrows on fdMain through the Box; the borrow is at most the largest the guard and Euler accept
    function _openMainPosition(uint256 collateralSeed, uint256 borrowSeed) internal returns (uint256 assets, uint256 borrowed) {
        uint256 collateral = bound(collateralSeed, 1e6, 1e27);
        wsteth.mint(address(box), collateral);
        vm.prank(allocator);
        box.pledge(module, fdMain, wsteth, collateral);

        address sub = _sub(address(module), 1);
        uint256 shares = cvWsteth.balanceOf(sub);
        assets = cvWsteth.convertToAssets(shares);
        borrowed = bound(borrowSeed, 1, _maxBorrow(_mainPricing(), assets, shares, SEARCH_BOUND));
        vm.prank(allocator);
        box.borrow(module, fdMain, weth, borrowed);
    }

    /////////////////////////////
    /// ROUND TRIP THROUGH THE BOX
    /////////////////////////////

    function testFuzz_roundTripThroughBox(
        uint256 collateralSeed,
        uint256 borrowSeed,
        uint256 lenderDeposit,
        uint256 priceSeed,
        uint256 interestSeed,
        uint256 elapsed
    ) public {
        // Collateral share price: exactly 1:1, in (0.5, 1) after a loss, or in (1, 2) after a yield donation
        lenderDeposit = bound(lenderDeposit, 0, 1e27);
        uint256 mode = priceSeed % 4;
        if (mode == 1) _skewDown(cvWsteth, wsteth, lenderDeposit, bound(priceSeed, 0, lenderDeposit / 2));
        else if (mode > 1) _skew(cvWsteth, wsteth, lenderDeposit, bound(priceSeed, 0, lenderDeposit));
        bool unitSharePrice = cvWsteth.totalAssets() == cvWsteth.totalSupply();
        bool sharePriceBelowOne = cvWsteth.totalAssets() < cvWsteth.totalSupply();

        address sub = _sub(address(module), 1);
        assertEq(module.subAccount(fdMain), sub, "first facility on sub-account 1");
        uint256 collateral = bound(collateralSeed, 1e6, 1e27);
        wsteth.mint(address(box), collateral);
        uint256 boxCollateralStart = wsteth.balanceOf(address(box));
        uint256 boxDebtStart = weth.balanceOf(address(box));

        vm.prank(allocator);
        box.pledge(module, fdMain, wsteth, collateral);
        assertEq(wsteth.balanceOf(address(box)), boxCollateralStart - collateral, "Box sent the collateral");
        _assertNoStrayTokens(sub, "pledge");

        uint256 shares = cvWsteth.balanceOf(sub);
        uint256 maxBorrow = _maxBorrow(_mainPricing(), cvWsteth.convertToAssets(shares), shares, SEARCH_BOUND);
        uint256 borrowed = bound(borrowSeed, 1, maxBorrow);
        vm.prank(allocator);
        box.borrow(module, fdMain, weth, borrowed);
        assertEq(weth.balanceOf(address(box)), boxDebtStart + borrowed, "Box debt-token balance rises by exactly the borrow");
        assertEq(module.debtBalance(fdMain, weth), borrowed, "debt right after the borrow");
        _assertNoStrayTokens(sub, "borrow");

        // Interest up to 10% of the debt, accrued with sub-wei precision (debtOf rounds it up)
        vm.warp(block.timestamp + bound(elapsed, 0, 365 days));
        uint256 interestExact = bound(interestSeed, 0, borrowed * (DEBT_PRECISION / 10));
        bvWeth.accrue(sub, interestExact);
        uint256 interest = Math.ceilDiv(interestExact, DEBT_PRECISION);
        assertEq(module.debtBalance(fdMain, weth), borrowed + interest, "debt with interest");
        weth.mint(address(box), interest);

        vm.prank(allocator);
        box.repay(module, fdMain, weth, type(uint256).max);
        assertEq(module.debtBalance(fdMain, weth), 0, "repay(max) closes the debt");
        assertFalse(evc.isControllerEnabled(sub, address(bvWeth)), "controller released");
        _assertNoStrayTokens(sub, "repay");
        uint256 cost = boxDebtStart + interest - weth.balanceOf(address(box));
        assertEq(cost, interest, "Box pays exactly the rounded-up interest");
        assertLe(cost * DEBT_PRECISION, interestExact + 4 * DEBT_PRECISION, "net cost <= accrued interest + 1 wei per action");

        vm.prank(allocator);
        box.depledge(module, fdMain, wsteth, type(uint256).max);
        assertEq(module.collateralBalance(fdMain, wsteth), 0, "depledge(max) empties the collateral");
        assertEq(cvWsteth.balanceOf(sub), 0, "no share dust left");
        _assertNoStrayTokens(sub, "depledge");
        uint256 boxCollateralEnd = wsteth.balanceOf(address(box));
        assertLe(boxCollateralEnd, boxCollateralStart, "never more collateral back than pledged");
        // deposit mints floor(c / p) shares at share price p, and redeeming them (price only rose) returns more than c - p
        if (unitSharePrice) {
            assertEq(boxCollateralEnd, boxCollateralStart, "1:1 share price: collateral returns exactly");
        } else if (sharePriceBelowOne) {
            assertLe(boxCollateralStart - boxCollateralEnd, 1, "share rounding at a share price below 1 costs at most 1 wei");
        } else {
            assertLe(boxCollateralStart - boxCollateralEnd, 2, "share rounding at a share price below 2 costs at most 2 wei");
        }
        assertEq(module.nav(box), 0, "nothing left in the module");

        vm.startPrank(curator);
        box.removeFundingFacility(module, fdMain);
        box.removeFundingCollateral(module, wsteth);
        box.removeFundingDebt(module, weth);
        box.removeFunding(module);
        vm.stopPrank();
        assertFalse(module.isFacility(fdMain), "facility removed");
        assertFalse(evc.isCollateralEnabled(sub, address(cvWsteth)), "collateral disabled on removal");
    }

    /////////////////////////////
    /// GUARD BOUNDARY
    /////////////////////////////

    /// @dev A fresh module (fuzzed ltvCap) owned by moduleOwner with (cvWsteth, bvWeth or bvUsdc), fuzzed router prices and
    ///      LTVBorrow, a collateral share price above or below 1, and fuzzed collateral pledged
    function _guardCase(GuardInput memory input) internal returns (GuardCase memory g) {
        uint256 ltvCap = _ltvCap(input.ltvCapSeed);
        g.module = new FundingEuler(moduleOwner, address(evc), ltvCap);
        MockEVault bv = input.usdQuoted ? bvUsdc : bvWeth;
        g.debtToken = input.usdQuoted ? usdc : weth;
        g.fd = abi.encode(address(cvWsteth), address(bv));

        g.pricing.ltvBorrow = bound(input.ltvBorrow, 1, 1e4);
        g.pricing.maxLtv = (g.pricing.ltvBorrow * 1e14 * ltvCap) / WAD;
        bv.setLTV(address(cvWsteth), uint16(g.pricing.ltvBorrow), uint16(g.pricing.ltvBorrow));
        g.pricing.collateralPrice = bound(input.collateralPrice, 1e9, 1e24);
        router.setPrice(address(wsteth), input.usdQuoted ? USD : address(weth), g.pricing.collateralPrice);
        if (input.usdQuoted) {
            g.pricing.debtPrice = bound(input.debtPrice, 1e18, 1e36);
            router.setPrice(address(usdc), USD, g.pricing.debtPrice);
        }
        uint256 lenderDeposit = bound(input.lenderDeposit, 0, 1e30);
        if (input.priceSeed % 3 == 0) _skewDown(cvWsteth, wsteth, lenderDeposit, bound(input.priceSeed, 0, lenderDeposit / 2));
        else _skew(cvWsteth, wsteth, lenderDeposit, bound(input.priceSeed, 0, lenderDeposit));

        vm.startPrank(moduleOwner);
        g.module.addCollateralToken(wsteth);
        g.module.addDebtToken(g.debtToken);
        g.module.addFacility(g.fd);
        vm.stopPrank();
        g.sub = _sub(address(g.module), 1);
        assertEq(g.module.subAccount(g.fd), g.sub, "sub-account 1");

        uint256 collateral = bound(input.collateral, 1e3, 1e30);
        wsteth.mint(address(g.module), collateral);
        vm.prank(moduleOwner);
        g.module.pledge(g.fd, wsteth, collateral);
    }

    function _checkBorrowBoundary(GuardInput memory input) internal returns (bytes4 expected) {
        GuardCase memory g = _guardCase(input);
        uint256 shares = cvWsteth.balanceOf(g.sub);
        uint256 assets = cvWsteth.convertToAssets(shares);
        uint256 maxBorrow = _maxBorrow(g.pricing, assets, shares, SEARCH_BOUND);
        // Euler's account check runs when the EVC frame exits, before the module guard: it names the error when it fails
        expected = _eulerAccepts(g.pricing, assets, shares, maxBorrow + 1)
            ? ErrorsLib.ExcessiveLTV.selector
            : MockEVault.E_AccountLiquidity.selector;

        vm.prank(moduleOwner);
        vm.expectRevert(expected);
        g.module.borrow(g.fd, g.debtToken, maxBorrow + 1);

        uint256 ownerBefore = g.debtToken.balanceOf(moduleOwner);
        vm.prank(moduleOwner);
        g.module.borrow(g.fd, g.debtToken, maxBorrow);
        assertEq(g.debtToken.balanceOf(moduleOwner) - ownerBefore, maxBorrow, "owner receives exactly the largest allowed borrow");
        uint256 ltv = g.module.ltv(g.fd);
        assertEq(ltv, _ltvReplica(g.pricing, assets, shares, maxBorrow), "module ltv matches the replica");
        assertLe(ltv, g.pricing.maxLtv, "largest borrow is within the guard");
    }

    function _checkDepledgeBoundary(GuardInput memory input, uint256 debtSeed) internal returns (bytes4 expected) {
        GuardCase memory g = _guardCase(input);
        VaultState memory v;
        v.shares = cvWsteth.balanceOf(g.sub);
        v.debt = bound(debtSeed, 0, _maxBorrow(g.pricing, cvWsteth.convertToAssets(v.shares), v.shares, SEARCH_BOUND));
        if (v.debt > 0) {
            vm.prank(moduleOwner);
            g.module.borrow(g.fd, g.debtToken, v.debt);
        }
        v.totalAssets = cvWsteth.totalAssets();
        v.totalShares = cvWsteth.totalSupply();
        v.balance = Math.mulDiv(v.shares, v.totalAssets + VIRTUAL_DEPOSIT, v.totalShares + VIRTUAL_DEPOSIT);
        assertEq(g.module.collateralBalance(g.fd, wsteth), v.balance, "collateral balance matches the replica");

        uint256 maxDepledge = _maxDepledge(g.pricing, v);
        if (maxDepledge == v.balance) {
            expected = ErrorsLib.InvalidAmount.selector;
        } else {
            (uint256 sharesLeft, uint256 assetsLeft) = _afterDepledge(v, maxDepledge + 1);
            expected = _eulerAccepts(g.pricing, assetsLeft, sharesLeft, v.debt)
                ? ErrorsLib.ExcessiveLTV.selector
                : MockEVault.E_AccountLiquidity.selector;
        }

        vm.prank(moduleOwner);
        vm.expectRevert(expected);
        g.module.depledge(g.fd, wsteth, maxDepledge + 1);

        uint256 ownerBefore = wsteth.balanceOf(moduleOwner);
        vm.prank(moduleOwner);
        g.module.depledge(g.fd, wsteth, maxDepledge);
        assertEq(wsteth.balanceOf(moduleOwner) - ownerBefore, maxDepledge, "owner receives exactly the largest allowed depledge");
        (uint256 sharesAfter, uint256 assetsAfter) = _afterDepledge(v, maxDepledge);
        assertEq(cvWsteth.balanceOf(g.sub), sharesAfter, "shares left match the replica");
        assertEq(g.module.collateralBalance(g.fd, wsteth), assetsAfter, "collateral left matches the replica");
        uint256 ltv = g.module.ltv(g.fd);
        assertEq(ltv, _ltvReplica(g.pricing, assetsAfter, sharesAfter, v.debt), "module ltv matches the replica");
        assertLe(ltv, g.pricing.maxLtv, "largest depledge is within the guard");
    }

    function testFuzz_borrowGuardBoundaryIsExact(GuardInput memory input) public {
        _checkBorrowBoundary(input);
    }

    function testFuzz_depledgeGuardBoundaryIsExact(GuardInput memory input, uint256 debtSeed) public {
        _checkDepledgeBoundary(input, debtSeed);
    }

    function _fixedGuardInput(uint256 ltvCapSeed) internal pure returns (GuardInput memory) {
        return
            GuardInput({
                ltvCapSeed: ltvCapSeed,
                ltvBorrow: 9300,
                usdQuoted: false,
                collateralPrice: 1.2e18 + 7,
                debtPrice: 0,
                collateral: 100e18 + 13,
                lenderDeposit: 50e18,
                priceSeed: 1e18 + 1
            });
    }

    /// @dev ltvCap 0.5e18 (seed ≡ 2 mod 4): the module guard is stricter than Euler
    function testBorrowBoundaryModuleGuardBinds() public {
        assertEq(_checkBorrowBoundary(_fixedGuardInput(0.5e18 + 2)), ErrorsLib.ExcessiveLTV.selector);
    }

    /// @dev ltvCap 1e18 (seed 0): Euler's strict check rejects one unit before the module's inclusive bound
    function testBorrowBoundaryEulerCheckBinds() public {
        assertEq(_checkBorrowBoundary(_fixedGuardInput(0)), MockEVault.E_AccountLiquidity.selector);
    }

    function testDepledgeBoundaryModuleGuardBinds() public {
        assertEq(_checkDepledgeBoundary(_fixedGuardInput(0.5e18 + 2), 30e18), ErrorsLib.ExcessiveLTV.selector);
    }

    function testDepledgeBoundaryEulerCheckBinds() public {
        assertEq(_checkDepledgeBoundary(_fixedGuardInput(0), 30e18), MockEVault.E_AccountLiquidity.selector);
    }

    function testDepledgeBoundaryWithoutDebtIsTheBalance() public {
        assertEq(_checkDepledgeBoundary(_fixedGuardInput(0), 0), ErrorsLib.InvalidAmount.selector);
    }

    /////////////////////////////
    /// FACILITY DATA
    /////////////////////////////

    function _isKnownVault(address account) internal view returns (bool) {
        return
            account == address(cvWsteth) ||
            account == address(cvWsteth2) ||
            account == address(cvForeign) ||
            account == address(bvWeth) ||
            account == address(bvUsdc);
    }

    /// @dev A call to an address without code returns no data and the module's ABI decoding reverts with empty data
    function _isCodeless(address account) internal view returns (bool) {
        return account.code.length == 0 && uint160(account) > 0xff && !_isForgeAddress(account);
    }

    /// @dev Expected outcome of addFacility(data) by the owner. `exact` is false only when the module calls foreign code
    ///      (a precompile, a forge address or a non-vault contract) whose revert data it does not choose.
    function _predictAddFacility(bytes memory data) internal view returns (bool succeeds, bool exact, bytes memory revertData) {
        if (data.length != 64) return (false, true, _err(ErrorsLib.InvalidFacilityData.selector));
        (uint256 word0, uint256 word1) = abi.decode(data, (uint256, uint256));
        // abi.decode into address rejects dirty high bits with empty revert data
        if (word0 >> 160 != 0 || word1 >> 160 != 0) return (false, true, "");
        address cv = address(uint160(word0));
        address bv = address(uint160(word1));
        if (cv == address(0) || bv == address(0) || cv == bv) return (false, true, _err(ErrorsLib.InvalidFacilityData.selector));
        if (!_isKnownVault(cv)) return (false, _isCodeless(cv), "");
        if (MockEVault(cv).EVC() != address(evc)) return (false, true, _err(ErrorsLib.InvalidFacilityData.selector));
        if (!_isKnownVault(bv)) return (false, _isCodeless(bv), "");
        if (MockEVault(bv).EVC() != address(evc)) return (false, true, _err(ErrorsLib.InvalidFacilityData.selector));
        if (MockEVault(bv).LTVBorrow(cv) == 0) return (false, true, _err(ErrorsLib.InvalidFacilityData.selector));
        if (!module.isCollateralToken(IERC20(MockEVault(cv).asset())) || !module.isDebtToken(IERC20(MockEVault(bv).asset()))) {
            return (false, true, _err(ErrorsLib.TokenNotWhitelisted.selector));
        }
        if (module.isFacility(data)) return (false, true, _err(ErrorsLib.AlreadyWhitelisted.selector));
        return (true, true, "");
    }

    function _checkAddFacility(bytes memory data) internal {
        (bool succeeds, bool exact, bytes memory expected) = _predictAddFacility(data);
        uint256 lengthBefore = module.facilitiesLength();
        bool registeredBefore = module.isFacility(data);

        vm.prank(address(box));
        (bool ok, bytes memory returned) = address(module).call(abi.encodeCall(IFunding.addFacility, (data)));
        assertEq(ok, succeeds, "addFacility outcome matches the prediction");
        if (succeeds) {
            assertEq(data.length, 64, "only 64-byte data registers");
            (address cv, address bv) = abi.decode(data, (address, address));
            assertEq(keccak256(data), keccak256(abi.encode(cv, bv)), "registered bytes are the canonical encoding");
            assertTrue(module.isFacility(data), "registered");
            assertEq(module.facilitiesLength(), lengthBefore + 1, "one more facility");
        } else {
            if (exact) assertEq(returned, expected, "exact revert data");
            assertEq(module.isFacility(data), registeredBefore, "registration unchanged");
            assertEq(module.facilitiesLength(), lengthBefore, "facility count unchanged");
        }
    }

    function testFuzz_addFacilityRejectsArbitraryBytes(bytes memory data) public {
        _checkAddFacility(data);
    }

    function testFuzz_addFacilityVaultPairs(uint256 collateralPick, uint256 borrowPick, address arbitrary) public {
        if (_isForgeAddress(arbitrary)) arbitrary = makeAddr("arbitrary");
        address[7] memory candidates = [
            address(cvWsteth),
            address(cvWsteth2),
            address(cvForeign),
            address(bvWeth),
            address(bvUsdc),
            arbitrary,
            address(0)
        ];
        _checkAddFacility(abi.encode(candidates[collateralPick % 7], candidates[borrowPick % 7]));
    }

    function _truncate(bytes memory data, uint256 length) internal pure returns (bytes memory truncated) {
        truncated = new bytes(length);
        for (uint256 i; i < length; i++) {
            truncated[i] = data[i];
        }
    }

    function _assertAddFacilityReverts(bytes memory data, bytes memory expected, string memory what) internal {
        vm.prank(address(box));
        (bool ok, bytes memory returned) = address(module).call(abi.encodeCall(IFunding.addFacility, (data)));
        assertFalse(ok, string.concat(what, ": addFacility reverts"));
        assertEq(returned, expected, string.concat(what, ": exact revert data"));
        assertFalse(module.isFacility(data), string.concat(what, ": not registered"));
    }

    /// @dev Non-canonical facilityData is not a facility: views return 0 and every action reverts NotWhitelisted
    function _assertNotAFacility(bytes memory fd, string memory what) internal {
        assertFalse(module.isFacility(fd), string.concat(what, ": isFacility false"));
        assertEq(module.subAccount(fd), address(0), string.concat(what, ": no sub-account"));
        assertEq(module.ltv(fd), 0, string.concat(what, ": ltv 0"));
        assertEq(module.collateralBalance(fd, wsteth), 0, string.concat(what, ": collateral view 0"));
        assertEq(module.debtBalance(fd, weth), 0, string.concat(what, ": debt view 0"));

        bytes[4] memory calls = [
            abi.encodeCall(IFunding.pledge, (fd, IERC20(address(wsteth)), 1e18)),
            abi.encodeCall(IFunding.depledge, (fd, IERC20(address(wsteth)), 1)),
            abi.encodeCall(IFunding.borrow, (fd, IERC20(address(weth)), 1)),
            abi.encodeCall(IFunding.repay, (fd, IERC20(address(weth)), 1))
        ];
        for (uint256 i; i < calls.length; i++) {
            vm.prank(address(box));
            (bool ok, bytes memory returned) = address(module).call(calls[i]);
            assertFalse(ok, string.concat(what, ": action reverts"));
            assertEq(returned, _err(ErrorsLib.NotWhitelisted.selector), string.concat(what, ": action reverts NotWhitelisted"));
        }
    }

    function testFuzz_onlyCanonicalFacilityDataIsAFacility(bytes memory extra, uint256 dirt, uint256 cut, bytes memory other) public {
        bytes memory canonical = abi.encode(address(cvWsteth2), address(bvWeth));
        if (extra.length == 0) extra = hex"00";
        uint256 dirtyBits = bound(dirt, 1, type(uint96).max) << 160;
        uint256 cvWord = uint256(uint160(address(cvWsteth2)));
        uint256 bvWord = uint256(uint160(address(bvWeth)));

        bytes[6] memory variants = [
            bytes.concat(canonical, extra),
            abi.encode(cvWord | dirtyBits, bvWord),
            abi.encode(cvWord, bvWord | dirtyBits),
            _truncate(canonical, bound(cut, 0, 63)),
            abi.encodePacked(address(cvWsteth2), address(bvWeth)),
            abi.encode(address(cvWsteth2), address(bvWeth), uint256(0))
        ];
        bytes memory invalid = _err(ErrorsLib.InvalidFacilityData.selector);
        bytes[6] memory expected = [invalid, bytes(""), bytes(""), invalid, invalid, invalid];
        string[6] memory names = [
            string("appended data"),
            "dirty collateral word",
            "dirty borrow word",
            "truncated",
            "packed",
            "extra word"
        ];

        for (uint256 i; i < variants.length; i++) {
            _assertAddFacilityReverts(variants[i], expected[i], names[i]);
        }

        vm.prank(address(box));
        module.addFacility(canonical);
        assertTrue(module.isFacility(canonical), "canonical bytes register");
        wsteth.mint(address(module), 1e18);
        vm.prank(address(box));
        module.pledge(canonical, wsteth, 1e18);
        assertEq(module.collateralBalance(canonical, wsteth), 1e18, "canonical facility is live");

        for (uint256 i; i < variants.length; i++) {
            _assertNotAFacility(variants[i], names[i]);
            _assertAddFacilityReverts(variants[i], expected[i], names[i]);
        }
        if (keccak256(other) != keccak256(canonical) && keccak256(other) != keccak256(fdMain)) _assertNotAFacility(other, "fuzzed bytes");

        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        module.addFacility(canonical);
    }

    /////////////////////////////
    /// CALLERS
    /////////////////////////////

    function _ownerGatedCalls(bytes memory fd, IERC20 token, uint256 amount) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](11);
        calls[0] = abi.encodeCall(IFunding.addFacility, (fd));
        calls[1] = abi.encodeCall(IFunding.removeFacility, (fd));
        calls[2] = abi.encodeCall(IFunding.addCollateralToken, (token));
        calls[3] = abi.encodeCall(IFunding.addDebtToken, (token));
        calls[4] = abi.encodeCall(IFunding.removeCollateralToken, (token));
        calls[5] = abi.encodeCall(IFunding.removeDebtToken, (token));
        calls[6] = abi.encodeCall(IFunding.skim, (token));
        calls[7] = abi.encodeCall(IFunding.pledge, (fd, token, amount));
        calls[8] = abi.encodeCall(IFunding.depledge, (fd, token, amount));
        calls[9] = abi.encodeCall(IFunding.borrow, (fd, token, amount));
        calls[10] = abi.encodeCall(IFunding.repay, (fd, token, amount));
    }

    function _assertAllOnlyOwner(address caller, bytes[] memory calls, string memory who) internal {
        for (uint256 i; i < calls.length; i++) {
            vm.prank(caller);
            (bool ok, bytes memory returned) = address(module).call(calls[i]);
            string memory what = string.concat(who, " call #", vm.toString(i));
            assertFalse(ok, string.concat(what, " reverts"));
            assertEq(returned, _err(ErrorsLib.OnlyOwner.selector), string.concat(what, " reverts OnlyOwner"));
        }
    }

    function testFuzz_nonOwnerCallsRevertOnlyOwner(address caller, bytes memory fd, address token, uint256 amount, uint256 wrapped) public {
        caller = _nonOwner(caller);
        _assertAllOnlyOwner(caller, _ownerGatedCalls(fd, IERC20(token), amount), "fuzzed arguments");
        _assertAllOnlyOwner(caller, _ownerGatedCalls(fdMain, wsteth, bound(amount, 1, 1e24)), "collateral token");
        _assertAllOnlyOwner(caller, _ownerGatedCalls(fdMain, weth, bound(amount, 1, 1e24)), "debt token");

        bytes[] memory calls = _ownerGatedCalls(fdMain, weth, 1e18);
        bytes[] memory inner = new bytes[](2);
        inner[0] = abi.encodeCall(IFunding.facilitiesLength, ());
        inner[1] = calls[wrapped % calls.length];
        vm.prank(caller);
        (bool ok, bytes memory returned) = address(module).call(abi.encodeCall(FundingBase.multicall, (inner)));
        assertFalse(ok, "non-owner multicall reverts");
        assertEq(returned, _err(ErrorsLib.OnlyOwner.selector), "non-owner multicall reverts OnlyOwner");

        // The owner check is the only obstacle: the owner passes it for the same multicall shape
        inner[1] = abi.encodeCall(IFunding.addCollateralToken, (IERC20(address(stranger))));
        vm.prank(address(box));
        module.multicall(inner);
        assertTrue(module.isCollateralToken(stranger), "owner multicall executed");
    }

    function testFuzz_boxRolesCannotCallModuleDirectly(address registered, uint256 amount, uint256 tokenPick) public {
        if (registered == address(0) || registered == address(box) || registered == allocator || _isForgeAddress(registered)) {
            registered = makeAddr("registeredAllocator");
        }
        vm.prank(curator);
        box.setIsAllocator(registered, true);
        assertTrue(box.isAllocator(registered), "allocator registered on the Box");
        assertEq(box.curator(), curator, "curator of the Box");
        assertEq(box.guardian(), guardian, "guardian of the Box");
        assertEq(module.owner(), address(box), "the Box owns the module");

        wsteth.mint(address(box), 10e18);
        vm.startPrank(registered);
        box.pledge(module, fdMain, wsteth, 10e18);
        box.borrow(module, fdMain, weth, 5e18);
        vm.stopPrank();

        IERC20 token = tokenPick % 2 == 0 ? IERC20(address(wsteth)) : IERC20(address(weth));
        bytes[] memory calls = _ownerGatedCalls(fdMain, token, bound(amount, 0, 20e18));
        _assertAllOnlyOwner(registered, calls, "allocator");
        _assertAllOnlyOwner(curator, calls, "curator");
        _assertAllOnlyOwner(guardian, calls, "guardian");

        vm.prank(registered);
        box.repay(module, fdMain, weth, type(uint256).max);
        assertEq(module.debtBalance(fdMain, weth), 0, "the allocator acts through the Box");
    }

    /////////////////////////////
    /// UNKNOWN TOKENS AND FACILITIES
    /////////////////////////////

    function _assertUnknownTokenViewsZero(address token, string memory what) internal view {
        IERC20 t = IERC20(token);
        assertEq(module.debtBalance(t), 0, string.concat(what, ": debtBalance(token)"));
        assertEq(module.collateralBalance(t), 0, string.concat(what, ": collateralBalance(token)"));
        assertEq(module.debtBalance(fdMain, t), 0, string.concat(what, ": debtBalance(fd, token)"));
        assertEq(module.collateralBalance(fdMain, t), 0, string.concat(what, ": collateralBalance(fd, token)"));
    }

    function _assertUnknownFacilityViewsZero(bytes memory fd, address token, string memory what) internal view {
        assertFalse(module.isFacility(fd), string.concat(what, ": not a facility"));
        assertEq(module.ltv(fd), 0, string.concat(what, ": ltv"));
        address[3] memory tokens = [address(weth), address(wsteth), token];
        for (uint256 i; i < tokens.length; i++) {
            assertEq(module.debtBalance(fd, IERC20(tokens[i])), 0, string.concat(what, ": debtBalance"));
            assertEq(module.collateralBalance(fd, IERC20(tokens[i])), 0, string.concat(what, ": collateralBalance"));
        }
    }

    function testFuzz_unknownTokensAndFacilitiesViewZero(
        address token,
        bytes memory otherFd,
        uint256 collateralSeed,
        uint256 borrowSeed
    ) public {
        (uint256 assets, uint256 borrowed) = _openMainPosition(collateralSeed, borrowSeed);
        assertEq(module.debtBalance(weth), borrowed, "live debt");
        assertEq(module.debtBalance(fdMain, weth), borrowed, "live facility debt");
        assertEq(module.collateralBalance(wsteth), assets, "live collateral");
        assertEq(module.collateralBalance(fdMain, wsteth), assets, "live facility collateral");

        if (token == address(wsteth) || token == address(weth) || _isForgeAddress(token)) token = address(stranger);
        _assertUnknownTokenViewsZero(token, "fuzzed token");
        _assertUnknownTokenViewsZero(address(0), "address(0)");
        _assertUnknownTokenViewsZero(makeAddr("eoa"), "EOA");
        (bool hasBalanceOf, ) = address(evc).staticcall(abi.encodeCall(IERC20.balanceOf, (address(module))));
        assertFalse(hasBalanceOf, "the EVC has no balanceOf");
        _assertUnknownTokenViewsZero(address(evc), "contract without balanceOf");
        _assertUnknownTokenViewsZero(address(stranger), "ERC20 no vault uses");
        _assertUnknownTokenViewsZero(address(usdc), "asset of an unused vault");
        _assertUnknownTokenViewsZero(address(cvWsteth), "facility share token");

        if (keccak256(otherFd) == keccak256(fdMain)) otherFd = bytes.concat(otherFd, hex"00");
        _assertUnknownFacilityViewsZero(otherFd, token, "fuzzed facilityData");
        _assertUnknownFacilityViewsZero("", token, "empty");
        _assertUnknownFacilityViewsZero(abi.encode(address(cvWsteth2), address(bvWeth)), token, "canonical, unregistered");
        _assertUnknownFacilityViewsZero(abi.encodePacked(address(cvWsteth), address(bvWeth)), token, "packed registered pair");
        _assertUnknownFacilityViewsZero(bytes.concat(fdMain, hex"00"), token, "registered pair with a byte appended");
        _assertUnknownFacilityViewsZero(
            abi.encode(uint256(uint160(address(cvWsteth))) | (uint256(1) << 160), address(bvWeth)),
            token,
            "registered pair with a dirty word"
        );
    }
}

/// @dev nav of FundingEuler against an independent reference, with a real Box as oracles provider. Token pools hold one
///      token per decimals choice (6, 8, 18) so each run picks the Box asset, both collaterals and the debt token
///      independently. Facilities: 1 = (X -> Box asset), 2 = (Z -> Y), 3 = (Box asset -> Y).
contract FundingEulerNavFuzzTest is FundingEulerFuzzBase {
    using BoxLib for IBox;

    uint256 internal constant POOL = 3;
    /// @dev Cash of each borrow vault, above any fuzzed debt (at most 1.5e36 under the bounds below)
    uint256 internal constant NAV_VAULT_CASH = 1e40;

    address internal liquidator = makeAddr("liquidator");

    ERC20MockDecimals[POOL] internal boxAssets;
    ERC20MockDecimals[POOL] internal xTokens;
    ERC20MockDecimals[POOL] internal zTokens;
    ERC20MockDecimals[POOL] internal yTokens;
    MockEVault[POOL] internal cvX;
    MockEVault[POOL] internal cvZ;
    MockEVault[POOL] internal cvAsset;
    MockEVault[POOL] internal bvAsset;
    MockEVault[POOL] internal bvY;
    MockOracle[POOL] internal xOracles;
    MockOracle[POOL] internal zOracles;
    MockOracle[POOL] internal yOracles;
    IBox[POOL] internal boxes;
    FundingEuler[POOL] internal modules;

    struct NavInput {
        uint256 decimalsSeed;
        uint256[3] priceSeeds; // Box prices of X, Z and Y
        uint256[3] collateralSeeds;
        uint256[3] ratioSeeds; // debt value over collateral value at the Box prices when borrowing, in [0, 1.5]
        uint256[3] interestSeeds;
        uint256[3] skewSeeds;
        uint256 moveSeed; // Box price of Z moved by a factor in [0, 2] after borrowing
        uint256 seizeSeed; // even: nothing seized; odd: part of facility 2's shares seized
    }

    struct NavFacility {
        bytes fd;
        MockEVault cv;
        MockEVault bv;
        ERC20MockDecimals collateral;
        ERC20MockDecimals debt;
        uint256 collateralPrice; // Box price, 1e36 scale; 1e36 for the Box asset
        uint256 debtPrice;
        address sub;
    }

    struct NavResult {
        uint256 nav;
        uint256 expectedNav;
        uint256 netted;
        uint256 exactEquity;
        uint256 underwater;
    }

    function setUp() public {
        evc = new MockEVC();
        router = new MockEulerRouter();
        for (uint256 i; i < POOL; i++) {
            uint8 decimals = _decimalsAt(i);
            boxAssets[i] = new ERC20MockDecimals(decimals);
            xTokens[i] = new ERC20MockDecimals(decimals);
            zTokens[i] = new ERC20MockDecimals(decimals);
            yTokens[i] = new ERC20MockDecimals(decimals);
            cvX[i] = new MockEVault(address(evc), address(xTokens[i]), address(router), USD);
            cvZ[i] = new MockEVault(address(evc), address(zTokens[i]), address(router), USD);
            cvAsset[i] = new MockEVault(address(evc), address(boxAssets[i]), address(router), USD);
            bvAsset[i] = new MockEVault(address(evc), address(boxAssets[i]), address(router), address(boxAssets[i]));
            bvY[i] = new MockEVault(address(evc), address(yTokens[i]), address(router), address(yTokens[i]));
            router.setResolvedVault(address(cvX[i]), true);
            router.setResolvedVault(address(cvZ[i]), true);
            router.setResolvedVault(address(cvAsset[i]), true);
            _seed(bvAsset[i], boxAssets[i], NAV_VAULT_CASH);
            _seed(bvY[i], yTokens[i], NAV_VAULT_CASH);
            xOracles[i] = new MockOracle(ORACLE_SCALE);
            zOracles[i] = new MockOracle(ORACLE_SCALE);
            yOracles[i] = new MockOracle(ORACLE_SCALE);

            boxes[i] = IBox(
                address(new Box(address(boxAssets[i]), boxOwner, curator, "Box Euler Nav", "BOXEN", 0.01 ether, 7 days, 10 days, 7 days))
            );
            modules[i] = new FundingEuler(address(boxes[i]), address(evc), WAD);
            vm.prank(curator);
            boxes[i].setIsAllocator(allocator, true);
        }
        for (uint256 b; b < POOL; b++) {
            for (uint256 c; c < POOL; c++) {
                bvAsset[b].setLTV(address(cvX[c]), 9000, 9200);
                bvY[b].setLTV(address(cvZ[c]), 9000, 9200);
                bvY[b].setLTV(address(cvAsset[c]), 9000, 9200);
            }
        }
    }

    function _decimalsAt(uint256 index) internal pure returns (uint8) {
        if (index == 0) return 6;
        if (index == 1) return 8;
        return 18;
    }

    /// @dev Non-round Box price (1e36 scale) of a token in the Box asset: 1/1000 to 1000 whole assets per whole token,
    ///      plus low digits
    function _boxPrice(uint256 seed, uint8 tokenDecimals, uint8 assetDecimals) internal pure returns (uint256) {
        uint256 unitPrice = 10 ** (36 + uint256(assetDecimals) - tokenDecimals);
        return Math.mulDiv(unitPrice, bound(seed, 1e15, 1e21), WAD) + ((seed >> 128) % 999_983) + 1;
    }

    /// @dev Pledges fuzzed collateral through the Box, then borrows a fuzzed fraction (0 to 150%) of its Box value. Euler's
    ///      router prices the collateral generously (independently of the Box oracles) so the guard always accepts it.
    function _open(NavFacility memory f, IBox box, FundingEuler module, NavInput memory input, uint256 i) internal {
        uint256 unit = 10 ** f.collateral.decimals();
        uint256 lenderDeposit = bound(input.skewSeeds[i], 0, 1e12 * unit);
        _skew(f.cv, f.collateral, lenderDeposit, bound(uint256(keccak256(abi.encode(input.skewSeeds[i]))), 0, lenderDeposit));

        uint256 amount = bound(input.collateralSeeds[i], 1e3, 1e12 * unit);
        f.collateral.mint(address(box), amount);
        vm.prank(allocator);
        box.pledge(module, f.fd, f.collateral, amount);

        uint256 assets = f.cv.convertToAssets(f.cv.balanceOf(f.sub));
        uint256 debt = Math.mulDiv(Math.mulDiv(assets, f.collateralPrice, f.debtPrice), bound(input.ratioSeeds[i], 0, 1.5e18), WAD);
        if (debt == 0) return;
        router.setPrice(address(f.collateral), address(f.debt), Math.mulDiv(3 * debt + 3, WAD, assets, Math.Rounding.Ceil));
        vm.prank(allocator);
        box.borrow(module, f.fd, f.debt, debt);
        f.bv.accrue(f.sub, bound(input.interestSeeds[i], 0, debt * (DEBT_PRECISION / 10)));
    }

    function _checkNav(NavInput memory input) internal returns (NavResult memory r) {
        uint256 ia = input.decimalsSeed % 3;
        uint256 ix = (input.decimalsSeed / 3) % 3;
        uint256 iz = (input.decimalsSeed / 9) % 3;
        uint256 iy = (input.decimalsSeed / 27) % 3;
        IBox box = boxes[ia];
        FundingEuler module = modules[ia];
        ERC20MockDecimals asset = boxAssets[ia];
        uint8 assetDecimals = asset.decimals();

        xOracles[ix].setPrice(_boxPrice(input.priceSeeds[0], xTokens[ix].decimals(), assetDecimals));
        zOracles[iz].setPrice(_boxPrice(input.priceSeeds[1], zTokens[iz].decimals(), assetDecimals));
        yOracles[iy].setPrice(_boxPrice(input.priceSeeds[2], yTokens[iy].decimals(), assetDecimals));

        NavFacility[3] memory f;
        f[0] = NavFacility({
            fd: abi.encode(address(cvX[ix]), address(bvAsset[ia])),
            cv: cvX[ix],
            bv: bvAsset[ia],
            collateral: xTokens[ix],
            debt: asset,
            collateralPrice: xOracles[ix].price(),
            debtPrice: ORACLE_SCALE,
            sub: _sub(address(module), 1)
        });
        f[1] = NavFacility({
            fd: abi.encode(address(cvZ[iz]), address(bvY[iy])),
            cv: cvZ[iz],
            bv: bvY[iy],
            collateral: zTokens[iz],
            debt: yTokens[iy],
            collateralPrice: zOracles[iz].price(),
            debtPrice: yOracles[iy].price(),
            sub: _sub(address(module), 2)
        });
        f[2] = NavFacility({
            fd: abi.encode(address(cvAsset[ia]), address(bvY[iy])),
            cv: cvAsset[ia],
            bv: bvY[iy],
            collateral: asset,
            debt: yTokens[iy],
            collateralPrice: ORACLE_SCALE,
            debtPrice: yOracles[iy].price(),
            sub: _sub(address(module), 3)
        });

        vm.startPrank(curator);
        box.addTokenInstant(xTokens[ix], xOracles[ix]);
        box.addTokenInstant(zTokens[iz], zOracles[iz]);
        box.addTokenInstant(yTokens[iy], yOracles[iy]);
        box.addFundingInstant(module);
        box.addFundingCollateralInstant(module, xTokens[ix]);
        box.addFundingCollateralInstant(module, zTokens[iz]);
        box.addFundingCollateralInstant(module, asset);
        box.addFundingDebtInstant(module, asset);
        box.addFundingDebtInstant(module, yTokens[iy]);
        for (uint256 i; i < 3; i++) {
            box.addFundingFacilityInstant(module, f[i].fd);
        }
        vm.stopPrank();

        for (uint256 i; i < 3; i++) {
            assertEq(module.subAccount(f[i].fd), f[i].sub, "sub-accounts assigned 1, 2, 3 in order");
            _open(f[i], box, module, input, i);
        }

        // Box oracle move on facility 2's collateral (can push it underwater), and optionally a partial seizure
        uint256 movedPrice = Math.mulDiv(f[1].collateralPrice, bound(input.moveSeed, 0, 2e18), WAD);
        zOracles[iz].setPrice(movedPrice);
        f[1].collateralPrice = movedPrice;
        if (input.seizeSeed % 2 == 1) {
            f[1].cv.seize(f[1].sub, liquidator, bound(input.seizeSeed, 0, f[1].cv.balanceOf(f[1].sub)));
        }

        // Reference, per facility i (price of the Box asset = 1e36, i.e. valued 1:1):
        //   collateral_i = convertToAssets(balanceOf(sub_i)), debt_i = debtOf(sub_i)
        //   nav = Σ_i max(0, floor(collateral_i × collateralPrice_i / 1e36) − ceil(debt_i × debtPrice_i / 1e36))
        uint256 collateralSum;
        uint256 debtSum;
        for (uint256 i; i < 3; i++) {
            uint256 collateral = f[i].cv.convertToAssets(f[i].cv.balanceOf(f[i].sub));
            uint256 debt = f[i].bv.debtOf(f[i].sub);
            uint256 collateralValue = Math.mulDiv(collateral, f[i].collateralPrice, ORACLE_SCALE);
            uint256 debtValue = Math.mulDiv(debt, f[i].debtPrice, ORACLE_SCALE, Math.Rounding.Ceil);
            r.expectedNav += collateralValue > debtValue ? collateralValue - debtValue : 0;
            if (collateralValue < debtValue) r.underwater++;
            collateralSum += collateralValue;
            debtSum += debtValue;
            // Unrounded equity, 1e36-scaled (no overflow: amounts <= 1e12 whole units, prices <= 1e3 whole assets per unit)
            uint256 exactCollateral = collateral * f[i].collateralPrice;
            uint256 exactDebt = debt * f[i].debtPrice;
            r.exactEquity += exactCollateral > exactDebt ? exactCollateral - exactDebt : 0;
        }
        r.netted = collateralSum > debtSum ? collateralSum - debtSum : 0;

        bool reverted;
        try module.nav(box) returns (uint256 value) {
            r.nav = value;
        } catch {
            reverted = true;
        }
        assertFalse(reverted, "nav never reverts");
        assertEq(r.nav, r.expectedNav, "nav equals the per-facility floored reference");
        assertLe(r.nav * ORACLE_SCALE, r.exactEquity, "rounding never overstates the equity");
        assertLt(r.exactEquity, r.nav * ORACLE_SCALE + 2 * 3 * ORACLE_SCALE, "at most one unit lost per rounding and facility");
        assertGe(r.nav, r.netted, "per-facility floor is never below netting across facilities");

        uint256 idle = asset.balanceOf(address(box));
        idle += Math.mulDiv(xTokens[ix].balanceOf(address(box)), xOracles[ix].price(), ORACLE_SCALE);
        idle += Math.mulDiv(zTokens[iz].balanceOf(address(box)), zOracles[iz].price(), ORACLE_SCALE);
        idle += Math.mulDiv(yTokens[iy].balanceOf(address(box)), yOracles[iy].price(), ORACLE_SCALE);
        assertEq(box.totalAssets(), idle + r.nav, "Box totalAssets includes the module nav");
    }

    function testFuzz_navMatchesPerFacilityReference(NavInput memory input) public {
        _checkNav(input);
    }

    /// @dev Facility 2 is pushed underwater by halving the Box price of its collateral: it counts 0 instead of dragging the
    ///      other facilities down
    function testNavFloorsUnderwaterFacilityAtZero() public {
        NavInput memory input;
        input.decimalsSeed = 59; // asset 18, X 8, Z 6, Y 18 decimals
        input.priceSeeds = [uint256(1e18 + 12_345), 2e18 + 777, 0.5e18 + 3];
        input.collateralSeeds = [uint256(1_000e8 + 1), 5_000e6 + 3, 20e18 + 5];
        input.ratioSeeds = [uint256(0.6e18), 0.9e18, 0.4e18];
        input.moveSeed = 0.5e18;
        NavResult memory r = _checkNav(input);
        assertEq(r.underwater, 1, "facility 2 is underwater");
        assertGt(r.nav, r.netted, "the underwater facility is floored at 0");
    }
}
