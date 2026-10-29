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
| F-2 | High | The pause guardian can replace the oracle | `test_F2_*` |
| F-3 | High | The oracle answer has no sign, age or decimals check | `test_F3_*` |
| F-5 | High | Unbounded risk parameters can freeze the market | `test_F5_*`, `test/Freeze.t.sol` |
| F-4 | Medium | `withdrawCollateral` checks health on stale debt | `test_F4_*` |
| F-6 | Low | Anyone can initialize the bare implementation | `test_F6_*` |

IDs follow the order I found them. Every test in `test/Findings.t.sol` fails on the baseline commit and passes here. `test/Invariant.t.sol` adds a liquidation payout invariant that also catches F-1, plus solvency, liveness and bookkeeping checks.

### F-1: Liquidation ignores the collateral price
**Impact.** `seizeAmount = repayAmount * liquidationIncentive / FACTOR` treats a base amount as a collateral amount. Anyone can strip any unhealthy position and the debt left behind falls on suppliers, which makes it Critical.
**Exploit.** Bob posts 10 WETH at 2,000, borrows 15,000, and WETH dips to 1,800. A liquidator repays 1,000 and takes all 10 WETH, worth 18,000, while Bob still owes 14,000 with no collateral.
**Fix.** The seize is now `repayAmount * liquidationIncentive / price`. If that exceeds the balance, the liquidator gets the whole balance and pays only `ceil(seize * price / incentive)`.

### F-2: The pause guardian can choose the price feed
**Impact.** `setOracle` is `onlyGuardian`, but the README limits the warm, widely held guardian key to stopping the market. It is High rather than Critical only because it needs that key.
**Exploit.** The guardian points the market at a feed quoting 1,000,000 per WETH, posts 1 WETH and borrows the whole pool.
**Fix.** `setOracle` is now `onlyAdmin`, same selector.

### F-3: Oracle answer is trusted blindly
**Impact.** `getPrice` returns `uint256(answer)`, so a negative answer wraps to a huge number and a frozen or mis-scaled feed misprices every position. One feed fault can cost the whole pool with no key needed, hence High.
**Exploit.** The feed reports -1 and Bob borrows all 100,000 of liquidity against 1 wei of WETH. Or the feed freezes at 2,000 while WETH falls, and a day later Bob still borrows 16,000 against 10 WETH.
**Fix.** `getPrice` requires `answer > 0` and an answer no older than `MAX_PRICE_AGE` (a one hour heartbeat plus 15 minutes). `setOracle` and `initialize` require `decimals() == 18`.

### F-5: Risk parameters are unbounded
**Impact.** `setParameters` and `initialize` accept any rate and incentive, so one wrong proposal can wipe out borrowers and freeze the market. A privileged role acting within its powers by mistake is High on the brief's scale.
**Exploit.** Governance passes `0.05e18` per second meaning 5% a year, so each 12 second accrual adds 60% to every debt. `test/Freeze.t.sol` shows the index overflowing after about 100 accruals, after which `setParameters` and even `repay` revert until an upgrade.
**Fix.** The rate is capped at 100% APR, the incentive at 1.5x, and `collateralFactor * liquidationIncentive` must stay below 1 so a liquidation never leaves a position less healthy. Both functions share `_checkParameters`.

### F-4: Collateral withdrawal does not accrue first
**Impact.** `withdrawCollateral` runs `isHealthy` on the last stored borrow index, so a borrower can leave a position that is already underwater. The gap is only the interest since the last accrual, which keeps it at Medium.
**Exploit.** Bob borrows 15,000 against 10 WETH and the market sits idle for a year, so he really owes 15,750. He withdraws 0.6 WETH, leaving 15,040 of borrowing power, and it passes because the check still reads 15,000.
**Fix.** `withdrawCollateral` calls `accrueInterest()` first, as `borrow` and `liquidate` already do.

### F-6: Implementation can be initialized
**Impact.** Anyone can call `initialize` on the implementation and become its admin. It has no `delegatecall` or `selfdestruct`, so I rate it Low.
**Exploit.** Anyone calls `initialize` directly on the implementation address.
**Fix.** A constructor sets `_initialized` in the implementation's own storage, which the proxy never reads.

### Found, not fixed
- Bad debt is never written off (Medium). Debt left after a capped seize keeps accruing to suppliers, so the last ones out take the loss. Fixing it needs a reserve or a `baseSupplyIndex` write-down, which is a design decision and a new slot.
- Pause blocks `liquidate` and `supplyCollateral` while interest runs (Medium, unsure). I would let top-ups through and ask the team whether liquidations should stop during an oracle incident.
- Token decimals are never read and fee-on-transfer tokens would be over-credited (Medium, latent). Fine for WETH, but the next listing needs it.
- Rounding favours users (Low). `borrow` and `withdraw` round principal down, and `accrueInterest` rounds the borrow index down while crediting suppliers in full, a drift of a few thousand wei the solvency invariant tolerates.
- `setAdmin` does not move the proxy admin, transfer return values are ignored, and the guardian can unpause (Low).

### Upgrade safety
Storage layout matches the baseline exactly (19 variables in 18 slots) and all 38 selectors are unchanged, because every fix is logic or a constant. `test/Upgrade.t.sol` upgrades a live copy of the baseline holding balances and interest, checks every role, index, total and balance, and shows F-1 fixed on the upgraded proxy.

## Scope note
- Prioritised: liquidation and pricing, then accrual order and admin bounds, all shippable as a plain `upgradeTo`.
- Left out: bad debt, pause semantics and rounding, which need a design decision or new storage.
- Unsure: the 75 minute price age is my guess at the live heartbeat, and stale feeds now block liquidations, so I would check both first.
- AI tooling: Claude Code ran two audit passes and wrote the tests and fixes while I read each diff. I rejected its idea to scale every price read by `decimals()` and check once when the feed is wired.
