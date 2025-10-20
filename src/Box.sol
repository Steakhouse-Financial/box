// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBox} from "./interfaces/IBox.sol";
import {IBoxFlashCallback} from "./interfaces/IBox.sol";
import {IFunding, IOracleCallback} from "./interfaces/IFunding.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import "./libraries/Constants.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";

/**
 * @title Box
 * @notice An ERC4626 vault that holds a base asset, invest in other ERC20 tokens and can borrow/lend via funding modules.
 * @dev Features role-based access control, timelocked governance, and slippage protection
 * @dev Box is not inflation or donation resistant as deposits are strictly controlled via the isFeeder role.
 * @dev Should deposit happen in an automated way (liquidity on a Vault V2) and from multiple feeders, it should be seeded first.
 * @dev Oracles can be manipulated to give an unfair price
 * @dev It is recommanded to create resiliency by using the BoxAdapterCached
 * @dev and/or by using a Vault V2 as a parent vault, which can have a reported price a but lower the NAV price and a setMaxRate()
 * @dev During flash operations there is no totalAssets() calculation possible to avoid NAV based attacks
 * @dev There is no protection against ERC4626 inflation attacks, as deposits are controlled via the isFeeder role.
 * @dev Users shouldn't be able to deposited directly or indirectly to a Box.
 * @dev The Box uses forApprove with 0 value, making it incompatible with BNB chain
 * @dev Token removal can be stopped by sending dust amount of tokens. Can be fixed by deallocating then removing the token atomically
 * @dev The epoch-based slippage protection is relative to Box total assets, but a bad allocator can deposit all parent Vault V2
 * @dev fund into one Box to temporarily inflate its total asset and extract more value than expected.
 */
