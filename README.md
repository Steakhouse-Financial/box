# Box

**Box** is an ERC-4626–compatible vault contract designed to manage assets, allocations, and funding in a modular way.  

It allows to:  
- Hold an **underlying asset** (e.g. USDC) used for `deposit` and `redeem`.  
- `allocate` / `deallocate` / `reallocate` liquidity between the underlying asset and whitelisted tokens.  
- `pledge` / `depledge` assets as collateral and `borrow` / `repay` through funding modules.  

⚠️ Box is **not intended to be used standalone**. It is expected to be integrated via a front-end smart contract.  


## Trust Assumptions

### Curator checks and limits
- **Slippage controls**: Every swap is bounded by an oracle-based slippage check. Cumulative slippage over time is also limited.  
- **Shutdown mechanism**: In case of curator misbehavior, anyone can trigger a `shutdown`. This ensures depositors can eventually withdraw through a permissionless `winddown` process.  

### Remaining assumptions
- Allocators will not manipulate weak oracles during allocations.  
- Guardian will veto malicious curator proposals.  
- Allocators will not deliberately set excessive LTVs that harm depositors.  

⚠️ Deposits are restricted to whitelisted **feeder** addresses to prevent arbitrage. Liquidity is not expected under normal conditions, so that `redeem` can't be used as an arbitrage path.  

## Roles & Controls

The Box contract define the following roles:

### Owner
Each Box has one `owner`, it can:
- Set the **curator**
- Transfer ownership of the Box
- Set the skim recipient

The `owner`is a critical role that should be strongly protected.

### Curator
Each Box has one `curator`, it can:  
- Add/remove an **allocator**  
- Add/remove a **feeder** (timelocked)
- Set the **guardian**  (timelocked, not during wind-down)
- Trigger a `shutdown` process
- Add new tokens and their oracles (timelocked)
- Remove a token
- Change an existing token’s oracle (timelocked, not during wind-down)
- Add funding modules and facilities (timelocked)
- Add collateral and debt tokens for funding mdoules (timelocked)
- Remove funding modules, facilities, debt and collateral tokens
- Set max slippage (timelocked)
- Increase timelocks
- Decrease timelocks (timelocked)
- `revoke`a timelocked action (cancel it before execution)  

The `curator` is an important role that should be strongly protected, but all critical actions can be revoked during a timelock and a compromised curator can be removed by the `owner`.

### Feeders
Direct depositor in the Box are given the role `feeder`
- `deposit` while the Box is active (not in `shutdown`)  
- `withdraw` available liquidity in normal mode, or all assets during `winddown`  

Notice that a Box holder don't need to be a `feeder` to redeem and transfer a Box token.

### Allocators (when not in `winddown` mode)
- `allocate` from the underlying asset to whitelisted tokens (within slippage constraints)
- `deallocate` from whitelisted tokens to the underlying asset (within slippage constraints)
- `reallocate` from whitelisted tokens to another whitelisted tokens (within slippage constraints)
- `pledge`/`depledge` the underlying asset or a token as collateral on a funding module / facility
- `borrow`/`repay` the underlying asset or a token as debt on a funding module / facility
- Call the `flash` function with a callback to execute a flashloan-enabled operation

### Guardian
- `revoke`a timelocked action from the curator (cancel it before execution)  
- Trigger a `shutdown` process
- `recover` from a shutdown back to normal mode (only before `winddown` begins)  
- Change an existing token’s oracle  (only during `winddown`)

### Anyone (during `winddown`)
- `repay` debt
- `depledge` collateral
- `deallocate` from tokens without a debt balance
- `allocate` to a token with a debt balance (so the debt balance can be repaid)

## Funding Modules

The curator can add modular funding integrations (`IFunding`).  
Supported modules: **Morpho Blue**, **Aave v3** and **Aave v4**.  

- Each module instance belongs to a single Box (constructor parameter).  
- Only whitelisted tokens from the parent Box can be used as collateral/debt.  
- Only empty modules (no facilities, collateral, or debt tokens) can be added.  
- Modules are chain-agnostic: every protocol address (pool, Spoke) is a constructor argument, so a module can be deployed on any chain where its protocol is deployed. Each module has a factory in `src/factories/` that records the modules it created (`isFundingX`) and emits a creation event.  
- `nav` values positions with the Box oracles (collateral rounded down, debt rounded up, floored at 0 because there is no recourse beyond the collateral) and ignores tokens held idle by the module. `ltv` uses the protocol's own pricing and is only used by the module's post-action guard.  
- Views never revert for tokens or `facilityData` the module does not know (they return 0), so a winddown `deallocate` cannot be blocked by an attached module.  

### Morpho Module
- `facilityData` encodes Morpho Blue market parameters.  
- Each module instance is tied to a Morpho instance address.  
- Borrowing is capped by a max LTV relative to the market’s LLTV.  

### Aave Module
- `facilityData` is always empty (`""`).  
- Each module is tied to an Aave pool address and a given `eMode` parameter.  
- `debtBalance` / `collateralBalance` return 0 for tokens that are not listed on the Aave pool (instead of reverting).  
- `addCollateralToken` / `addDebtToken` only accept listed Aave reserves (non-zero aToken / variable debt token), so an unlisted token can no longer make `nav` revert.  

### Aave v4 Module (`FundingAaveV4`)
- One module instance = one position (the module address) on one Aave v4 Spoke. Use one module per Spoke.  
- `facilityData` is always empty (`""`); any other value is rejected.  
- Constructor / factory: `createFundingAaveV4(owner, spoke, reserveIds, lltvCap)`.  
  - `reserveIds`: the Spoke reserves the module may use. Their underlying tokens must be pairwise distinct: when a Spoke lists the same token several times (reserves backed by different Hubs), this list selects which reserve the token uses.  
  - `lltvCap`: fraction (1e18 = 100%) of the Spoke's own borrowing limit the module may use, in `(0, 1e18]`.  
- A collateral token must be the underlying of a configured reserve with a non-zero collateral factor; a debt token must be the underlying of a configured borrowable reserve.  
- `pledge` supplies and enables the reserve as collateral. `borrow` and `depledge` deliver exactly the requested amount to the Box and are followed by a health guard: `healthFactor >= ceil(1e36 / lltvCap)`, i.e. `ltv <= avgCollateralFactor * lltvCap / 1e18` (Aave v4 lets a position borrow down to a health factor of exactly 1).  
- `debtBalance` includes the Aave v4 premium debt, so repaying `debtBalance` closes the debt with no dust; unused tokens are returned to the Box.  

## Arbitrage Protection

Box mitigates oracle manipulation and front-running risks by:  
- Restricting deposits to **whitelisted feeders**.  
- Limiting withdrawals to available liquidity.  

This prevents attackers from depositing at artificially low valuations and redeeming at artificially high valuations.  

## Lifecycle

A Box moves through three possible states:  

1. **Normal mode**  
   - Deposits, withdrawals, allocations, pledges, and borrowing are active.  

2. **Shutdown mode**  
   - Triggered by the guardian (or curator).  
   - New deposits are blocked.  
   - The guardian may restore normal mode *only before wind-down begins*.  

3. **Winddown mode**  
   - Permissionless recovery process.  
   - Increasing slippage tolerance allows full exit for all feeders.  
   - Anyone may help unwind positions and repay debt.  
