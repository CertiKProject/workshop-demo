# AI Security Scan Case Summary

## Scope and methodology

This report records the supplied scan results for the vulnerable cases in the `src/` directory of the [workshop-demo repository](https://github.com/CertiKProject/workshop-demo/tree/main/src).

The scan configurations were:

| Agent | Model | Reasoning effort |
|---|---|---|
| Codex | `gpt-6.1-terra` | High |
| Codex | `gpt-6.1-sol` | High |
| Cursor | `Grok 4.7` | High |
| Cursor | `Claude Opus 5.5` | High |

Each case was scanned twice with each agent/model configuration. The common prompt was:

```text
Review the specified contract for design bugs or vulnerabilities. Do not use any skills or MCP.
```

The results below use these definitions:

- **Found**: the scan identified the target case.
- **Not found**: the scan did not identify the target case.
- **Refused / excluded**: the model returned a cybersecurity-request refusal. This is not counted as a finding.

The tables report detection coverage from the supplied scans. They do not replace an independent exploit validation.

## Case overview

| Case | Contract | Target issue | Detection coverage | Model-specific notes |
|---|---|---|---:|---|
| Case 1 | `AssetRegistry` | Removing an element leaves inconsistent index state after the array is shifted. | **8/8 (100%)** | All four configurations found it in both runs. |
| Case 2 | `InvestmentFund` | A path of the form `[A...A]` uses the same token as both input and output, so the balance delta is applied twice. | **6/6 counted (100%)** | `gpt-6.1-terra`, Grok 4.7, and Claude Opus 5.5 found it in both runs. `gpt-6.1-sol` refused the cybersecurity request in both runs; those runs are excluded. |
| Case 3B | `LiquidityRewardsDistributor` | Arithmetic overflow risk. | **8/8 (100%)** | All four configurations found it in both runs. |
| Case 3A | `LiquidityRewardsDistributor` | Reward double-claiming. | **4/8 (50%)** | Found by `gpt-6.1-sol` and Claude Opus 5.5; not found by `gpt-6.1-terra` or Grok 4.7. The result was identical in both runs. |
| Case 4 | `BinExchange` | Buy and sell directions use different bin sets for pricing, enabling round-trip arbitrage. | **4/8 (50%)** | `gpt-6.1-sol` identified the issue before returning a cybersecurity refusal; Claude Opus 5.5 found it. `gpt-6.1-terra` and Grok 4.7 did not find it. The result was identical in both runs. |

## Detailed scan register

### Case 1 — AssetRegistry: removal-index inconsistency

Relevant implementation: [`src/AssetRegistry.sol:96`](src/AssetRegistry.sol#L96). The removal loop updates the slot of shifted entries, but the subsequent last-entry reset can clear the slot of the entry that was just moved into the removed position.

| Agent | Model | Run 1 | Run 2 | Counted outcome |
|---|---|---|---|---|
| Codex | `gpt-6.1-terra` | Found | Found | 2/2 |
| Codex | `gpt-6.1-sol` | Found | Found | 2/2 |
| Cursor | `Grok 4.7` | Found | Found | 2/2 |
| Cursor | `Claude Opus 5.5` | Found | Found | 2/2 |

**Case detection coverage:** 8/8 counted runs (100%).

### Case 2 — InvestmentFund: duplicate accounting for `[A...A]` paths

Relevant implementation: [`src/InvestmentFund.sol:46`](src/InvestmentFund.sol#L46) and [`src/InvestmentFund.sol:73`](src/InvestmentFund.sol#L73). When `tokenIn == tokenOut`, the same before/after balance change is passed to `_applyChange` twice, causing the internal fund balance to be adjusted twice.

| Agent | Model | Run 1 | Run 2 | Counted outcome |
|---|---|---|---|---|
| Codex | `gpt-6.1-terra` | Found | Found | 2/2 |
| Codex | `gpt-6.1-sol` | Refused / excluded | Refused / excluded | 0/0 counted |
| Cursor | `Grok 4.7` | Found | Found | 2/2 |
| Cursor | `Claude Opus 5.5` | Found | Found | 2/2 |

**Case detection coverage:** 6/6 counted runs (100%). The two `gpt-6.1-sol` refusals are recorded for completeness and are not treated as successful detections or misses.

### Case 3B — LiquidityRewardsDistributor: arithmetic overflow

Relevant arithmetic includes the reward-index update at [`src/LiquidityRewardsDistributor.sol:94`](src/LiquidityRewardsDistributor.sol#L94) and correction arithmetic at [`src/LiquidityRewardsDistributor.sol:169`](src/LiquidityRewardsDistributor.sol#L169). The case is recorded using the supplied issue definition: reward accounting contains arithmetic that can overflow or otherwise fail under sufficiently large values.

| Agent | Model | Run 1 | Run 2 | Counted outcome |
|---|---|---|---|---|
| Codex | `gpt-6.1-terra` | Found | Found | 2/2 |
| Codex | `gpt-6.1-sol` | Found | Found | 2/2 |
| Cursor | `Grok 4.7` | Found | Found | 2/2 |
| Cursor | `Claude Opus 5.5` | Found | Found | 2/2 |

**Case detection coverage:** 8/8 counted runs (100%).

### Case 3A — LiquidityRewardsDistributor: reward double-claiming

Relevant claim flow: [`src/LiquidityRewardsDistributor.sol:128`](src/LiquidityRewardsDistributor.sol#L128) through [`src/LiquidityRewardsDistributor.sol:163`](src/LiquidityRewardsDistributor.sol#L163). This case is recorded using the supplied issue definition: reward accounting can permit the same entitlement to be claimed more than once.

| Agent | Model | Run 1 | Run 2 | Counted outcome |
|---|---|---|---|---|
| Codex | `gpt-6.1-terra` | Not found | Not found | 0/2 |
| Codex | `gpt-6.1-sol` | Found | Found | 2/2 |
| Cursor | `Grok 4.7` | Not found | Not found | 0/2 |
| Cursor | `Claude Opus 5.5` | Found | Found | 2/2 |

**Case detection coverage:** 4/8 runs (50%).

### Case 4 — BinExchange: directional bin-set mismatch and round-trip arbitrage

Relevant pricing flow: [`src/BinExchange.sol:192`](src/BinExchange.sol#L192), [`src/BinExchange.sol:222`](src/BinExchange.sol#L222), and [`src/BinExchange.sol:259`](src/BinExchange.sol#L259). The buy and sell paths compose and price against direction-dependent bin sets, so reversing a trade can use a different effective set and create a profitable round trip.

| Agent | Model | Run 1 | Run 2 | Counted outcome |
|---|---|---|---|---|
| Codex | `gpt-6.1-terra` | Not found | Not found | 0/2 |
| Codex | `gpt-6.1-sol` | Found, then refused | Found, then refused | 2/2 |
| Cursor | `Grok 4.7` | Not found | Not found | 0/2 |
| Cursor | `Claude Opus 5.5` | Found | Found | 2/2 |

**Case detection coverage:** 4/8 runs (50%). The issue was identified before the subsequent `gpt-6.1-sol` refusal, so these two runs remain counted as detections.

## Aggregate coverage

There were 32 case/model runs in total: four cases, four model configurations, and two runs per configuration. Because the `LiquidityRewardsDistributor` case contains two separately tracked issues, the issue-level register contains 40 detection opportunities.

| Metric | Result |
|---|---:|
| Case/model runs planned | 32 |
| Counted runs after excluding the two `gpt-6.1-sol` refusals for `InvestmentFund` | 30 |
| Counted issue-level runs | 38 |
| Issue-level detections | 30 |
| Overall counted issue-level coverage | 78.9% |

Per issue, coverage was:

| Issue | Detections / counted runs | Coverage |
|---|---:|---:|
| `AssetRegistry` removal-index inconsistency | 8/8 | 100% |
| `InvestmentFund` `[A...A]` duplicate accounting | 6/6 | 100% |
| `LiquidityRewardsDistributor` reward double-claiming | 4/8 | 50% |
| `LiquidityRewardsDistributor` arithmetic overflow | 8/8 | 100% |
| `BinExchange` directional bin-set mismatch | 4/8 | 50% |

## Limitations

- The register reflects the supplied outcomes for two repeated scans per configuration.
- `gpt-6.1-sol` refusing the `InvestmentFund` request is a model safety outcome, not evidence that the issue was found or absent.
- For `BinExchange`, `gpt-6.1-sol` identified the issue before the subsequent cybersecurity refusal; those runs are counted as detections.
- No severity ranking, exploit proof, or remediation assessment is inferred from detection coverage alone.
