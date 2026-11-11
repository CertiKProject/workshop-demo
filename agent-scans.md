## Code: 

https://github.com/CertiKProject/distributor-demo/blob/main/src/LiquidityRewardsDistributor.sol

## Basic Prompt

```txt
[LiquidityRewardsDistributor.sol](src/LiquidityRewardsDistributor.sol)  
Review the scoped contracts for exploitable flaws.
Report file/function, root cause, preconditions, impact, and reproduction steps.
Separate unverified hypotheses.Do not modify code and write new files. 
```

## gpt-6.1-sol-raw

### Prompt
```txt
[LiquidityRewardsDistributor.sol](src/LiquidityRewardsDistributor.sol)  
Review the scoped contracts for exploitable flaws.
Report file/function, root cause, preconditions, impact, and reproduction steps.
Separate unverified hypotheses.Do not modify code and write new files. 

PLEASE DON'T USE ANY MCP/SKILLS in the local machine.
```

### Confirmed findings

**F-01 — Public refresh can erase accrued rewards**

- **Location:** [`fundDistribution`](src/LiquidityRewardsDistributor.sol:79), [`refreshPosition`](src/LiquidityRewardsDistributor.sol:102), [`_refresh`](src/LiquidityRewardsDistributor.sol:165)
- **Root cause:** `_refresh` applies the current dividend index to the entire balance delta. If an account’s snapshot is stale when a distribution occurs, refreshing afterward subtracts that distribution from the account’s correction.
- **Preconditions:** The account holds LP tokens, but `lpBalanceSnap[account]` is lower than its current balance; a distribution occurs before the account is refreshed.
- **Impact:** The account’s accrued rewards can be reduced to zero and permanently trapped in the distributor. Anyone can trigger this by calling `refreshPosition(account)`, and `redeemRewards()` performs the same refresh automatically.
- **Reproduction:**
    1. Alice holds 100 LP; her snapshot is `0`.
    2. Fund 100 reward tokens while total LP supply is 100.
    3. `claimableAmount(Alice)` reports 100.
    4. Call `refreshPosition(Alice)`.
    5. The correction becomes `-100 * MAG`, `claimableAmount(Alice)` becomes 0, and `redeemRewards()` reverts with `"no dividend"`.

`enrollParticipant` does not initialize the snapshot, so newly enrolled holders are exposed by default.

**F-02 — LP balance decreases cause permanent settlement DoS**

- **Location:** [`_refresh`](src/LiquidityRewardsDistributor.sol:165)
- **Root cause:** `current - previous` is evaluated as an unsigned subtraction before being cast to `int256`.
- **Preconditions:** `lpBalanceSnap[account] > lpToken.balanceOf(account)`, such as after a normal LP transfer, withdrawal, or burn.
- **Impact:** `refreshPosition`, `redeemRewards`, `settleParticipant`, and batches containing the account revert with arithmetic panic `0x11`. Rewards remain unclaimable while the balance is below the old snapshot; burned LP can make this permanent.
- **Reproduction:**
    1. Alice holds 100 LP.
    2. Call `refreshPosition(Alice)`; snapshot becomes 100.
    3. Fund a distribution.
    4. Alice transfers 1 LP away; current balance becomes 99.
    5. Call `redeemRewards()` or `refreshPosition(Alice)`.
    6. `current - previous` underflows and the transaction reverts.

### Unverified hypotheses

These depend on token implementations that are absent from the repository:

- **Fee-on-transfer or rebasing reward token:** `fundDistribution` credits the nominal amount without checking the actual received balance, and settlement assumes exact transfers. This can overstate liabilities, cause payout failures, or consume prefunded tokens.
- **Callback-capable reward token:** External token calls occur without a reentrancy guard. A malicious callback could reenter settlement or distribution and cause accounting failures or denial of service.

### Duration
11m34s

## gpt-6.1-terra-raw

### Prompt
```txt
[LiquidityRewardsDistributor.sol](src/LiquidityRewardsDistributor.sol)  
Review the scoped contracts for exploitable flaws.
Report file/function, root cause, preconditions, impact, and reproduction steps.
Separate unverified hypotheses.Do not modify code and write new files. 

PLEASE DON'T USE ANY MCP/SKILLS in the local machine.
```

