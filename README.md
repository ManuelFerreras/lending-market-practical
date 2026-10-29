# LendingMarket

Single-collateral money market. Suppliers deposit the base asset and earn interest, borrowers post collateral and draw the base asset against it, and positions that fall below their borrowing power can be liquidated.

## Running it

The project is self-contained. `forge-std` is vendored under `lib/`, so no network access or `forge install` is needed.

```bash
forge build
forge test
forge test -vvv --match-test <name>     # a single test, with traces
```

Requires Foundry. If you do not have it: `curl -L https://foundry.paradigm.xyz | bash && foundryup`

## Layout

```
src/
  LendingMarket.sol                 the implementation, and the only file you need to change
  TransparentUpgradeableProxy.sol   the proxy the market is deployed behind
  interfaces/                       IERC20, IPriceOracle (Chainlink-style aggregator)
  mocks/                            test doubles for the base asset, collateral and oracle
script/
  Deploy.s.sol                      staging deployment, mirrors the production topology
test/
  LendingMarket.t.sol               the suite the market ships with today
```

## How it works

**Accounting.** Supplier and borrower balances are stored as *principal* and scaled by two global indices, `baseSupplyIndex` and `baseBorrowIndex`. `accrueInterest()` advances both to the current timestamp. Present value is `principal * index / 1e18`, so a balance grows without anyone touching per-account storage.

**Scaling.** Everything is 1e18 fixed point unless stated otherwise. The oracle quotes the collateral in base-asset terms, also 1e18. So with WETH at 2,000 base, `getPrice()` returns `2000e18`.

**Borrowing power.** `collateralBalance * price * collateralFactor`, all 1e18 scaled. A position is healthy while its borrowing power covers its debt. `isHealthy()` is the single source of truth for this, and it is checked on any path that increases risk.

**Liquidation.** Once a position is unhealthy, anyone may repay part of its debt and receive collateral in exchange, plus the liquidation incentive. The incentive is 1e18 scaled and always at or above par, so `1.10e18` means the liquidator receives 110% of what they repaid, valued in collateral.

**Deployment.** The market is an implementation behind a `TransparentUpgradeableProxy`. All market state lives in the proxy's storage, which is why any change you make has to be layout-compatible with what is already deployed. The admin owns upgrades and risk parameters. A separate pause guardian exists so the market can be stopped quickly without reaching for the admin key.

## Roles

| Role | Held by | Remit |
|---|---|---|
| `admin` | governance timelock | upgrades, risk parameters, wiring |
| `pauseGuardian` | operations multisig | stopping the market in an incident |

The split matters. The guardian key is warmer and held by more people than the admin key, so anything the guardian can reach should be limited to stopping the market, not changing how it prices or values anything.

## Listed markets

See `script/Deploy.s.sol` for the current staging configuration.

## Findings

| ID | Severity | What breaks | Test |
|----|----------|-------------|------|
| F-1 | Critical | `liquidate` seizes collateral without converting by price | `test_F1_*`, `testFuzz_liquidation_*` |
| F-2 | High | The pause guardian can replace the oracle | `test_F2_guardian_cannot_replace_the_oracle` |
| F-3 | High | The oracle answer is used with no sign, age or decimals check | `test_F3_*` |
| F-4 | Medium | `withdrawCollateral` checks health on stale debt | `test_F4_withdraw_collateral_checks_health_on_accrued_debt` |
| F-5 | High | Risk parameters have no bounds, so one bad value can freeze the market | `test_F5_*` |
| F-6 | Low | The bare implementation can be initialized by anyone | `test_F6_implementation_cannot_be_initialized` |

The finding tests are in `test/Findings.t.sol`. Each one fails on the baseline commit and passes here. `test/Invariant.t.sol` adds an accounting invariant over random supply, borrow, liquidation, price and time moves.

### F-1: Liquidation ignores the collateral price
**Impact.** `seizeAmount = repayAmount * liquidationIncentive / FACTOR` treats a base amount as a collateral amount, so any liquidation can take the whole collateral balance. Anyone can do it to any unhealthy position and the debt left behind falls on suppliers, so Critical.
**Exploit.** Bob posts 10 WETH at 2,000, borrows 15,000, and WETH dips to 1,800 (borrowing power 14,400). A liquidator repays 1,000 and takes all 10 WETH, worth 18,000, while Bob still owes 14,000 with no collateral.
**Fix.** The seize is now `repayAmount * liquidationIncentive / price`. If that exceeds the balance, the liquidator gets the whole balance and pays only `ceil(seize * price / incentive)`.

### F-2: The pause guardian can choose the price feed
**Impact.** `setOracle` is `onlyGuardian`, but the README limits the warm, widely held guardian key to stopping the market. It is High rather than Critical only because it needs that key.
**Exploit.** The guardian points the market at a feed quoting 1,000,000 per WETH, posts 1 WETH and borrows the whole pool.
**Fix.** `setOracle` is now `onlyAdmin`, same selector.

