# Box

A box is an ERC4626 based currency (e.g. USDC) which it can hold and be used to deposit/redeem. It can also invest in others ERC20s called assets. 

## Trust assumptions

Trust assumption on the curator are limited by:
- A slippage control avoid too much slippage vs an oracle for each swap and limiting accumulated slippage over time
- A shutdown mechanism ensure that feeders will not get stuck and will be eventually able to withdraw their funds

Remaining trust assumptions are:
- Assuming the allocator will not manipulate oracles for weak oracles when doing allocations

Deposits are restricted to address call feeders to avoid arbitraging. No liquidity is expected in normal conditions so redeem can't be used for arbitraging.


## Control

- The owner can:
    - Add/remove an Allocator (timelocked)
    - Add/(not remove) a Feeder (timelocked)
    - Change the Guardian (timelocked)
    - Change a new (asset, oracle, backup swapper) (timelocked)
        - oracle and swapper can only be null if no assets in the Box
    - Change the slippage (timelocked)
    - Decrease a timelock (timelocked)
    - Increase a timelock (timelocked because it can increase the timelock of shutdown)
- Feeders can:
    - Deposit if the Box is not shut down
    - Withdraw the available liquidity if vault is not shut down, all assets if shut down
- Allocators can:
    - Allocate liquidity into an asset (subject to slippage constraints)
    - Deallocare liquidity from an asset (subject to slippage constraints)
    - Reallocate from one asset to another (subject to slippage constraints)
- The Guardian can:
    - Revoke a new proposal: adding an asset, changing an oracle, changing the backup swapper, changing the slippage
    - Trigger shutdown the box, which will let the feeder withdraw by deallocating automatically from the assets with a increasing slippage allowance over time

## Swapping mechanic

In normal times, the swapping between assets is done by the Allocator using a callback function. The result is enforced by slippage protection but nothing prevents the alloactor to use all the possible slippage.

When shut down, the swapping can only be done do deallocate from assets using a backup hardcoded immutable swapper.


## Arbitragers protection

One of the biggest risk of the contract related to pricing. Price could be manipulated, or front runned, to deposit in the smart contract when valuation is low (or made low by oracle manipulation) and redeem when valuation is high (or made high by oracle manipulation).

Only whitelisted feeders can deposits into the smart contract mitigating this risk. They can also only withdraw when there is liquidity which is not execpted to be the usual case.


## Emergency exit

In case the owner/allocator are non responsible to replenish the liquidty, any holder of Box can call the `unbox()` function returning their share of underlying token.

The issue is that it doesn't work if hold by Vault V2 as it calls redeem. The solution here is to allow anyone to deposit USDC, so a user can deposit USDC, call forceReallocateToIdle on the Vault V2 and get out and he can unbox the Box tokens he got (yes, it is convoluted already).