contract Box is IBox, ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ========== IMMUTABLE STATE ==========

    /// @notice Base currency token (e.g., USDC)
    address public immutable asset;

    /// @notice Duration of slippage tracking epochs
    uint256 public immutable slippageEpochDuration;

    /// @notice Duration over which shutdown slippage tolerance increases
    uint256 public immutable shutdownSlippageDuration;

    /// @notice Duration between shutdown and wind-down phase
    uint256 public immutable shutdownWarmup;

    // ========== MUTABLE STATE ==========

    /// @notice Contract owner with administrative privileges
    address public owner;

    /// @notice Curator who manages tokens and funding modules
    address public curator;

    /// @notice Guardian who can trigger shutdowns and revoke timelocked actions
    address public guardian;

    /// @notice Timestamp when shutdown was triggered, no shutdown if type(uint256).max
    uint256 public shutdownTime;

    /// @notice Recipient of skimmed tokens that aren't part of the vault's strategy
    address public skimRecipient;

    /// @notice Tracks which addresses can execute allocation strategies
    mapping(address => bool) public isAllocator;

    /// @notice Tracks which addresses can deposit into the vault
    mapping(address => bool) public isFeeder;

    /// @notice List of whitelisted investment tokens
    IERC20[] public tokens;

    /// @notice Maps each token to its price oracle
    mapping(IERC20 => IOracle) public oracles;

    /// @notice Maximum allowed slippage per operation and per epoch (scaled by PRECISION = 1e18)
    uint256 public maxSlippage;

    /// @notice Accumulated slippage within current epoch (scaled by PRECISION = 1e18)
    uint256 public accumulatedSlippage;

    /// @notice Timestamp when the current slippage tracking epoch started
    uint256 public slippageEpochStart;

    /// @notice Delay duration for each function selector (in seconds)
    mapping(bytes4 => uint256) public timelock;

    /// @notice Timestamp when specific calldata becomes executable
    mapping(bytes => uint256) public executableAt;

    /// @notice List of whitelisted funding modules for borrowing/lending
    IFunding[] public fundings;

    /// @notice Quick lookup to check if a funding module is whitelisted
    mapping(IFunding => bool) internal fundingMap;

    /// @notice Depth counter for nested NAV-caching operations (flash and swaps)
    uint8 private _navCacheDepth;

    /// @notice Cached NAV value during flash and swap operations to prevent manipulation
    uint256 private _cachedNav;

    // ========== CONSTRUCTOR ==========

    /**
     * @notice Initializes the Box vault
     * @param _asset Base currency token (e.g., USDC)
     * @param _owner Initial owner address
     * @param _curator Initial curator address
     * @param _name ERC20 token name
     * @param _symbol ERC20 token symbol
     * @param _maxSlippage Max allowed slippage for a swap or aggregated over `_slippageEpochDuration`
     * @param _slippageEpochDuration Duration for which slippage is measured
     * @param _shutdownSlippageDuration When shutdown duration for slippage allowance to widen
     * @param _shutdownWarmup Duration between shutdown and wind-down phase
     */
    constructor(
        address _asset,
        address _owner,
        address _curator,
        string memory _name,
        string memory _symbol,
        uint256 _maxSlippage,
        uint256 _slippageEpochDuration,
        uint256 _shutdownSlippageDuration,
        uint256 _shutdownWarmup
    ) ERC20(_name, _symbol) {
        require(_asset != address(0), ErrorsLib.InvalidAddress());
        require(_owner != address(0), ErrorsLib.InvalidAddress());
        require(_maxSlippage <= MAX_SLIPPAGE_LIMIT, ErrorsLib.SlippageTooHigh());
        require(_slippageEpochDuration != 0, ErrorsLib.InvalidValue());
        require(_shutdownSlippageDuration != 0, ErrorsLib.InvalidValue());
        require(_shutdownWarmup <= MAX_SHUTDOWN_WARMUP, ErrorsLib.InvalidValue());

        asset = _asset;
        owner = _owner;
        curator = _curator;
        skimRecipient = address(0);
        maxSlippage = _maxSlippage;
        slippageEpochDuration = _slippageEpochDuration;
        shutdownSlippageDuration = _shutdownSlippageDuration;
        shutdownWarmup = _shutdownWarmup;
        slippageEpochStart = block.timestamp;
        shutdownTime = type(uint256).max; // No shutdown initially

        emit EventsLib.BoxCreated(
            address(this),
            asset,
            owner,
            curator,
            _name,
            _symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration
        );
        emit EventsLib.OwnershipTransferred(address(0), _owner);
        emit EventsLib.CuratorUpdated(address(0), _curator);
    }

    // ========== ERC4626 IMPLEMENTATION ==========

    /// @inheritdoc IERC4626
    /// @notice Returns the total value of assets managed by the vault
    /// @dev Returns cached NAV during flash and swap operations to prevent manipulation
    function totalAssets() public view returns (uint256) {
        return _navCacheDepth > 0 ? _cachedNav : _nav();
    }

    /// @inheritdoc IERC4626
    /// @notice Calculates shares received for a given asset amount
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : assets.mulDiv(supply, totalAssets());
    }

    /// @inheritdoc IERC4626
    /// @notice Calculates assets received for redeeming shares
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : shares.mulDiv(totalAssets(), supply);
    }

    /// @inheritdoc IERC4626
    /// @notice Maximum assets that can be deposited
    function maxDeposit(address) external view returns (uint256) {
        return (isShutdown()) ? 0 : type(uint256).max;
    }

    /// @inheritdoc IERC4626
    /// @notice Simulates share minting for a deposit
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    /// @inheritdoc IERC4626
    /// @notice Deposits base asset and mints shares to receiver
    /// @dev Only authorized feeders can deposit
    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256 shares) {
        require(isFeeder[msg.sender], ErrorsLib.OnlyFeeders());
        require(!isShutdown(), ErrorsLib.CannotDuringShutdown());
        require(receiver != address(0), ErrorsLib.InvalidAddress());

        shares = previewDeposit(assets);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IERC4626
    /// @notice Maximum shares that can be minted
    function maxMint(address) external view returns (uint256) {
        return (isShutdown()) ? 0 : type(uint256).max;
    }

    /// @inheritdoc IERC4626
    /// @notice Simulates assets needed to mint shares
    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : shares.mulDiv(totalAssets(), supply, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    /// @notice Mints exact shares by depositing necessary base asset
    /// @dev Only authorized feeders can mint
    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        require(isFeeder[msg.sender], ErrorsLib.OnlyFeeders());
        require(!isShutdown(), ErrorsLib.CannotDuringShutdown());
        require(receiver != address(0), ErrorsLib.InvalidAddress());

        assets = previewMint(shares);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IERC4626
    /// @notice Maximum assets owner can withdraw
    function maxWithdraw(address owner_) external view returns (uint256) {
        uint256 ownerAssets = convertToAssets(balanceOf(owner_));
        uint256 availableLiquidity = IERC20(asset).balanceOf(address(this));
        return ownerAssets < availableLiquidity ? ownerAssets : availableLiquidity;
    }

    /// @inheritdoc IERC4626
    /// @notice Simulates shares burned for withdrawing assets
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : assets.mulDiv(supply, totalAssets(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    /// @notice Withdraws base asset by burning owner's shares
    /// @dev Requires sufficient shares and vault liquidity
    function withdraw(uint256 assets, address receiver, address owner_) public nonReentrant returns (uint256 shares) {
        if (receiver == address(0)) revert ErrorsLib.InvalidAddress();

        shares = previewWithdraw(assets);

        if (msg.sender != owner_) {
            uint256 allowed = allowance(owner_, msg.sender);
            if (allowed < shares) revert ErrorsLib.InsufficientAllowance();
            if (allowed != type(uint256).max) {
                _approve(owner_, msg.sender, allowed - shares);
            }
        }

        if (balanceOf(owner_) < shares) revert ErrorsLib.InsufficientShares();
        if (IERC20(asset).balanceOf(address(this)) < assets) revert ErrorsLib.InsufficientLiquidity();

        _burn(owner_, shares);
        IERC20(asset).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @inheritdoc IERC4626
    /// @notice Maximum shares owner can redeem
    function maxRedeem(address owner_) external view returns (uint256) {
        uint256 ownerShares = balanceOf(owner_);
        uint256 availableLiquidity = IERC20(asset).balanceOf(address(this));
        uint256 liquidityShares = convertToShares(availableLiquidity);
        return ownerShares < liquidityShares ? ownerShares : liquidityShares;
    }

    /// @inheritdoc IERC4626
    /// @notice Simulates assets received for redeeming shares
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /// @inheritdoc IERC4626
    /// @notice Redeems shares for underlying base asset
    /// @dev Burns shares and transfers base asset to receiver
    function redeem(uint256 shares, address receiver, address owner_) external nonReentrant returns (uint256 assets) {
        if (receiver == address(0)) revert ErrorsLib.InvalidAddress();

        if (msg.sender != owner_) {
            uint256 allowed = allowance(owner_, msg.sender);
            if (allowed < shares) revert ErrorsLib.InsufficientAllowance();
            if (allowed != type(uint256).max) {
                _approve(owner_, msg.sender, allowed - shares);
            }
        }

        if (balanceOf(owner_) < shares) revert ErrorsLib.InsufficientShares();

        assets = previewRedeem(shares);
        if (IERC20(asset).balanceOf(address(this)) < assets) revert ErrorsLib.InsufficientLiquidity();

        _burn(owner_, shares);
        IERC20(asset).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    // ========== SWAP FUNCTIONS ==========

    /**
     * @notice Transfers accidentally sent tokens to the skim recipient
     * @param token Token to skim from the contract
     * @dev Cannot skim the base asset or whitelisted investment tokens
     */
    function skim(IERC20 token) external nonReentrant {
        require(msg.sender == skimRecipient, ErrorsLib.OnlySkimRecipient());
        require(skimRecipient != address(0), ErrorsLib.InvalidAddress());

        if (address(token) == address(0)) {
            uint256 amount = address(this).balance;
            require(amount > 0, ErrorsLib.CannotSkimZero());
            payable(skimRecipient).transfer(amount);
            emit EventsLib.Skim(token, skimRecipient, amount);
            return;
        }

        require(address(token) != address(asset), ErrorsLib.CannotSkimAsset());
        require(!isToken(token), ErrorsLib.CannotSkimToken());

        uint256 amount = token.balanceOf(address(this));
        require(amount > 0, ErrorsLib.CannotSkimZero());

        token.safeTransfer(skimRecipient, amount);
        emit EventsLib.Skim(token, skimRecipient, amount);
    }

    /**
     * @notice Swaps base asset for investment tokens
     * @param token Target token to acquire
     * @param assetsAmount Maximum amount of base asset to spend
     * @param swapper Contract that will execute the swap
     * @param data Custom data for the swapper implementation
     * @return expected Expected amount of target token based on oracle price
     * @return received Actual amount of target token received from the allocation
     * @dev Enforces slippage protection based on oracle prices
     * @dev During wind-down, slippage tolerance increases over time
     */
    function allocate(
        IERC20 token,
        uint256 assetsAmount,
        ISwapper swapper,
        bytes calldata data
    ) public nonReentrant returns (uint256 expected, uint256 received) {
        _startNavCache();

        bool winddown = isWinddown();
        require((isAllocator[msg.sender] && !winddown) || (winddown && _debtBalance(token) > 0), ErrorsLib.OnlyAllocatorsOrWinddown());
        require(isToken(token), ErrorsLib.TokenNotWhitelisted());
        require(address(swapper) != address(0), ErrorsLib.InvalidAddress());

        uint256 oraclePrice = oracles[token].price();
        uint256 slippageTolerance = winddown ? _winddownSlippageTolerance() : maxSlippage;

        if (winddown) {
            // Limit allocation to debt shortfall adjusted for slippage tolerance
            uint256 debtAmount = _debtBalance(token);
            uint256 existingBalance = token.balanceOf(address(this));
            uint256 neededTokens = debtAmount > existingBalance ? debtAmount - existingBalance : 0;
            uint256 neededValue = neededTokens.mulDiv(oraclePrice, ORACLE_PRECISION);
            uint256 maxAllocation = neededValue.mulDiv(PRECISION, PRECISION - slippageTolerance);
            require(assetsAmount <= maxAllocation, ErrorsLib.InvalidAmount());
        }

        // Execute swap
        (uint256 assetsSpent, uint256 tokensReceived) = _executeSwap(IERC20(asset), token, assetsAmount, swapper, data);

        // Calculate and validate slippage
        uint256 expectedTokens = assetsAmount.mulDiv(ORACLE_PRECISION, oraclePrice);
        uint256 minTokens = _calculateMinAmount(expectedTokens, slippageTolerance);
        require(tokensReceived >= minTokens, ErrorsLib.AllocationTooExpensive());

        int256 slippagePct = _calculateSlippagePct(expectedTokens, tokensReceived);

        // Track slippage if we are not in winddown and have positive slippage
        if (!winddown && tokensReceived < expectedTokens) {
            uint256 slippageValue = (expectedTokens - tokensReceived).mulDiv(oraclePrice, ORACLE_PRECISION);
            _increaseSlippage(slippageValue.mulDiv(PRECISION, totalAssets()));
        }

        emit EventsLib.Allocation(token, assetsSpent, expectedTokens, tokensReceived, slippagePct, swapper, data);

        _endNavCache();
        return (expectedTokens, tokensReceived);
    }

    /**
     * @notice Swaps investment tokens back to base asset
     * @param token Token to sell
     * @param tokensAmount Maximum amount of tokens to sell
     * @param swapper Contract that will execute the swap
     * @param data Custom data for the swapper implementation
     * @return expected Expected amount of base asset based on oracle price
     * @return received Actual amount of base asset received from the deallocation
     * @dev Enforces slippage protection based on oracle prices
     * @dev During wind-down, anyone can deallocate tokens with no outstanding debt
     */
    function deallocate(
        IERC20 token,
        uint256 tokensAmount,
        ISwapper swapper,
        bytes calldata data
    ) external nonReentrant returns (uint256 expected, uint256 received) {
        _startNavCache();

        bool winddown = isWinddown();
        require((isAllocator[msg.sender] && !winddown) || (winddown && _debtBalance(token) == 0), ErrorsLib.OnlyAllocatorsOrWinddown());
        require(address(swapper) != address(0), ErrorsLib.InvalidAddress());
        require(isToken(token), ErrorsLib.TokenNotWhitelisted());

        uint256 oraclePrice = oracles[token].price();
        uint256 slippageTolerance = winddown ? _winddownSlippageTolerance() : maxSlippage;

        // Execute swap
        (uint256 tokensSpent, uint256 assetsReceived) = _executeSwap(token, IERC20(asset), tokensAmount, swapper, data);

        // Calculate and validate slippage
        uint256 expectedAssets = tokensAmount.mulDiv(oraclePrice, ORACLE_PRECISION);
        uint256 minAssets = _calculateMinAmount(expectedAssets, slippageTolerance);
        require(assetsReceived >= minAssets, ErrorsLib.TokenSaleNotGeneratingEnoughAssets());

        int256 slippagePct = _calculateSlippagePct(expectedAssets, assetsReceived);

        // Track slippage if not in winddown and we have positive slippage
        if (!winddown && assetsReceived < expectedAssets) {
            // slippage is already in asset units
            uint256 slippageValue = expectedAssets - assetsReceived;
            _increaseSlippage(slippageValue.mulDiv(PRECISION, totalAssets()));
        }

        emit EventsLib.Deallocation(token, tokensSpent, expectedAssets, assetsReceived, slippagePct, swapper, data);

        _endNavCache();
        return (expectedAssets, assetsReceived);
    }

    /**
     * @notice Swaps between two investment tokens directly
     * @param from Source token to sell
     * @param to Target token to buy
     * @param tokensAmount Maximum amount of source token to sell
     * @param swapper Contract that will execute the swap
     * @param data Custom data for the swapper implementation
     * @return expected Expected amount of target token based on oracle prices
     * @return received Actual amount of target token received from the reallocation
     * @dev More gas efficient than separate deallocate + allocate
     */
    function reallocate(
        IERC20 from,
        IERC20 to,
        uint256 tokensAmount,
        ISwapper swapper,
        bytes calldata data
    ) external nonReentrant returns (uint256 expected, uint256 received) {
        _startNavCache();

        require(isAllocator[msg.sender], ErrorsLib.OnlyAllocators());
        require(!isWinddown(), ErrorsLib.CannotDuringWinddown());
        require(isToken(from) && isToken(to), ErrorsLib.TokenNotWhitelisted());
        require(address(swapper) != address(0), ErrorsLib.InvalidAddress());

        uint256 fromOraclePrice = oracles[from].price();
        uint256 toOraclePrice = oracles[to].price();

        // Execute swap
        (uint256 fromSpent, uint256 toReceived) = _executeSwap(from, to, tokensAmount, swapper, data);

        // Calculate expected amounts and validate slippage
        uint256 fromValue = tokensAmount.mulDiv(fromOraclePrice, ORACLE_PRECISION);
        uint256 expectedToTokens = fromValue.mulDiv(ORACLE_PRECISION, toOraclePrice);
        uint256 minToTokens = _calculateMinAmount(expectedToTokens, maxSlippage);
        require(toReceived >= minToTokens, ErrorsLib.ReallocationSlippageTooHigh());

        int256 slippagePct = _calculateSlippagePct(expectedToTokens, toReceived);

        // Track slippage if we have positive slippage
        // Note: No winddown check needed as reallocate cannot be called during winddown
        if (toReceived < expectedToTokens) {
            uint256 slippageValue = (expectedToTokens - toReceived).mulDiv(toOraclePrice, ORACLE_PRECISION);
            _increaseSlippage(slippageValue.mulDiv(PRECISION, totalAssets()));
        }

        emit EventsLib.Reallocation(from, to, fromSpent, expectedToTokens, toReceived, slippagePct, swapper, data);

        _endNavCache();
        return (expectedToTokens, toReceived);
    }

    // ========== FUNDING FUNCTIONS ==========

    /**
     * @notice Posts collateral to a lending facility
     * @param fundingModule Module managing the facility
     * @param facilityData Encoded facility identifier
     * @param collateralToken Token to pledge as collateral
     * @param collateralAmount Amount to pledge
     * @dev Transfers tokens to module and updates collateral position
     */
    function pledge(
        IFunding fundingModule,
        bytes calldata facilityData,
        IERC20 collateralToken,
        uint256 collateralAmount
    ) external nonReentrant {
        require(isAllocator[msg.sender] && !isWinddown(), ErrorsLib.OnlyAllocators());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        collateralToken.safeTransfer(address(fundingModule), collateralAmount);
        fundingModule.pledge(facilityData, collateralToken, collateralAmount);

        emit EventsLib.Pledge(fundingModule, facilityData, collateralToken, collateralAmount);
    }

    /**
     * @notice Withdraws collateral from a lending facility
     * @param fundingModule Module managing the facility
     * @param facilityData Encoded facility identifier
     * @param collateralToken Token to withdraw
     * @param collateralAmount Amount to withdraw (max uint256 = all)
     * @dev Returns tokens to vault, must maintain required collateral ratios
     */
    function depledge(
        IFunding fundingModule,
        bytes calldata facilityData,
        IERC20 collateralToken,
        uint256 collateralAmount
    ) external nonReentrant {
        require(isAllocator[msg.sender] || isWinddown(), ErrorsLib.OnlyAllocatorsOrWinddown());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        uint256 pledgeAmount = fundingModule.collateralBalance(facilityData, collateralToken);

        if (collateralAmount == type(uint256).max) {
            collateralAmount = pledgeAmount;
        }

        fundingModule.depledge(facilityData, collateralToken, collateralAmount);

        emit EventsLib.Depledge(fundingModule, facilityData, collateralToken, collateralAmount);
    }

    /**
     * @notice Takes out a loan from a lending facility
     * @param fundingModule Module managing the facility
     * @param facilityData Encoded facility identifier
     * @param debtToken Token to borrow
     * @param borrowAmount Amount to borrow
     * @dev Requires sufficient collateral, borrowed tokens sent to vault
     */
    function borrow(IFunding fundingModule, bytes calldata facilityData, IERC20 debtToken, uint256 borrowAmount) external nonReentrant {
        require(isAllocator[msg.sender] && !isWinddown(), ErrorsLib.OnlyAllocators());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        fundingModule.borrow(facilityData, debtToken, borrowAmount);

        emit EventsLib.Borrow(fundingModule, facilityData, debtToken, borrowAmount);
    }

    /**
     * @notice Repays borrowed tokens to a lending facility
     * @param fundingModule Module managing the facility
     * @param facilityData Encoded facility identifier
     * @param debtToken Token to repay
     * @param repayAmount Amount to repay (max uint256 = full debt)
     * @dev Transfers tokens from vault to module, reduces debt position
     */
    function repay(IFunding fundingModule, bytes calldata facilityData, IERC20 debtToken, uint256 repayAmount) external nonReentrant {
        require(isAllocator[msg.sender] || isWinddown(), ErrorsLib.OnlyAllocatorsOrWinddown());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        uint256 debtAmount = fundingModule.debtBalance(facilityData, debtToken);

        if (repayAmount > debtAmount) {
            repayAmount = debtAmount;
        }

        debtToken.safeTransfer(address(fundingModule), repayAmount);
        fundingModule.repay(facilityData, debtToken, repayAmount);

        emit EventsLib.Repay(fundingModule, facilityData, debtToken, repayAmount);
    }

    /**
     * @notice Recovers non-position tokens from a funding module
     * @param fundingModule Module to skim from
     * @param token Token to recover
     * @dev NAV must remain unchanged to prevent skimming tokenized positions
     */
    function skimFunding(IFunding fundingModule, IERC20 token) external nonReentrant {
        require(isAllocator[msg.sender] || isWinddown(), ErrorsLib.OnlyAllocatorsOrWinddown());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        fundingModule.skim(token, IOracleCallback(address(this)));
    }

    /**
     * @notice Provides temporary liquidity for complex operations
     * @param flashToken Token to flash loan
     * @param flashAmount Amount to provide temporarily
     * @param data Custom data passed to the callback
     * @dev Caller must implement IBoxFlashCallback and return tokens within same transaction
     * @dev NAV is cached during flash to prevent manipulation
     */
    function flash(IERC20 flashToken, uint256 flashAmount, bytes calldata data) external {
        require(isAllocator[msg.sender] || isWinddown(), ErrorsLib.OnlyAllocators());
        require(address(flashToken) != address(0), ErrorsLib.InvalidAddress());
        require(isTokenOrAsset(flashToken), ErrorsLib.TokenNotWhitelisted());
        // Prevent re-entrancy. Can't use nonReentrant modifier because of conflict with allocate/deallocate/reallocate
        require(_navCacheDepth == 0, ErrorsLib.AlreadyInFlash());

        // Cache NAV before starting flash operation for slippage calculations
        _startNavCache();

        // Transfer flash amount FROM caller TO this contract
        flashToken.safeTransferFrom(msg.sender, address(this), flashAmount);

        // Call the callback function on the caller
        IBoxFlashCallback(msg.sender).onBoxFlash(flashToken, flashAmount, data);

        // Repay the flash loan by transferring back TO caller
        flashToken.safeTransfer(msg.sender, flashAmount);

        _endNavCache();

        emit EventsLib.Flash(msg.sender, flashToken, flashAmount);
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Sets the address that receives skimmed tokens
     * @param newSkimRecipient New recipient address for skimmed tokens
     * @dev Only owner can call this function
     */
    function setSkimRecipient(address newSkimRecipient) external {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(newSkimRecipient != address(0), ErrorsLib.InvalidAddress());
        require(newSkimRecipient != skimRecipient, ErrorsLib.AlreadySet());

        address oldRecipient = skimRecipient;
        skimRecipient = newSkimRecipient;

        emit EventsLib.SkimRecipientUpdated(oldRecipient, newSkimRecipient);
    }

    /**
     * @notice Transfers ownership of the contract
     * @param newOwner Address that will become the new owner
     * @dev Immediately transfers all owner privileges
     */
    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(newOwner != address(0), ErrorsLib.InvalidAddress());

        address oldOwner = owner;
        owner = newOwner;

        emit EventsLib.OwnershipTransferred(oldOwner, newOwner);
    }

    /**
     * @notice Sets a new curator for the vault
     * @param newCurator Address that will manage tokens and funding
     * @dev Only owner can update the curator
     */
    function setCurator(address newCurator) external {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());

        address oldCurator = curator;
        curator = newCurator;

        emit EventsLib.CuratorUpdated(oldCurator, newCurator);
    }

    /**
     * @notice Sets a new guardian with emergency powers
     * @param newGuardian Address that can trigger shutdowns and revoke actions
     * @dev Requires timelock, only curator can execute
     */
    function setGuardian(address newGuardian) external {
        require(!isWinddown(), ErrorsLib.CannotDuringWinddown());
        timelocked();
        require(msg.sender == curator, ErrorsLib.OnlyCurator());

        address oldGuardian = guardian;
        guardian = newGuardian;

        emit EventsLib.GuardianUpdated(oldGuardian, newGuardian);
    }

    /**
     * @notice Grants or revokes allocator privileges
     * @param account Address to modify permissions for
     * @param newIsAllocator True to grant allocator role, false to revoke
     * @dev Allocators can execute investment strategies
     */
    function setIsAllocator(address account, bool newIsAllocator) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        //        require(account != address(0), ErrorsLib.InvalidAddress());

        isAllocator[account] = newIsAllocator;

        emit EventsLib.AllocatorUpdated(account, newIsAllocator);
    }

    /**
     * @notice Initiates emergency shutdown of the vault
     * @dev Stops deposits and starts the wind-down process after warmup period
     * @dev Guardian or curator can trigger shutdown
     */
    function shutdown() external {
        require(msg.sender == guardian || msg.sender == curator, ErrorsLib.OnlyGuardianOrCuratorCanShutdown());
        require(!isShutdown(), ErrorsLib.AlreadyShutdown());

        shutdownTime = block.timestamp;

        emit EventsLib.Shutdown(msg.sender);
    }

    /**
     * @notice Cancels shutdown and returns vault to normal operation
     * @dev Only guardian can recover, must be before wind-down phase starts
     */
    function recover() external {
        require(msg.sender == guardian, ErrorsLib.OnlyGuardianCanRecover());
        require(isShutdown(), ErrorsLib.NotShutdown());
        require(!isWinddown(), ErrorsLib.CannotRecoverAfterWinddown());

        shutdownTime = type(uint256).max;

        emit EventsLib.Recover(msg.sender);
    }

    // ========== TIMELOCK GOVERNANCE ==========

    /**
     * @notice Submits a function call to the timelock queue
     * @param data Encoded function call to be executed after delay
     * @dev Delay duration depends on the function selector
     */
    function submit(bytes calldata data) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(executableAt[data] == 0, ErrorsLib.DataAlreadyTimelocked());
        require(data.length >= 4, ErrorsLib.InvalidAmount());

        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = bytes4(data);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 delay = selector == IBox.decreaseTimelock.selector ? timelock[bytes4(data[4:8])] : timelock[selector];
        executableAt[data] = block.timestamp + delay;

        emit EventsLib.TimelockSubmitted(selector, data, executableAt[data], msg.sender);
    }

    /**
     * @dev Validates and consumes a timelocked transaction
     * @dev Checks if current calldata is timelocked and ready for execution
     */
    function timelocked() internal {
        require(executableAt[msg.data] > 0, ErrorsLib.DataNotTimelocked());
        require(block.timestamp >= executableAt[msg.data], ErrorsLib.TimelockNotExpired());

        executableAt[msg.data] = 0;

        emit EventsLib.TimelockExecuted(bytes4(msg.data), msg.data, msg.sender);
    }

    /**
     * @notice Cancels a pending timelocked transaction
     * @param data Encoded function call to cancel
     * @dev Guardian or curator can revoke pending transactions
     */
    function revoke(bytes calldata data) external {
        require(msg.sender == curator || msg.sender == guardian, ErrorsLib.OnlyCuratorOrGuardian());
        require(executableAt[data] > 0, ErrorsLib.DataNotTimelocked());

        executableAt[data] = 0;

        // forge-lint: disable-next-line(unsafe-typecast)
        emit EventsLib.TimelockRevoked(bytes4(data), data, msg.sender);
    }

    /**
     * @notice Extends the timelock delay for a function
     * @param selector Function signature to modify
     * @param newDuration New delay in seconds (must be longer than current)
     * @dev No timelock required to increase delays
     */
    function increaseTimelock(bytes4 selector, uint256 newDuration) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(newDuration <= TIMELOCK_CAP, ErrorsLib.InvalidTimelock());
        require(newDuration > timelock[selector], ErrorsLib.TimelockDecrease());

        timelock[selector] = newDuration;

        emit EventsLib.TimelockIncreased(selector, newDuration, msg.sender);
    }

    /**
     * @notice Reduces the timelock delay for a function
     * @param selector Function signature to modify
     * @param newDuration New delay in seconds (must be shorter than current)
     * @dev Requires timelock to prevent governance attacks
     */
    function decreaseTimelock(bytes4 selector, uint256 newDuration) external {
        timelocked();
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(newDuration <= TIMELOCK_CAP, ErrorsLib.InvalidTimelock());
        require(newDuration < timelock[selector], ErrorsLib.TimelockIncrease());
        require(timelock[selector] != TIMELOCK_DISABLED, ErrorsLib.InvalidTimelock());

        timelock[selector] = newDuration;

        emit EventsLib.TimelockDecreased(selector, newDuration, msg.sender);
    }

    /**
     * @notice Permanently disables a function by setting infinite timelock
     * @param selector Function signature to disable
     * @dev Irreversible - function becomes permanently inaccessible
     */
    function abdicateTimelock(bytes4 selector) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());

        timelock[selector] = TIMELOCK_DISABLED;

        emit EventsLib.TimelockIncreased(selector, TIMELOCK_DISABLED, msg.sender);
    }

    // ========== TIMELOCKED FUNCTIONS ==========

    /**
     * @notice Grants or revokes deposit privileges
     * @param account Address to modify permissions for
     * @param newIsFeeder True to allow deposits, false to revoke
     * @dev Requires timelock to add feeders
     */
    function setIsFeeder(address account, bool newIsFeeder) external {
        timelocked();
        require(account != address(0), ErrorsLib.InvalidAddress());

        isFeeder[account] = newIsFeeder;

        emit EventsLib.FeederUpdated(account, newIsFeeder);
    }

    /**
     * @notice Sets the maximum tolerated slippage for swaps
     * @param newMaxSlippage New limit scaled by PRECISION (e.g., 0.01e18 = 1%)
     * @dev Requires timelock, applies per-swap and per-epoch
     */
    function setMaxSlippage(uint256 newMaxSlippage) external {
        timelocked();
        require(newMaxSlippage <= MAX_SLIPPAGE_LIMIT, ErrorsLib.SlippageTooHigh());

        uint256 oldMaxSlippage = maxSlippage;
        maxSlippage = newMaxSlippage;

        emit EventsLib.MaxSlippageUpdated(oldMaxSlippage, newMaxSlippage);
    }

    /**
     * @notice Whitelists a new investment token
     * @param token Token contract to add
     * @param oracle Price feed for the token
     * @dev Requires timelock, oracle must return prices in base asset terms
     */
    function addToken(IERC20 token, IOracle oracle) external {
        timelocked();
        require(address(token) != address(0), ErrorsLib.InvalidAddress());
        require(address(oracle) != address(0), ErrorsLib.OracleRequired());
        require(!isToken(token), ErrorsLib.TokenAlreadyWhitelisted());
        require(tokens.length < MAX_TOKENS, ErrorsLib.TooManyTokens());

        tokens.push(token);
        oracles[token] = oracle;

        emit EventsLib.TokenAdded(token, oracle);
    }

    /**
     * @notice Removes a token from the whitelist
     * @param token Token to delist
     * @dev Token balance must be zero and not used in any funding module
     */
    function removeToken(IERC20 token) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(isToken(token), ErrorsLib.TokenNotWhitelisted());
        require(token.balanceOf(address(this)) == 0, ErrorsLib.TokenBalanceMustBeZero());
        require(!_isTokenUsedInFunding(token), ErrorsLib.CannotRemove());

        uint256 length = tokens.length;
        for (uint256 i; i < length; ) {
            if (tokens[i] == token) {
                tokens[i] = tokens[length - 1];
                tokens.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        delete oracles[token];

        emit EventsLib.TokenRemoved(token);
    }

    /**
     * @notice Updates the price oracle for a whitelisted token
     * @param token Token to update oracle for
     * @param oracle New price feed contract
     * @dev Requires timelock in normal operation, guardian can update during final wind-down
     */
    function changeTokenOracle(IERC20 token, IOracle oracle) external {
        if (isWinddown()) {
            require(block.timestamp >= shutdownTime + shutdownWarmup + shutdownSlippageDuration, ErrorsLib.NotAllowed());
            require(msg.sender == guardian, ErrorsLib.OnlyGuardian());
        } else {
            timelocked();
        }
        require(address(oracle) != address(0), ErrorsLib.InvalidAddress());
        require(isToken(token), ErrorsLib.TokenNotWhitelisted());

        oracles[token] = oracle;

        emit EventsLib.TokenOracleChanged(token, oracle);
    }

    /**
     * @notice Adds a new funding module for borrowing/lending
     * @param fundingModule Module contract to whitelist
     * @dev Module must be empty with no facilities, collateral, or debt
     */
    function addFunding(IFunding fundingModule) external {
        timelocked();
        require(!fundingMap[fundingModule], ErrorsLib.AlreadyWhitelisted());
        require(address(fundingModule) != address(0), ErrorsLib.InvalidAddress());
        require(fundingModule.facilitiesLength() == 0, ErrorsLib.NotClean());
        require(fundingModule.collateralTokensLength() == 0, ErrorsLib.NotClean());
        require(fundingModule.debtTokensLength() == 0, ErrorsLib.NotClean());

        fundingMap[fundingModule] = true;
        fundings.push(fundingModule);

        emit EventsLib.FundingModuleAdded(fundingModule);
    }

    /**
     * @notice Registers a lending facility within a funding module
     * @param fundingModule Module to add facility to
     * @param facilityData Encoded facility parameters
     * @dev Requires timelock, facility specifics depend on module implementation
     */
    function addFundingFacility(IFunding fundingModule, bytes calldata facilityData) external {
        timelocked();
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        fundingModule.addFacility(facilityData);

        emit EventsLib.FundingFacilityAdded(fundingModule, facilityData);
    }

    /**
     * @notice Enables a token as collateral in a funding module
     * @param fundingModule Module to configure
     * @param collateralToken Token to use as collateral
     * @dev Token must be whitelisted in the vault first
     */
    function addFundingCollateral(IFunding fundingModule, IERC20 collateralToken) external {
        timelocked();
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());
        require(isTokenOrAsset(collateralToken), ErrorsLib.TokenNotWhitelisted());

        fundingModule.addCollateralToken(collateralToken);

        emit EventsLib.FundingCollateralAdded(fundingModule, collateralToken);
    }

    /**
     * @notice Enables a token for borrowing in a funding module
     * @param fundingModule Module to configure
     * @param debtToken Token that can be borrowed
     * @dev Token must be whitelisted in the vault first
     */
    function addFundingDebt(IFunding fundingModule, IERC20 debtToken) external {
        timelocked();
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());
        require(isTokenOrAsset(debtToken), ErrorsLib.TokenNotWhitelisted());

        fundingModule.addDebtToken(debtToken);

        emit EventsLib.FundingDebtAdded(fundingModule, debtToken);
    }

    /**
     * @notice Removes a funding module from the vault
     * @param fundingModule Module to remove
     * @dev Module must be empty with no active facilities, collateral, or debt
     */
    function removeFunding(IFunding fundingModule) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        require(fundingModule.facilitiesLength() == 0, ErrorsLib.CannotRemove());
        require(fundingModule.collateralTokensLength() == 0, ErrorsLib.CannotRemove());
        require(fundingModule.debtTokensLength() == 0, ErrorsLib.CannotRemove());

        fundingMap[fundingModule] = false;
        uint256 index = _findFundingIndex(fundingModule);
        fundings[index] = fundings[fundings.length - 1];
        fundings.pop();

        emit EventsLib.FundingModuleRemoved(fundingModule);
    }

    /**
     * @notice Deregisters a lending facility from a funding module
     * @param fundingModule Module containing the facility
     * @param facilityData Encoded facility identifier
     * @dev Facility must have no outstanding positions
     */
    function removeFundingFacility(IFunding fundingModule, bytes calldata facilityData) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        fundingModule.removeFacility(facilityData);

        emit EventsLib.FundingFacilityRemoved(fundingModule, facilityData);
    }

    /**
     * @notice Disables a token as collateral in a funding module
     * @param fundingModule Module to update
     * @param collateralToken Token to remove from collateral list
     * @dev Token must not be actively used as collateral
     */
    function removeFundingCollateral(IFunding fundingModule, IERC20 collateralToken) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        fundingModule.removeCollateralToken(collateralToken);

        emit EventsLib.FundingCollateralRemoved(fundingModule, collateralToken);
    }

    /**
     * @notice Disables borrowing of a token in a funding module
     * @param fundingModule Module to update
     * @param debtToken Token to remove from debt list
     * @dev No outstanding debt must exist for this token
     */
    function removeFundingDebt(IFunding fundingModule, IERC20 debtToken) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        fundingModule.removeDebtToken(debtToken);

        emit EventsLib.FundingDebtRemoved(fundingModule, debtToken);
    }

    // ========== VIEW FUNCTIONS ==========
    /**
     * @notice Checks if a token is whitelisted for investment
     * @param token Token to check
     * @return True if the token has an associated oracle
     */
    function isToken(IERC20 token) public view returns (bool) {
        return address(oracles[token]) != address(0);
    }

    /**
     * @notice Checks if a token is the base asset or a whitelisted token
     * @param token Token to check
     * @return True if it's the base asset or has an oracle
     */
    function isTokenOrAsset(IERC20 token) public view returns (bool) {
        return address(token) == asset || address(oracles[token]) != address(0);
    }

    /**
     * @notice Gets the count of whitelisted tokens
     * @return Number of tokens in the investment list
     */
    function tokensLength() external view returns (uint256) {
        return tokens.length;
    }

    /**
     * @notice Checks if a funding module is authorized
     * @param fundingModule Module to verify
     * @return True if the module can be used for borrowing/lending
     */
    function isFunding(IFunding fundingModule) public view returns (bool) {
        return fundingMap[fundingModule];
    }

    /**
     * @notice Gets the count of active funding modules
     * @return Number of modules available for borrowing/lending
     */
    function fundingsLength() external view override returns (uint256) {
        return fundings.length;
    }

    /**
     * @notice Checks if the vault is in shutdown mode
     * @return True if shutdown has been triggered
     */
    function isShutdown() public view returns (bool) {
        return shutdownTime != type(uint256).max;
    }

    /**
     * @notice Checks if the vault has entered wind-down phase
     * @return True if past the warmup period after shutdown
     */
    function isWinddown() public view returns (bool) {
        return shutdownTime != type(uint256).max && block.timestamp >= shutdownTime + shutdownWarmup;
    }

    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @dev Starts NAV caching for the current operation
     * @dev Caches NAV on first call (depth 0 -> 1), increments depth on nested calls
     * @dev Properly handles nesting when swaps are called from flash callbacks
     */
    function _startNavCache() internal {
        if (_navCacheDepth == 0) {
            _cachedNav = _nav();
        }
        _navCacheDepth++;
    }

    /**
     * @dev Ends NAV caching for the current operation
     * @dev Decrements the depth counter
     */
    function _endNavCache() internal {
        _navCacheDepth--;
    }

    /**
     * @dev Executes a swap through a swapper contract with approval management
     * @param fromToken Token to sell
     * @param toToken Token to buy
     * @param maxAmount Maximum amount of fromToken to sell
     * @param swapper Swapper contract to execute the trade
     * @param data Custom data for the swapper
     * @return spent Actual amount of fromToken spent
     * @return received Amount of toToken received
     */
    function _executeSwap(
        IERC20 fromToken,
        IERC20 toToken,
        uint256 maxAmount,
        ISwapper swapper,
        bytes calldata data
    ) internal returns (uint256 spent, uint256 received) {
        uint256 fromBefore = fromToken.balanceOf(address(this));
        uint256 toBefore = toToken.balanceOf(address(this));

        fromToken.forceApprove(address(swapper), maxAmount);
        swapper.sell(fromToken, toToken, maxAmount, data);
        fromToken.forceApprove(address(swapper), 0);

        spent = fromBefore - fromToken.balanceOf(address(this));
        received = toToken.balanceOf(address(this)) - toBefore;

        require(spent <= maxAmount, ErrorsLib.SwapperDidSpendTooMuch());
    }

    /**
     * @dev Calculates slippage percentage from expected vs actual amounts
     * @param expectedAmount Expected amount based on oracle price
     * @param actualAmount Actual amount received/spent
     * @return slippagePct Slippage as a percentage scaled by PRECISION
     */
    function _calculateSlippagePct(uint256 expectedAmount, uint256 actualAmount) internal pure returns (int256 slippagePct) {
        int256 slippage = expectedAmount.toInt256() - actualAmount.toInt256();
        slippagePct = expectedAmount == 0 ? int256(0) : (slippage * PRECISION.toInt256()) / expectedAmount.toInt256();
    }

    /**
     * @dev Calculates minimum acceptable amount based on slippage tolerance
     * @param expectedAmount Expected amount based on oracle price
     * @param tolerance Maximum allowed slippage scaled by PRECISION
     * @return minAmount Minimum acceptable amount after slippage
     */
    function _calculateMinAmount(uint256 expectedAmount, uint256 tolerance) internal pure returns (uint256 minAmount) {
        minAmount = expectedAmount.mulDiv(PRECISION - tolerance, PRECISION);
    }

    /**
     * @dev Tracks slippage within current epoch and enforces limits
     * @param slippagePct Slippage to add scaled by PRECISION
     * @dev Resets epoch if duration has passed
     */
    function _increaseSlippage(uint256 slippagePct) internal {
        // Reset epoch if expired
        if (block.timestamp >= slippageEpochStart + slippageEpochDuration) {
            slippageEpochStart = block.timestamp;
            accumulatedSlippage = slippagePct;
            emit EventsLib.SlippageEpochReset(block.timestamp);
        } else {
            accumulatedSlippage += slippagePct;
        }

        require(accumulatedSlippage < maxSlippage, ErrorsLib.TooMuchAccumulatedSlippage());

        emit EventsLib.SlippageAccumulated(slippagePct, accumulatedSlippage);
    }

    /**
     * @dev Calculates total vault value across all positions
     * @return nav Sum of base asset, token values, and funding positions
     * @dev Negative funding NAV is floored to zero
     */
    function _nav() internal view returns (uint256 nav) {
        require(_navCacheDepth == 0, ErrorsLib.NoNavDuringCache());
        nav = IERC20(asset).balanceOf(address(this));

        // Add value of all tokens
        uint256 length = tokens.length;
        for (uint256 i; i < length; ) {
            IERC20 token = tokens[i];
            IOracle oracle = oracles[token];
            if (address(oracle) != address(0)) {
                uint256 tokenBalance = token.balanceOf(address(this));
                if (tokenBalance > 0) {
                    nav += tokenBalance.mulDiv(oracle.price(), ORACLE_PRECISION);
                }
            }
            unchecked {
                ++i;
            }
        }
        // Loop over funding sources
        length = fundings.length;
        for (uint256 i; i < length; ) {
            IFunding funding = fundings[i];
            nav += funding.nav(IOracleCallback(address(this)));
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Calculates dynamic slippage tolerance during wind-down
     * @return Slippage limit that increases linearly over shutdown duration
     * @dev Returns up to 100% slippage after full duration
     */
    function _winddownSlippageTolerance() internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp - shutdownWarmup - shutdownTime;
        return
            (timeElapsed < shutdownSlippageDuration)
                ? timeElapsed.mulDiv(MAX_SLIPPAGE_LIMIT, shutdownSlippageDuration)
                : MAX_SLIPPAGE_LIMIT;
    }

    /**
     * @dev Locates a funding module's position in the array
     * @param fundingData Module to find
     * @return Index in the fundings array
     * @dev Reverts if module is not whitelisted
     */
    function _findFundingIndex(IFunding fundingData) internal view returns (uint256) {
        for (uint256 i = 0; i < fundings.length; i++) {
            if (fundings[i] == fundingData) {
                return i;
            }
        }
        revert ErrorsLib.NotWhitelisted();
    }

    /**
     * @dev Checks if a token is used in any funding module
     * @param token Token to check
     * @return True if token is used as collateral or debt anywhere
     */
    function _isTokenUsedInFunding(IERC20 token) internal view returns (bool) {
        uint256 length = fundings.length;
        for (uint256 i; i < length; i++) {
            IFunding funding = fundings[i];
            if (funding.isCollateralToken(token) || funding.isDebtToken(token)) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Sums outstanding debt for a token across all modules
     * @param debtToken Token to check debt for
     * @return totalDebt Combined debt balance from all facilities
     */
    function _debtBalance(IERC20 debtToken) internal view returns (uint256 totalDebt) {
        uint256 length = fundings.length;
        for (uint256 i; i < length; i++) {
            IFunding funding = fundings[i];
            totalDebt += funding.debtBalance(debtToken);
        }
    }
}
