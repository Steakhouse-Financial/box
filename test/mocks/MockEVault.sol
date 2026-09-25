// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceOracle} from "../../src/interfaces/euler/IPriceOracle.sol";
import {MockEVC} from "./MockEVC.sol";

/// @notice Euler Vault Kit vault mock for unit tests. Written from the documented EVK behaviour, not from EVK code.
/// @dev Semantics reproduced:
/// - ERC-4626 share math with a 1e6 virtual deposit: `deposit` mints shares rounded down, `withdraw` burns shares
///   rounded up and sends exactly the amount, `redeem` sends assets rounded down; cash is tracked internally;
/// - direct calls act as `msg.sender`; calls through the EVC act as the EVC's current on-behalf-of account;
/// - `deposit(max)` deposits the caller's whole balance, `redeem(max)` the owner's whole shares, `borrow(max)` all the
///   cash; `withdraw` has no max sentinel and reverts above the owner's balance;
/// - `withdraw`/`redeem` require the acting account to own the shares; assets can never be pushed to address(0) or to
///   a known non-owner sub-account (`E_BadAssetReceiver`);
/// - `borrow` requires this vault to be the acting account's controller; `borrow`, `withdraw` and `redeem` require an
///   account status check, which checks `Σ quote(shares_i) × LTVBorrow_i / 1e4 > quote(debt)` (strict) and never
///   calls the oracle when the debt is 0;
/// - debt is kept with 1e9 extra precision: `debtOf` rounds up; `repay(max)` repays exactly `debtOf`, above-debt
///   repays revert, and any repay clears the sub-wei remainder; repay has no account check (no oracle call);
/// - `disableController` reverts while any debt remains, including sub-wei precision dust;
/// - `lock` makes the balance, conversion and debt views revert `E_Reentrancy()` (as during a vault operation).
contract MockEVault {
    using SafeERC20 for IERC20;

    error E_Reentrancy();
    error E_ZeroShares();
    error E_ZeroAssets();
    error E_InsufficientCash();
    error E_InsufficientBalance();
    error E_InsufficientAllowance();
    error E_BadAssetReceiver();
    error E_ControllerDisabled();
    error E_RepayTooMuch();
    error E_OutstandingDebt();
    error E_AccountLiquidity();
    error E_NoPriceOracle();
    error E_Unauthorized();

    uint256 internal constant VIRTUAL_DEPOSIT = 1e6;
    uint256 internal constant DEBT_PRECISION = 1e9;

    address public immutable EVC;
    address public immutable asset;
    address public oracle;
    address public unitOfAccount;

    uint256 internal cashInternal;
    uint256 internal totalSharesInternal;
    uint256 internal totalBorrowsExact;
    mapping(address account => uint256) internal shares;
    mapping(address account => uint256) internal debtExact;
    mapping(address collateral => uint16) public LTVBorrow;
    mapping(address collateral => uint16) public LTVLiquidation;
    bool public locked;

    constructor(address evc_, address asset_, address oracle_, address unitOfAccount_) {
        EVC = evc_;
        asset = asset_;
        oracle = oracle_;
        unitOfAccount = unitOfAccount_;
    }

    // ========== TEST SETTERS ==========

    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV) external {
        LTVBorrow[collateral] = borrowLTV;
        LTVLiquidation[collateral] = liquidationLTV;
    }

    function setLocked(bool locked_) external {
        locked = locked_;
    }

    /// @notice Adds interest to `account`'s debt, in units of 1e-9 asset
    function accrue(address account, uint256 exactAmount) external {
        debtExact[account] += exactAmount;
        totalBorrowsExact += exactAmount;
    }

    /// @notice Liquidation stand-in: moves `amount` shares from `from` to `to` without any check
    function seize(address from, address to, uint256 amount) external {
        shares[from] -= amount;
        shares[to] += amount;
    }

    /// @notice Supplier yield: raises the share price by adding `amount` of cash pulled from the caller
    function addYield(uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        cashInternal += amount;
    }

    /// @notice Bad-debt socialisation stand-in on the borrower side: forgives `account`'s whole debt without repayment
    function writeOff(address account) external {
        totalBorrowsExact -= debtExact[account];
        debtExact[account] = 0;
    }

    /// @notice Bad-debt socialisation stand-in on the supplier side: lowers the share price by sending `amount` of cash
    ///         to the caller
    function socializeLoss(uint256 amount) external {
        cashInternal -= amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    // ========== VIEWS ==========

    function balanceOf(address account) external view returns (uint256) {
        _nonReentrantView();
        return shares[account];
    }

    function convertToAssets(uint256 amount) external view returns (uint256) {
        _nonReentrantView();
        return _toAssetsDown(amount);
    }

    function totalAssets() external view returns (uint256) {
        _nonReentrantView();
        return _totalAssets();
    }

    function totalSupply() external view returns (uint256) {
        _nonReentrantView();
        return totalSharesInternal;
    }

    function cash() external view returns (uint256) {
        _nonReentrantView();
        return cashInternal;
    }

    function debtOf(address account) external view returns (uint256) {
        _nonReentrantView();
        return _debtOf(account);
    }

    function debtOfExact(address account) external view returns (uint256) {
        _nonReentrantView();
        return debtExact[account];
    }

    // ========== OPERATIONS ==========

    function deposit(uint256 amount, address receiver) external returns (uint256 minted) {
        address account = _actingAccount();
        if (amount == type(uint256).max) amount = IERC20(asset).balanceOf(account);
        if (amount == 0) return 0;
        minted = Math.mulDiv(amount, totalSharesInternal + VIRTUAL_DEPOSIT, _totalAssets() + VIRTUAL_DEPOSIT);
        require(minted > 0, E_ZeroShares());
        IERC20(asset).safeTransferFrom(account, address(this), amount);
        cashInternal += amount;
        shares[receiver] += minted;
        totalSharesInternal += minted;
    }

    function withdraw(uint256 amount, address receiver, address owner) external returns (uint256 burned) {
        address account = _actingAccount();
        if (amount == 0) return 0;
        require(cashInternal >= amount, E_InsufficientCash());
        burned = Math.mulDiv(amount, totalSharesInternal + VIRTUAL_DEPOSIT, _totalAssets() + VIRTUAL_DEPOSIT, Math.Rounding.Ceil);
        _burnAndSend(account, owner, receiver, burned, amount);
    }

    function redeem(uint256 amount, address receiver, address owner) external returns (uint256 assets) {
        address account = _actingAccount();
        if (amount == type(uint256).max) amount = shares[owner];
        if (amount == 0) return 0;
        assets = _toAssetsDown(amount);
        require(assets > 0, E_ZeroAssets());
        require(cashInternal >= assets, E_InsufficientCash());
        _burnAndSend(account, owner, receiver, amount, assets);
    }

    function borrow(uint256 amount, address receiver) external returns (uint256) {
        address account = _actingAccount();
        require(MockEVC(EVC).isControllerEnabled(account, address(this)), E_ControllerDisabled());
        if (amount == type(uint256).max) amount = cashInternal;
        if (amount == 0) return 0;
        require(cashInternal >= amount, E_InsufficientCash());
        _checkReceiver(receiver);
        debtExact[account] += amount * DEBT_PRECISION;
        totalBorrowsExact += amount * DEBT_PRECISION;
        cashInternal -= amount;
        IERC20(asset).safeTransfer(receiver, amount);
        MockEVC(EVC).requireAccountStatusCheck(account);
        return amount;
    }

    function repay(uint256 amount, address receiver) external returns (uint256 assets) {
        address account = _actingAccount();
        uint256 owed = _debtOf(receiver);
        assets = amount == type(uint256).max ? owed : amount;
        if (assets == 0) return 0;
        require(assets <= owed, E_RepayTooMuch());
        IERC20(asset).safeTransferFrom(account, address(this), assets);
        uint256 remaining = (owed - assets) * DEBT_PRECISION;
        totalBorrowsExact = totalBorrowsExact - debtExact[receiver] + remaining;
        debtExact[receiver] = remaining;
        cashInternal += assets;
    }

    /// @dev Not routed through the EVC: through `evc.call` it acts for the on-behalf-of account, else for msg.sender
    function disableController() external {
        address account = msg.sender == EVC ? _actingAccount() : msg.sender;
        require(debtExact[account] == 0, E_OutstandingDebt());
        MockEVC(EVC).disableController(account);
    }

    /// @notice Account status check run by the EVC for accounts controlled by this vault
    function checkAccountStatus(address account, address[] calldata collaterals) external view returns (bytes4) {
        require(msg.sender == EVC, E_Unauthorized());
        uint256 debt = _debtOf(account);
        if (debt == 0) return this.checkAccountStatus.selector;
        require(oracle != address(0), E_NoPriceOracle());

        uint256 liabilityValue = asset == unitOfAccount ? debt : IPriceOracle(oracle).getQuote(debt, asset, unitOfAccount);
        uint256 collateralValue;
        for (uint256 i; i < collaterals.length; i++) {
            uint16 ltv = LTVBorrow[collaterals[i]];
            if (ltv == 0) continue;
            uint256 balance = MockEVault(collaterals[i]).balanceOf(account);
            if (balance == 0) continue;
            collateralValue += (IPriceOracle(oracle).getQuote(balance, collaterals[i], unitOfAccount) * ltv) / 1e4;
        }
        require(collateralValue > liabilityValue, E_AccountLiquidity());
        return this.checkAccountStatus.selector;
    }

    // ========== INTERNAL ==========

    function _burnAndSend(address account, address owner, address receiver, uint256 burned, uint256 assets) internal {
        require(account == owner, E_InsufficientAllowance());
        require(shares[owner] >= burned, E_InsufficientBalance());
        _checkReceiver(receiver);
        shares[owner] -= burned;
        totalSharesInternal -= burned;
        cashInternal -= assets;
        IERC20(asset).safeTransfer(receiver, assets);
        MockEVC(EVC).requireAccountStatusCheck(owner);
    }

    function _actingAccount() internal view returns (address account) {
        if (msg.sender != EVC) return msg.sender;
        (account, ) = MockEVC(EVC).getCurrentOnBehalfOfAccount(address(0));
    }

    function _checkReceiver(address receiver) internal view {
        require(receiver != address(0), E_BadAssetReceiver());
        address accountOwner = MockEVC(EVC).getAccountOwner(receiver);
        require(accountOwner == address(0) || accountOwner == receiver, E_BadAssetReceiver());
    }

    function _nonReentrantView() internal view {
        require(!locked, E_Reentrancy());
    }

    function _totalAssets() internal view returns (uint256) {
        return cashInternal + Math.ceilDiv(totalBorrowsExact, DEBT_PRECISION);
    }

    function _toAssetsDown(uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, _totalAssets() + VIRTUAL_DEPOSIT, totalSharesInternal + VIRTUAL_DEPOSIT);
    }

    function _debtOf(address account) internal view returns (uint256) {
        return Math.ceilDiv(debtExact[account], DEBT_PRECISION);
    }
}

