// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool success);
    function allowance(address owner, address spender) external view returns (uint256 remaining);
    function approve(address spender, uint256 amount) external returns (bool success);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool success);
}

interface IERC4626 {
    function asset() external view returns (address assetTokenAddress);
    function totalAssets() external view returns (uint256 totalManagedAssets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function maxMint(address receiver) external view returns (uint256 maxShares);
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function maxRedeem(address owner) external view returns (uint256 maxShares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

interface IOracle {    
    /// @notice Returns the price of 1 asset of collateral token quoted in 1 asset of loan token, scaled by 1e36.
    function price() external view returns (uint256);
}

interface ISwapper {
    /// @notice Take `amountIn` `input` from `msg.sender` swap to `output` and send back to `msg.sender`
    function swap(IERC20 input, IERC20 output, uint256 amountIn) external;
}

/// @title Box: A contract that can hold a currency and some assets and swap them
contract Box is IERC4626 {
    IERC20 public immutable currency;
    ISwapper public immutable backupSwapper;

    address public owner;
    address public guardian;

    // Role-based access control
    mapping(address => bool) public isAllocator;
    mapping(address => bool) public isFeeder;

    // INVESTMENT TOKENS
    IERC20[] public investmentTokens;
    mapping(IERC20 => IOracle) public oracles;
    mapping(IERC20 => bool) public isInvestmentToken;

    // SHARES (ERC4626)
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public constant name = "Box Shares";
    string public constant symbol = "BOX";
    uint8 public constant decimals = 18;

    // SWAPPING RELATED
    /// @notice starting date of a swapping epoch
    uint256 public slippageEpochStart;
    /// @notice amount of currency already rotated
    uint256 public slippageAccum;
    /// @notice maximum allowed slippage per epoch
    uint256 public maxSlippage = 0.01 ether; // 1%

    /// @notice Is the Box shut down
    bool public shutdown;
    /// @notice Timestamp when shutdown was triggered
    uint256 public shutdownTime;
  
    uint256 public timelock = 7 days;
    
    // Pending values for timelock pattern
    struct PendingValue {
        uint192 value;
        uint64 validAt;
    }
    
    PendingValue public pendingTimelock;
    mapping(address => PendingValue) public pendingGuardian;
    mapping(address => PendingValue) public pendingAllocator;
    mapping(address => PendingValue) public pendingFeeder;
    mapping(IERC20 => PendingValue) public pendingInvestmentToken;
    PendingValue public pendingSlippage;

    // Events
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event Allocate(IERC20 indexed token, uint256 currencyAmount, uint256 tokensReceived);
    event Deallocate(IERC20 indexed token, uint256 tokensAmount, uint256 currencyReceived);
    event Shutdown(address indexed guardian);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event AllocatorAdded(address indexed allocator);
    event AllocatorRemoved(address indexed allocator);
    event FeederAdded(address indexed feeder);
    event FeederRemoved(address indexed feeder);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event InvestmentTokenAdded(IERC20 indexed token, IOracle indexed oracle);
    event InvestmentTokenRemoved(IERC20 indexed token);
    event SlippageChanged(uint256 newSlippage);
    event TimelockChanged(uint256 newTimelock);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    // Timelock events
    event TimelockSubmitted(uint256 newTimelock);
    event PendingTimelockRevoked();
    event GuardianSubmitted(address indexed newGuardian);
    event PendingGuardianRevoked(address indexed guardian);
    event AllocatorSubmitted(address indexed allocator, bool isAdd);
    event PendingAllocatorRevoked(address indexed allocator);
    event FeederSubmitted(address indexed feeder, bool isAdd);
    event PendingFeederRevoked(address indexed feeder);
    event SlippageSubmitted(uint256 newSlippage);
    event PendingSlippageRevoked();
    event InvestmentTokenSubmitted(IERC20 indexed token, IOracle indexed oracle, bool isAdd);
    event PendingInvestmentTokenRevoked(IERC20 indexed token);

    constructor(
        address _owner, 
        IERC20 _currency,
        ISwapper _backupSwapper
    ) {
        owner = _owner;
        currency = _currency;
        backupSwapper = _backupSwapper;
        slippageEpochStart = block.timestamp;
    }

    /////////////////////////////
    /// ERC4626 Implementation
    /////////////////////////////

    /// @notice Returns the address of the underlying token used for the Vault for accounting, depositing, and withdrawing.
    function asset() external view returns (address) {
        return address(currency);
    }

    /// @notice Returns the total amount of the underlying asset that is "managed" by Vault.
    function totalAssets() public view returns (uint256 assets_) {
        assets_ = currency.balanceOf(address(this));
        
        // Add value of all investment tokens
        for (uint256 i = 0; i < investmentTokens.length; i++) {
            IERC20 token = investmentTokens[i];
            IOracle oracle = oracles[token];
            if (address(oracle) != address(0)) {
                uint256 tokenBalance = token.balanceOf(address(this));
                assets_ += (tokenBalance * oracle.price()) / 1e36;
            }
        }
    }

    /// @notice Returns the amount of shares that the Vault would exchange for the amount of assets provided
    function convertToShares(uint256 assets) public view returns (uint256) {
        return totalSupply == 0 ? assets : (assets * totalSupply) / totalAssets();
    }

    /// @notice Returns the amount of assets that the Vault would exchange for the amount of shares provided
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return totalSupply == 0 ? shares : (shares * totalAssets()) / totalSupply;
    }

    /// @notice Returns the maximum amount of the underlying asset that can be deposited
    function maxDeposit(address) external view returns (uint256) {
        return shutdown ? 0 : type(uint256).max;
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their deposit
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Mints shares Vault shares to receiver by depositing exactly amount of underlying tokens.
    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        require(isFeeder[msg.sender], "BOX: Only feeders can deposit");
        require(!shutdown, "BOX: Can't deposit if shut down");
        require(assets > 0, "BOX: Cannot deposit zero");

        shares = previewDeposit(assets);
        require(shares > 0, "BOX: Zero shares");

        currency.transferFrom(msg.sender, address(this), assets);
        
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Returns the maximum amount of the Vault shares that can be minted
    function maxMint(address) external view returns (uint256) {
        return shutdown ? 0 : type(uint256).max;
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their mint
    function previewMint(uint256 shares) public view returns (uint256) {
        return totalSupply == 0 ? shares : (shares * totalAssets() + totalSupply - 1) / totalSupply;
    }

    /// @notice Mints exactly shares Vault shares to receiver
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        require(isFeeder[msg.sender], "BOX: Only feeders can mint");
        require(!shutdown, "BOX: Can't mint if shut down");
        require(shares > 0, "BOX: Cannot mint zero");

        assets = previewMint(shares);
        
        currency.transferFrom(msg.sender, address(this), assets);
        
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Returns the maximum amount of the underlying asset that can be withdrawn
    function maxWithdraw(address owner_) external view returns (uint256) {
        uint256 shares = balanceOf[owner_];
        return convertToAssets(shares);
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their withdrawal
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return totalSupply == 0 ? assets : (assets * totalSupply + totalAssets() - 1) / totalAssets();
    }

    /// @notice Burns shares from owner and sends exactly assets of underlying tokens to receiver
    function withdraw(uint256 assets, address receiver, address owner_) public returns (uint256 shares) {
        require(isFeeder[msg.sender], "BOX: Only feeders can withdraw");
        require(msg.sender == owner_ || allowance[owner_][msg.sender] >= previewWithdraw(assets), "BOX: Insufficient allowance");
        
        shares = previewWithdraw(assets);
        require(balanceOf[owner_] >= shares, "BOX: Insufficient shares");

        // If we are shut down, try to gather enough liquidity by deallocating
        if (shutdown && currency.balanceOf(address(this)) < assets) {
            _deallocateForLiquidity(assets - currency.balanceOf(address(this)));
        }

        require(currency.balanceOf(address(this)) >= assets, "BOX: Insufficient liquidity");

        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[owner_][msg.sender] = allowed - shares;
            }
        }

        _burn(owner_, shares);
        currency.transfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @notice Returns the maximum amount of Vault shares that can be redeemed
    function maxRedeem(address owner_) external view returns (uint256) {
        return balanceOf[owner_];
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their redemption
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /// @notice Burns exactly shares from owner and sends assets of underlying tokens to receiver
    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        require(isFeeder[msg.sender], "BOX: Only feeders can redeem");
        require(msg.sender == owner_ || allowance[owner_][msg.sender] >= shares, "BOX: Insufficient allowance");
        require(balanceOf[owner_] >= shares, "BOX: Insufficient shares");

        assets = previewRedeem(shares);

        // If we are shut down, try to gather enough liquidity by deallocating
        if (shutdown && currency.balanceOf(address(this)) < assets) {
            _deallocateForLiquidity(assets - currency.balanceOf(address(this)));
        }

        require(currency.balanceOf(address(this)) >= assets, "BOX: Insufficient liquidity");

        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[owner_][msg.sender] = allowed - shares;
            }
        }

        _burn(owner_, shares);
        currency.transfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /////////////////////////////
    /// ERC20 Functions for Shares
    /////////////////////////////

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    /////////////////////////////
    /// Emergency Exit (Unbox)
    /////////////////////////////

    /// @notice Return the prorata share of currency and assets against shares (emergency exit)
    function unbox(uint256 shares) public {
        require(balanceOf[msg.sender] >= shares, "BOX: Insufficient shares");
        require(shares > 0, "BOX: Cannot unbox zero shares");

        uint256 currencyAmount = (currency.balanceOf(address(this)) * shares) / totalSupply;
        
        _burn(msg.sender, shares);

        if (currencyAmount > 0) {
            currency.transfer(msg.sender, currencyAmount);
        }

        // Transfer pro-rata share of each investment token
        for (uint256 i = 0; i < investmentTokens.length; i++) {
            IERC20 token = investmentTokens[i];
            uint256 tokenAmount = (token.balanceOf(address(this)) * shares) / (totalSupply + shares);
            if (tokenAmount > 0) {
                token.transfer(msg.sender, tokenAmount);
            }
        }
    }
    
    /////////////////////////////
    /// SWAPPING
    /////////////////////////////

    /// @notice Buy investment token with currency
    function allocate(IERC20 token, uint256 currencyAmount, ISwapper swapper) public {
        require(isAllocator[msg.sender], "BOX: Only allocators can allocate");
        require(!shutdown, "BOX: Can't allocate if shut down");
        require(isInvestmentToken[token], "BOX: Token not whitelisted");
        require(address(oracles[token]) != address(0), "BOX: No oracle for token");

        uint256 tokensBefore = token.balanceOf(address(this));

        currency.approve(address(swapper), currencyAmount);
        swapper.swap(currency, token, currencyAmount);
        
        uint256 tokensReceived = token.balanceOf(address(this)) - tokensBefore;

        // Calculate expected tokens and minimum acceptable
        uint256 expectedTokens = (currencyAmount * 1e36) / oracles[token].price();
        uint256 minTokens = (expectedTokens * (1 ether - maxSlippage)) / 1 ether;

        require(tokensReceived >= minTokens, "BOX: Allocation too expensive");

        // Calculate slippage as difference between expected and actual
        uint256 slippage = expectedTokens > tokensReceived ? 
            expectedTokens - tokensReceived : 0;
        _increaseSlippage((slippage * oracles[token].price() / 1e36 * 1e18) / totalAssets());

        emit Allocate(token, currencyAmount, tokensReceived);
    }

    /// @notice Sell investment token for currency
    function deallocate(IERC20 token, uint256 tokensAmount, ISwapper swapper) public {
        require(isAllocator[msg.sender] || shutdown, "BOX: Only allocators can deallocate or during shutdown");
        require(isInvestmentToken[token], "BOX: Token not whitelisted");
        require(address(oracles[token]) != address(0), "BOX: No oracle for token");

        if (shutdown) {
            _deallocateShutdown(token, tokensAmount);
        } else {
            _deallocateNormal(token, tokensAmount, swapper);
        }
    }

    function _deallocateNormal(IERC20 token, uint256 tokensAmount, ISwapper swapper) internal {
        uint256 currencyBefore = currency.balanceOf(address(this));

        token.approve(address(swapper), tokensAmount);
        swapper.swap(token, currency, tokensAmount);

        uint256 currencyReceived = currency.balanceOf(address(this)) - currencyBefore;

        // Calculate expected currency and minimum acceptable
        uint256 expectedCurrency = (tokensAmount * oracles[token].price()) / 1e36;
        uint256 minCurrency = (expectedCurrency * (1 ether - maxSlippage)) / 1 ether;

        require(currencyReceived >= minCurrency, "BOX: Token sale not generating enough currency");

        // Calculate slippage
        uint256 slippage = expectedCurrency > currencyReceived ? 
            expectedCurrency - currencyReceived : 0;
        _increaseSlippage((slippage * 1e18) / totalAssets());

        emit Deallocate(token, tokensAmount, currencyReceived);
    }

    function _deallocateShutdown(IERC20 token, uint256 tokensAmount) internal {
        uint256 currencyBefore = currency.balanceOf(address(this));

        // Use backup swapper during shutdown
        token.approve(address(backupSwapper), tokensAmount);
        backupSwapper.swap(token, currency, tokensAmount);

        uint256 currencyReceived = currency.balanceOf(address(this)) - currencyBefore;

        // During shutdown, slippage tolerance increases over time (0% to 10% over 10 days)
        uint256 timeElapsed = block.timestamp - shutdownTime;
        uint256 shutdownSlippage = timeElapsed > 10 days ? 0.1 ether : (timeElapsed * 0.1 ether) / 10 days;
        
        uint256 expectedCurrency = (tokensAmount * oracles[token].price()) / 1e36;
        uint256 minCurrency = (expectedCurrency * (1 ether - shutdownSlippage)) / 1 ether;

        require(currencyReceived >= minCurrency, "BOX: Shutdown deallocate slippage too high");

        emit Deallocate(token, tokensAmount, currencyReceived);
    }

    function _deallocateForLiquidity(uint256 currencyNeeded) internal {
        // Try to deallocate from investment tokens to get needed liquidity
        for (uint256 i = 0; i < investmentTokens.length && currency.balanceOf(address(this)) < currencyNeeded; i++) {
            IERC20 token = investmentTokens[i];
            uint256 tokenBalance = token.balanceOf(address(this));
            if (tokenBalance > 0) {
                uint256 tokensToSell = ((currencyNeeded - currency.balanceOf(address(this))) * 1e36) / oracles[token].price();
                if (tokensToSell > tokenBalance) {
                    tokensToSell = tokenBalance;
                }
                _deallocateShutdown(token, tokensToSell);
            }
        }
    }

    /// @notice Reallocate from one investment token to another
    function reallocate(IERC20 from, IERC20 to, uint256 fromAmount, ISwapper swapper) public {
        require(isAllocator[msg.sender], "BOX: Only allocators can reallocate");
        require(!shutdown, "BOX: Can't reallocate if shut down");
        require(isInvestmentToken[from] && isInvestmentToken[to], "BOX: Tokens not whitelisted");
        require(address(oracles[from]) != address(0) && address(oracles[to]) != address(0), "BOX: Oracles required");

        uint256 toBefore = to.balanceOf(address(this));

        from.approve(address(swapper), fromAmount);
        swapper.swap(from, to, fromAmount);

        uint256 toReceived = to.balanceOf(address(this)) - toBefore;

        // Calculate expected amounts based on both oracles
        // fromAmount * fromPrice / toPrice = expected toTokens
        uint256 fromValue = (fromAmount * oracles[from].price()) / 1e36; // Value in currency terms
        uint256 expectedToTokens = (fromValue * 1e36) / oracles[to].price(); // Expected tokens based on oracle prices
        uint256 minToTokens = (expectedToTokens * (1 ether - maxSlippage)) / 1 ether;

        require(toReceived >= minToTokens, "BOX: Reallocation slippage too high");

        // Calculate slippage as difference between expected and actual, in currency terms
        uint256 expectedValue = (expectedToTokens * oracles[to].price()) / 1e36;
        uint256 actualValue = (toReceived * oracles[to].price()) / 1e36;
        uint256 slippage = expectedValue > actualValue ? expectedValue - actualValue : 0;
        
        // Track slippage as percentage of total assets
        _increaseSlippage((slippage * 1e18) / totalAssets());

        emit Allocate(to, fromValue, toReceived);
        emit Deallocate(from, fromAmount, fromValue);
    }

    function _increaseSlippage(uint256 slippagePct) internal {
        // Reset the slippage epoch if more than a week old
        if (slippageEpochStart + 7 days < block.timestamp) {
            slippageEpochStart = block.timestamp;
            slippageAccum = 0;
        }

        slippageAccum += slippagePct;
        require(slippageAccum < maxSlippage, "BOX: Too much accumulated slippage");
    }

    /////////////////////////////
    /// OWNER FUNCTIONS (TIMELOCKED)
    /////////////////////////////

    /// @notice Submit a new timelock value
    function submitTimelock(uint256 newTimelock) external {
        require(msg.sender == owner, "BOX: Only owner");
        require(newTimelock >= 1 days, "BOX: Timelock too short");
        require(newTimelock <= 90 days, "BOX: Timelock too long");
        require(pendingTimelock.validAt == 0, "BOX: Already pending");
        
        pendingTimelock = PendingValue({
            value: uint192(newTimelock),
            validAt: uint64(block.timestamp + timelock)
        });
        
        emit TimelockSubmitted(newTimelock);
    }

    /// @notice Accept a pending timelock change
    function acceptTimelock() external {
        require(msg.sender == owner, "BOX: Only owner");
        require(pendingTimelock.validAt != 0, "BOX: No pending timelock");
        require(block.timestamp >= pendingTimelock.validAt, "BOX: Timelock not elapsed");
        
        uint256 newTimelock = pendingTimelock.value;
        delete pendingTimelock;
        
        timelock = newTimelock;
        emit TimelockChanged(newTimelock);
    }

    /// @notice Revoke a pending timelock change
    function revokePendingTimelock() external {
        require(msg.sender == guardian, "BOX: Only guardian");
        require(pendingTimelock.validAt != 0, "BOX: No pending timelock");
        
        delete pendingTimelock;
        emit PendingTimelockRevoked();
    }

    /// @notice Submit a new guardian
    function submitGuardian(address newGuardian) external {
        require(msg.sender == owner, "BOX: Only owner");
        require(newGuardian != address(0), "BOX: Invalid guardian");
        require(pendingGuardian[newGuardian].validAt == 0, "BOX: Already pending");
        
        pendingGuardian[newGuardian] = PendingValue({
            value: 1, // Just a flag
            validAt: uint64(block.timestamp + timelock)
        });
        
        emit GuardianSubmitted(newGuardian);
    }

    /// @notice Accept a pending guardian change
    function acceptGuardian(address newGuardian) external {
        require(msg.sender == owner, "BOX: Only owner");
        require(pendingGuardian[newGuardian].validAt != 0, "BOX: No pending guardian");
        require(block.timestamp >= pendingGuardian[newGuardian].validAt, "BOX: Timelock not elapsed");
        
        delete pendingGuardian[newGuardian];
        
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit GuardianChanged(oldGuardian, newGuardian);
    }

    /// @notice Revoke a pending guardian change
    function revokePendingGuardian(address newGuardian) external {
        require(msg.sender == guardian, "BOX: Only guardian");
        require(pendingGuardian[newGuardian].validAt != 0, "BOX: No pending guardian");
        
        delete pendingGuardian[newGuardian];
        emit PendingGuardianRevoked(newGuardian);
    }

    /// @notice Submit a new allocator
    function submitAllocator(address allocator, bool isAdd) external {
        require(msg.sender == owner, "BOX: Only owner");
        require(allocator != address(0), "BOX: Invalid allocator");
        require(pendingAllocator[allocator].validAt == 0, "BOX: Already pending");
        
        pendingAllocator[allocator] = PendingValue({
            value: isAdd ? 1 : 0,
            validAt: uint64(block.timestamp + timelock)
        });
        
        emit AllocatorSubmitted(allocator, isAdd);
    }

    /// @notice Accept a pending allocator change
    function acceptAllocator(address allocator) external {
        require(msg.sender == owner, "BOX: Only owner");
        require(pendingAllocator[allocator].validAt != 0, "BOX: No pending allocator");
        require(block.timestamp >= pendingAllocator[allocator].validAt, "BOX: Timelock not elapsed");
        
        bool isAdd = pendingAllocator[allocator].value == 1;
        delete pendingAllocator[allocator];
        
        isAllocator[allocator] = isAdd;
        
        if (isAdd) {
            emit AllocatorAdded(allocator);
        } else {
            emit AllocatorRemoved(allocator);
        }
    }

    /// @notice Revoke a pending allocator change
    function revokePendingAllocator(address allocator) external {
        require(msg.sender == guardian, "BOX: Only guardian");
        require(pendingAllocator[allocator].validAt != 0, "BOX: No pending allocator");
        
        delete pendingAllocator[allocator];
        emit PendingAllocatorRevoked(allocator);
    }

    /// @notice Submit a new feeder
    function submitFeeder(address feeder, bool isAdd) external {
        require(msg.sender == owner, "BOX: Only owner");
        require(feeder != address(0), "BOX: Invalid feeder");
        require(pendingFeeder[feeder].validAt == 0, "BOX: Already pending");
        
        pendingFeeder[feeder] = PendingValue({
            value: isAdd ? 1 : 0,
            validAt: uint64(block.timestamp + timelock)
        });
        
        emit FeederSubmitted(feeder, isAdd);
    }

    /// @notice Accept a pending feeder change
    function acceptFeeder(address feeder) external {
        require(msg.sender == owner, "BOX: Only owner");
        require(pendingFeeder[feeder].validAt != 0, "BOX: No pending feeder");
        require(block.timestamp >= pendingFeeder[feeder].validAt, "BOX: Timelock not elapsed");
        
        bool isAdd = pendingFeeder[feeder].value == 1;
        delete pendingFeeder[feeder];
        
        isFeeder[feeder] = isAdd;
        
        if (isAdd) {
            emit FeederAdded(feeder);
        } else {
            emit FeederRemoved(feeder);
        }
    }

    /// @notice Revoke a pending feeder change
    function revokePendingFeeder(address feeder) external {
        require(msg.sender == guardian, "BOX: Only guardian");
        require(pendingFeeder[feeder].validAt != 0, "BOX: No pending feeder");
        
        delete pendingFeeder[feeder];
        emit PendingFeederRevoked(feeder);
    }

    /// @notice Submit a new slippage value
    function submitSlippage(uint256 newSlippage) external {
        require(msg.sender == owner, "BOX: Only owner");
        require(newSlippage <= 0.1 ether, "BOX: Slippage too high"); // Max 10%
        require(pendingSlippage.validAt == 0, "BOX: Already pending");
        
        pendingSlippage = PendingValue({
            value: uint192(newSlippage),
            validAt: uint64(block.timestamp + timelock)
        });
        
        emit SlippageSubmitted(newSlippage);
    }

    /// @notice Accept a pending slippage change
    function acceptSlippage() external {
        require(msg.sender == owner, "BOX: Only owner");
        require(pendingSlippage.validAt != 0, "BOX: No pending slippage");
        require(block.timestamp >= pendingSlippage.validAt, "BOX: Timelock not elapsed");
        
        uint256 newSlippage = pendingSlippage.value;
        delete pendingSlippage;
        
        maxSlippage = newSlippage;
        emit SlippageChanged(newSlippage);
    }

    /// @notice Revoke a pending slippage change
    function revokePendingSlippage() external {
        require(msg.sender == guardian, "BOX: Only guardian");
        require(pendingSlippage.validAt != 0, "BOX: No pending slippage");
        
        delete pendingSlippage;
        emit PendingSlippageRevoked();
    }

    /// @notice Submit a new investment token
    function submitInvestmentToken(IERC20 token, IOracle oracle, bool isAdd) external {
        require(msg.sender == owner, "BOX: Only owner");
        require(address(token) != address(0), "BOX: Invalid token");
        if (isAdd) {
            require(address(oracle) != address(0), "BOX: Oracle required");
            require(!isInvestmentToken[token], "BOX: Token already added");
        } else {
            require(isInvestmentToken[token], "BOX: Token not found");
            require(token.balanceOf(address(this)) == 0, "BOX: Token balance must be zero");
        }
        require(pendingInvestmentToken[token].validAt == 0, "BOX: Already pending");
        
        pendingInvestmentToken[token] = PendingValue({
            value: isAdd ? 1 : 0,
            validAt: uint64(block.timestamp + timelock)
        });
        
        emit InvestmentTokenSubmitted(token, oracle, isAdd);
    }

    /// @notice Accept a pending investment token change
    function acceptInvestmentToken(IERC20 token, IOracle oracle) external {
        require(msg.sender == owner, "BOX: Only owner");
        require(pendingInvestmentToken[token].validAt != 0, "BOX: No pending investment token");
        require(block.timestamp >= pendingInvestmentToken[token].validAt, "BOX: Timelock not elapsed");
        
        bool isAdd = pendingInvestmentToken[token].value == 1;
        delete pendingInvestmentToken[token];
        
        if (isAdd) {
            require(address(oracle) != address(0), "BOX: Oracle required");
            require(!isInvestmentToken[token], "BOX: Token already added");
            
            investmentTokens.push(token);
            oracles[token] = oracle;
            isInvestmentToken[token] = true;
            
            emit InvestmentTokenAdded(token, oracle);
        } else {
            require(isInvestmentToken[token], "BOX: Token not found");
            require(token.balanceOf(address(this)) == 0, "BOX: Token balance must be zero");
            
            // Remove from array
            for (uint256 i = 0; i < investmentTokens.length; i++) {
                if (investmentTokens[i] == token) {
                    investmentTokens[i] = investmentTokens[investmentTokens.length - 1];
                    investmentTokens.pop();
                    break;
                }
            }
            
            delete oracles[token];
            isInvestmentToken[token] = false;
            
            emit InvestmentTokenRemoved(token);
        }
    }

    /// @notice Revoke a pending investment token change
    function revokePendingInvestmentToken(IERC20 token) external {
        require(msg.sender == guardian, "BOX: Only guardian");
        require(pendingInvestmentToken[token].validAt != 0, "BOX: No pending investment token");
        
        delete pendingInvestmentToken[token];
        emit PendingInvestmentTokenRevoked(token);
    }

    /// @notice Change owner (immediate, no timelock needed)
    function setOwner(address newOwner) external {
        require(msg.sender == owner, "BOX: Only owner");
        require(newOwner != address(0), "BOX: Invalid owner");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnerChanged(oldOwner, newOwner);
    }

    /////////////////////////////
    /// GUARDIAN FUNCTIONS
    /////////////////////////////

    /// @notice Trigger shutdown (guardian only)
    function triggerShutdown() external {
        require(msg.sender == guardian, "BOX: Only guardian can shutdown");
        require(!shutdown, "BOX: Already shut down");
        shutdown = true;
        shutdownTime = block.timestamp;
        emit Shutdown(guardian);
    }

    /////////////////////////////
    /// VIEW FUNCTIONS
    /////////////////////////////

    /// @notice Get number of investment tokens
    function getInvestmentTokensLength() external view returns (uint256) {
        return investmentTokens.length;
    }

    /// @notice Get investment token at index
    function getInvestmentToken(uint256 index) external view returns (IERC20) {
        return investmentTokens[index];
    }

}
