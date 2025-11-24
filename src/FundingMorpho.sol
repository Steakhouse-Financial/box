// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Steakhouse Financial
pragma solidity 0.8.28;

import {IMorpho, Id, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import "@morpho-blue/libraries/ConstantsLib.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoLib} from "@morpho-blue/libraries/periphery/MorphoLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {MathLib} from "./../lib/morpho-blue/src/libraries/MathLib.sol";
import {IFunding, IOracleCallback} from "./interfaces/IFunding.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

contract FundingMorpho is IFunding {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;
    using MathLib for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    address public immutable owner;
    IMorpho public immutable morpho;
    uint256 public immutable lltvCap; // Maximum LTV/LTTV ration in 18 decimals, e.g. 80e16 for 80%

    EnumerableSet.Bytes32Set internal facilitiesSet;
    mapping(bytes32 => bytes) public facilityDataMap; // hash => facility data
    EnumerableSet.AddressSet internal collateralTokensSet;
    EnumerableSet.AddressSet internal debtTokensSet;

    // ========== INITIALIZATION ==========

    /**
     * @notice Allows the contract to receive native currency
     * @dev Required for skimming native currency back to the Box
     */
    receive() external payable {}

    /**
     * @notice Fallback function to receive native currency
     * @dev Required for skimming native currency back to the Box
     */
    fallback() external payable {}

    constructor(address owner_, address morpho_, uint256 lltvCap_) {
        require(owner_ != address(0), ErrorsLib.InvalidAddress());
        require(morpho_ != address(0), ErrorsLib.InvalidAddress());
        require(lltvCap_ <= 100e16, ErrorsLib.InvalidValue()); // Max 100%
        require(lltvCap_ > 0, ErrorsLib.InvalidValue()); // Min above 0%

        owner = owner_;
        morpho = IMorpho(morpho_);
        lltvCap = lltvCap_;
    }

    // ========== IFunding implementations ==========

    // ========== ADMIN ==========

    /// @dev Before adding a facility, you need to add the underlying tokens as collateral/debt tokens
    function addFacility(bytes calldata facilityData) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());

        MarketParams memory market = decodeFacilityData(facilityData);
        require(isCollateralToken(IERC20(market.collateralToken)), ErrorsLib.TokenNotWhitelisted());
        require(isDebtToken(IERC20(market.loanToken)), ErrorsLib.TokenNotWhitelisted());

        bytes32 facilityHash = keccak256(facilityData);
        require(facilitiesSet.add(facilityHash), ErrorsLib.AlreadyWhitelisted());
        facilityDataMap[facilityHash] = facilityData;
    }

    function removeFacility(bytes calldata facilityData) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(!_isFacilityUsed(facilityData), ErrorsLib.CannotRemove());

        bytes32 facilityHash = keccak256(facilityData);
        require(facilitiesSet.remove(facilityHash), ErrorsLib.NotWhitelisted());
        delete facilityDataMap[facilityHash];
    }

    function isFacility(bytes calldata facilityData) public view override returns (bool) {
        bytes32 facilityHash = keccak256(facilityData);
        return facilitiesSet.contains(facilityHash);
    }

    function facilitiesLength() external view returns (uint256) {
        return facilitiesSet.length();
    }

    function facilities(uint256 index) external view returns (bytes memory) {
        bytes32 facilityHash = facilitiesSet.at(index);
        return facilityDataMap[facilityHash];
    }

    function addCollateralToken(IERC20 collateralToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(collateralTokensSet.add(address(collateralToken)), ErrorsLib.AlreadyWhitelisted());
    }

    /// @dev Before being able to remove a collateral, no facility should reference it and the balance should be 0
    function removeCollateralToken(IERC20 collateralToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(_collateralBalance(collateralToken) == 0, ErrorsLib.CannotRemove());

        uint256 length = facilitiesSet.length();
        for (uint i = 0; i < length; i++) {
            bytes32 facilityHash = facilitiesSet.at(i);
            MarketParams memory market = decodeFacilityData(facilityDataMap[facilityHash]);
            require(address(market.collateralToken) != address(collateralToken), ErrorsLib.CannotRemove());
        }

        require(collateralTokensSet.remove(address(collateralToken)), ErrorsLib.NotWhitelisted());
    }

    function isCollateralToken(IERC20 collateralToken) public view override returns (bool) {
        return collateralTokensSet.contains(address(collateralToken));
    }

    function collateralTokensLength() external view returns (uint256) {
        return collateralTokensSet.length();
    }

    function collateralTokens(uint256 index) external view returns (IERC20) {
        return IERC20(collateralTokensSet.at(index));
    }

    function addDebtToken(IERC20 debtToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(debtTokensSet.add(address(debtToken)), ErrorsLib.AlreadyWhitelisted());
    }

    /// @dev Before being able to remove a debt, no facility should reference it and the balance should be 0
    function removeDebtToken(IERC20 debtToken) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(_debtBalance(debtToken) == 0, ErrorsLib.CannotRemove());

        uint256 length = facilitiesSet.length();
        for (uint i = 0; i < length; i++) {
            bytes32 facilityHash = facilitiesSet.at(i);
            MarketParams memory market = decodeFacilityData(facilityDataMap[facilityHash]);
            require(address(market.loanToken) != address(debtToken), ErrorsLib.CannotRemove());
        }

        require(debtTokensSet.remove(address(debtToken)), ErrorsLib.NotWhitelisted());
    }

    function isDebtToken(IERC20 debtToken) public view override returns (bool) {
        return debtTokensSet.contains(address(debtToken));
    }

    function debtTokensLength() external view returns (uint256) {
        return debtTokensSet.length();
    }

    function debtTokens(uint256 index) external view returns (IERC20) {
        return IERC20(debtTokensSet.at(index));
    }

    // ========== ACTIONS ==========
    function skim(IERC20 token) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());

        uint256 navBefore = nav(IOracleCallback(owner));
        uint256 balance;

        if (address(token) != address(0)) {
            // ERC-20 tokens
            balance = token.balanceOf(address(this));
            require(balance > 0, ErrorsLib.InvalidAmount());
            token.safeTransfer(owner, balance);
        } else {
            // ETH
            balance = address(this).balance;
            require(balance > 0, ErrorsLib.InvalidAmount());
            payable(owner).transfer(balance);
        }

        uint256 navAfter = nav(IOracleCallback(owner));
        require(navBefore == navAfter, ErrorsLib.SkimChangedNav());
    }

    /// @dev Assume caller did transfer the collateral tokens to this contract before calling
    function pledge(bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), ErrorsLib.NotWhitelisted());
        require(isCollateralToken(collateralToken), ErrorsLib.TokenNotWhitelisted());

        MarketParams memory market = decodeFacilityData(facilityData);
        require(address(collateralToken) == market.collateralToken, "FundingModuleMorpho: Wrong collateral token");

        collateralToken.forceApprove(address(morpho), collateralAmount);
        morpho.supplyCollateral(market, collateralAmount, address(this), "");
    }

    function depledge(bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), ErrorsLib.NotWhitelisted());
        require(isCollateralToken(collateralToken), ErrorsLib.TokenNotWhitelisted());

        MarketParams memory market = decodeFacilityData(facilityData);
        require(address(collateralToken) == market.collateralToken, "FundingModuleMorpho: Wrong collateral token");

        morpho.withdrawCollateral(market, collateralAmount, address(this), owner);

        require(ltv(facilityData) <= (market.lltv * lltvCap) / 100e16, ErrorsLib.ExcessiveLTV());
    }

    function borrow(bytes calldata facilityData, IERC20 debtToken, uint256 borrowAmount) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), ErrorsLib.NotWhitelisted());
        require(isDebtToken(debtToken), ErrorsLib.TokenNotWhitelisted());

        MarketParams memory market = decodeFacilityData(facilityData);
        require(address(debtToken) == market.loanToken, "FundingModuleMorpho: Wrong debt token");

        morpho.borrow(market, borrowAmount, 0, address(this), owner);

        require(ltv(facilityData) <= (market.lltv * lltvCap) / 100e16, ErrorsLib.ExcessiveLTV());
    }

    /// @dev Assume caller did transfer the debt tokens to this contract before calling
    function repay(bytes calldata facilityData, IERC20 debtToken, uint256 repayAmount) external override {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(isFacility(facilityData), ErrorsLib.NotWhitelisted());
        require(isDebtToken(debtToken), ErrorsLib.TokenNotWhitelisted());

        MarketParams memory market = decodeFacilityData(facilityData);
        require(address(debtToken) == market.loanToken, "FundingModuleMorpho: Wrong debt token");

        uint256 debtAmount = morpho.expectedBorrowAssets(market, address(this));

        debtToken.forceApprove(address(morpho), repayAmount);

        // If the amount repaid is all the debt, we convert to all shares
        // amount repaid would internally get translated to more shares that there is to repaid
        if (repayAmount == debtAmount) {
            morpho.repay(market, 0, morpho.borrowShares(market.id(), address(this)), address(this), "");
        } else {
            morpho.repay(market, repayAmount, 0, address(this), "");
        }
    }

    /**
     * @notice Executes multiple calls in a single transaction
     * @param data Array of encoded function calls
     * @dev Allows EOAs to execute multiple operations atomically
     */
    function multicall(bytes[] calldata data) external {
        uint256 length = data.length;
        for (uint256 i = 0; i < length; i++) {
            (bool success, bytes memory returnData) = address(this).delegatecall(data[i]);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(32, returnData), mload(returnData))
                }
            }
        }
    }

    // ========== POSITION ==========

    /// @dev returns 0 if there is no collateral
    function ltv(bytes calldata facilityData) public view override returns (uint256) {
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

    /// @dev The NAV for a given lending market can be negative but there is no recourse so it can be floored to 0.
    function nav(IOracleCallback oraclesProvider) public view returns (uint256) {
        uint256 nav_ = 0;
        uint256 length = facilitiesSet.length();
        for (uint256 i = 0; i < length; i++) {
            uint256 facilityNav = 0;
            bytes32 facilityHash = facilitiesSet.at(i);
            MarketParams memory market = decodeFacilityData(facilityDataMap[facilityHash]);
            uint256 collateralBalance_ = morpho.collateral(market.id(), address(this));

            if (collateralBalance_ == 0) continue; // No debt if no collateral

            if (market.collateralToken == oraclesProvider.asset()) {
                // RIs are considered to have a price of ORACLE_PRECISION
                facilityNav += collateralBalance_;
            } else {
                IOracle oracle = oraclesProvider.oracles(IERC20(market.collateralToken));
                if (address(oracle) != address(0)) {
                    facilityNav += collateralBalance_.mulDivDown(oracle.price(), ORACLE_PRICE_SCALE);
                }
            }

            uint256 debtBalance_ = morpho.expectedBorrowAssets(market, address(this));

            if (market.loanToken == oraclesProvider.asset()) {
                facilityNav = (facilityNav > debtBalance_) ? facilityNav - debtBalance_ : 0;
            } else {
                IOracle oracle = oraclesProvider.oracles(IERC20(market.loanToken));
                if (address(oracle) != address(0)) {
                    uint256 value = debtBalance_.mulDivDown(oracle.price(), ORACLE_PRICE_SCALE);
                    facilityNav = (facilityNav > value) ? facilityNav - value : 0;
                }
            }

            nav_ += facilityNav;
        }
        return nav_;
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
        uint256 length = facilitiesSet.length();
        for (uint256 i = 0; i < length; i++) {
            bytes32 facilityHash = facilitiesSet.at(i);
            MarketParams memory market = decodeFacilityData(facilityDataMap[facilityHash]);
            if (address(debtToken) == market.loanToken) {
                balance += morpho.expectedBorrowAssets(market, address(this));
            }
        }
    }

    function _collateralBalance(IERC20 collateralToken) internal view returns (uint256 balance) {
        uint256 length = facilitiesSet.length();
        for (uint256 i = 0; i < length; i++) {
            bytes32 facilityHash = facilitiesSet.at(i);
            MarketParams memory market = decodeFacilityData(facilityDataMap[facilityHash]);
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

    // ========== ENUMERABLE SET GETTERS ==========

    /// @notice Get all facility hashes as an array
    function facilitiesArray() external view returns (bytes32[] memory) {
        uint256 length = facilitiesSet.length();
        bytes32[] memory allFacilities = new bytes32[](length);
        for (uint256 i = 0; i < length; i++) {
            allFacilities[i] = facilitiesSet.at(i);
        }
        return allFacilities;
    }

    /// @notice Get all collateral token addresses as an array
    function collateralTokensArray() external view returns (address[] memory) {
        uint256 length = collateralTokensSet.length();
        address[] memory allTokens = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            allTokens[i] = collateralTokensSet.at(i);
        }
        return allTokens;
    }

    /// @notice Get all debt token addresses as an array
    function debtTokensArray() external view returns (address[] memory) {
        uint256 length = debtTokensSet.length();
        address[] memory allTokens = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            allTokens[i] = debtTokensSet.at(i);
        }
        return allTokens;
    }
}
