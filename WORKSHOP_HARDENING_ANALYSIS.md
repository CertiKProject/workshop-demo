# Workshop 合约加难分析

## 结论

当前项目适合演示“模型能否识别典型 Solidity 缺陷”，不适合测试模型在信息不完整时能否完成真实审计。漏洞很容易被找到，主要不是模型已经推导出了复杂的攻击，而是仓库把攻击目标、模式和复现路径都暴露了。提高难度应让漏洞依赖跨函数、跨合约、跨时间的状态关系，并给模型提供足够的业务规格来证明影响；不要靠无意义的变量改名、代码混淆或超大文件制造噪声。

## 为什么一句话就能找到

### 1. 答案已经写进仓库

- `agent-scans.md` 包含完整审计提示词、F-01/F-02 标题、根因、前置条件和逐步复现。即使模型只被要求审计 `src/`，它通常也会先读取仓库文档。
- `test/LiquidityRewardsDistributor.PoC.t.sol` 的测试名直接暴露漏洞语义：`test_doubleCountingDrain`、`test_decreaseBricksClaims`、`test_unrefreshedHolderLosesRewards`、`test_settleBatchGriefing`。断言还给出攻击者收益、预期 revert 和状态结果。
- `README.md` 是标准 Foundry 模板，没有业务背景或权限模型；模型自然会把所有代码当作独立的安全练习题。

### 2. 漏洞是局部、单步、教科书式的模式

- `LiquidityRewardsDistributor._refresh` 直接计算 `current - previous`，缺少分支即可触发 Solidity 0.8 算术回退。
- 同一合约把 `fundDistribution`、`refreshPosition`、`redeemRewards` 和全局奖励变量放在一起，攻击路径不需要跨模块。
- `InvestmentFund.swap` 用整个合约的 token 余额差更新单个 fund 的账本；`RandomNumber.getRoundResultExtended` 中的 `while`、`continue`、`attempts` 和 `uint32` 边界也都是静态扫描器熟悉的高信号组合。
- `RandomSeed` 的注释明确写出 `Use block data as pseudo-randomness`、`commit block`、`local mode/oracle mode`，降低了威胁建模成本。

### 3. 缺少真实业务约束和反例

代码没有说明谁负责同步 LP 快照、多个 fund 是否共享 token、随机数结果何时才可消费、资产 registry 与下游存款模块如何协作。模型无需先建立系统不变量，就可以直接套审计清单。

### 4. 触发条件和影响都被人为放大

测试使用简单 Mock ERC20、固定数量和单一角色，攻击只需要几次直观调用。没有 fee-on-transfer、rebasing、异步回调、多个 fund、epoch、keeper 或失败重试等真实状态变化，模型不需要判断外部依赖和部署假设。

## 建议的加难目标

### A. 先消除信息泄漏

1. 将 `agent-scans.md`、PoC 和答案移到评测机外或私有 solution 包；公开仓库只保留无漏洞命名的 happy-path 测试。
2. 删除注释中直接描述实现弱点的词，例如 pseudo-randomness、commit/reveal 风险和“membership is the slot map”。保留正常的业务注释，不要把代码改成不可读的混淆体。
3. 文件名、测试名、事件名避免出现 `Drain`、`Bricks`、`Griefing`、`stale`、`underflow` 等答案关键词。
4. 公开一份业务规格，描述角色、资产所有权、结算时序、失败处理和信任边界；不要公开漏洞所在函数或攻击序列。

### B. 把局部模式改成状态机问题

推荐每个目标漏洞至少需要三个外部动作、两个角色和一次状态变化，且从入口函数到影响点跨越 2--4 个模块。例子：

