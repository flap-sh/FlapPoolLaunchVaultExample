# Flap Pool Launch Vault 与 Launcher 示例

[English](README.md) | **中文**

> ⚠️ **本仓库只适用于 Flap _Pool Launch_（Direct Launch，直接开池发射）的 Vault。**
> Pool Launch 的代币不经过 Bonding Curve：发射时直接注入 V2 池子。它的 Vault 规范与 Bonding Curve 税收 Vault 规范**不同**。如果你的代币走 Bonding Curve 发射（`VaultPortal.newTokenV6WithVault`），请使用 [FlapVaultExample](https://github.com/flap-sh/FlapVaultExample)。两套框架的合约**不能**互用。

本仓库包含 Pool Launch 的规范接口，以及你可以在一次发射上构建的两类合约的参考实现：

- **Vault**：接收代币税收收入的一部分（也可以选择接收预留代币）。示例：`SplitVault`、`CrowdVault`。
- **Launcher**：在代币出现**之前**，用户与之交互的合约（募资、Mint、预售）。条件满足后由它自己发射代币。示例：`MintLauncher`、`CrowdLauncher`。

Launcher 可以不带 Vault 单独发射，也可以与 Vault 配对。`CrowdLauncher` + `CrowdVault` 就是配对示例。

---

## 目录

- [Pool Launch 还是 Bonding Curve：我该用哪个规范？](#pool-launch-还是-bonding-curve我该用哪个规范)
- [目录结构](#目录结构)
- [Pool Launch Vault 接口](#pool-launch-vault-接口)
- [Pool Launch Vault 是如何被创建的](#pool-launch-vault-是如何被创建的)
- [税收收入：原生币与 ERC20](#税收收入原生币与-erc20)
- [SplitVault 示例](#splitvault-示例)
- [StakeMine 示例：接收预留代币的 Vault](#stakemine-示例接收预留代币的-vault)
- [Crowd 配对：一个 Launcher 加一个 Vault](#crowd-配对一个-launcher-加一个-vault)
- [Launcher 接口](#launcher-接口)
- [推荐部署模式：Beacon 可升级 Vault](#推荐部署模式beacon-可升级-vault)
- [可选功能](#可选功能)
  - [接收开发者预留的代币](#接收开发者预留的代币)
  - [Token Dock：托管预留代币](#token-dock托管预留代币)
  - [计算分红代币](#计算分红代币)
- [如何编写你自己的 Vault](#如何编写你自己的-vault)
- [审计前的测试](#审计前的测试)
- [上线：Flap 审计](#上线flap-审计)

---

## Pool Launch 还是 Bonding Curve：我该用哪个规范？

| | **Pool Launch**（本仓库） | **Bonding Curve**（[FlapVaultExample](https://github.com/flap-sh/FlapVaultExample)） |
|---|---|---|
| 代币如何开始交易 | 发射时直接注入 V2 池子 | 先在 Flap Bonding Curve 上交易，毕业后迁移到 DEX |
| 谁调用你的 Factory | **Direct Launch Portal**（"Hub"） | VaultPortal |
| 发射入口 | `launchTaxTokenV2(...)` | `newTokenV6WithVault(...)` |
| Factory 基类 | `DirectLaunchVaultFactoryBase` | `VaultFactoryBaseV2` |
| Vault 基类 | `DirectLaunchVaultBase` | `VaultBaseV2` / `VaultBaseV3` |
| Factory 创建函数 | `newVault(token, creator, launchKind, launchParams)` | `newVault(taxToken, quoteToken, creator, vaultData)` |
| `factorySpecVersion()` | `"pl-v1"` | `"v2.x"` |
| 预留代币 | 可交给 Vault（`IStrategy.initializeDistribution`） | 不适用 |

> Direct Launch Portal **不是** Bonding Curve Portal，也不是 VaultPortal。请勿混用它们的地址。

[`IVaultSchemas.sol`](src/flap/IVaultSchemas.sol) 中的 UI Schema 结构体（`VaultUISchema`、`VaultDataSchema`、`FieldDescriptor` 等）与 Bonding Curve 规范相同。如果你已经写过，UI Schema 的代码可以直接复用。

---

## 目录结构

`src/flap/` 是唯一强制且不可修改的目录，存放 Pool Launch 的规范文件和推荐基类（包括 Launcher 的两个基类）。示例按你要构建的东西分组：`src/vault/`（仅 Vault）、`src/launcher/`（仅 Launcher）和 `src/launcher-vault/`（成对构建的 Launcher 和 Vault，需要放在一起看）。

```
src/
├── flap/                              ← 必需且不可修改，请勿重命名或改动
│   ├── ILaunchVaultSpec.sol           ← IDirectLaunchVault / IDirectLaunchVaultFactory / ITokenDock / ...
│   ├── DirectLaunchVaultBase.sol      ← 推荐的 Vault 基类
│   ├── DirectLaunchVaultFactoryBase.sol ← 推荐的 Vault Factory 基类
│   ├── ILauncher.sol                  ← ILauncherFactory / LauncherRecord
│   ├── LauncherBase.sol               ← 推荐的 Launcher 基类
│   ├── LauncherHelper.sol             ← 生成 `description()` 返回的 v1 JSON
│   ├── LauncherFactoryBase.sol        ← Launcher Factory 基类
│   ├── IPortal.sol                    ← 发射参数（CreateTaxTokenParams、FeeConfig 等）以及 Launcher 会调用的 Portal 函数
│   ├── IVaultSchemas.sol              ← UI Schema 结构体（Vault 与 Launcher）
│   ├── IDividend.sol                  ← 税收代币部署的分红合约（Vault 可以把持有者份额存入）
│   ├── IStrategy.sol                  ← 预留代币交接接口
│   ├── Distribution.sol               ← 预留代币交接结构体
│   ├── LaunchVaultAddresses.sol       ← 各链的 Hub / Guardian / Token Dock 地址
│   └── LaunchExtensionHelper.sol      ← Launcher 用的 creator 展示工具（无 import，原样复制即可）
├── vault/                             ← 仅 Vault
│   ├── SplitVault.sol / SplitVaultFactory.sol   ← 按 bps 把收入分给多个收款人
│   └── StakeMineVault.sol / StakeMineVaultFactory.sol ← 接收预留代币、存入驿站、质押挖矿
├── launcher/                          ← 仅 Launcher
│   └── MintLauncher.sol / MintLauncherFactory.sol    ← 募到目标后发射一次
└── launcher-vault/                    ← Launcher + Vault，成对构建
    ├── CrowdLauncher.sol / CrowdLauncherFactory.sol  ← 众筹发射
    └── CrowdVault.sol / CrowdVaultFactory.sol        ← 出资人按比例分享税收收入
```

---

## Pool Launch Vault 接口

只有两个接口是强制的，都在 [`ILaunchVaultSpec.sol`](src/flap/ILaunchVaultSpec.sol) 中。

**`IDirectLaunchVault`**：Vault 必须实现的全部接口：

| 函数 | 要求 |
|---|---|
| `description()` | 动态、可读的状态描述。**必须**披露所有费用/佣金，以及每一个获得收入或预留代币的参与方。 |
| `vaultUISchema()` | 描述每个面向用户或 keeper 的方法，供 Flap.sh 渲染交互面板。 |

**`IDirectLaunchVaultFactory`**：

| 函数 | 要求 |
|---|---|
| `newVault(token, creator, launchKind, launchParams)` | 在一次调用中**同时**校验发射参数并创建 Vault。只允许 Hub 调用。 |
| `isQuoteTokenSupported(quote)` | 必须如实返回，与 `newVault` 实际接受的币种一致。`address(0)` = 原生币。 |
| `factorySpecVersion()` | 返回 `"pl-v1"`。 |
| `vaultDataSchema()` | 描述你的 `vaultData` 字节，供 Flap.sh 渲染创建表单。 |
| `tokenCreationPolicies()` | 与 `newVault` 校验规则一致的 UI 提示（仅供展示）。 |
| `upgradeVaultImplementation(newImpl)` | 升级该 Factory 部署的全部 Vault。获得低风险标识**只能由 Guardian 调用**。 |

[`DirectLaunchVaultBase`](src/flap/DirectLaunchVaultBase.sol) 和 [`DirectLaunchVaultFactoryBase`](src/flap/DirectLaunchVaultFactoryBase.sol) 是推荐（非强制）的基类。它们没有存储，只提供：

- `onlyHub` / `onlyGuardian` 修饰器，地址按链从 [`LaunchVaultAddresses`](src/flap/LaunchVaultAddresses.sol) 解析；
- `_validateLaunch()` / `_requireNoReserveDistribution()` 严格的发射校验，以及 `_decodeLaunchParams()` / `_vaultDataFor()` 解码工具（Factory）；
- `_getTokenDockRouter()`（Vault）。

所有接口都附有详细的 NatSpec 注释，它们就是规范本身，请仔细阅读。

---

## Pool Launch Vault 是如何被创建的

```
creator ──launchTaxTokenV2(p, distribution, creatorBuy)──▶ Direct Launch Portal (Hub)
                                                              │
                     1. 解析 p.feeConfigs，找到 VAULT 槽位 {vaultFactory, vaultData}
                     2. newVault(predictedToken, creator, launchKind, abi.encode(p, distribution))
                                                              ▼
                                                        YourFactory ──部署──▶ YourVault
                     3. 部署代币，注入并锁定 V2 池子
                     4. （可选）distribution → vault.initializeDistribution(...)
                     5. 此后：TaxProcessor 按 VAULT 槽位的 bps 把税收收入打给 Vault
```

`newVault` 的要点：

- **`token` 此时还没有代码**，它只是 CREATE2 预测地址，不要调用它。
- **`launchParams` 是完整的原始发射参数**：`abi.encode(IPortalTypes.CreateTaxTokenParams, Distribution)`。调用 `_validateLaunch(...)`：它会解码输入、执行每个 Factory 都需要的检查，并返回你自己的 `vaultData`。
- **`p.quoteToken` 是原始值**：`address(0)` 表示原生币，没有 WBNB 归一化。
- **必须加 `onlyHub`**。否则任何人都能抢先部署到你的确定性 Vault 地址，导致真正的发射因 CREATE2 地址冲突而 revert。
- **先校验再部署**，不接受的发射要带清晰的原因 revert。`_validateLaunch` 会拒绝零地址的 `token` 或 `creator`、缺失或重复指向你的 Factory 的 VAULT 槽位、bps 为 0 的槽位以及不支持的 quote。不接收预留代币的 Vault 还要调用 `_requireNoReserveDistribution`。然后严格解码你自己的 `vaultData`：多余或被截断的字节要拒绝，不能忽略。
- 目前只有 `LaunchKind.DIRECT_V2_POOL_TAX`（0）。`_validateLaunch()` 遇到其他 kind 会 revert，未来的新 kind 需要主动适配。

费用槽位：一次发射最多 4 个 `feeConfigs`，bps 合计必须为 10000，并且 **VAULT 与 MARKETING 互斥**：要么一个 Vault，要么一个营销钱包。

流动性门槛：Hub 要求注入池子的报价币 USD 价值（`poolQuote × quotePriceUsd`）达到一个随 `totalSupply / poolToken` 放大的门槛。低于创建门槛会 revert `LaunchLiquidityTooLow`；达到创建门槛的两倍则在发射交易中直接标记为毕业。也就是说，你的 Vault 预留的份额越大（`poolToken` 越小），创建者需要注入的报价币越多。Flap 可以为某个 Factory 设置 `multiplierBps`（≤ 10000）来同时降低这两个门槛，注册 Factory 时可以一并申请。`PortalLaunchLens.graduationFloorV2(...)` 可以预览具体数字。

---

## 税收收入：原生币与 ERC20

Pool Launch 支持原生币（BNB）和 ERC20 作为报价币种，但仅限协议已启用的组合：`(DIRECT_V2_POOL_TAX, quoteToken)` 未启用时发射会 revert `LaunchQuotePairNotEnabled`，可通过 Hub 的 `launchQuoteConfig(kind, quote)` 查询。Vault 以该发射的报价币种收到收入：

- **原生币**：TaxProcessor 直接转账，触发 `receive()`。
- **ERC20**：TaxProcessor 先普通 `transfer`，再向 Vault 发一次**零 value、空 calldata 的 "ping"**，同样进入 `receive()`。ping 失败不会回滚分发，会转发分发者的 gas，并且可能被多次或无故触发。

因此 Vault 必须用**余额差额记账**识别收入：用当前余额减去记录的基线（`balance - accountedQuote`），不能用 `msg.value`，也不能直接用余额。**每一笔流出都必须同步扣减基线。** `receive()` 要轻量且幂等。这与 Bonding Curve V3 的 ERC20 规范是同一套模型。

`isQuoteTokenSupported()` 必须如实返回。如果声称支持某个币种而 Vault 实际不处理，用户的税收收入会被卡在 Vault 里。

---

## SplitVault 示例

[`SplitVaultFactory`](src/vault/SplitVaultFactory.sol) 读取 `vaultData = abi.encode(SplitVault.Recipient[])`，为每次发射部署一个 [`SplitVault`](src/vault/SplitVault.sol) beacon 代理。Vault 在每次 `receive()` / `sync()` 时给各收款人记账，收款人调用 `claim()` 自行领取。

Factory 的 `vaultDataSchema()` 告诉 Flap.sh 如何渲染创建表单：

```solidity
function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
    schema.description = unicode"Split vault: the launch's quote revenue is split among recipients by bps "
        unicode"(sum = 10000, at most 10 recipients). / " unicode"分账 Vault：按 bps 将税收收入分给多个收款人（合计 10000，最多 10 个）。";
    schema.fields = new FieldDescriptor[](2);
    schema.fields[0] = FieldDescriptor("recipient", "address", "Recipient address", 0);
    schema.fields[1] = FieldDescriptor("bps", "uint16", "Share in bps (sum across recipients = 10000)", 0);
    schema.isArray = true;
}
```

Vault 的 `vaultUISchema()` 描述了 `claimable`、`claimed`、`recipients` 和 `claim`。它的 `description()` 列出所有收款人及其份额，满足披露要求：

```
SplitVault: 100% of this vault's quote revenue is split across 3 recipients, no fee: 0x…1111=5000bps; 0x…2222=3000bps; 0x…3333=2000bps; each recipient pulls its share via claim().
```

Factory 的 `newVault` 先严格校验，再部署：

```solidity
function newVault(address token, address creator, uint8 launchKind, bytes calldata launchParams)
    external override onlyHub returns (address vault)
{
    (IPortalTypes.CreateTaxTokenParams memory p, Distribution memory d, bytes memory vaultData) =
        _validateLaunch(token, creator, launchKind, launchParams);
    _requireNoReserveDistribution(d);
    SplitVault.Recipient[] memory recipients = _decodeRecipients(vaultData); // 长度精确、地址唯一、bps 合计 10000

    vault = LibClone.deployDeterministicERC1967BeaconProxy(beacon, bytes32(uint256(uint160(token))));
    SplitVault(payable(vault)).initialize(token, quote, weth, recipients);
}
```

Factory 在构造函数里接收 `weth`，并把原生币发射的原始 quote（`address(0)`）当作 WETH 传给 Vault。Vault 通过比较 `quoteToken == weth` 知道自己收到的是原生 BNB，所以一条余额差额基线就能同时覆盖两种情况。

---

## StakeMine 示例：接收预留代币的 Vault

[`StakeMineVaultFactory`](src/vault/StakeMineVaultFactory.sol) 是收益依赖发射预留代币的 Vault 的示例。发射把 80% 的供应量交给 Vault（`Distribution.target == VAULT`），Factory 会在部署任何东西之前，**拒绝所有不是这种形态的发射**：目标必须是 `VAULT`，数量恰好是供应量的 80%，池子里放另外的 20%。

[`StakeMineVault`](src/vault/StakeMineVault.sol) 随后会：

- 通过 `TokenDockRouter` 把**全部**预留代币存入 Token Dock，这样 terminal 看到的是带标签的预留，而不是一个巨大的未知持有人。Flap 把该 Vault 加入白名单之前，预留代币在开放驿站里，之后会自动迁移到已验证驿站；Vault 从不缓存 router，也看不到这次切换；
- 把供应量的 1% 在 30 天内线性释放给开发者，用 `claimDevVested` 领取；
- 把另外 79% 在 90 天内按权重（`数量 × 档位倍数`：默认 30 天 x1、90 天 x1.5、180 天 x2）挖给质押者；
- 收入到账时即拆分：20% 给开发者直到收回其注入 quote 的 1.5 倍，其余通过无需许可的 `flushDividends` 交给代币的分红合约。因此 factory 会拒绝没有 DIVIDEND 槽位、或分红资产不是 quote 的发射。

---

## Crowd 配对：一个 Launcher 加一个 Vault

[`CrowdLauncher`](src/launcher-vault/CrowdLauncher.sol) 向许多出资人募集 BNB。目标达成时，达到目标的那一笔出资会在同一笔交易里发射代币。出资人随后按比例领取一半供应量，并通过配对的 [`CrowdVault`](src/launcher-vault/CrowdVault.sol) 分享代币的税收收入。如果目标未达成，所有人都会被退款。

```
创建者 ──Portal.newLauncher(CrowdLauncherFactory, config)──▶ CrowdLauncher   （自己锁定 salt）
出资人 ──contribute()──▶ CrowdLauncher
        最后一笔出资达到目标
CrowdLauncher ──launchTaxTokenV2(...)──▶ Portal ──newVault(...)──▶ CrowdVaultFactory ──部署──▶ CrowdVault
                                         Portal ──initializeDistribution(...)──▶ CrowdLauncher   （预留的一半）
```

两个 Factory 互相锁定，因此一个 Vault 只会服务于与它配对的 Launcher：

- `CrowdLauncherFactory` 只接受自己配对的 `CrowdVaultFactory`。
- `CrowdVaultFactory.newVault` 会检查调用方是由该 Launcher Factory 创建的 Launcher（读取 Portal 的记录）、`vaultData` 指向发起调用的 Launcher，并且该 Launcher 正处于发射途中且已募满。

---

## Launcher 接口

Launcher Factory 实现 `ILauncherFactory`（[`ILauncher.sol`](src/flap/ILauncher.sol)）。Portal 在 `Portal.newLauncher(factory, data)` 中调用它。

| 函数 | 要求 |
|---|---|
| `newLauncher(creator, data)` | 在一次调用中部署并初始化 Launcher。仅限 Portal 调用（`onlyHub`）。`creator` 是调用 Portal 的钱包；`data` 由你自己定义。 |
| `factorySpecVersion()` | 返回 `"lf-v1"`。 |
| `launcherDataSchema()` | 描述你的 `data` 字节，让 Flap.sh 渲染创建表单。 |
| `upgradeVaultImplementation(newImpl)` | 升级该 Factory 所有 Launcher。**仅限 Guardian。** 持有不可变 Launcher 的 Factory 直接 revert。 |

[`LauncherFactoryBase`](src/flap/LauncherFactoryBase.sol) 与 [`LauncherBase`](src/flap/LauncherBase.sol) 是无存储的基类。`LauncherFactoryBase` 给 `newLauncher` 加上 `onlyHub` 并固定 `factorySpecVersion`；`LauncherBase` 为你的 Launcher 提供 `_getHub()`、`onlyHub`、`onlyGuardian`、`_launchOnHub(...)` 以及 `description()`（实现 `_description()`，由 `LauncherHelper` 渲染成 Portal 折进 `FlapNewLauncherCreated` 的 v1 JSON）。

Launcher 必须做对的几件事：

- **自己锁 salt。** `Portal.lockSalt` 把 `msg.sender` 记为锁定者，发射要求 `locker == Launcher`。由 Factory 完成的锁会让发射 revert。
- **只发射一次。** Portal 对每个 Launcher 只允许一次发射。
- **传入恰好正确的数值。** 原生币 quote 时，发射的 `msg.value` 必须等于 `poolQuote + creatorBuyQuote`。
- **展示真实的 creator。** Launcher 是调用 Portal 的一方，`FlapDirectLaunched.creator` 默认会是 Launcher。改为声明用户：

  ```solidity
  (p.extensionID, p.extensionData) = LaunchExtensionHelper.encodeCreator(creator);
  ```

  它只改变发射事件里的 `creator` 字段。vault、salt 锁和付款仍然使用 Launcher。只有通过 `Portal.newLauncher` 创建的 Launcher 才能使用。
- **`description()` 保持在 4 KB 以内。** Portal 最多读取 4,096 字节，超出就静默存成 `""`：不 revert、不报错，JSON 直接消失。固定文案在这些示例里是 0.7–1 KB，给用户的 `name` 和 `symbol` 留下约 3 KB；渲染内容更多的 Launcher 应该给这两个字段加上长度上限。`description()` 只用于展示：它永远不影响门控、记账和付款，坏掉的 `description()` 也不该让发射失败。

[`MintLauncher`](src/launcher/MintLauncher.sol) 是最小的示例：募集固定金额、发射一次、把预留部分分给出资人。

---

## 推荐部署模式：Beacon 可升级 Vault

- **Factory 不可升级。** 要改动就部署一个新的 Factory。
- **Vault 可升级**：用 Factory 持有的 solady `UpgradeableBeacon`，每次发射用 `LibClone.deployDeterministicERC1967BeaconProxy` 以代币地址为 salt 部署一个代理。升级一次 beacon 即可更新所有已发射的 Vault。
- 给 Vault 实现加一个 `version()`，每次升级时递增。

### 升级权限：仅限 Guardian

要获得低风险标识，**`upgradeVaultImplementation` 必须只能由 Flap Guardian 调用**（`onlyGuardian`），并且不能有任何其他升级路径：不能有 owner、proxy admin、beacon owner、upgrader 角色、多签或部署者 EOA。如果 Factory 完全不需要升级，可以让该函数直接 revert。

Vault 上其他所有带权限的函数也必须**同时允许 Guardian 调用**，例如 `if (msg.sender != creator && msg.sender != _getGuardian()) revert`。

> **Guardian 地址由 Flap 安全团队控制。** 如需升级（例如修复 bug），请直接联系我们。安全团队大约需要 **24 小时**评估请求、验证改动，审核通过后执行升级。请不要把 Vault 设计成依赖自行升级或临时紧急升级。

---

## 可选功能

### 接收开发者预留的代币

Pool Launch 把供应量中的 `p.poolToken` 注入池子，剩余部分（`totalSupply - poolToken`）必须在同一笔发射交易中通过 `Distribution` 参数交出去。当 `Distribution.target = VAULT` 时，Hub 会把它交给本次发射的 Vault：

```solidity
IStrategy(vault).initializeDistribution(token, amount, configData, salt);
```

如果你的 Vault 要接收预留代币，需要实现 [`IStrategy`](src/flap/IStrategy.sol)，加上 `onlyHub`，只允许执行一次，校验 `token == taxToken`，用 `transferFrom` 拉取恰好 `amount`（Hub 恰好授权了这么多，若有剩余授权会 revert `AllowanceNotFullyConsumed`），核对余额差额，并 emit `FlapDistributionInitialized`。Factory 在 `newVault` 中能看到完整的 `Distribution`，应当在那里校验（例如 `target == VAULT`、`amount == totalSupply × reserveBps / 10000`、`poolToken + amount == totalSupply`）。

余量策略对每次发射都生效：不超过 1 枚的余量会作为灰尘销毁，超过则 revert `ExcessiveRemainder`。发射后没有单独的分发入口。

### Token Dock：托管预留代币

预留代币应存放在共享的 **Token Dock** 中，而不是 Vault 自己。始终通过 `_getTokenDockRouter()` 调用 `deposit` / `withdraw` / `balanceOf`：

- **不要缓存 Dock 地址。** Hub 把 `(vault, token)` 加入白名单后，Router 会把存款路由到带标签的 `VerifiedTokenDock`，在此之前路由到无标签的 `OpenTokenDock`，并自动迁移余额。
- `withdraw` 永远不受限制。
- 在两个 Dock 都被排除出该代币的分红之前，不要把预留代币存进 Dock，先留在 Vault 中（Hub 会把 Vault 排除出分红）。

### 计算分红代币

如果发射的 DIVIDEND 槽位使用 `MAGIC_DIVIDEND_COMPUTED`，Hub 会通过 [`IVaultFactoryDividend.resolveDividendToken`](src/flap/ILaunchVaultSpec.sol) 向 Vault Factory 询问分红代币。Factory 没有实现该函数时，此类发射会被拒绝。当前版本中，非报价币的分红资产只允许在 DIVIDEND 槽位 `bps == 0`（仅追踪模式）时使用，`bps > 0` 会 revert。

---

## 如何编写你自己的 Vault

### Vault

1. **Vault**：继承 `DirectLaunchVaultBase`，实现 `description()`、`vaultUISchema()`、初始化函数，以及收入逻辑（余额差额记账，见上文）。
2. **Factory**：继承 `DirectLaunchVaultFactoryBase`，实现 `newVault`（`onlyHub`，先调用 `_validateLaunch`）、`isQuoteTokenSupported`、`vaultDataSchema`、`tokenCreationPolicies`、`upgradeVaultImplementation`（`onlyGuardian`）。
3. **测试**：见下文。
4. **部署 Factory** 到 BNB Chain：

   ```bash
   forge create src/vault/YourVaultFactory.sol:YourVaultFactory \
       --rpc-url https://bsc-dataseed.bnbchain.org --account deployer --broadcast
   ```

5. **发射**：把你的 Factory 放进发射参数的 VAULT 费用槽位：

   ```solidity
   p.feeConfigs[i] = IPortalTypes.FeeConfig({
       feeType: IPortalTypes.FeeSlotType.VAULT,
       bps: 7000,
       configData: abi.encode(IPortalTypes.FeeConfigVault({
           vaultFactory: address(yourFactory),
           vaultData: abi.encode(/* 你的 vaultData */)
       }))
   });
   IPortal(DIRECT_LAUNCH_PORTAL).launchTaxTokenV2{value: ...}(p, distribution, creatorBuy);
   ```

### Launcher

1. **Launcher**：继承 `LauncherBase`。把 Portal 地址保存在你自己的存储里，并从 `_getHub()` 返回。实现 `_description()`，填入用户应该看到的展示数据。在初始化函数里锁定 salt。机制完成后调用 `_launchOnHub(p, distribution, creatorBuy)`。
2. **Factory**：继承 `LauncherFactoryBase`，实现 `_newLauncher(creator, data)`、`launcherDataSchema()` 和 `upgradeVaultImplementation`（`onlyGuardian`）。
3. 如果发射需要 Vault，就**与 Vault 配对**，像 Crowd 配对那样。
4. 针对 Portal 替身进行**测试**，见下文。

各链地址（见 [`LaunchVaultAddresses.sol`](src/flap/LaunchVaultAddresses.sol)）：

| | BNB Chain (56) | BNB Testnet (97) |
|---|---|---|
| Direct Launch Portal (Hub) | `0x000042108465206185A077Edc3F3fd2b49060000` | `0x000042108465206185A077Edc3F3fd2b49060000` |
| Guardian | `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b` | `0x00004d58290854c5E9880F4b5B1993c6Ad8b0000` |
| TokenDockRouter | `0x000048E888aBf09f690a952E1b386b2D031a0000` | `0x000048E888aBf09f690a952E1b386b2D031a0000` |

---

## 审计前的测试

```bash
forge install            # 或：git submodule update --init --recursive
```

测试都是 fork 测试：[`test/`](test/README.zh-CN.md) 里有 fork 测试，针对 BNB Chain 和 BNB Testnet 上**线上的 Portal** 运行每个示例，不使用任何 mock。**每种模式一个**，因为你构建的东西决定了谁调用谁，以及 Flap 需要开放什么：

  | 模式 | 你要构建的 | 示例 | 测试 |
  |---|---|---|---|
  | **仅 Vault** | 接入普通发射的 Vault | `SplitVault` | [`vault/SplitVault`](test/vault/SplitVault.fork.t.sol) |
  | **仅 Vault，接收预留代币** | 被交付 80% 供应量并存入驿站的 Vault | `StakeMineVault` | [`vault/StakeMine`](test/vault/StakeMine.fork.t.sol) |
  | **仅 Launcher** | 先募集、再发射的 Launcher | `MintLauncher` | [`launcher/MintLauncher`](test/launcher/MintLauncher.fork.t.sol) |
  | **Launcher + Vault** | 两者互相锁定 | `CrowdLauncher` + `CrowdVault` | [`launcher-vault/Crowd`](test/launcher-vault/Crowd.fork.t.sol) |

  [`test/README.zh-CN.md`](test/README.zh-CN.md) 解释了这三种模式、每个测试覆盖什么，以及如何只跑一种模式或一条链。简要命令：

  ```bash
  cp .env.example .env        # 填入你自己的 RPC 地址，见文件里的说明
  set -a && . ./.env && set +a
  forge test --match-path "test/**/*.fork.t.sol"
  ```

你的测试至少应覆盖：

| # | 场景 | 断言 |
|---|---|---|
| 1 | Hub 调用 `newVault` | Vault 部署在预期地址，并用正确的 token / quote / 参数完成初始化 |
| 2 | 非 Hub 调用 `newVault` | revert（`NotHub`） |
| 3 | 非法 `vaultData` / 不支持的 quote / 不支持的 `launchKind` | `newVault` 在**部署前** revert |
| 4 | 原生币收入经 `receive()` 到账 | 正确记账 |
| 5 | ERC20 收入 + 零 value ping，以及多余的第二次 ping | 只记账一次（幂等） |
| 6 | 每一笔流出 | 基线已扣减，无重复计算 |
| 7 | Vault 核心操作（如 `claim()`）及其权限 | 金额正确；非法调用 revert |
| 8 | `upgradeVaultImplementation` | Guardian 成功，其他人 revert，升级后状态保留 |
| 9 | （如使用）`initializeDistribution` | 仅限 Hub；恰好拉取 `amount` |

请始终使用 `vm.startPrank(user)` / `vm.stopPrank()`，不要用单独的 `vm.prank(user)`，以免包含多次调用的辅助函数悄悄以错误的身份执行。

---

## 上线：Flap 审计

你的 Factory（Vault Factory 或 Launcher Factory）在用于发射之前，必须经过 Flap 审计。测试全部通过后，**请联系我们发起审计。** 审计通过后，经由你的 Factory 的发射即可开放，你的 Vault 会被标记为低风险。在此之前，它们在 Flap.sh 上显示为 **UNVERIFIED**。

请在发射代币之前完成：发射后你可能无法再修改 Vault，有些问题可能就无法补救了。
