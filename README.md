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
Supported modules: **Morpho Blue**, **Aave v3**, **Aave v4**, **Morpho Midnight** and **Euler v2**.  

- Each module instance belongs to a single Box (constructor parameter).  
- Only whitelisted tokens from the parent Box can be used as collateral/debt.  
- Only empty modules (no facilities, collateral, or debt tokens) can be added.  
- Modules are chain-agnostic: every protocol address (pool, Spoke, Midnight, EVC) is a constructor argument, so a module can be deployed on any chain where its protocol is deployed. Each module has a factory in `src/factories/` that records the modules it created (`isFundingX`) and emits a creation event.  
- `nav` values positions with the Box oracles (collateral rounded down, debt rounded up, floored at 0 because there is no recourse beyond the collateral) and ignores tokens held idle by the module. `ltv` uses the protocol's own pricing. Every module checks it in a post-action guard after `borrow` and `depledge`.  
- The token-only views `debtBalance(token)` and `collateralBalance(token)` return 0 (and never revert) for tokens the module does not use, so a winddown `deallocate` cannot be blocked by an attached module.  
- The Aave v4, Midnight and Euler modules also return 0 instead of reverting from the per-facility views (`debtBalance(facilityData, token)`, `collateralBalance(facilityData, token)`, `ltv(facilityData)`) for tokens the facility does not use and for unregistered `facilityData`. The Morpho Blue module's per-facility views revert on a wrong token or malformed `facilityData`, and the Aave v3 module's per-facility views ignore `facilityData`.  

### Morpho Module
- `facilityData` encodes Morpho Blue market parameters.  
- Each module instance is tied to a Morpho instance address.  
- Borrowing is capped by a max LTV relative to the market’s LLTV.  

### Aave Module
- `facilityData` is always empty (`""`).  
- Each module is tied to an Aave pool address and a given `eMode` parameter.  
- Constructor / factory: `createFundingAave(owner, pool, eMode, lltvCap)`.  
  - `lltvCap`: fraction (1e18 = 100%) of the Aave liquidation threshold the module may use, in `(0, 1e18]`.  
- `borrow` and `depledge` are followed by a health guard: `healthFactor >= ceil(1e36 / lltvCap)`, i.e. `ltv <= liquidationThreshold * lltvCap / 1e18` (Aave v3 on its own lets a position withdraw collateral down to a health factor of exactly 1).  
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

### Morpho Midnight Module (`FundingMidnight`)
Morpho Midnight is fixed-rate, fixed-term lending: each maturity is a separate market, and borrowing sells "units" (face value due at maturity) to lenders at a price below 1.  
- Constructor / factory: `createFundingMidnight(owner, midnight, lltvCap)`. `lltvCap` is the fraction (1e18 = 100%) of the market LLTV the module may use, in `(0, 1e18]`.  
- `facilityData = abi.encode(Market market, uint256 collateralIndex, uint256 maxBorrowApr)` (three top-level values, canonical encoding only; see `encodeFacilityData`).  
  - `market`: the Midnight market struct. It must belong to this Midnight contract and chain, already exist on Midnight and mature in the future.  
  - `collateralIndex`: index of the collateral in `market.collateralParams`. The facility's debt token is `market.loanToken` and its collateral token is `market.collateralParams[collateralIndex].token`; both must already be registered module tokens.  
  - `maxBorrowApr`: highest simple annual rate (1e18 = 100%, 365-day year) the module accepts when borrowing, in `(0, 1e18]`. It is set by the curator through the timelocked `addFacility`.  
  - Midnight keeps one position per market and address, so the module accepts at most one facility per market.  
