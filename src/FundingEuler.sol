// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {FundingBase} from "./FundingBase.sol";
import {IEVault} from "./interfaces/euler/IEVault.sol";
import {IEVC} from "./interfaces/euler/IEVC.sol";
import {IPriceOracle} from "./interfaces/euler/IPriceOracle.sol";
import {IOracleCallback} from "./interfaces/IFunding.sol";
import {ORACLE_PRECISION} from "./libraries/Constants.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/**
 * @title FundingEuler
 * @notice Funding module borrowing from Euler v2 (EVC + EVK vaults), one isolated EVC sub-account per facility
 * @dev facilityData = abi.encode(address collateralVault, address borrowVault), exactly 64 bytes. Collateral is held as
 *      collateral-vault shares and debt is owed to the borrow vault, both on the facility's sub-account
 *      `address(this) ^ id` with id in 1..255 (the lowest free id at registration, freed on removal unless zero-value
 *      shares remain on the sub-account). The module's own address (id 0) never holds positions. An EVC account has a
 *      single controller, hence one sub-account per pair.
 * @dev Borrowed and withdrawn assets go straight to the owner. The module never sets EVC operators or permits.
 * @dev Euler's balance and debt views revert while the vault runs an operation (e.g. inside its flash-loan callback).
 *      `nav`, and therefore the Box's totalAssets, revert in that window rather than return a wrong value.
 */