### Confirmed findings

**1. High: stale snapshots misallocate rewards**

Locations: `fundDistribution` at line 79, `accruedEntitlement` at line 106, `_refresh` at line 165.

Root cause: `fundDistribution` advances the global index using the current total supply, but does not synchronize account snapshots. `_refresh` later applies corrections using the account’s balance at claim time. `enrollParticipant` only records an address and does not initialize its snapshot.

Impact:

- A holder with `lpBalanceSnap == 0` can hold LP tokens during funding, then have its entitlement reduced to zero when it first claims.
- A prior holder can retain a positive snapshot, sell the LP before funding, reacquire the same balance afterward, and claim rewards despite holding no LP when the distribution occurred.
- Rewards can be denied to the actual holder and captured by an account with a stale snapshot.

Reproduction:

1. Total LP supply is 100; Alice owns 100 LP.
2. Alice calls `refreshPosition(Alice)`, setting `lpBalanceSnap[Alice] = 100`.
3. Alice transfers the 100 LP to Bob before funding.
4. The reward source calls `fundDistribution(100)`. The index increment is `2**128`.
5. Bob transfers the 100 LP back to Alice after funding.
6. Alice calls `redeemRewards()`. Her balance equals her stale snapshot, so no correction is applied and she receives 100 reward tokens.
7. Alice held no LP when the distribution was funded.

A simpler loss case is a fresh holder with snapshot zero: funding occurs while the holder owns LP, but its first `redeemRewards()` refreshes the balance and applies a correction that removes the entire distribution.

This requires an external integration to synchronize every account before funding and on transfers; no such mechanism exists in the scoped contract.

**2. Medium: balance decreases permanently block refresh and claims**

Location: `_refresh` at line 170.

Root cause: `current - previous` is evaluated as `uint256`. When the live LP balance is lower than the stored snapshot, Solidity 0.8 reverts before updating the snapshot.

Reproduction:

1. Alice holds 100 LP and calls `refreshPosition(Alice)`.
2. `lpBalanceSnap[Alice]` becomes 100.
3. Alice transfers 1 LP away, leaving 99.
4. Alice calls `redeemRewards()` or `refreshPosition(Alice)`.
5. The subtraction `99 - 100` reverts.

Impact: `redeemRewards`, `settleParticipant`, and any `settleBatch` containing the account revert. The account cannot claim previously accrued rewards until its balance is restored to at least the old snapshot. Burns and rebasing LP tokens can trigger this without a user transfer.

**3. Low: rounding dust is permanently trapped**

Locations: `fundDistribution` at line 94 and `accruedEntitlement` at line 116.

Root cause: Per-share rewards are floored, while the full nominal deposit is added to `trackedRewardBalance`. There is no remainder accounting or recovery function.

Reproduction:

1. Total LP supply is 3.
2. The source deposits 1 reward token.
3. The index increment is `floor(2**128 / 3)`.
4. Even an account holding all 3 LP receives zero after division by `MAG`.
5. The deposited reward remains in the contract with no claim path.

This is a protocol loss rather than an attacker-controlled theft.

**Unverified, deployment-dependent hypotheses**

- Fee-on-transfer, rebasing, or non-standard reward tokens can make nominal accounting differ from actual token balances because `transferFrom` and `transfer` amounts are trusted.
- ERC777-style reward callbacks could reenter settlement functions; no direct exploit is established for a conventional ERC20 reward token.
- Very large values may trigger signed-cast or multiplication failures in the `int256` entitlement calculations.

### Duration
8m1s

## gpt-6.1-terra-skill

### Prompt
```txt
[LiquidityRewardsDistributor.sol](src/LiquidityRewardsDistributor.sol)  
Review the scoped contracts for exploitable flaws.
Report file/function, root cause, preconditions, impact, and reproduction steps.
Separate unverified hypotheses.Do not modify code and write new files. 
```

### Confirmed findings
This content can’t be shown
We take extra care with some cybersecurity requests. If you’re doing authorized security work, apply for Daybreak to get broader access.

### Duration
~20m