### F-3: Oracle answer is trusted blindly
**Impact.** `getPrice` returns `uint256(answer)` with no check on sign, age or decimals, so a negative answer wraps to a huge number and a frozen or mis-scaled feed misprices every position. Any feed fault becomes a total loss of liquidity or collateral, so High.
**Exploit.** The feed reports -1 and Bob borrows all 100,000 of liquidity against 1 wei of WETH. Or the feed freezes at 2,000 while WETH falls, and a day later Bob still borrows 16,000 against 10 WETH.
**Fix.** `getPrice` requires `answer > 0` and an answer younger than `MAX_PRICE_AGE`, a constant set to a one hour heartbeat plus 15 minutes. `setOracle` and `initialize` require `decimals() == 18`, the scale the market is specified in.

### F-4: Collateral withdrawal does not accrue first
**Impact.** `withdrawCollateral` runs `isHealthy` on the last stored borrow index, so a borrower can pull collateral and leave a position that is already underwater. Medium, because the gap is only the interest since the last accrual.
**Exploit.** Bob borrows 15,000 against 10 WETH (limit 16,000) and the market sits idle for a year, so he really owes 15,750. He withdraws 0.6 WETH, leaving 15,040 of borrowing power, and it passes because the check still reads 15,000.
**Fix.** `withdrawCollateral` calls `accrueInterest()` before the health check, as `borrow` and `liquidate` already do.

### F-5: Risk parameters are unbounded
**Impact.** `setParameters` and `initialize` accept any rate, any incentive and any collateral factor and incentive pair, so one wrong proposal can wipe out borrowers and freeze the market. That is a privileged role acting within its powers by mistake, which is High on the brief's scale.
**Exploit.** Governance means 5% a year but passes `0.05e18` per second, so each 12 second accrual adds 60% to every debt and every borrower is liquidatable within a few blocks. I measured an overflow after about 100 accruals, after which every accruing function reverts, `setParameters` included, and only an upgrade recovers.
**Fix.** The rate is capped at 100% APR, the incentive at 1.5x, and `collateralFactor * liquidationIncentive` must stay below 1, because at or above 1 each liquidation leaves the position less healthy. Both functions share one `_checkParameters`.

### F-6: Implementation can be initialized
**Impact.** The implementation is deployed bare, so anyone can call `initialize` on it and become its admin. Nothing is at risk today because it has no `delegatecall` or `selfdestruct`, so Low.
**Exploit.** Anyone calls `initialize` directly on the implementation address.
**Fix.** A constructor sets `_initialized` in the implementation's own storage, which the proxy never reads.

### Found, not fixed
- Bad debt is never written off (Medium). Debt left after a capped seize stays in `totalBorrowPrincipal` and keeps accruing to suppliers, so the last suppliers out take the loss. The fix needs a design choice (a reserve, or a write-down of `baseSupplyIndex`) and a new slot after `_initialized`.
- Pause blocks `liquidate` and `supplyCollateral` while interest runs (Medium, unsure). I would let top-ups through and ask the team whether liquidations should stop during an oracle incident.
- `borrow` and `withdraw` round principal down, in the user's favour (Low). The gain is below gas cost at 18 decimals, and the fix (round up, and let a full repay clear the whole principal) needs care to leave no dust.
- Token assumptions (Medium, latent). Token decimals are never read and a fee-on-transfer token would be over-credited, which is fine for WETH but needs a check at the next listing.
- Transfer return values are ignored and `setAdmin` is one step with no event (Low).
- There is no gap between the borrow limit and the liquidation threshold (Low, design). A position borrowed to the limit is liquidatable a second later.

### Upgrade safety
No state variable was added, moved or retyped. `forge inspect LendingMarket storageLayout` matches the baseline exactly (19 variables in 18 slots) and all 38 selectors are unchanged. `test/Upgrade.t.sol` runs the baseline behind the proxy with a supplier, a borrower and 30 days of interest, upgrades as the proxy admin, checks every role, parameter, index, total and balance, and shows the F-1 liquidation now seizes 0.611 WETH. Before the upgrade I would confirm the live feed reports 18 decimals and updates within 75 minutes, and check past `Liquidate` events for borrowers who are owed restitution.

## Scope note
- Prioritised: liquidation and pricing first, then accrual order and admin bounds, all as logic or constants so it ships as a plain `upgradeTo`.
- Left out on purpose: bad debt write-down, pause semantics and rounding, which need a design decision or new storage.
- Unsure: the 75 minute price age is a guess at the production heartbeat, and `isHealthy` now reverts on a stale feed, so liquidation bots must handle that.
- AI tooling: I worked with Claude Code, which ran two parallel audit passes, wrote each test and fix and committed as it went while I read the diffs. It rated F-5 High, I cut it to Medium, then restored High after we measured the overflow and I reread the brief's scale.
