// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {FundingBase} from "./FundingBase.sol";
import {IBox} from "./interfaces/IBox.sol";
import {IOracleCallback} from "./interfaces/IFunding.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {CollateralParams, IMidnight, Market, Offer} from "./interfaces/midnight/IMidnight.sol";
import {ORACLE_PRECISION} from "./libraries/Constants.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {IdLib} from "./libraries/midnight/IdLib.sol";
import {MidnightMathLib} from "./libraries/midnight/MidnightMathLib.sol";

/// @notice A lender bid staged by an allocator for a later `borrow`.
/// @param offer A Midnight buy offer (lender bid) in the facility market
/// @param ratifierData Passed verbatim to `take`
/// @param maxUnits Cap on the units sold into this offer; 0 skips the fill, type(uint256).max means no cap
struct OfferFill {
    Offer offer;
    bytes ratifierData;
    uint256 maxUnits;
}

/**
 * @title FundingMidnight
 * @notice Funding module borrowing at a fixed rate and term on Morpho Midnight, one Midnight market per facility
 * @dev facilityData = abi.encode(Market market, uint256 collateralIndex, uint256 maxBorrowApr). Midnight keeps one
 *      position per market and address, so at most one facility per market id is accepted.
 * @dev Borrowing sells units (face value due at maturity) into lender bids. IFunding.borrow carries no offer, so an
 *      allocator stages the bids first with `stageBorrow`; `borrow` consumes the staging and only takes bids whose price
 *      net of the settlement fee implies at most `maxBorrowApr` (simple annual rate, 365-day year).
 * @dev debtBalance is the face value (what closes the loan). nav accretes the debt linearly from the proceeds to the
 *      face value at maturity, so a borrow does not move nav and the implied interest is recognised over the term.
 * @dev The module never grants Midnight authorisations. Repay is at face value only (no buy-back below par).
 */