/// @notice EulerRouter mock: settable mid prices, vault shares resolved to their asset, and a revert switch.
/// @dev `getQuote(in, base, quote) = in × price(base, quote) / 1e18`, rounded down; identical base and quote return
///      `in`; a resolved vault converts shares with its `convertToAssets` first.
contract MockEulerRouter is IPriceOracle {
    error PriceOracle_NotSupported(address base, address quote);
    error PriceOracle_Reverted();

    mapping(address base => mapping(address quote => uint256)) public prices;
    mapping(address vault => bool) public resolvedVaults;
    bool public reverts;

    function setPrice(address base, address quote, uint256 price) external {
        prices[base][quote] = price;
    }

    function setResolvedVault(address vault, bool resolved) external {
        resolvedVaults[vault] = resolved;
    }

    function setReverts(bool reverts_) external {
        reverts = reverts_;
    }

    function getQuote(uint256 inAmount, address base, address quote) external view returns (uint256) {
        require(!reverts, PriceOracle_Reverted());
        if (resolvedVaults[base]) {
            inAmount = MockEVault(base).convertToAssets(inAmount);
            base = MockEVault(base).asset();
        }
        if (base == quote) return inAmount;
        uint256 price = prices[base][quote];
        require(price != 0, PriceOracle_NotSupported(base, quote));
        return Math.mulDiv(inAmount, price, 1e18);
    }
}
