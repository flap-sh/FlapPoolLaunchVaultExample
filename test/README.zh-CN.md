# Fork 测试

[English](README.md) | **中文**

这些测试针对 BNB Chain 和 BNB Testnet 上**线上的 Portal** 运行示例，不使用任何 mock。测试版期间，每次发射都经过 Flap 已启用其 LauncherFactory 的 Launcher。Vault 参考测试会取消 Portal 暂停，以单独验证 Vault 行为。

## 示例覆盖范围

你构建的东西决定了谁调用谁，也就决定了需要开放什么、可能在哪里出错。Vault 示例是放在 Launcher 后面的参考实现：

| 模式 | 你构建的 | 谁调用谁 | 示例 | 测试 |
|---|---|---|---|---|
| **Vault 参考实现** | 接收代币税收收入一部分的 Vault | Launcher 调用 Portal；Portal 调用 Vault Factory 创建 vault | `SplitVault` | [`vault/SplitVault`](vault/SplitVault.fork.t.sol) |
| **Vault 参考实现，接收预留代币** | 同时会被交付发射预留代币的 Vault | Portal 还会把 80% 供应量交给 vault | `StakeMineVault` | [`vault/StakeMine`](vault/StakeMine.fork.t.sol) |
| **仅 Launcher** | 先募集或发售、再发射的 Launcher | 用户与你的 Launcher 交互；**你的 Launcher 调用 Portal** | `MintLauncher` | [`launcher/MintLauncher`](launcher/MintLauncher.fork.t.sol) |
| **Launcher + Vault** | 两者互相锁定 | Launcher 调用 Portal，Portal 调用 Vault Factory，两个 Factory 只接受对方 | `CrowdLauncher` + `CrowdVault` | [`launcher-vault/Crowd`](launcher-vault/Crowd.fork.t.sol) |

简单说：

- 做 **Vault**，你是被调用的一方。你的 Factory 必须拒绝任何不是你的 vault 所服务的确切形态的发射。
- 做 **Launcher**，你是调用方。推荐由 Launcher 自己锁 salt；它必须只发射一次，并传入恰好正确的数值。
- **两者都做**，双方只能互相信任、不信任任何其他人，这样陌生合约就不能冒充你的 Launcher。

每个 Factory 都必须通过 Flap 审计后才能启用。测试版期间，Flap 会启用通过审计的 LauncherFactory 及其配对且通过审计的 Vault Factory；配对 Vault Factory 的 `enabled` 标志用于它自己的流动性门槛乘数和 UI。发射能否绕过创建暂停只取决于调用方的 LauncherFactory。没有 Launcher 的项目不会单独启用 Vault Factory，未通过审计的 Factory 一律不启用。

## 每个测试覆盖什么

- **`SplitVault`**：普通发射、在真实池子上交易产生的税收，以及每位收款人的领取。
- **`StakeMine`**：没有交付预留代币的发射被拒绝；完整预留代币存入 Token Dock；两个档位的质押权重分别为 x1 和 x2，挖矿收益按权重分配；锁定期内不能取出、到期后可以；开发者的 1% 线性释放；收入 20% 给开发者、其余给持币人；只有 Guardian 能升级。
- **`MintLauncher`**：Portal 执行门控时拒绝未开放的 Factory；拒绝格式错误的配置和黑名单 name/symbol；出资直到达成目标；发射展示真实的 creator；领取；目标未达成时退款；每个 Launcher 只发射一次；`description()` 渲染 v1 JSON，Portal 把同一个字符串折进 `FlapNewLauncherCreated`。
- **`Crowd`**：Vault 一侧关闭时只开 Launcher Factory 就足够；门控测试覆盖关闭 LauncherFactory 和暂停；包含交易、税收和每一项领取的完整流程；取消暂停后陌生 Launcher 被 Vault Factory 拒绝；这里同样校验 `description()` 及其事件载荷。
- **`LauncherDescription`**：不需要链的展示层：精确的 v1 JSON、`name`/`symbol` 的转义，以及渲染结果仍在 Portal 4 KB 读取上限之内。

## 目录结构

```
test/
├── ForkBase.sol            所有测试共用：线上 Portal、带资金的账户、开放 Factory、
│                           挖 salt、交易、分发税收
├── ForkAddresses.sol       两条链的所有地址
├── LauncherDescription.t.sol  v1 展示 JSON，不需要链
├── vault/                  SplitVault.*  StakeMine.*
├── launcher/               MintLauncher.*
└── launcher-vault/         Crowd.*
```

每个示例有三个文件：

| 文件 | 作用 |
|---|---|
| `<示例>.fork.t.sol` | 测试场景，写成抽象合约。 |
| `<示例>.BSC.fork.t.sol` | 在 BNB Chain 上运行（`BSC_RPC_URL`）。 |
| `<示例>.BSCTest.fork.t.sol` | 在 BNB Testnet 上运行（`BSC_TESTNET_RPC_URL`）。 |

没有设置对应的 RPC 环境变量时，该测试会被跳过。

## 运行

把你的 RPC 地址放进 `.env`（已被 git 忽略），然后运行：

```bash
cp .env.example .env       # 然后填入 BSC_RPC_URL 和 BSC_TESTNET_RPC_URL
set -a && . ./.env && set +a
forge test --match-path "test/**/*.fork.t.sol"
```

**请使用你自己的节点或服务商的 key。** fork 测试要读取成千上万个存储槽（发射、池子和交易涉及的一切），而免费的公共节点会限速并裁剪旧状态，所以运行很慢，还可能在中途失败，而且与你的合约无关。任何 BNB Chain 服务商的 key，或你自己的节点，都能避免这个问题。[`.env.example`](../.env.example) 里的公共节点只适合试跑单个测试。

只跑一种模式或一条链：

```bash
forge test --match-path "test/launcher/*"          # 仅 Launcher，两条链
forge test --match-path "test/**/*.BSCTest.*"      # BNB Testnet，所有模式
```

## 说明

- Portal、它的 ProxyAdmin 和税币实现合约在两条链上相同；Guardian、WBNB 和 V2 router 不同，`ForkAddresses` 同时存放两套。`setUp` 会断言这里的 Hub 与 Guardian 和 `LaunchVaultAddresses`（Factory 在运行时读取的那个）一致，所以两者不会悄悄不同步。
- 测试使用固定的普通账户，而不是 `makeAddr`：哈希出的地址可能与主网上的真实账户冲突，其中一个带有 EIP-7702 代码，会把退款转走。
- 新增一条链：在 `ForkAddresses` 加一个函数，并为每个示例加一个很薄的类。
- 两条链都跑 Portal **`v1.1.2`**，它把 Launcher 的 `description()` 作为第四个参数折进 `FlapNewLauncherCreated`。`setUp` 会断言版本及 EIP-1967 implementation 地址；2026-11-11 Portal 曾在版本号不变的情况下更新实现。测试会把事件载荷与 `description()` 本身对比。
- BNB 测试网目前不执行 LauncherFactory 门控，依赖该门控的三个测试网用例会跳过。请向 Flap 确认原因；如已修复，在 `ForkAddresses` 中把测试网的 `enforcesLauncherGate` 改回 `true`。
