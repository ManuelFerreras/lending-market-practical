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
| F-5 | High | `setParameters` has no bound on the rate or on cf times incentive | `test_F5_*` |
| F-6 | Low | The bare implementation can be initialized by anyone | `test_F6_implementation_cannot_be_initialized` |

All tests are in `test/Findings.t.sol`. Each one fails on the baseline commit and passes here.

### F-1: Liquidation ignores the collateral price
**Impact.** `seizeAmount = repayAmount * liquidationIncentive / FACTOR` treats a base amount as a collateral amount, so any liquidation takes up to the whole collateral balance. Anyone can do it to any unhealthy position, and the debt left behind lands on suppliers, so I rate it Critical.
**Exploit.** Bob posts 10 WETH at 2,000 and borrows 15,000. WETH dips to 1,800 and his borrowing power falls to 14,400. A liquidator repays 1,000, the formula gives 1,100 WETH, the cap gives 10, and they walk away with 18,000 of collateral while Bob still owes 14,000 with nothing behind it.
**Fix.** `seizeAmount = repayAmount * liquidationIncentive / price`. If that is more than the borrower has, I seize the whole balance and charge only the repay it covers, `ceil(seize * price / incentive)`, so the liquidator never pays for collateral that does not exist.

### F-2: The pause guardian can choose the price feed
**Impact.** `setOracle` is `onlyGuardian`. The README says the guardian key is warmer and held by more people, and must only be able to stop the market. Whoever holds that key can set any price. High, not Critical, because it needs that key.
**Exploit.** The guardian points the market at a feed that reports 1,000,000 per WETH, posts 1 WETH and borrows the whole pool.
**Fix.** `setOracle` is now `onlyAdmin`. Same selector.

### F-3: Oracle answer is trusted blindly
**Impact.** `getPrice` returns `uint256(answer)` with no checks. A negative answer becomes 2^256 - 1, a frozen feed keeps quoting an old price, and a feed with the wrong decimals misprices every position by orders of magnitude. Each case is a total loss of liquidity or collateral if the feed misbehaves, so High.
**Exploit.** The feed reports -1. Bob posts 1 wei of WETH and borrows all 100,000 of liquidity. In the stale case the feed stops at 2,000, a day passes while WETH falls, and Bob still borrows 16,000 against 10 WETH at the frozen price.
**Fix.** `getPrice` requires `answer > 0` and `updatedAt` no older than `MAX_PRICE_AGE` (1 hour, a constant). `setOracle` requires `decimals() == 18`, since the market is specified in 1e18 throughout.

### F-4: Collateral withdrawal does not accrue first
**Impact.** `withdrawCollateral` calls `isHealthy` on the last stored borrow index, so pending interest is ignored. A borrower can pull collateral out and leave a position that is already underwater. Medium, because the gap is limited to interest since the last accrual and it needs a quiet market.
**Exploit.** Bob borrows 15,000 against 10 WETH (limit 16,000). Nobody touches the market for a year, so he really owes 15,750. He withdraws 0.6 WETH, which leaves 15,040 of borrowing power, and it passes because the check still reads 15,000.
**Fix.** `withdrawCollateral` calls `accrueInterest()` before the health check, as `borrow` and `liquidate` already do.

### F-5: Risk parameters are unbounded
**Impact.** `setParameters` accepts any borrow rate and any collateral factor and incentive pair. A single wrong proposal can freeze the market until an upgrade, which is High on the scale in the brief (a privileged role acting within its powers by mistake).
**Exploit.** Governance means 5% a year and passes `0.05e18` per second. Each 12 second accrual grows the borrow index by 60%, and in my test it overflows after 99 accruals, about 20 minutes. From then on `accrueInterest` reverts, so supply, withdraw, borrow, repay and liquidate all revert, and so does `setParameters`, which accrues first. Separately, with a 0.95 factor and a 1.10 incentive, every liquidation cuts borrowing power by 1.045 per 1.00 of debt repaid, so liquidations push positions into bad debt.
**Fix.** The rate is capped at `MAX_BORROW_RATE` (100% APR per second, a constant) and `collateralFactor * liquidationIncentive` must stay below 1e36.