contract FundingEuler is FundingBase {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 internal constant WAD = 1e18;
    /// @dev Euler LTVs are on a 1e4 scale
    uint256 internal constant LTV_TO_WAD = 1e14;
    uint256 internal constant MAX_SUB_ACCOUNT_ID = 255;

    struct FacilityInfo {
        address collateralVault;
        address borrowVault;
        address collateralToken;
        address debtToken;
        uint256 subAccountId;
    }

    IEVC public immutable evc;
    /// @notice Fraction (1e18 = 100%) of the Euler borrow LTV the module may use
    uint256 public immutable ltvCap;

    mapping(bytes32 facilityHash => bytes) public facilityDataMap;
    mapping(bytes32 facilityHash => FacilityInfo) internal facilityInfo;
    /// @dev Bit i is set while sub-account id i is assigned to a facility, and stays set forever once a removed
    ///      facility left zero-value collateral-vault shares on it
    uint256 internal usedSubAccountIds;

    /**
     * @param _owner The Box owning this module
     * @param _evc The Ethereum Vault Connector of the chain
     * @param _ltvCap Fraction of the Euler borrow LTV the module may use, in (0, 1e18]
     */
    constructor(address _owner, address _evc, uint256 _ltvCap) FundingBase(_owner) {
        require(_evc != address(0), ErrorsLib.InvalidAddress());
        require(_ltvCap > 0 && _ltvCap <= WAD, ErrorsLib.InvalidValue());
        evc = IEVC(_evc);
        ltvCap = _ltvCap;
    }

    // ========== ADMIN ==========

    /// @dev Before adding a facility, the collateral vault asset must be a collateral token and the borrow vault asset a
    ///      debt token. Both vaults must belong to this EVC and the borrow vault must accept the collateral vault
    ///      (LTVBorrow > 0). Assigns the lowest free sub-account id; reverts when all 255 are in use.
    function addFacility(bytes calldata facilityData) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());

        (address collateralVault, address borrowVault) = decodeFacilityData(facilityData);
        require(IEVault(collateralVault).EVC() == address(evc), ErrorsLib.InvalidFacilityData());
        require(IEVault(borrowVault).EVC() == address(evc), ErrorsLib.InvalidFacilityData());
        require(IEVault(borrowVault).LTVBorrow(collateralVault) > 0, ErrorsLib.InvalidFacilityData());

        address collateralToken = IEVault(collateralVault).asset();
        address debtToken = IEVault(borrowVault).asset();
        require(isCollateralToken(IERC20(collateralToken)), ErrorsLib.TokenNotWhitelisted());
        require(isDebtToken(IERC20(debtToken)), ErrorsLib.TokenNotWhitelisted());

        bytes32 facilityHash = keccak256(facilityData);
        require(facilitiesSet.add(facilityHash), ErrorsLib.AlreadyWhitelisted());
        facilityDataMap[facilityHash] = facilityData;
        facilityInfo[facilityHash] = FacilityInfo({
            collateralVault: collateralVault,
            borrowVault: borrowVault,
            collateralToken: collateralToken,
            debtToken: debtToken,
            subAccountId: _takeSubAccountId()
        });
    }

    /// @dev Only when the sub-account owes no debt and its collateral-vault shares (donated shares included) are worth 0
    ///      assets. Releases the controller and the collateral on the EVC.
    /// @dev Shares worth 0 assets can remain after Euler socialises bad debt (share price below 1). Euler refuses to
    ///      redeem them (E_ZeroAssets), so they are left on the sub-account and its id is never assigned again: a later
    ///      facility can never count them if they regain value. Without shares, the id is freed.
    function removeFacility(bytes calldata facilityData) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        bytes32 facilityHash = keccak256(facilityData);
        require(facilitiesSet.contains(facilityHash), ErrorsLib.NotWhitelisted());
        require(!_isFacilityUsed(facilityData), ErrorsLib.CannotRemove());

        FacilityInfo memory info = facilityInfo[facilityHash];
        address account = _subAccount(info.subAccountId);
        uint256 shares = IEVault(info.collateralVault).balanceOf(account);
        _releaseController(account, info.borrowVault);
        if (evc.isCollateralEnabled(account, info.collateralVault)) evc.disableCollateral(account, info.collateralVault);

        facilitiesSet.remove(facilityHash);
        if (shares == 0) usedSubAccountIds &= ~(uint256(1) << info.subAccountId);
        delete facilityInfo[facilityHash];
        delete facilityDataMap[facilityHash];
    }

    function facilities(uint256 index) external view returns (bytes memory) {
        return facilityDataMap[facilitiesSet.at(index)];
    }

    /// @dev Only when the balance is 0 and no facility references the token
    function removeCollateralToken(IERC20 collateralToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(_collateralBalance(collateralToken) == 0, ErrorsLib.CannotRemove());
        uint256 length = facilitiesSet.length();
        for (uint256 i = 0; i < length; i++) {
            require(facilityInfo[facilitiesSet.at(i)].collateralToken != address(collateralToken), ErrorsLib.CannotRemove());
        }
        require(collateralTokensSet.remove(address(collateralToken)), ErrorsLib.NotWhitelisted());
    }

    /// @dev Only when the balance is 0 and no facility references the token
    function removeDebtToken(IERC20 debtToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(_debtBalance(debtToken) == 0, ErrorsLib.CannotRemove());
        uint256 length = facilitiesSet.length();
        for (uint256 i = 0; i < length; i++) {
            require(facilityInfo[facilitiesSet.at(i)].debtToken != address(debtToken), ErrorsLib.CannotRemove());
        }
        require(debtTokensSet.remove(address(debtToken)), ErrorsLib.NotWhitelisted());
    }

    // ========== ACTIONS ==========

    /// @dev Assume caller did transfer the collateral tokens to this contract before calling
    /// @dev Deposits into the collateral vault for the facility sub-account and enables the vault as its collateral.
    ///      type(uint256).max is rejected (Euler would deposit this contract's whole balance).
    function pledge(bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external override {
        FacilityInfo storage info = _checkCollateralAction(facilityData, collateralToken);
        require(collateralAmount != type(uint256).max, ErrorsLib.InvalidAmount());
        address account = _subAccount(info.subAccountId);
        address collateralVault = info.collateralVault;

        collateralToken.forceApprove(collateralVault, collateralAmount);
        IEVault(collateralVault).deposit(collateralAmount, account);
        if (!evc.isCollateralEnabled(account, collateralVault)) evc.enableCollateral(account, collateralVault);
    }

    /// @dev Withdraws exactly `collateralAmount` to the owner, acting as the sub-account. When the amount is the whole
    ///      collateral balance (how the Box resolves type(uint256).max) all shares are redeemed so no share dust is
    ///      left. Reverts above the collateral balance (never delivers less).
    /// @dev Followed by the LTV guard, also during winddown when anyone can trigger it through the Box.
    function depledge(bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external override {
        FacilityInfo storage info = _checkCollateralAction(facilityData, collateralToken);
        address account = _subAccount(info.subAccountId);
        IEVault collateralVault = IEVault(info.collateralVault);

        uint256 balance = collateralVault.convertToAssets(collateralVault.balanceOf(account));
        require(collateralAmount <= balance, ErrorsLib.InvalidAmount());
        bytes memory data = collateralAmount == balance
            ? abi.encodeCall(IEVault.redeem, (type(uint256).max, owner, account))
            : abi.encodeCall(IEVault.withdraw, (collateralAmount, owner, account));

        uint256 ownerBalanceBefore = collateralToken.balanceOf(owner);
        evc.call(address(collateralVault), account, 0, data);
        require(collateralToken.balanceOf(owner) - ownerBalanceBefore >= collateralAmount, ErrorsLib.InsufficientLiquidity());

        _requireGuard(info, account);
    }

    /// @dev Borrows exactly `borrowAmount` to the owner, acting as the sub-account; enables the borrow vault as its
    ///      controller first if needed. type(uint256).max is rejected (Euler would borrow all the vault cash).
    /// @dev Followed by the LTV guard. Euler also enforces its own borrow LTV when the EVC checks the account.
    function borrow(bytes calldata facilityData, IERC20 debtToken, uint256 borrowAmount) external override {
        FacilityInfo storage info = _checkDebtAction(facilityData, debtToken);
        require(borrowAmount != type(uint256).max, ErrorsLib.InvalidAmount());
        address account = _subAccount(info.subAccountId);
        address borrowVault = info.borrowVault;

        if (!evc.isControllerEnabled(account, borrowVault)) evc.enableController(account, borrowVault);
        uint256 ownerBalanceBefore = debtToken.balanceOf(owner);
        evc.call(borrowVault, account, 0, abi.encodeCall(IEVault.borrow, (borrowAmount, owner)));
        require(debtToken.balanceOf(owner) - ownerBalanceBefore >= borrowAmount, ErrorsLib.InsufficientLiquidity());

        _requireGuard(info, account);
    }

    /// @dev Assume caller did transfer the debt tokens to this contract before calling
    /// @dev Repays for the sub-account. At or above the debt, the exact debt is repaid (Euler's max) and the borrow
    ///      vault is released as controller; whatever is not used is returned to the owner. No guard and no Euler
    ///      price read, so repaying works when Euler price feeds are stale.
    function repay(bytes calldata facilityData, IERC20 debtToken, uint256 repayAmount) external override {
        FacilityInfo storage info = _checkDebtAction(facilityData, debtToken);
        address account = _subAccount(info.subAccountId);
        address borrowVault = info.borrowVault;

        uint256 debt = IEVault(borrowVault).debtOf(account);
        uint256 repaid;
        if (debt > 0 && repayAmount > 0) {
            debtToken.forceApprove(borrowVault, repayAmount);
            repaid = IEVault(borrowVault).repay(repayAmount >= debt ? type(uint256).max : repayAmount, account);
            debtToken.forceApprove(borrowVault, 0);
        }

        if (repayAmount > repaid) debtToken.safeTransfer(owner, repayAmount - repaid);
        if (repayAmount >= debt) _releaseController(account, borrowVault);
    }

    // ========== POSITION ==========

    /// @notice Debt value over collateral value (1e18 scale, rounded up) at the borrow vault's oracle, in its unit of
    ///         account. This is the raw ratio, not weighted by the Euler LTVs.
    /// @dev 0 without debt (the oracle is not called), type(uint256).max with debt and a zero collateral value, and 0
    ///      for unregistered facilityData.
    function ltv(bytes calldata facilityData) external view override returns (uint256) {
        if (!isFacility(facilityData)) return 0;
        FacilityInfo storage info = facilityInfo[keccak256(facilityData)];
        return _ltv(info, _subAccount(info.subAccountId));
    }

    /// @dev Borrow-vault debt of the sub-account, rounded up (the exact closing amount). 0 for tokens the facility does
    ///      not borrow and for unregistered or malformed facilityData (never reverts on those).
    function debtBalance(bytes calldata facilityData, IERC20 debtToken) external view override returns (uint256) {
        if (!isFacility(facilityData)) return 0;
        FacilityInfo storage info = facilityInfo[keccak256(facilityData)];
        if (info.debtToken != address(debtToken)) return 0;
        return IEVault(info.borrowVault).debtOf(_subAccount(info.subAccountId));
    }

    /// @dev Assets of the sub-account's collateral-vault shares, rounded down. 0 for tokens the facility does not use as
    ///      collateral and for unregistered or malformed facilityData.
    function collateralBalance(bytes calldata facilityData, IERC20 collateralToken) external view override returns (uint256) {
        if (!isFacility(facilityData)) return 0;
        FacilityInfo storage info = facilityInfo[keccak256(facilityData)];
        if (info.collateralToken != address(collateralToken)) return 0;
        return _collateralAssets(info.collateralVault, _subAccount(info.subAccountId));
    }

    /// @notice Value of the positions in the Box asset, using the Box oracles
    /// @dev Per facility: collateral (rounded down) minus debt (rounded up), floored at 0. The Box asset is valued 1:1.
    ///      Only the vault balance and debt views are used, never the Euler oracles. Tokens held idle by this contract
    ///      are not counted.
    /// @dev Reverts while a facility vault is in the middle of an operation (Euler's views revert E_Reentrancy, e.g.
    ///      inside that vault's flash-loan callback). This is intended: a value computed without that vault would let
    ///      Box shares be minted or redeemed at a wrong price. Do not source flash liquidity from a vault used by a
    ///      facility of the same Box.
    function nav(IOracleCallback oraclesProvider) public view override returns (uint256 nav_) {
        address asset = oraclesProvider.asset();
        uint256 length = facilitiesSet.length();
        for (uint256 i = 0; i < length; i++) {
            FacilityInfo storage info = facilityInfo[facilitiesSet.at(i)];
            address account = _subAccount(info.subAccountId);
            uint256 shares = IEVault(info.collateralVault).balanceOf(account);
            if (shares == 0) continue; // No recourse beyond the collateral

            uint256 collateral = IEVault(info.collateralVault).convertToAssets(shares);
            uint256 value = _valueOf(oraclesProvider, asset, info.collateralToken, collateral, Math.Rounding.Floor);
            uint256 debt = IEVault(info.borrowVault).debtOf(account);
            if (debt > 0) {
                uint256 debtValue = _valueOf(oraclesProvider, asset, info.debtToken, debt, Math.Rounding.Ceil);
                value = value > debtValue ? value - debtValue : 0;
            }
            nav_ += value;
        }
    }

    // ========== VIEWS ==========

    /// @notice Sub-account id (1..255) of a registered facility; 0 for unregistered facilityData
    function subAccountId(bytes calldata facilityData) external view returns (uint256) {
        return facilityInfo[keccak256(facilityData)].subAccountId;
    }

    /// @notice EVC sub-account holding the positions of a registered facility; address(0) for unregistered facilityData
    function subAccount(bytes calldata facilityData) external view returns (address) {
        uint256 id = facilityInfo[keccak256(facilityData)].subAccountId;
        return id == 0 ? address(0) : _subAccount(id);
    }

    /// @dev Reverts unless facilityData is exactly abi.encode(address, address) (64 bytes, clean address bits) with two
    ///      distinct non-zero vaults
    function decodeFacilityData(bytes memory facilityData) public pure returns (address collateralVault, address borrowVault) {
        require(facilityData.length == 64, ErrorsLib.InvalidFacilityData());
        (collateralVault, borrowVault) = abi.decode(facilityData, (address, address));
        require(collateralVault != address(0) && borrowVault != address(0), ErrorsLib.InvalidFacilityData());
        require(collateralVault != borrowVault, ErrorsLib.InvalidFacilityData());
    }

    function encodeFacilityData(address collateralVault, address borrowVault) external pure returns (bytes memory) {
        return abi.encode(collateralVault, borrowVault);
    }

    // ========== INTERNAL ==========

    function _checkCollateralAction(bytes calldata facilityData, IERC20 collateralToken) internal view returns (FacilityInfo storage info) {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), ErrorsLib.NotWhitelisted());
        info = facilityInfo[keccak256(facilityData)];
        require(info.collateralToken == address(collateralToken), ErrorsLib.TokenNotWhitelisted());
    }

    function _checkDebtAction(bytes calldata facilityData, IERC20 debtToken) internal view returns (FacilityInfo storage info) {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), ErrorsLib.NotWhitelisted());
        info = facilityInfo[keccak256(facilityData)];
        require(info.debtToken == address(debtToken), ErrorsLib.TokenNotWhitelisted());
    }

    function _takeSubAccountId() internal returns (uint256 id) {
        uint256 used = usedSubAccountIds;
        for (id = 1; id <= MAX_SUB_ACCOUNT_ID; id++) {
            if (used & (uint256(1) << id) == 0) {
                usedSubAccountIds = used | (uint256(1) << id);
                return id;
            }
        }
        revert ErrorsLib.TooManyFacilities();
    }

    function _subAccount(uint256 id) internal view returns (address) {
        return address(uint160(address(this)) ^ uint160(id));
    }

    /// @dev Only the vault can remove itself as controller, acting for the account; it reverts with any debt left
    function _releaseController(address account, address borrowVault) internal {
        if (evc.isControllerEnabled(account, borrowVault)) {
            evc.call(borrowVault, account, 0, abi.encodeCall(IEVault.disableController, ()));
        }
    }

    function _collateralAssets(address collateralVault, address account) internal view returns (uint256) {
        return IEVault(collateralVault).convertToAssets(IEVault(collateralVault).balanceOf(account));
    }

    function _ltv(FacilityInfo storage info, address account) internal view returns (uint256) {
        IEVault borrowVault = IEVault(info.borrowVault);
        uint256 debt = borrowVault.debtOf(account);
        if (debt == 0) return 0;
        uint256 shares = IEVault(info.collateralVault).balanceOf(account);
        if (shares == 0) return type(uint256).max;

        IPriceOracle oracle = IPriceOracle(borrowVault.oracle());
        address unitOfAccount = borrowVault.unitOfAccount();
        uint256 collateralValue = oracle.getQuote(shares, info.collateralVault, unitOfAccount);
        if (collateralValue == 0) return type(uint256).max;
        uint256 debtValue = info.debtToken == unitOfAccount ? debt : oracle.getQuote(debt, info.debtToken, unitOfAccount);
        return debtValue.mulDiv(WAD, collateralValue, Math.Rounding.Ceil);
    }

    function _requireGuard(FacilityInfo storage info, address account) internal view {
        uint256 maxLtv = (uint256(IEVault(info.borrowVault).LTVBorrow(info.collateralVault)) * LTV_TO_WAD * ltvCap) / WAD;
        require(_ltv(info, account) <= maxLtv, ErrorsLib.ExcessiveLTV());
    }

    function _valueOf(
        IOracleCallback oraclesProvider,
        address asset,
        address token,
        uint256 amount,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        if (token == asset) return amount;
        return amount.mulDiv(oraclesProvider.oracles(IERC20(token)).price(), ORACLE_PRECISION, rounding);
    }

    /// @dev Returns 0 for tokens no facility borrows: Box calls debtBalance for arbitrary tokens during winddown
    function _debtBalance(IERC20 debtToken) internal view override returns (uint256 balance) {
        uint256 length = facilitiesSet.length();
        for (uint256 i = 0; i < length; i++) {
            FacilityInfo storage info = facilityInfo[facilitiesSet.at(i)];
            if (info.debtToken == address(debtToken)) balance += IEVault(info.borrowVault).debtOf(_subAccount(info.subAccountId));
        }
    }

    /// @dev Returns 0 for tokens no facility uses as collateral
    function _collateralBalance(IERC20 collateralToken) internal view override returns (uint256 balance) {
        uint256 length = facilitiesSet.length();
        for (uint256 i = 0; i < length; i++) {
            FacilityInfo storage info = facilityInfo[facilitiesSet.at(i)];
            if (info.collateralToken == address(collateralToken)) {
                balance += _collateralAssets(info.collateralVault, _subAccount(info.subAccountId));
            }
        }
    }

    /// @dev Shares worth 0 assets do not count as use (see removeFacility)
    function _isFacilityUsed(bytes calldata facilityData) internal view override returns (bool) {
        FacilityInfo storage info = facilityInfo[keccak256(facilityData)];
        address account = _subAccount(info.subAccountId);
        return _collateralAssets(info.collateralVault, account) > 0 || IEVault(info.borrowVault).debtOf(account) > 0;
    }
}