- Borrowing is a two-step flow, because `IFunding.borrow` carries no lender offer:  
  1. An allocator calls `stageBorrow(facilityData, fills, validUntil)` on the module (allocator-only). Each `OfferFill` holds a lender bid, the `ratifierData` passed to Midnight's `take`, and `maxUnits` (0 skips the fill, `type(uint256).max` means no cap). A new staging replaces the previous one for that facility.  
  2. The allocator calls `Box.borrow(module, facilityData, loanToken, amount)`. The module consumes the staging: it tries the fills in order and skips (does not revert on) offers that are not bids of this market, were made by the module itself (`maker == module`), are outside their validity window, have no capacity left, whose price net of the settlement fee is below the floor `1 / (1 + maxBorrowApr * timeToMaturity / 365 days)`, or whose `take` reverts. Proceeds go straight to the Box. The call reverts if the Box received less than `amount`, if the staging is expired (`block.timestamp > validUntil`) or was staged by an address that is no longer an allocator, if the market is matured, or if the LTV guard is broken. The staging is deleted whatever the number of fills used.  
- `debtBalance` is the face value owed at maturity (the exact amount that closes the loan). Repayment is at face value only; unused tokens are returned to the Box. Repay, depledge, views and `nav` never read the staging, so it can never block a winddown.  
- `nav` values the debt at its accreted value: linear from the proceeds at borrow time to the face value at maturity (`debtValue(facilityData)`). A borrow therefore does not move `nav`, and the implied interest is recognised over the term.  
- Guard after `borrow` and `depledge`: `ltv <= lltv * lltvCap / 1e18`, where `ltv` is face debt over collateral value at the market's own Midnight oracle and `lltv` is the LLTV of the facility's collateral.  
- Maturity views for keepers: `maturity(facilityData)`, `isMatured(facilityData)` (true from the maturity timestamp) and `marketId(facilityData)`.  
- Before maturity, a position can be liquidated when its debt exceeds the LLTV-weighted collateral value at the Midnight oracle.  
- ⚠️ Maturity risk: there is no grace period. Borrowing closes at maturity, and one second after maturity anyone can liquidate the whole position, even a healthy one, with a liquidation bonus that ramps up linearly over the following hour. Allocators (or anyone during winddown) must repay before maturity.  

### Euler v2 Module (`FundingEuler`)
- Constructor / factory: `createFundingEuler(owner, evc, ltvCap)`. `evc` is the Ethereum Vault Connector of the chain; `ltvCap` is the fraction (1e18 = 100%) of the Euler borrow LTV the module may use, in `(0, 1e18]`.  
- `facilityData = abi.encode(address collateralVault, address borrowVault)`: exactly 64 bytes, two distinct non-zero EVK vaults of this EVC (see `encodeFacilityData`). The borrow vault must accept the collateral vault (`LTVBorrow > 0`), and both vault assets must already be registered module tokens.  
- Each facility uses its own EVC sub-account (`address(module) ^ id`, id in 1..255, the lowest free id at registration; see `subAccount(facilityData)`), because an EVC account can only have one controller (debt vault). The module address itself (id 0) never holds positions. `addFacility` reverts with `TooManyFacilities` when all 255 ids are taken.  
- Removing a facility frees its id, unless the sub-account still holds collateral-vault shares worth 0 assets (possible after Euler socialises bad debt, and anyone can donate such shares). Euler refuses to redeem them, so they stay on the sub-account and its id is retired for good (never assigned again), which lowers the 255-facility budget.  
- Collateral is held as collateral-vault shares. `borrow` and `depledge` deliver exactly the requested amount to the Box and are followed by a guard: `ltv <= LTVBorrow * 1e14 * ltvCap / 1e18` (Euler's `LTVBorrow` is on a 1e4 scale), where `ltv` is the raw debt/collateral value ratio (1e18 scale) at the borrow vault's oracle. Repaying `debtBalance` closes the debt and releases the controller.  
- ⚠️ Euler's balance views revert while a vault is in the middle of an operation (for example inside its flash-loan callback), so `nav` and the Box `totalAssets` revert in that window instead of returning a wrong value. Do not source flash liquidity from a vault used by a facility of the same Box.  

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
