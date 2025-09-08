// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.13;

import {IMorpho, Id, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import "@morpho-blue/libraries/ConstantsLib.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoLib} from "@morpho-blue/libraries/periphery/MorphoLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MathLib} from "./../lib/morpho-blue/src/libraries/MathLib.sol";
import {IFunding} from "./interfaces/IFunding.sol";
import {ErrorsLib} from "./lib/ErrorsLib.sol";

contract FundingMorpho is IFunding {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;
    using MathLib for uint256;

    address public immutable owner;
    IMorpho public immutable morpho;

    bytes[] public facilities;
    IERC20[] public collateralTokens;
    IERC20[] public debtTokens;

    // ========== INITIALIZATION ==========

    constructor(address owner_, address morpho_) {
        owner = owner_;
        morpho = IMorpho(morpho_);
    }

    // ========== IFunding implementations ==========

    // ========== ADMIN ==========

    function addFacility(bytes calldata facilityData) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(!isFacility(facilityData), ErrorsLib.AlreadyWhitelisted());

        facilities.push(facilityData);
    }

    function removeFacility(bytes calldata facilityData) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(!_isFacilityUsed(facilityData), ErrorsLib.CannotRemove());

        uint256 index = _findFacilityIndex(facilityData);
        facilities[index] = facilities[facilities.length - 1];
        facilities.pop();
    }

    function isFacility(bytes calldata facilityData) public view override returns (bool) {
        for (uint i = 0; i < facilities.length; i++) {
            if (keccak256(facilities[i]) == keccak256(facilityData)) {
                return true;
            }
        }
        return false;
    }

    function facilitiesLength() external view returns (uint256) {
        return facilities.length;
    }

    function addCollateralToken(IERC20 collateralToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(!isCollateralToken(collateralToken), ErrorsLib.AlreadyWhitelisted());

        collateralTokens.push(collateralToken);
    }

    function removeCollateralToken(IERC20 collateralToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(_collateralBalance(collateralToken) == 0, ErrorsLib.CannotRemove());

        uint256 index = _findCollateralTokenIndex(collateralToken);
        collateralTokens[index] = collateralTokens[collateralTokens.length - 1];
        collateralTokens.pop();
    }

    function isCollateralToken(IERC20 collateralToken) public view override returns (bool) {
        for (uint i = 0; i < collateralTokens.length; i++) {
            if (address(collateralTokens[i]) == address(collateralToken)) {
                return true;
            }
        }
        return false;
    }

    function collateralTokensLength() external view returns (uint256) {
        return collateralTokens.length;
    }

    function addDebtToken(IERC20 debtToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(!isDebtToken(debtToken), ErrorsLib.AlreadyWhitelisted());

        debtTokens.push(debtToken);
    }

    function removeDebtToken(IERC20 debtToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(_debtBalance(debtToken) == 0, ErrorsLib.CannotRemove());

        uint256 index = _findDebtTokenIndex(debtToken);
        debtTokens[index] = debtTokens[debtTokens.length - 1];
        debtTokens.pop();
    }

    function isDebtToken(IERC20 debtToken) public view override returns (bool) {
        for (uint i = 0; i < debtTokens.length; i++) {
            if (address(debtTokens[i]) == address(debtToken)) {
                return true;
            }
        }
        return false;
    }

    function debtTokensLength() external view returns (uint256) {
        return debtTokens.length;
    }

    // ========== ACTIONS ==========

    /// @dev Assume caller did transfer the collateral tokens to this contract before calling
    function pledge(bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), "Invalid facility");
        require(isCollateralToken(collateralToken), "Invalid collateral token");

        MarketParams memory market = decodeFacilityData(facilityData);
        collateralToken.forceApprove(address(morpho), collateralAmount);
        morpho.supplyCollateral(market, collateralAmount, address(this), "");
    }

    /// @dev We don't check if valid facility/collateral, allowing donations
    function depledge(bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());

        MarketParams memory market = decodeFacilityData(facilityData);
        morpho.withdrawCollateral(market, collateralAmount, address(this), address(this));
        collateralToken.safeTransfer(owner, collateralAmount);
    }

    function borrow(bytes calldata facilityData, IERC20 debtToken, uint256 borrowAmount) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), "Invalid facility");
        require(isDebtToken(debtToken), "Invalid debt token");

        MarketParams memory market = decodeFacilityData(facilityData);
        morpho.borrow(market, borrowAmount, 0, address(this), address(this));
        debtToken.safeTransfer(owner, borrowAmount);
    }

    /// @dev Assume caller did transfer the debt tokens to this contract before calling
    function repay(bytes calldata facilityData, IERC20 debtToken, uint256 repayAmount) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), "Invalid facility");
        require(isDebtToken(debtToken), "Invalid debt token");

        MarketParams memory market = decodeFacilityData(facilityData);

        uint256 debtAmount = morpho.expectedBorrowAssets(market, address(this));

        if (repayAmount == type(uint256).max) {
            repayAmount = debtAmount;
        }

        IERC20(market.loanToken).forceApprove(address(morpho), repayAmount);

        // If the amount repaid is all the debt, we convert to all shares
        // amount repaid would internally get translated to more shares that there is to repaid
        if (repayAmount == debtAmount) {
            morpho.repay(market, 0, morpho.borrowShares(market.id(), address(this)), address(this), "");
        } else {
            morpho.repay(market, repayAmount, 0, address(this), "");
        }
    }

    // ========== POSITION ==========

    function ltv(bytes calldata facilityData) external view override returns (uint256) {
        MarketParams memory market = decodeFacilityData(facilityData);
        Id marketId = market.id();
        uint256 borrowedAssets = morpho.expectedBorrowAssets(market, address(this));
        uint256 collateralAmount = morpho.collateral(marketId, address(this));
        uint256 collateralPrice = (market.oracle == address(0)) ? 0 : IOracle(market.oracle).price();
        uint256 collateralValue = collateralAmount.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);
        return (collateralValue == 0) ? 0 : borrowedAssets.wDivUp(collateralValue);
    }

    function debtBalance(bytes calldata facilityData, IERC20 debtToken) external view override returns (uint256) {
        MarketParams memory market = decodeFacilityData(facilityData);
        require(address(debtToken) == market.loanToken, "FundingModuleMorpho: Wrong debt token");
        return morpho.expectedBorrowAssets(market, address(this));
    }

    function collateralBalance(bytes calldata facilityData, IERC20 collateralToken) external view override returns (uint256) {
        MarketParams memory market = decodeFacilityData(facilityData);
        require(address(collateralToken) == market.collateralToken, "FundingModuleMorpho: Wrong collateral token");
        return morpho.collateral(market.id(), address(this));
    }

    function debtBalance(IERC20 debtToken) external view override returns (uint256) {
        return _debtBalance(debtToken);
    }

    function collateralBalance(IERC20 collateralToken) external view override returns (uint256) {
        return _collateralBalance(collateralToken);
    }

    // ========== Other exposed view functions ==========

    function decodeFacilityData(bytes memory facilityData) public pure returns (MarketParams memory market) {
        (MarketParams memory marketParams) = abi.decode(facilityData, (MarketParams));
        return (marketParams);
    }

    function encodeFacilityData(MarketParams memory market) public pure returns (bytes memory) {
        return abi.encode(market);
    }

    // ========== Internal functions ==========
    function _debtBalance(IERC20 debtToken) internal view returns (uint256 balance) {
        for (uint256 i = 0; i < facilities.length; i++) {
            MarketParams memory market = decodeFacilityData(facilities[i]);
            if (address(debtToken) == market.loanToken) {
                balance += morpho.expectedBorrowAssets(market, address(this));
            }
        }
    }

    function _collateralBalance(IERC20 collateralToken) internal view returns (uint256 balance) {
        for (uint256 i = 0; i < facilities.length; i++) {
            MarketParams memory market = decodeFacilityData(facilities[i]);
            if (address(collateralToken) == market.collateralToken) {
                balance += morpho.collateral(market.id(), address(this));
            }
        }
    }

    function _isFacilityUsed(bytes calldata facilityData) internal view returns (bool) {
        MarketParams memory market = decodeFacilityData(facilityData);
        Position memory position = morpho.position(market.id(), address(this));
        return position.collateral > 0 || position.borrowShares > 0;
    }

    function _findFacilityIndex(bytes calldata facilityData) internal view returns (uint256) {
        for (uint256 i = 0; i < facilities.length; i++) {
            if (keccak256(facilities[i]) == keccak256(facilityData)) {
                return i;
            }
        }
        revert ErrorsLib.NotWhitelisted();
    }

    function _findCollateralTokenIndex(IERC20 collateralToken) internal view returns (uint256) {
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            if (collateralTokens[i] == collateralToken) {
                return i;
            }
        }
        revert ErrorsLib.NotWhitelisted();
    }

    function _findDebtTokenIndex(IERC20 debtToken) internal view returns (uint256) {
        for (uint256 i = 0; i < debtTokens.length; i++) {
            if (debtTokens[i] == debtToken) {
                return i;
            }
        }
        revert ErrorsLib.NotWhitelisted();
    }
}
