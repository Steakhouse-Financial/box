// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.13;

import {IFunding} from "./interfaces/IFunding.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MathLib} from "@morpho-blue/libraries/MathLib.sol";
import {ErrorsLib} from "./lib/ErrorsLib.sol";


interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
    function setUserEMode(uint8 categoryId) external;
    function getUserEMode(address user) external view returns (uint256);
    function getEModeCategoryData(uint8 categoryId)
        external
        view
        returns (
            uint16 ltv,
            uint16 liquidationThreshold,
            uint16 liquidationBonus,
            address priceSource,
            string memory label
        );
    function getReserveEModeCategory(address asset) external view returns (uint256);

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    function getReserveData(address asset)
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        );

    function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);
}

interface IScaledBalanceToken {
    function scaledBalanceOf(address user) external view returns (uint256);
}


contract FundingAave is IFunding {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    uint256 internal constant RAY = 1e27;

    address public immutable owner;
    IPool public immutable pool;
    uint256 public immutable rateMode = 2; // 1 = Stable, 2 = Variable (Aave v3 constant)
    uint8 public immutable eMode; // 0 = no e-mode

    bytes[] public facilities;
    IERC20[] public collateralTokens;
    IERC20[] public debtTokens;

    // interestRateMode: 1 = Stable, 2 = Variable (Aave v3 constant)

    constructor(address _owner, IPool _pool, uint8 _eMode) {
        owner = _owner;
        pool = _pool;
        eMode = _eMode;     
        if (pool.getUserEMode(address(this)) != eMode) {
            pool.setUserEMode(eMode);
        }
    }

    // ========== IFunding implementations ==========

    // ========== ADMIN ==========

    function addFacility(bytes calldata facilityData) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(!isFacility(facilityData), "Facility already added");

        facilities.push(facilityData);
    }

    function removeFacility(bytes calldata facilityData) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(!_isFacilityUsed(facilityData), "Facility is still in use");

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
        require(!isCollateralToken(collateralToken), "Collateral token already added");

        collateralTokens.push(collateralToken);
    }

    function removeCollateralToken(IERC20 collateralToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(_collateralBalance(collateralToken) == 0, "Collateral token is still in use");

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
        require(!isDebtToken(debtToken), "Debt token already added");

        debtTokens.push(debtToken);
    }

    function removeDebtToken(IERC20 debtToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(_debtBalance(debtToken) == 0, "Debt token is still in use");

        uint256 index = _findDebtTokenIndex(debtToken);
        debtTokens[index] = debtTokens[debtTokens.length - 1];
        debtTokens.pop();
    }

    function isDebtToken(IERC20 debtToken) public view override returns (bool)  {
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

    function deposit(bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), "Invalid facility");
        require(isCollateralToken(collateralToken), "Invalid collateral token");
        
        IERC20(collateralToken).forceApprove(address(pool), collateralAmount);
        pool.supply(address(collateralToken), collateralAmount, address(this), 0);
        pool.setUserUseReserveAsCollateral(address(collateralToken), true);
    }

    /// @dev We don't check if valid facility/collateral, allowing donations
    function withdraw(bytes calldata, IERC20 collateralToken, uint256 collateralAmount) external {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());

        pool.withdraw(address(collateralToken), collateralAmount, address(this));
        collateralToken.safeTransfer(owner, collateralAmount);
    }

    function borrow(bytes calldata facilityData, IERC20 debtToken, uint256 borrowAmount) external {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), "Invalid facility");
        require(isDebtToken(debtToken), "Invalid debt token");

        pool.borrow(address(debtToken), borrowAmount, rateMode, 0, address(this));
        debtToken.safeTransfer(owner, borrowAmount);
    }

    function repay(bytes calldata facilityData, IERC20 debtToken, uint256 repayAmount) external {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), "Invalid facility");
        require(isDebtToken(debtToken), "Invalid debt token");

        debtToken.forceApprove(address(pool), repayAmount);
        pool.repay(address(debtToken), repayAmount, rateMode, address(this));
    }

/* TODO: We probably don't need this anymore, type(uint256).max for repayAmount is fixing it, but let me know if we do
    function repayShares(bytes calldata data, uint256 shares) external {
        (IPool pool, address loanAsset, , uint256 rateMode,) = dataToAaveParams(data);

        uint256 repayAmount;
        if (rateMode == 2) {
            // Variable debt: shares are scaledBalance; convert to amount using normalized variable debt index
            uint256 normalizedIndex = pool.getReserveNormalizedVariableDebt(loanAsset); // RAY-scaled
            repayAmount = shares.mulDivUp(normalizedIndex, RAY);
        } else {
            // Stable debt has no shares concept; interpret shares as amount
            repayAmount = shares;
        }

        IERC20(loanAsset).forceApprove(address(pool), repayAmount);
        pool.repay(loanAsset, repayAmount, rateMode, address(this));
    }
*/


    // ========== POSITION ==========

    function ltv(bytes calldata data) external view returns (uint256) {
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            ,
            ,
            ,
            
        ) = pool.getUserAccountData(address(this));

        return totalCollateralBase == 0 ? 0 : totalDebtBase.wDivUp(totalCollateralBase);
    }

    function debtBalance(bytes calldata facilityData, IERC20 debtToken) public view returns (uint256) {
        return _debtBalance(debtToken);
    }