contract FundingMidnight is FundingBase {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 internal constant WAD = 1e18;
    /// @dev Precision of the discount rate (discount units per second, scaled)
    uint256 internal constant RATE_SCALE = 1e18;

    struct FacilityInfo {
        bytes32 marketId;
        address loanToken;
        address collateralToken;
        uint256 collateralIndex;
        uint256 maturity;
        // Face units the accretion state accounts for; synced down to Midnight's debt before every debt mutation
        uint256 trackedUnits;
        // Sum over borrows of (units - proceeds) * RATE_SCALE / (maturity - borrowTime)
        uint256 discountRate;
    }

    struct Staging {
        uint256 validUntil;
        address stager; // The staging is void once this address is no longer an allocator
        bytes fills; // abi.encode(OfferFill[])
    }

    IMidnight public immutable midnight;
    /// @notice Fraction (1e18 = 100%) of the market LLTV the module may use
    uint256 public immutable lltvCap;

    mapping(bytes32 facilityHash => bytes) public facilityDataMap;
    mapping(bytes32 facilityHash => FacilityInfo) internal facilityInfo;
    mapping(bytes32 facilityHash => Staging) internal staging;
    mapping(bytes32 id => bytes32 facilityHash) public facilityOfMarket;

    /**
     * @param _owner The Box owning this module
     * @param _midnight The Morpho Midnight contract
     * @param _lltvCap Fraction of the market LLTV the module may use, in (0, 1e18]
     */
    constructor(address _owner, address _midnight, uint256 _lltvCap) FundingBase(_owner) {
        require(_midnight != address(0), ErrorsLib.InvalidAddress());
        require(_lltvCap > 0 && _lltvCap <= WAD, ErrorsLib.InvalidValue());
        midnight = IMidnight(_midnight);
        lltvCap = _lltvCap;
    }

    // ========== ADMIN ==========

    /// @dev Before adding a facility, the loan token must be a debt token and the collateral a collateral token.
    /// @dev Only the canonical encoding is accepted. The market must exist on this Midnight (it is never created here),
    ///      mature in the future and not be used by another facility; 0 < maxBorrowApr <= 1e18 (100% a year).
    function addFacility(bytes calldata facilityData) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());

        (Market memory market, uint256 collateralIndex, uint256 maxBorrowApr) = decodeFacilityData(facilityData);
        require(market.midnight == address(midnight), ErrorsLib.InvalidValue());
        require(market.chainId == block.chainid, ErrorsLib.InvalidValue());
        require(collateralIndex < market.collateralParams.length, ErrorsLib.InvalidValue());
        require(market.maturity > block.timestamp, ErrorsLib.InvalidValue());
        require(maxBorrowApr > 0 && maxBorrowApr <= WAD, ErrorsLib.InvalidValue());

        bytes32 id = IdLib.toId(market);
        require(midnight.tickSpacing(id) > 0, ErrorsLib.InvalidValue());

        address collateralToken = market.collateralParams[collateralIndex].token;
        require(isCollateralToken(IERC20(collateralToken)), ErrorsLib.TokenNotWhitelisted());
        require(isDebtToken(IERC20(market.loanToken)), ErrorsLib.TokenNotWhitelisted());
        require(facilityOfMarket[id] == bytes32(0), ErrorsLib.AlreadyWhitelisted());

        bytes32 facilityHash = keccak256(facilityData);
        require(facilitiesSet.add(facilityHash), ErrorsLib.AlreadyWhitelisted());
        facilityDataMap[facilityHash] = facilityData;
        facilityOfMarket[id] = facilityHash;
        facilityInfo[facilityHash] = FacilityInfo({
            marketId: id,
            loanToken: market.loanToken,
            collateralToken: collateralToken,
            collateralIndex: collateralIndex,
            maturity: market.maturity,
            trackedUnits: 0,
            discountRate: 0
        });
    }

    /// @dev Only when the Midnight position has no collateral and no debt. Clears the staging and accretion state.
    function removeFacility(bytes calldata facilityData) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        bytes32 facilityHash = keccak256(facilityData);
        require(facilitiesSet.contains(facilityHash), ErrorsLib.NotWhitelisted());
        require(!_isFacilityUsed(facilityData), ErrorsLib.CannotRemove());

        facilitiesSet.remove(facilityHash);
        delete facilityOfMarket[facilityInfo[facilityHash].marketId];
        delete facilityInfo[facilityHash];
        delete facilityDataMap[facilityHash];
        delete staging[facilityHash];
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
            require(facilityInfo[facilitiesSet.at(i)].loanToken != address(debtToken), ErrorsLib.CannotRemove());
        }
        require(debtTokensSet.remove(address(debtToken)), ErrorsLib.NotWhitelisted());
    }

    // ========== STAGING ==========

    /**
     * @notice Stages the lender bids the next `borrow` of this facility may take, replacing any previous staging
     * @param facilityData A registered facility
     * @param fills Bids tried in order; bids that are not usable at borrow time are skipped
     * @param validUntil Last timestamp at which `borrow` may use this staging (inclusive)
     * @dev Callable by the Box allocators only. `borrow` ignores the staging once its stager is no longer an allocator.
     *      Staging is only read by `borrow`, which deletes it; repay, depledge, views and removal never depend on it.
     *      Storage costs gas per byte: stage only the bids needed.
     */
    function stageBorrow(bytes calldata facilityData, OfferFill[] calldata fills, uint256 validUntil) external {
        require(IBox(owner).isAllocator(msg.sender), ErrorsLib.OnlyAllocators());
        require(isFacility(facilityData), ErrorsLib.NotWhitelisted());
        require(validUntil >= block.timestamp, ErrorsLib.InvalidValue());
        staging[keccak256(facilityData)] = Staging(validUntil, msg.sender, abi.encode(fills));
    }

    // ========== ACTIONS ==========

    /// @dev Assume caller did transfer the collateral tokens to this contract before calling
    function pledge(bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external override {
        _checkCollateralAction(facilityData, collateralToken);
        (Market memory market, uint256 collateralIndex, ) = decodeFacilityData(facilityData);

        collateralToken.forceApprove(address(midnight), collateralAmount);
        midnight.supplyCollateral(market, collateralIndex, collateralAmount, address(this));
    }

    /// @dev Withdraws straight to the owner. Midnight reverts above the pledged amount (never delivers less).
    /// @dev Followed by the LTV guard, also during winddown when anyone can trigger it through the Box.
    function depledge(bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external override {
        _checkCollateralAction(facilityData, collateralToken);
        (Market memory market, uint256 collateralIndex, ) = decodeFacilityData(facilityData);

        midnight.withdrawCollateral(market, collateralIndex, collateralAmount, address(this), owner);
        _requireGuard(market, collateralIndex);
    }

    /**
     * @notice Borrows at least `borrowAmount` by selling units into the staged lender bids; proceeds go to the owner
     * @dev Requires a staging of this facility with `block.timestamp <= validUntil`, staged by an address that is still
     *      a Box allocator, and `block.timestamp < maturity`. The staging is deleted whatever the number of fills used.
     * @dev Fills are skipped (not reverted) when: maxUnits is 0, the offer is not a bid of this market, it is outside
     *      its start/expiry window, its price net of the settlement fee is below the `maxBorrowApr` floor (which also
     *      covers ticks above the maximum, tick 0 and fees at or above the price) or it has no capacity left. Each take
     *      runs in a try/catch so that a consumed, cancelled or failing offer does not block the borrow.
     * @dev Reverts if the owner received less than `borrowAmount` (any rounding surplus stays with the owner), and
     *      when the LTV guard is broken afterwards. type(uint256).max is rejected.
     */
    function borrow(bytes calldata facilityData, IERC20 debtToken, uint256 borrowAmount) external override {
        bytes32 facilityHash = _checkDebtAction(facilityData, debtToken);
        require(borrowAmount > 0 && borrowAmount != type(uint256).max, ErrorsLib.InvalidAmount());
        FacilityInfo storage info = facilityInfo[facilityHash];
        require(block.timestamp < info.maturity, ErrorsLib.FacilityMatured());

        Staging storage staged = staging[facilityHash];
        require(block.timestamp <= staged.validUntil && IBox(owner).isAllocator(staged.stager), ErrorsLib.NoValidStaging());
        OfferFill[] memory fills = abi.decode(staged.fills, (OfferFill[]));
        delete staging[facilityHash];

        (Market memory market, uint256 collateralIndex, uint256 maxBorrowApr) = decodeFacilityData(facilityData);
        _sync(info, midnight.debt(info.marketId, address(this)));

        uint256 timeToMaturity = info.maturity - block.timestamp;
        uint256 balanceBefore = debtToken.balanceOf(owner);
        uint256 proceeds = _takeFills(
            fills,
            info,
            borrowAmount,
            MidnightMathLib.minSellerPrice(maxBorrowApr, timeToMaturity),
            midnight.settlementFee(info.marketId, timeToMaturity),
            timeToMaturity
        );
        require(proceeds >= borrowAmount, ErrorsLib.InsufficientLiquidity());
        require(debtToken.balanceOf(owner) - balanceBefore >= borrowAmount, ErrorsLib.InsufficientLiquidity());

        _requireGuard(market, collateralIndex);
    }

    /// @dev Assume caller did transfer the debt tokens to this contract before calling
    /// @dev Repays min(repayAmount, face) at face value: repaying debtBalance closes the debt exactly. Whatever is not
    ///      used is returned to the owner. Never reads the staging and has no guard, so it cannot be blocked by either.
    function repay(bytes calldata facilityData, IERC20 debtToken, uint256 repayAmount) external override {
        bytes32 facilityHash = _checkDebtAction(facilityData, debtToken);
        FacilityInfo storage info = facilityInfo[facilityHash];

        uint256 face = midnight.debt(info.marketId, address(this));
        _sync(info, face);

        uint256 repaid = Math.min(repayAmount, face);
        if (repaid > 0) {
            (Market memory market, , ) = decodeFacilityData(facilityData);
            debtToken.forceApprove(address(midnight), repaid);
            midnight.repay(market, repaid, address(this), address(0), "");

            uint256 tracked = info.trackedUnits;
            if (repaid >= tracked) {
                info.trackedUnits = 0;
                info.discountRate = 0;
            } else {
                info.discountRate = info.discountRate.mulDiv(tracked - repaid, tracked);
                info.trackedUnits = tracked - repaid;
            }
        }

        if (repayAmount > repaid) {
            debtToken.safeTransfer(owner, repayAmount - repaid);
        }
    }

    // ========== POSITION ==========

    /// @notice Face debt over collateral value (1e18 scale, rounded up) at the market's own Midnight oracle
    /// @dev 0 without debt (the oracle is not called), type(uint256).max with debt and a zero collateral value, and 0
    ///      for unregistered facilityData.
    function ltv(bytes calldata facilityData) external view override returns (uint256) {
        if (!isFacility(facilityData)) return 0;
        (Market memory market, uint256 collateralIndex, ) = decodeFacilityData(facilityData);
        return _ltv(market, collateralIndex);
    }

    /// @dev Face value owed at maturity (the exact closing amount). 0 for tokens the facility does not borrow and for
    ///      unregistered or malformed facilityData (never reverts).
    function debtBalance(bytes calldata facilityData, IERC20 debtToken) external view override returns (uint256) {
        if (!isFacility(facilityData)) return 0;
        FacilityInfo storage info = facilityInfo[keccak256(facilityData)];
        if (info.loanToken != address(debtToken)) return 0;
        return midnight.debt(info.marketId, address(this));
    }

    /// @dev 0 for tokens the facility does not use as collateral and for unregistered or malformed facilityData
    function collateralBalance(bytes calldata facilityData, IERC20 collateralToken) external view override returns (uint256) {
        if (!isFacility(facilityData)) return 0;
        FacilityInfo storage info = facilityInfo[keccak256(facilityData)];
        if (info.collateralToken != address(collateralToken)) return 0;
        return midnight.collateral(info.marketId, address(this), info.collateralIndex);
    }

    /// @notice Value of the positions in the Box asset, using the Box oracles
    /// @dev Per facility: collateral (rounded down) minus the accreted debt value (rounded up), floored at 0. The Box
    ///      asset is valued 1:1. Only Midnight's balance getters are used (never its oracles or health check). Tokens
    ///      held idle by this contract are not counted.
    function nav(IOracleCallback oraclesProvider) public view override returns (uint256 nav_) {
        address asset = oraclesProvider.asset();
        uint256 length = facilitiesSet.length();
        for (uint256 i = 0; i < length; i++) {
            FacilityInfo storage info = facilityInfo[facilitiesSet.at(i)];
            uint256 collateral = midnight.collateral(info.marketId, address(this), info.collateralIndex);
            if (collateral == 0) continue; // No recourse beyond the collateral

            uint256 value = _valueOf(oraclesProvider, asset, info.collateralToken, collateral, Math.Rounding.Floor);
            uint256 debtValue_ = _debtValue(info, midnight.debt(info.marketId, address(this)));
            if (debtValue_ > 0) {
                uint256 debtInAsset = _valueOf(oraclesProvider, asset, info.loanToken, debtValue_, Math.Rounding.Ceil);
                value = value > debtInAsset ? value - debtInAsset : 0;
            }
            nav_ += value;
        }
    }

    // ========== VIEWS ==========

    /// @notice Accreted debt of a facility in loan-token units: from the proceeds at borrow time to face at maturity
    /// @dev Face value at and after maturity; 0 for unregistered facilityData.
    function debtValue(bytes calldata facilityData) external view returns (uint256) {
        if (!isFacility(facilityData)) return 0;
        FacilityInfo storage info = facilityInfo[keccak256(facilityData)];
        return _debtValue(info, midnight.debt(info.marketId, address(this)));
    }

    /// @notice Accretion state of a facility (zero for unregistered facilityData)
    function accretionState(bytes calldata facilityData) external view returns (uint256 trackedUnits, uint256 discountRate) {
        FacilityInfo storage info = facilityInfo[keccak256(facilityData)];
        return (info.trackedUnits, info.discountRate);
    }

    /// @notice Staged fills of a facility; validUntil is 0 when nothing is staged
    /// @dev `borrow` also ignores the staging when its stager is no longer an allocator
    function stagedBorrow(bytes calldata facilityData) external view returns (uint256 validUntil, OfferFill[] memory fills) {
        Staging storage staged = staging[keccak256(facilityData)];
        validUntil = staged.validUntil;
        if (validUntil != 0) fills = abi.decode(staged.fills, (OfferFill[]));
    }

    /// @notice Maturity of the facility market
    function maturity(bytes calldata facilityData) external pure returns (uint256) {
        (Market memory market, , ) = decodeFacilityData(facilityData);
        return market.maturity;
    }

    /// @notice True from the maturity timestamp on (borrowing is closed; Midnight allows liquidations from maturity + 1)
    function isMatured(bytes calldata facilityData) external view returns (bool) {
        (Market memory market, , ) = decodeFacilityData(facilityData);
        return block.timestamp >= market.maturity;
    }

    /// @notice Midnight market id of the facility market
    function marketId(bytes calldata facilityData) external pure returns (bytes32) {
        (Market memory market, , ) = decodeFacilityData(facilityData);
        return IdLib.toId(market);
    }

    /// @dev Reverts unless facilityData is the canonical encoding of (Market, uint256, uint256)
    function decodeFacilityData(
        bytes memory facilityData
    ) public pure returns (Market memory market, uint256 collateralIndex, uint256 maxBorrowApr) {
        (market, collateralIndex, maxBorrowApr) = abi.decode(facilityData, (Market, uint256, uint256));
        require(keccak256(abi.encode(market, collateralIndex, maxBorrowApr)) == keccak256(facilityData), ErrorsLib.InvalidFacilityData());
    }

    function encodeFacilityData(Market memory market, uint256 collateralIndex, uint256 maxBorrowApr) external pure returns (bytes memory) {
        return abi.encode(market, collateralIndex, maxBorrowApr);
    }

    // ========== INTERNAL ==========

    function _checkCollateralAction(bytes calldata facilityData, IERC20 collateralToken) internal view {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), ErrorsLib.NotWhitelisted());
        require(facilityInfo[keccak256(facilityData)].collateralToken == address(collateralToken), ErrorsLib.TokenNotWhitelisted());
    }

    function _checkDebtAction(bytes calldata facilityData, IERC20 debtToken) internal view returns (bytes32 facilityHash) {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), ErrorsLib.NotWhitelisted());
        facilityHash = keccak256(facilityData);
        require(facilityInfo[facilityHash].loanToken == address(debtToken), ErrorsLib.TokenNotWhitelisted());
    }

    /// @dev Sells units into `fills` until `target` proceeds are reached. Nothing before `take` can revert on offer data.
    /// @dev The accretion state is updated after each take rather than once at the end: maker callbacks of later fills
    ///      can read nav, which must then count the settled takes (whose proceeds are already at the owner).
    function _takeFills(
        OfferFill[] memory fills,
        FacilityInfo storage info,
        uint256 target,
        uint256 minPrice,
        uint256 fee,
        uint256 timeToMaturity
    ) internal returns (uint256 proceeds) {
        bytes32 id = info.marketId;
        for (uint256 i = 0; i < fills.length && proceeds < target; i++) {
            Offer memory offer = fills[i].offer;
            if (fills[i].maxUnits == 0 || !offer.buy || offer.maker == address(this)) continue;
            if (block.timestamp < offer.start || block.timestamp > offer.expiry) continue;
            if (IdLib.toId(offer.market) != id) continue;

            // 0 for a tick above the maximum, tick 0 or a fee at or above the price
            uint256 price = MidnightMathLib.sellerPrice(offer.tick, fee);
            if (price == 0 || price < minPrice) continue;

            uint256 units = MidnightMathLib.unitsForSellerAssets(target - proceeds, price);
            uint256 capacity = MidnightMathLib.consumableUnitsOfBuyOffer(
                offer.maxUnits,
                offer.maxAssets,
                midnight.consumed(offer.maker, offer.group),
                price + fee
            );
            units = Math.min(units, Math.min(capacity, fills[i].maxUnits));
            if (units == 0) continue;

            try midnight.take(offer, fills[i].ratifierData, units, address(this), owner, address(0), "") returns (
                uint256,
                uint256 sellerAssets
            ) {
                proceeds += sellerAssets;
                info.trackedUnits += units;
                if (units > sellerAssets) info.discountRate += (units - sellerAssets).mulDiv(RATE_SCALE, timeToMaturity);
            } catch {
                continue;
            }
        }
    }

    /// @dev Midnight's debt only drops without the module (liquidation, bad debt): scale the discount down with it
    function _sync(FacilityInfo storage info, uint256 face) internal {
        uint256 tracked = info.trackedUnits;
        if (face < tracked) {
            info.discountRate = info.discountRate.mulDiv(face, tracked);
            info.trackedUnits = face;
        }
    }

    /// @dev face - unearned discount, the discount rounded down (debt rounded up). Never above face; face at and after
    ///      maturity. When an external event reduced the face since the last sync, the discount rate is scaled by
    ///      face / tracked exactly as `_sync` will store it, so that the next sync does not move the value.
    /// @dev Midnight's face only exceeds the tracked units while a take is in progress: the maker callback runs after
    ///      the debt grew and before the proceeds reach the owner. Counting at most the tracked units keeps nav read from
    ///      that callback equal to nav before the take, instead of counting the new debt without its proceeds.
    function _debtValue(FacilityInfo storage info, uint256 face) internal view returns (uint256) {
        uint256 tracked = info.trackedUnits;
        if (face > tracked) face = tracked;
        if (face == 0 || block.timestamp >= info.maturity) return face;
        uint256 rate = info.discountRate;
        if (face < tracked) rate = rate.mulDiv(face, tracked);
        uint256 discount = rate.mulDiv(info.maturity - block.timestamp, RATE_SCALE);
        return discount < face ? face - discount : 0;
    }

    function _ltv(Market memory market, uint256 collateralIndex) internal view returns (uint256) {
        bytes32 id = IdLib.toId(market);
        uint256 face = midnight.debt(id, address(this));
        if (face == 0) return 0;
        uint256 collateral = midnight.collateral(id, address(this), collateralIndex);
        if (collateral == 0) return type(uint256).max;
        CollateralParams memory params = market.collateralParams[collateralIndex];
        uint256 collateralValue = collateral.mulDiv(IOracle(params.oracle).price(), ORACLE_PRECISION);
        if (collateralValue == 0) return type(uint256).max;
        return face.mulDiv(WAD, collateralValue, Math.Rounding.Ceil);
    }

    function _requireGuard(Market memory market, uint256 collateralIndex) internal view {
        uint256 maxLtv = (market.collateralParams[collateralIndex].lltv * lltvCap) / WAD;
        require(_ltv(market, collateralIndex) <= maxLtv, ErrorsLib.ExcessiveLTV());
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
            if (info.loanToken == address(debtToken)) balance += midnight.debt(info.marketId, address(this));
        }
    }

    /// @dev Returns 0 for tokens no facility uses as collateral
    function _collateralBalance(IERC20 collateralToken) internal view override returns (uint256 balance) {
        uint256 length = facilitiesSet.length();
        for (uint256 i = 0; i < length; i++) {
            FacilityInfo storage info = facilityInfo[facilitiesSet.at(i)];
            if (info.collateralToken == address(collateralToken)) {
                balance += midnight.collateral(info.marketId, address(this), info.collateralIndex);
            }
        }
    }

    function _isFacilityUsed(bytes calldata facilityData) internal view override returns (bool) {
        FacilityInfo storage info = facilityInfo[keccak256(facilityData)];
        return
            midnight.debt(info.marketId, address(this)) > 0 || midnight.collateral(info.marketId, address(this), info.collateralIndex) > 0;
    }
}