- 奖励系统拆成 `Pool`、`ShareLedger`、`RewardRouter`。奖励按 epoch 结算，转账、keeper 同步和 claim 分别更新缓存。保留一个跨 epoch 的快照/修正错误，使攻击需要“转账 -> 新 epoch funding -> router claim”，而不是直接调用 `refreshPosition`。
- 基金系统增加两个 fund 共享同一 token，并把 swap 委托给 adapter。让账本错误来自“全局余额差被归因给调用 fund”，只有在第二个 fund 有余额、交易产生手续费或 callback 时才出现。这样需要建立 fund 隔离不变量并验证资产流。
- Registry 不直接作为孤立数组使用，增加 `DepositController` 和 guard/recording adapter。让 stale metadata、exclude/include 顺序或重复输入只在下游读取缓存时造成资产不可用，避免把问题停留在一个 `swap-and-pop` 循环里。
- 随机数系统把 coordinator、local fallback 和消费者拆开。将“已收到 VRF”“已揭示”“可消费”设为不同状态，允许多个 request 并发；目标问题放在 request-to-round 关联、旧回调、零值结果或窗口边界上，由消费者的错误信任触发影响。

### C. 增加合理的干扰项和外部语义

- 使用真实 ERC20 行为的最小 adapter（返回值差异、转账税、rebasing 或回调只选一两种），并在规格中说明哪些 token 被支持。
- 加入安全的相似实现，让模型不能看到一个模式就全部报错；例如一个模块正确处理下降余额，另一个模块遗漏负向 delta。
- 把关键值放进 library、继承合约、配置结构和事件消费路径中，但保持每个模块职责清楚。复杂度应来自数据流和时序，不来自无关代码数量。
- 公开 happy-path、边界和权限测试，不公开目标攻击的测试名与断言。隐藏测试验证完整调用序列、资产差额、可用性和 revert 位置。

## 对现有五个合约的具体改造方向

| 合约 | 当前显眼线索 | 建议的目标形态 |
| --- | --- | --- |
| `LiquidityRewardsDistributor` | 公开 refresh、全局 index、快照差额在同一文件；PoC 直接给出奖励丢失和 sybil 路径 | epoch ledger + router + keeper sync；漏洞只在转账与 funding 的时间交错下出现，要求证明“持有期间奖励”和“当前余额”不变量 |
| `InvestmentFund` | `balanceOf(address(this))` 前后差直接写入单个 fund | 多 fund 共用 custody、swap adapter 和 fee accounting；验证不同 fund 之间不能互相获得余额 |
| `AssetRegistry` | `entrySlot`、`swap-and-pop`、guard 都在一个短文件里 | registry 只维护版本化配置，下游 controller 缓存版本；问题通过更新/读取顺序影响存款或提款 |
| `RandomSeed` | 注释直接说明 local/oracle、commit block、pseudo-randomness | request 状态表 + coordinator adapter + consumer；要求区分 fulfilled、finalized、consumable，并覆盖并发回调和窗口边界 |
| `RandomNumber` | `while` 中 `continue` 跳过 attempts，边界算术紧邻 | 把生成器放入 library，由 lottery/allocator 消费；隐藏 DoS 需要构造合法输入和证明 gas/可用性影响 |

## Workshop 设计和验收

建议做两个公开难度等级。Level 1 保留当前单合约模式，用来讲解典型漏洞；Level 2 使用上面的跨模块版本，仓库不含答案文档和 PoC。每个目标保留一份评测机外的 oracle，包括攻击前置状态、最短调用序列、资产差额和预期失败位置。

不要只用“是否提到漏洞”评分。对每次模型运行记录：是否找到根因、是否给出可执行调用序列、影响是否量化、是否错误地把安全代码报成漏洞、是否把管理员信任假设说清楚。至少用 Codex、Cursor/Claude 等主流 agent 各运行多次，并分别测试只给文件路径、给业务规格、允许运行测试三种条件。目标是让只读静态扫描的命中率明显下降，但允许模型通过构造状态、读接口和运行公开测试逐步发现问题。

## 推荐实施顺序

1. 立即移除 `agent-scans.md` 和带漏洞语义的 PoC/命名，这是成本最低、收益最大的改动。
2. 为每个合约写一页业务规格和状态不变量，再将至少两个目标漏洞迁移到跨函数或跨合约调用链。
3. 增加两个共享资产或异步回调场景，补充安全的相似实现和正常测试。
4. 建立隐藏 oracle 与多模型重复评测，按发现率、证明质量和误报率调节难度。

这样得到的是“需要理解系统并证明攻击”的 workshop，而不是把答案藏在更长的 Solidity 文件里。