/*
    function debtShares(bytes calldata data, address who) external view returns (uint256) {
        (IPool pool, address loanAsset, , uint256 rateMode,) = dataToAaveParams(data);
        if (rateMode == 2) {
            (,,,,,,,, , , address variableDebtToken,,,,) = pool.getReserveData(loanAsset);
            return IScaledBalanceToken(variableDebtToken).scaledBalanceOf(who);
        } else {
            (,,,,,,,, , address stableDebtToken, ,,,,) = pool.getReserveData(loanAsset);
            return IERC20(stableDebtToken).balanceOf(who);
        }
    }*/

    function collateralBalance(bytes calldata facilityData, IERC20 collateralToken) external view returns (uint256) {
        return _collateralBalance(collateralToken);
    }

    function debtBalance(IERC20 debtToken) external override view returns (uint256) {
        return _debtBalance(debtToken);
    }

    function collateralBalance(IERC20 collateralToken) external override view returns (uint256) {
        return _collateralBalance(collateralToken);
    }
/*
    function dataToAaveParams(bytes calldata data)
        public
        pure
        returns (IPool pool, address loanAsset, address collateralAsset, uint256 interestRateMode, uint8 eMode)
    {
        // Check data length to determine format
        if (data.length == 160) { // 5 * 32 bytes for new format with e-mode
            (address poolAddress, address _loanAsset, address _collateralAsset, uint256 rateMode, uint8 _eMode) =
                abi.decode(data, (address, address, address, uint256, uint8));
            return (IPool(poolAddress), _loanAsset, _collateralAsset, rateMode, _eMode);
        } else { // Old format without e-mode
            (address poolAddress, address _loanAsset, address _collateralAsset, uint256 rateMode) =
                abi.decode(data, (address, address, address, uint256));
            return (IPool(poolAddress), _loanAsset, _collateralAsset, rateMode, 0);
        }
    }

    function aaveParamsToData(IPool pool, address loanAsset, address collateralAsset, uint256 interestRateMode)
        public
        pure
        returns (bytes memory)
    {
        return abi.encode(address(pool), loanAsset, collateralAsset, interestRateMode);
    }
    
    function aaveParamsToDataWithEMode(IPool pool, address loanAsset, address collateralAsset, uint256 interestRateMode, uint8 eMode)
        public
        pure
        returns (bytes memory)
    {
        return abi.encode(address(pool), loanAsset, collateralAsset, interestRateMode, eMode);
    }

    function collateralPositionKey(bytes calldata data) external pure returns (bytes32) {
        (IPool pool, , address collateralAsset, ,) = dataToAaveParams(data);
        return keccak256(abi.encodePacked(address(pool), collateralAsset));
    }

    function debtPositionKey(bytes calldata data) external pure returns (bytes32) {
        (IPool pool, address loanAsset, , ,) = dataToAaveParams(data);
        return keccak256(abi.encodePacked(address(pool), loanAsset));
    }
    */


    function _debtBalance(IERC20 debtToken) internal view returns (uint256 balance) {
        (,,,,,,,, , address stableDebtToken, address variableDebtToken,,,,) = pool.getReserveData(address(debtToken));
        address aDebtToken = rateMode == 2 ? variableDebtToken : stableDebtToken;
        return IERC20(aDebtToken).balanceOf(address(this));
    }

    function _collateralBalance(IERC20 collateralToken) internal view returns (uint256 balance) {
        (,,,,,,,, address aTokenAddress, , ,,,,) = pool.getReserveData(address(collateralToken));
        return IERC20(aTokenAddress).balanceOf(address(this));
    }

    function _isFacilityUsed(bytes calldata facilityData) internal view returns (bool) {
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            ,
            ,
            ,
            
        ) = pool.getUserAccountData(address(this));

        return totalCollateralBase > 0 || totalDebtBase > 0;
    }

    function _findFacilityIndex(bytes calldata facilityData) internal view returns (uint256) {
        for (uint256 i = 0; i < facilities.length; i++) {
            if (keccak256(facilities[i]) == keccak256(facilityData)) {
                return i;
            }
        }
        revert("Facility not found");
    }

    function _findCollateralTokenIndex(IERC20 collateralToken) internal view returns (uint256) {
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            if (collateralTokens[i] == collateralToken) {
                return i;
            }
        }
        revert("Collateral token not found");
    }

    function _findDebtTokenIndex(IERC20 debtToken) internal view returns (uint256) {
        for (uint256 i = 0; i < debtTokens.length; i++) {
            if (debtTokens[i] == debtToken) {
                return i;
            }
        }
        revert("Debt token not found");
    }
}


