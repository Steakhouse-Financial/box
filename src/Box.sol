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

interface IOracle {    
    /// @notice Returns the price of 1 asset of collateral token quoted in 1 asset of loan token, scaled by 1e36.
    function price() external view returns (uint256);
}

interface ISwapper {
    /// @notice Take `amountIn``input` from `msg.sender` swap to òutput`and send back to `msg.sender`
    function swap(IERC20 input, IERC20 output, uint256 amountIn) external;
}

/// @title Box: A contract that can hold a currency and some assets and swap them
contract Box /* is IERC4626 */ {
    IERC20 public immutable currency;

    address public owner;
    // TODO: Maybe allow multiple allocators, but we can use a proxy anyway
    address public allocator;
    address public guardian;
    // TODO: Allow multiple feeders?
    address public feeder;

    // ASSETS RELATED
    // TODO: make it multi-assets, avoid too much slippage when going from a PT-sSUDe to another maturoty
    IERC20 public asset;
    IOracle public oracle;

    // SWAPPING RELATED
    /// @notice starting date of a swapping epoch
    uint256 slippageEpochStart;
    /// @notice amount of currency alread rotated
    uint256 slippageAccum;

    /// @notice Is the Box shut down and only emergenct
    bool shutdown;
  
    /// @dev calldata => executable at
    mapping(bytes => uint256) public validAt;    
    
    // TODO: do we want different timelock or to update it?
    // TODO: we will need a longer 21 (90?) days for shutdown at least
    uint256 public timelock = 7 days;
    uint256 constant maxSlippage = 0.01 ether;

    constructor(address _owner, address _allocator, IERC20 _currency ) {
        owner = _owner;
        allocator = _allocator;
        currency = _currency;
    }


    function isFeeder(address who) public view returns (bool) {
        return who == feeder;
    }

    function isAllocator(address who) public view returns (bool) {
        return who == allocator;
    }


    /////////////////////////////
    /// Box 
    /////////////////////////////

    /// @notice Deposit currency, if not the whitelisted, there will be a fee
    function deposit(uint256 amount, address who) public {
        require(msg.sender == who, "BOX: Can't donate to third parties");
        require(isFeeder(msg.sender), "BOX: Only feeders can deposit");
        require(shutdown == false, "BOX: Can't deposit if shut down");

        currency.transferFrom(msg.sender, address(this), amount);
        // TODO: mint shares
    }

    function withdraw(uint256 amount) public {
        require(isFeeder(msg.sender), "BOX: Only feeders can withdraw");

        // If we are shut down, try to gather enough liqudity
        // Do we need it or assume someone will be smart enough to use deallocate?
        if(shutdown && currency.balanceOf(address(this)) < amount)
            deallocate(0, ISwapper(0));

        // Burn shares

        // Can only transfer the USDC don't touch the assets
        currency.transfer(msg.sender, amount);
    }

    /// @notice Return the prorata share of currency and assets against shares
    function unbox(uint256 shares) public {
        // TODO is it needed? probably not
    }    
    
    /////////////////////////////
    /// SWAPPING
    /////////////////////////////

    /// @notice Buy asset with currency
    /// @dev we don't specify any code, just a safety threshold
    function allocate(uint256 cash, ISwapper swapper) public {
        require(isAllocator(msg.sender), "BOX: Only allocator can allocate");
        require(shutdown == false, "BOX: Can't allocate if shut down");


        uint256 assetsBefore = asset.balanceOf(address(this));

        cash.approve(address(swapper), cash);
        swapper.swap(cash, asset, cash);
        
        uint256 assetsReceived = asset.balanceOf(address(this)) - assetsBefore;

        // TODO: safe mulDiv
        uint256 expectedAssets =  (cash * oracle.price()) / 10**36;
        uint256 minAssets = (cost * (1 ether + maxSlippage)) / 1 ether;

        require(assetsReceived < minAssets, "BOX: Allocation too expensive");

        uint256 slippage = cash - cost; // min 0
        _increaseSlippage(slippage);
    }    

    /// @notice Sell asset for currency
    function deallocate(uint256 assets, ISwapper swapper) public {
        require(isAllocator(msg.sender), "BOX: Only allocator can deallocate");
        // Alternatively we could let people deallocate when shutdown
        require(isAllocator(msg.sender) || shutdown, "BOX: Only allocator can deallocate or during shutdown");

        uint256 cashBefore = cash.balanceOf(address(this));

        swapper.swap(asset, cash, assets);

        uint256 cashReceived = cash.balanceOf(address(this)) - cashBefore;

        // TODO: safe mulDiv
        uint256 expectedCash =  (assets * oracle.price()) / 10**36;
        uint256 minCash = (expectedCash * (1 ether - maxSlippage)) / 1 ether;
        _increaseSlippage(slippage);

        // TODO: In case of shutdown, the allowed slippage is function of time since shutdown 0% to 10% in 10 days ?

        require(cashReceived < minCash, "BOX: Asset sale is not generating enough cash");
    }    
    
    /// @notice Sell asset for another
    // TODO: Use the callback way
    function reallocate(IERC20 from, IERC20 to, uint256 fromAmount, ISwapper swapper) public {
        require(isAllocator(msg.sender), "BOX: Only allocator can reallocate");
        require(shutdown == false, "BOX: Can't reallocate if shut down");

        swapper.swap(from, to, fromAmount);

        // TODO : check slippage
    }    

    function _increaseSlippage(uint slippage) internal {
        uint256 sipplagePct = (slippage * 10**18)/totalAssets();

        // reset the slippage epoch if more than a week old
        if(slippageEpochStart + 7 days < block.timestamp) {
            slippageEpochStart = block.timestamp;
            slippageAccum = 0;
        }

        slippageAccum += sipplagePct;

        require(slippageAccum < maxSlippage, "BOX: Too much accumulated slippage");

    }
    

    /// @notice Returns total asset of the Box, cash + assets * oracle price
    function totalAssets() public view returns (uint256 assets) {
        assets = currency.balanceOf(address(this));
        // TODO: safe mulDiv as it can overflow
        assets += asset.balanceOf(address(this)) * oracle.price() / 10**36;
    }


    /* TIMELOCKS */
    function submit(bytes calldata data) external {
        require(msg.sender == owner, "BOX: Unauthorized");
        require(validAt[data] == 0, "BOX: Already Pending");

        bytes4 selector = bytes4(data);
        validAt[data] = block.timestamp + timelock[selector];
    }

    modifier timelocked() {
        require(validAt[msg.data] != 0, "BOX: No timelock set");
        require(block.timestamp >= validAt[msg.data], "BOX: Timelock not expired");
        validAt[msg.data] = 0;
        _;
    }

    function revoke(bytes calldata data) external {
        require(msg.sender == guardian, "BOX: Unauthorized, only guardian");
        require(validAt[data] != 0, "BOX: No timelock set");
        validAt[data] = 0;
    }

}
