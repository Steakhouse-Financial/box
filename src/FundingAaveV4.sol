// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Steakhouse Financial
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {FundingBase} from "./FundingBase.sol";
import {IAaveV4Spoke} from "./interfaces/aave-v4/IAaveV4Spoke.sol";
import {IOracleCallback} from "./interfaces/IFunding.sol";
import {ORACLE_PRECISION} from "./libraries/Constants.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/**
 * @title FundingAaveV4
 * @notice Funding module for one position (this contract) on one Aave v4 Spoke
 * @dev facilityData is always "" (a Spoke account is cross-margined across all its reserves).
 * @dev The usable reserves are fixed at construction, one reserve per underlying. This resolves Spokes that list the
 *      same underlying several times (from different Hubs): the constructor list decides which reserve a token uses.
 * @dev Aave v4 lets a position borrow down to a health factor of exactly 1, so borrow and depledge are followed by a
 *      guard requiring `healthFactor >= ceil(1e36 / lltvCap)`, i.e. `ltv <= avgCollateralFactor * lltvCap / 1e18`.
 */
contract FundingAaveV4 is FundingBase {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 internal constant WAD = 1e18;

    IAaveV4Spoke public immutable spoke;
    /// @notice Fraction (1e18 = 100%) of the Spoke's own borrowing limit the module may use
    uint256 public immutable lltvCap;
    /// @notice Health factor floor enforced after borrow and depledge: ceil(1e36 / lltvCap)
    uint256 public immutable minHealthFactor;

    uint256[] internal reserveIds;
    mapping(IERC20 token => uint256) internal reserveIdPlusOne;

    /**
     * @param _owner The Box owning this module
     * @param _spoke The Aave v4 Spoke
     * @param _reserveIds The Spoke reserves this module may use; their underlyings must be pairwise distinct
     * @param _lltvCap Fraction of the Spoke's borrowing limit the module may use, in (0, 1e18]
     */
    constructor(address _owner, address _spoke, uint256[] memory _reserveIds, uint256 _lltvCap) FundingBase(_owner) {
        require(_spoke != address(0), ErrorsLib.InvalidAddress());
        require(_lltvCap > 0 && _lltvCap <= WAD, ErrorsLib.InvalidValue());
        require(_reserveIds.length > 0, ErrorsLib.InvalidValue());

        spoke = IAaveV4Spoke(_spoke);
        lltvCap = _lltvCap;
        minHealthFactor = Math.ceilDiv(WAD * WAD, _lltvCap);

        uint256 reserveCount = spoke.getReserveCount();
        for (uint256 i = 0; i < _reserveIds.length; i++) {
            uint256 reserveId = _reserveIds[i];
            require(reserveId < reserveCount, ErrorsLib.InvalidValue());
            IERC20 underlying = IERC20(spoke.getReserve(reserveId).underlying);
            require(address(underlying) != address(0), ErrorsLib.InvalidValue());
            // Also rejects a repeated reserve id
            require(reserveIdPlusOne[underlying] == 0, ErrorsLib.InvalidValue());
            reserveIdPlusOne[underlying] = reserveId + 1;
            reserveIds.push(reserveId);
        }
    }

    // ========== ADMIN ==========

    /// @dev FundingAaveV4 only accepts "" as facilityData
    function addFacility(bytes calldata facilityData) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(facilityData.length == 0, ErrorsLib.InvalidValue());
        require(facilitiesSet.add(keccak256(facilityData)), ErrorsLib.AlreadyWhitelisted());
    }

    /// @dev Only when no configured reserve has supplied shares or debt (not based on account data, which ignores
    ///      supplies that are not enabled as collateral or have a zero collateral factor)
    function removeFacility(bytes calldata facilityData) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        bytes32 facilityHash = keccak256(facilityData);
        require(facilitiesSet.contains(facilityHash), ErrorsLib.NotWhitelisted());
        require(!_isFacilityUsed(facilityData), ErrorsLib.CannotRemove());
        facilitiesSet.remove(facilityHash);
    }

    /// @notice facilityData of the facility at `index`; always "" for this module
    function facilities(uint256 index) external view returns (bytes memory) {
        // Reverts on an invalid index, like FundingMorpho
        facilitiesSet.at(index);
        return "";
    }

    /// @dev The token must be the underlying of a configured reserve whose latest collateral factor is not 0.
    ///      Prevents registering a token the Spoke would never count as collateral.
    function addCollateralToken(IERC20 collateralToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        uint256 reserveId = _requireReserveId(collateralToken);
        uint32 latestKey = spoke.getReserve(reserveId).dynamicConfigKey;
        require(spoke.getDynamicReserveConfig(reserveId, latestKey).collateralFactor > 0, ErrorsLib.InvalidValue());
        require(collateralTokensSet.add(address(collateralToken)), ErrorsLib.AlreadyWhitelisted());
    }

    /// @dev The token must be the underlying of a configured reserve flagged borrowable
    function addDebtToken(IERC20 debtToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        uint256 reserveId = _requireReserveId(debtToken);
        require(spoke.getReserveConfig(reserveId).borrowable, ErrorsLib.InvalidValue());
        require(debtTokensSet.add(address(debtToken)), ErrorsLib.AlreadyWhitelisted());
    }

    /// @dev Only when the supplied balance of the token is 0
    function removeCollateralToken(IERC20 collateralToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(_collateralBalance(collateralToken) == 0, ErrorsLib.CannotRemove());
        require(collateralTokensSet.remove(address(collateralToken)), ErrorsLib.NotWhitelisted());
    }

    /// @dev Only when the debt of the token (premium included) is 0
    function removeDebtToken(IERC20 debtToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(_debtBalance(debtToken) == 0, ErrorsLib.CannotRemove());
        require(debtTokensSet.remove(address(debtToken)), ErrorsLib.NotWhitelisted());
    }

    // ========== ACTIONS ==========

    /// @dev Assume caller did transfer the collateral tokens to this contract before calling
    /// @dev Supplies and enables the reserve as collateral (an Aave v4 supply never does it). No health guard, so a
    ///      pledge can always improve a position.
    function pledge(bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external override {
        uint256 reserveId = _checkCollateralAction(facilityData, collateralToken);

        collateralToken.forceApprove(address(spoke), collateralAmount);
        spoke.supply(reserveId, collateralAmount, address(this));

        (bool usingAsCollateral, ) = spoke.getUserReserveStatus(reserveId, address(this));
        if (!usingAsCollateral) spoke.setUsingAsCollateral(reserveId, true, address(this));
    }

    /// @dev Sends exactly `collateralAmount` to the owner. The Spoke silently caps withdrawals at the supplied
    ///      balance, so a larger amount (including type(uint256).max) reverts instead of delivering less.
    /// @dev Followed by the health guard, also during winddown when anyone can trigger it through the Box.
    function depledge(bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external override {
        uint256 reserveId = _checkCollateralAction(facilityData, collateralToken);

        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        spoke.withdraw(reserveId, collateralAmount, address(this));
        uint256 received = collateralToken.balanceOf(address(this)) - balanceBefore;
        require(received >= collateralAmount, ErrorsLib.InvalidAmount());

        collateralToken.safeTransfer(owner, collateralAmount);
        _requireHealthy();
    }

    /// @dev Sends exactly `borrowAmount` to the owner, then applies the health guard.
    ///      type(uint256).max is rejected: there is no "borrow all" sentinel.
    function borrow(bytes calldata facilityData, IERC20 debtToken, uint256 borrowAmount) external override {
        uint256 reserveId = _checkDebtAction(facilityData, debtToken);
        require(borrowAmount != type(uint256).max, ErrorsLib.InvalidAmount());

        uint256 balanceBefore = debtToken.balanceOf(address(this));
        spoke.borrow(reserveId, borrowAmount, address(this));
        uint256 received = debtToken.balanceOf(address(this)) - balanceBefore;
        require(received >= borrowAmount, ErrorsLib.InvalidAmount());

        debtToken.safeTransfer(owner, borrowAmount);
        _requireHealthy();
    }

    /// @dev Assume caller did transfer the debt tokens to this contract before calling
    /// @dev Repays min(repayAmount, total debt incl. premium): repaying debtBalance("", token) closes the debt with no
    ///      dust. Whatever was not used is returned to the owner. No health guard, so a repay is never blocked by it.
    function repay(bytes calldata facilityData, IERC20 debtToken, uint256 repayAmount) external override {
        uint256 reserveId = _checkDebtAction(facilityData, debtToken);

        // The Spoke reverts on a zero repay or when there is no debt
        uint256 toRepay = Math.min(repayAmount, spoke.getUserTotalDebt(reserveId, address(this)));
        uint256 spent;
        if (toRepay > 0) {
            uint256 balanceBefore = debtToken.balanceOf(address(this));
            debtToken.forceApprove(address(spoke), toRepay);
            spoke.repay(reserveId, toRepay, address(this));
            debtToken.forceApprove(address(spoke), 0);
            spent = balanceBefore - debtToken.balanceOf(address(this));
        }

        if (spent < repayAmount) {
            debtToken.safeTransfer(owner, repayAmount - spent);
        }
    }

    // ========== POSITION ==========

    /// @notice Debt value over collateral value (1e18 scale, rounded up) at the Spoke's own prices
    /// @dev Uses the Spoke account data: only collateral enabled with a non-zero collateral factor counts.
    /// @dev Returns 0 without debt, type(uint256).max with debt but no collateral value, and 0 for facilityData != "".
    function ltv(bytes calldata facilityData) external view override returns (uint256) {
        if (facilityData.length != 0) return 0;
        IAaveV4Spoke.UserAccountData memory data = spoke.getUserAccountData(address(this));
        if (data.totalDebtValueRay == 0) return 0;
        if (data.totalCollateralValue == 0) return type(uint256).max;
        // totalDebtValueRay is in value units * 1e27, totalCollateralValue in value units
        return data.totalDebtValueRay.ceilDiv(data.totalCollateralValue * 1e9);
    }

    /// @dev Total debt including premium, rounded up. 0 for unknown tokens and facilityData != "" (never reverts).
    function debtBalance(bytes calldata facilityData, IERC20 debtToken) external view override returns (uint256) {
        return facilityData.length == 0 ? _debtBalance(debtToken) : 0;
    }

    /// @dev Supplied assets, rounded down. 0 for unknown tokens and facilityData != "" (never reverts).
    function collateralBalance(bytes calldata facilityData, IERC20 collateralToken) external view override returns (uint256) {
        return facilityData.length == 0 ? _collateralBalance(collateralToken) : 0;
    }

    /// @notice Value of the position in the Box asset, using the Box oracles
    /// @dev Collateral rounded down, debt rounded up, floored at 0 (no recourse beyond the position).
    /// @dev Only uses Spoke balance views (no Spoke oracle), which keep working when a reserve is paused or the Spoke
    ///      is halted. Tokens held idle by this contract are not counted.
    function nav(IOracleCallback oraclesProvider) public view override returns (uint256) {
        address asset = oraclesProvider.asset();
        uint256 totalCollateralValue;
        uint256 totalDebtValue;

        uint256 length = collateralTokensSet.length();
        for (uint256 i = 0; i < length; i++) {
            IERC20 token = IERC20(collateralTokensSet.at(i));
            uint256 balance = _collateralBalance(token);
            if (balance == 0) continue;
            totalCollateralValue += address(token) == asset
                ? balance
                : balance.mulDiv(oraclesProvider.oracles(token).price(), ORACLE_PRECISION, Math.Rounding.Floor);
        }

        length = debtTokensSet.length();
        for (uint256 i = 0; i < length; i++) {
            IERC20 token = IERC20(debtTokensSet.at(i));
            uint256 balance = _debtBalance(token);
            if (balance == 0) continue;
            totalDebtValue += address(token) == asset
                ? balance
                : balance.mulDiv(oraclesProvider.oracles(token).price(), ORACLE_PRECISION, Math.Rounding.Ceil);
        }

        return totalCollateralValue > totalDebtValue ? totalCollateralValue - totalDebtValue : 0;
    }

    // ========== VIEWS ==========

    /// @notice Reserve used for `token`; `listed` is false if the token is not the underlying of a configured reserve
    function reserveIdOf(IERC20 token) external view returns (bool listed, uint256 reserveId) {
        uint256 idPlusOne = reserveIdPlusOne[token];
        if (idPlusOne == 0) return (false, 0);
        return (true, idPlusOne - 1);
    }

    /// @notice Configured reserve ids, in constructor order
    function reserveIdsArray() external view returns (uint256[] memory) {
        return reserveIds;
    }

    // ========== INTERNAL ==========

    function _requireReserveId(IERC20 token) internal view returns (uint256) {
        uint256 idPlusOne = reserveIdPlusOne[token];
        require(idPlusOne != 0, ErrorsLib.TokenNotWhitelisted());
        return idPlusOne - 1;
    }

    function _checkCollateralAction(bytes calldata facilityData, IERC20 collateralToken) internal view returns (uint256) {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), ErrorsLib.NotWhitelisted());
        require(isCollateralToken(collateralToken), ErrorsLib.TokenNotWhitelisted());
        return _requireReserveId(collateralToken);
    }

    function _checkDebtAction(bytes calldata facilityData, IERC20 debtToken) internal view returns (uint256) {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), ErrorsLib.NotWhitelisted());
        require(isDebtToken(debtToken), ErrorsLib.TokenNotWhitelisted());
        return _requireReserveId(debtToken);
    }

    /// @dev Returns 0 for tokens not registered as debt: Box calls debtBalance for arbitrary tokens during winddown
    function _debtBalance(IERC20 debtToken) internal view override returns (uint256) {
        if (!isDebtToken(debtToken)) return 0;
        return spoke.getUserTotalDebt(reserveIdPlusOne[debtToken] - 1, address(this));
    }

    /// @dev Returns 0 for tokens not registered as collateral
    function _collateralBalance(IERC20 collateralToken) internal view override returns (uint256) {
        if (!isCollateralToken(collateralToken)) return 0;
        return spoke.getUserSuppliedAssets(reserveIdPlusOne[collateralToken] - 1, address(this));
    }

    /// @dev Share and debt based over every configured reserve, registered or not
    function _isFacilityUsed(bytes calldata) internal view override returns (bool) {
        uint256 length = reserveIds.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 reserveId = reserveIds[i];
            if (spoke.getUserSuppliedShares(reserveId, address(this)) > 0) return true;
            if (spoke.getUserTotalDebt(reserveId, address(this)) > 0) return true;
        }
        return false;
    }

    /// @dev The Spoke rebinds the account to the latest risk configuration inside borrow and withdraw, so the account
    ///      data read right after reflects it. Health factor is type(uint256).max without debt.
    function _requireHealthy() internal view {
        require(spoke.getUserAccountData(address(this)).healthFactor >= minHealthFactor, ErrorsLib.ExcessiveLTV());
    }
}