### F-6: Implementation can be initialized
**Impact.** The implementation is deployed bare, so anyone can call `initialize` on it and become its admin. There is no `delegatecall` or `selfdestruct` in it today, so nothing is at risk. Low, hygiene for future versions.
**Exploit.** Anyone calls `initialize` on the implementation address with themselves as admin.
**Fix.** A constructor sets `_initialized` on the implementation's own storage. The proxy's storage is untouched, so the proxy keeps initializing through `initialize`.

### Found, not fixed
- Bad debt is never written off (Medium). When a seize hits the cap, the leftover debt stays in `totalBorrowPrincipal` and suppliers keep accruing interest on it, so the last suppliers to withdraw take the whole loss. Fixing it needs a design choice (a reserve, or a write-down of `baseSupplyIndex` when collateral reaches zero) and a new storage slot appended after `_initialized`. I would not ship that without a spec.
- Pause blocks `liquidate` and `supplyCollateral` while interest keeps running (Medium, unsure). Borrowers cannot top up and liquidators cannot act, so positions decay during a pause and get liquidated as soon as it lifts. Blocking liquidations during an oracle incident can be intended, so I would ask the team before changing it. I would allow `supplyCollateral` while paused either way.
- Rounding on `borrow` and `withdraw` favours the user (Low). Principal rounds down, so once the index is above 1e18 `borrow(1)` records no debt. Gas costs more than the gain with an 18 decimal base. The fix is to round those up and let a full repay clear the whole principal.
- Token transfer return values are ignored (Low). Fine for the listed tokens. A token that returns false would need a safe transfer wrapper.
- There is no gap between the borrow limit and the liquidation threshold (Low, design). A position borrowed to the limit is liquidatable one second later.

### Upgrade safety
Every change is logic or a constant, so no state variable was added, removed or moved. `forge inspect LendingMarket storageLayout` is identical to the baseline (18 variables, same slots and offsets), and all 38 baseline selectors are still present and unchanged. `test/Upgrade.t.sol` deploys the baseline contract (`test/legacy/LendingMarketV1.sol`, with only the contract name and import paths changed) behind the proxy, builds up a supplier, a borrower and 30 days of interest, upgrades as the proxy admin, and checks that every role, parameter, index, total and balance survives. It then shows that `initialize` stays locked on the proxy and that the F-1 liquidation now seizes 0.611 WETH instead of everything. No migration is needed. Before upgrading I would check two things on the live market. The wired feed must report 18 decimals and update within an hour, because the decimals check only runs in `setOracle` and the new age check would otherwise block borrowing and liquidations. Past `Liquidate` events should also be checked for seizures above `repaid * incentive / price`, since those borrowers are owed restitution.

## Scope note
- Prioritised: the paths that move value on someone else's position (liquidation) and everything that sets the price, then accrual ordering and admin bounds. Each fix is logic or constants only, so it ships as a plain `upgradeTo` with no migration.
- Left out on purpose: bad debt write-down, pause semantics and rounding direction. They need a design decision or new storage, and I described each above.
- Unsure: `MAX_PRICE_AGE` of 1 hour is my guess at the production heartbeat. I would read the live feed's heartbeat before shipping, because a check stricter than the feed would block liquidations.
- AI tooling: I worked with Claude Code. It ran two audit passes in parallel, one on the math and one on access control and liveness, wrote each test and fix, and I read every diff. One pass rated F-5 High. I first cut it to Medium as a governance error, then put it back to High after we measured the overflow at 99 accruals and I reread the brief's scale. I rejected its idea to scale by `decimals()` on every price read and check once in `setOracle` instead.
