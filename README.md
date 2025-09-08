# Box

A box is an ERC4626-compatable contract that is allows to:
- Hold an underlying asset (e.g. USDC) which is also used to `deposit`/`redeem`. 
- `allocate`/`deallocate`/`reallocate` from the underlying asset to whitelisted tokens
- Can use its assets to be `pledge`/`depledge`to be able to `borrow`/`repay` against those using funding modules

Box is not intended to be used as stand alone. It more likely requires a front end smart contract.

## Trust assumptions

Trust assumptions on the curator are limited by:
- A slippage control avoid too much slippage vs an oracle for each swap and limiting accumulated slippage over time
- A `shutdown` mechanism ensure that feeders will not get stuck and will be eventually able to withdraw their funds by allowing `windown`of the box in a permissionless way

Remaining trust assumptions are:
- Assuming the allocator will not manipulate oracles for weak oracles when doing allocations
- Assuming some depositors in the vault will veto bad proposal by the curator

Deposits are restricted to address call feeders to avoid arbitraging. No liquidity is expected in normal conditions so redeem can't be used for arbitraging.

## Control

- The owner can:
    - Add/remove an `allocator` (timelocked)
    - Add/(not remove) a `feeder` (timelocked)
    - Change the `guardian` (timelocked)
    - Add a new `token` and its `oracle` (timelocked)
    - Change an existing `token` `oracle` (timelocked)
    - Add funding module (timelocked)
    - Add funding facility (timelocked)
    - Add debt token, token that can be used in `borrow`/`repay` (timelocked)
    - Add collateral token, token that can be used in `pledge`/`depledge` (timelocked)
    - Change the `slippage` (timelocked)
    - Decrease a timelock (timelocked)
    - Increase a timelock (timelocked because it can increase the timelock of shutdown)
- Feeders can:
    - Deposit if the Box is not `shutdown`
    - Withdraw the available liquidity if vault is not `winddown`, all assets otherwise
- Allocators can (outside of `winddown` mode):
    - Allocate liquidity into an asset (subject to slippage constraints)
    - Deallocare liquidity from an asset (subject to slippage constraints)
    - Reallocate from one asset to another (subject to slippage constraints)
    - Pledge/depledge a collateral
    - Borrow/repay against a collateral
- The Guardian can:
    - Revoke a new proposal: adding an asset, changing an oracle, changing the backup swapper, changing the slippage
    - Trigger `shutdown` the box, which will let the feeder withdraw by deallocating automatically from the assets with a increasing slippage allowance over time
    - When the box is in a shutdown mode, the guardian can `recover` from it
- During `winddown`mode, anyone can:
    - Repay a debt
    - Deallocate from a token if there is not debt in this token
    - Depledge a token


## Funding

The `curator` can add funding modules (`IFunding`)

## Arbitragers protection

One of the biggest risk of the contract related to pricing. Price could be manipulated, or front runned, to deposit in the smart contract when valuation is low (or made low by oracle manipulation) and redeem when valuation is high (or made high by oracle manipulation).

Only whitelisted feeders can deposits into the smart contract mitigating this risk. They can also only `withdraw` up to the available liquidity, on which there is no requirement.


## Box lifecycle

### Normal operations

### Shutdown mode

When the `guardian` triggers a shutdown, 

### Winddown mode

In case the owner/allocator are non responsible to replenish the liquidty, any holder of Box can call the `unbox()` function returning their share of underlying token.

The issue is that it doesn't work if hold by Vault V2 as it calls redeem. The solution here is to allow anyone to deposit USDC, so a user can deposit USDC, call forceReallocateToIdle on the Vault V2 and get out and he can unbox the Box tokens he got (yes, it is convoluted already).


