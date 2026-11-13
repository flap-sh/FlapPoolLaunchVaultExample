# Flap Pool Launch Vault and Launcher Examples

**English** | [中文](README.zh-CN.md)

> ⚠️ **This repo is for Flap _Pool Launch_ (Direct Launch) vaults only.**
> Pool Launch tokens skip the bonding curve: the token is seeded straight into a V2 pool at launch. Its vault spec is **not** the same as the Bonding Curve Tax Vault spec. If your token launches on the bonding curve (`VaultPortal.newTokenV6WithVault`), use [FlapVaultExample](https://github.com/flap-sh/FlapVaultExample) instead. Contracts written for one framework do **not** work on the other.

This repo contains the canonical Pool Launch interfaces and reference implementations for the two things you can build on a launch:

- **Vault**: receives a share of the token's quote revenue (and, optionally, the reserved tokens). Examples: `SplitVault`, `CrowdVault`.
- **Launcher**: the contract users interact with *before* the token exists (a raise, a mint, a presale). When its conditions are met it launches the token itself. Examples: `MintLauncher`, `CrowdLauncher`.

A Launcher can launch with no vault, or pair with one. `CrowdLauncher` + `CrowdVault` is the paired example.

---

## Table of Contents

- [Pool Launch vs. Bonding Curve: Which Spec Do I Need?](#pool-launch-vs-bonding-curve-which-spec-do-i-need)
- [Directory Structure](#directory-structure)
- [The Pool Launch Vault Interfaces](#the-pool-launch-vault-interfaces)
- [How a Pool Launch Vault Gets Created](#how-a-pool-launch-vault-gets-created)
- [Quote Revenue: Native and ERC20](#quote-revenue-native-and-erc20)
- [The SplitVault Example](#the-splitvault-example)
- [The StakeMine Example: a Vault that takes the reserve](#the-stakemine-example-a-vault-that-takes-the-reserve)
- [The Crowd Pair: a Launcher and a Vault](#the-crowd-pair-a-launcher-and-a-vault)
- [The Launcher Interfaces](#the-launcher-interfaces)
- [Recommended Deployment Pattern: Beacon-Upgradeable Vaults](#recommended-deployment-pattern-beacon-upgradeable-vaults)
- [Optional Features](#optional-features)
  - [Receiving the dev-reserved token remainder](#receiving-the-dev-reserved-token-remainder)
  - [Token Dock: holding reserved tokens](#token-dock-holding-reserved-tokens)
  - [Computed dividend token](#computed-dividend-token)
- [How to Build Your Own Vault](#how-to-build-your-own-vault)
- [Testing Before Audit](#testing-before-audit)
- [Going Live: Flap Audit](#going-live-flap-audit)

---

## Pool Launch vs. Bonding Curve: Which Spec Do I Need?

| | **Pool Launch** (this repo) | **Bonding Curve** ([FlapVaultExample](https://github.com/flap-sh/FlapVaultExample)) |
|---|---|---|
| How the token starts trading | Seeded straight into a V2 pool at launch | Starts on the Flap bonding curve, then graduates to a DEX |
| Who calls your factory | **Direct Launch Portal** (the "Hub") | VaultPortal |
| Launch entry point | `launchTaxTokenV2(...)` | `newTokenV6WithVault(...)` |
| Factory base | `DirectLaunchVaultFactoryBase` | `VaultFactoryBaseV2` |
| Vault base | `DirectLaunchVaultBase` | `VaultBaseV2` / `VaultBaseV3` |
| Factory create function | `newVault(token, creator, launchKind, launchParams)` | `newVault(taxToken, quoteToken, creator, vaultData)` |
| `factorySpecVersion()` | `"pl-v1"` | `"v2.x"` |
| Reserved token remainder | Can go to the vault (`IStrategy.initializeDistribution`) | N/A |

> The Direct Launch Portal is **not** the Bonding Curve Portal or the VaultPortal. Never mix their addresses.

The UI schema structs (`VaultUISchema`, `VaultDataSchema`, `FieldDescriptor`, ...) in [`IVaultSchemas.sol`](src/flap/IVaultSchemas.sol) are the same as in the Bonding Curve spec. If you already know them, your UI-schema code carries over.

---

## Directory Structure

`src/flap/` contains the canonical Pool Launch spec files and the recommended bases, including the two Launcher bases; keep its interfaces and behavior unchanged. The examples are grouped by what you build: `src/vault/` (Vault references behind a Launcher), `src/launcher/` (a Launcher only) and `src/launcher-vault/` (a Launcher and a Vault built as a pair, which must be read together).

> **Beta:** every token launch must go through a Launcher whose LauncherFactory Flap has enabled. `src/vault/` contains reference vaults to use behind a Launcher; it is not a standalone launch mode. The vault-only fork tests unpause the Portal to isolate vault behavior.

```
src/
├── flap/                              ← REQUIRED & IMMUTABLE — do not rename or modify
│   ├── ILaunchVaultSpec.sol           ← IDirectLaunchVault / IDirectLaunchVaultFactory / ITokenDock / ...
│   ├── DirectLaunchVaultBase.sol      ← recommended base for your vault
│   ├── DirectLaunchVaultFactoryBase.sol ← recommended base for your vault factory
│   ├── ILauncher.sol                  ← ILauncherFactory / LauncherRecord
│   ├── LauncherBase.sol               ← recommended base for your Launcher
│   ├── LauncherHelper.sol             ← builds the v1 JSON `description()` returns
│   ├── LauncherFactoryBase.sol        ← base for your Launcher factory
│   ├── IPortal.sol                    ← launch params (CreateTaxTokenParams, FeeConfig, ...) and the Portal calls a Launcher makes
│   ├── IVaultSchemas.sol              ← UI schema structs (vault and launcher)
│   ├── IDividend.sol                  ← dividend tracker a tax token deploys (a vault may deposit into it)
│   ├── IStrategy.sol                  ← remainder hand-off interface
│   ├── Distribution.sol               ← remainder hand-off struct
│   ├── LaunchVaultAddresses.sol       ← per-chain Hub / Guardian / Token Dock addresses
│   └── LaunchExtensionHelper.sol      ← creator-display helper for Launchers (no imports, copy it as is)
├── common/                            ← shared anti-scam name/symbol check for Launcher factories
├── vault/                             ← Vault references (behind a Launcher)
│   ├── SplitVault.sol / SplitVaultFactory.sol   ← split revenue across recipients by bps
│   └── StakeMineVault.sol / StakeMineVaultFactory.sol ← takes the reserve, docks it, stake-to-mine
├── launcher/                          ← Launcher only
│   └── MintLauncher.sol / MintLauncherFactory.sol    ← raise to a target, then launch once
└── launcher-vault/                    ← Launcher + Vault, built as a pair
    ├── CrowdLauncher.sol / CrowdLauncherFactory.sol  ← crowd-funded launch
    └── CrowdVault.sol / CrowdVaultFactory.sol        ← contributors share the tax revenue pro rata
```

---

## The Pool Launch Vault Interfaces

Only two interfaces are mandatory. Both live in [`ILaunchVaultSpec.sol`](src/flap/ILaunchVaultSpec.sol).

**`IDirectLaunchVault`**: the vault's entire mandatory surface:

| Function | Requirement |
|---|---|
| `description()` | Dynamic, human-readable status. **MUST** disclose any fees/commission and every party that receives revenue or reserved tokens. |
| `vaultUISchema()` | Describes every user- or keeper-facing method, so Flap.sh can render an interaction panel. |

**`IDirectLaunchVaultFactory`**:

| Function | Requirement |
|---|---|
| `newVault(token, creator, launchKind, launchParams)` | Validate the launch **and** create the vault in one call. Called by the Hub only. |
| `isQuoteTokenSupported(quote)` | Truthful; must match what `newVault` accepts. `address(0)` = native. |
| `factorySpecVersion()` | Returns `"pl-v1"`. |
| `vaultDataSchema()` | Describes your `vaultData` bytes, so Flap.sh can render the creation form. |
| `tokenCreationPolicies()` | UI hints that mirror the checks in `newVault` (informational only). |
| `upgradeVaultImplementation(newImpl)` | Upgrades all vaults of this factory. **Guardian-only** for the low-risk badge. |

[`DirectLaunchVaultBase`](src/flap/DirectLaunchVaultBase.sol) and [`DirectLaunchVaultFactoryBase`](src/flap/DirectLaunchVaultFactoryBase.sol) are recommended (not mandatory) bases. They hold no storage and only provide:

- `onlyHub` / `onlyGuardian` modifiers, resolved per chain from [`LaunchVaultAddresses`](src/flap/LaunchVaultAddresses.sol);
- `_validateLaunch()` / `_requireNoReserveDistribution()` strict launch checks, and `_decodeLaunchParams()` / `_vaultDataFor()` decode helpers (factory);
- `_getTokenDockRouter()` (vault).

All interfaces carry detailed NatSpec. Read them; they are the normative spec.

---

## How a Pool Launch Vault Gets Created

```
creator ──launchTaxTokenV2(p, distribution, creatorBuy)──▶ Direct Launch Portal (Hub)
                                                              │
                     1. parse p.feeConfigs, find the VAULT slot {vaultFactory, vaultData}
                     2. newVault(predictedToken, creator, launchKind, abi.encode(p, distribution))
                                                              ▼
                                                        YourFactory ──deploys──▶ YourVault
                     3. deploy token, seed + lock the V2 pool
                     4. (optional) distribution → vault.initializeDistribution(...)
                     5. from then on: TaxProcessor pays the VAULT slot's bps share of tax revenue to the vault
```

Key facts for `newVault`:

- **`token` has no code yet.** It is a CREATE2 prediction. Never call it.
- **`launchParams` is the full raw launch input**: `abi.encode(IPortalTypes.CreateTaxTokenParams, Distribution)`. Call `_validateLaunch(...)`: it decodes the input, runs the checks every factory needs and returns your own `vaultData`.
- **`p.quoteToken` is raw.** `address(0)` means native. There is no WBNB normalization.
- **Gate it with `onlyHub`.** Otherwise anyone can pre-deploy your deterministic vault address and make the real launch revert on the CREATE2 collision.
- **Validate before deploying**, and revert with a clear reason if the launch is not acceptable. `_validateLaunch` rejects a zero `token` or `creator`, a missing or duplicate VAULT slot for your factory, a zero-bps slot and an unsupported quote. A vault that does not take the reserve also calls `_requireNoReserveDistribution`. Then decode your own `vaultData` strictly: reject trailing or truncated bytes instead of ignoring them.
- Only `LaunchKind.DIRECT_V2_POOL_TAX` (0) exists today. `_validateLaunch()` reverts on any other kind, so future kinds are opt-in.

Fee slots: a launch has at most 4 `feeConfigs` whose bps sum to 10000, and **VAULT and MARKETING are mutually exclusive**: a launch has either one vault or one marketing wallet.

Liquidity floor: the Hub requires the USD value of the seeded quote (`poolQuote × quotePriceUsd`) to reach a floor that scales with `totalSupply / poolToken`. Below the creation floor the launch reverts `LaunchLiquidityTooLow`; at twice that floor the token is marked graduated in the launch transaction. So the larger the share your vault reserves (the smaller `poolToken`), the more quote the creator must seed. Flap can set a per-factory multiplier (≤ 10000) that lowers both floors for launches through your factory. Agree it with Flap during the audit. `PortalLaunchLens.graduationFloorV2(...)` previews the numbers.

---

## Quote Revenue: Native and ERC20

Pool Launch supports native (BNB) and ERC20 quote tokens, but only the pairs the protocol has enabled: a launch whose `(DIRECT_V2_POOL_TAX, quoteToken)` is not enabled reverts `LaunchQuotePairNotEnabled`. Check `launchQuoteConfig(kind, quote)` on the Hub. Your vault receives revenue in the launch's quote currency:

- **Native**: the TaxProcessor sends value, which invokes `receive()`.
- **ERC20**: the TaxProcessor does a plain `transfer`, then sends a **zero-value, empty-calldata "ping"** to the vault, which also lands in `receive()`. The ping is failure-tolerant, forwards the dispatcher's gas, and may fire spuriously.

So the vault must recognize revenue by **balance-delta accounting**: compare the current quote balance against a stored baseline (`balance - accountedQuote`), never `msg.value` or the raw balance. **Every outflow must decrement the baseline.** Keep `receive()` lightweight and idempotent. This is the same model as the Bonding Curve V3 ERC20 spec.

`isQuoteTokenSupported()` must tell the truth. If it claims support for a quote your vault ignores, users' tax revenue is stranded.

---

## The SplitVault Example

[`SplitVaultFactory`](src/vault/SplitVaultFactory.sol) reads `vaultData = abi.encode(SplitVault.Recipient[])` and deploys one [`SplitVault`](src/vault/SplitVault.sol) beacon proxy per launch. The vault credits each recipient's share on every `receive()` / `sync()`, and each recipient pulls with `claim()`.

The factory's `vaultDataSchema()` tells Flap.sh how to render the creation form:

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

The vault's `vaultUISchema()` describes `claimable`, `claimed`, `recipients` and `claim`. Its `description()` lists every recipient and its share, which satisfies the disclosure rule:

```
SplitVault: 100% of this vault's quote revenue is split across 3 recipients, no fee: 0x…1111=5000bps; 0x…2222=3000bps; 0x…3333=2000bps; each recipient pulls its share via claim().
```

The factory's `newVault` validates strictly, then deploys:

```solidity
function newVault(address token, address creator, uint8 launchKind, bytes calldata launchParams)
    external override onlyHub returns (address vault)
{
    (IPortalTypes.CreateTaxTokenParams memory p, Distribution memory d, bytes memory vaultData) =
        _validateLaunch(token, creator, launchKind, launchParams);
    _requireNoReserveDistribution(d);
    SplitVault.Recipient[] memory recipients = _decodeRecipients(vaultData); // exact size, unique, bps sum = 10000

    vault = LibClone.deployDeterministicERC1967BeaconProxy(beacon, bytes32(uint256(uint160(token))));
    SplitVault(payable(vault)).initialize(token, quote, weth, recipients);
}
```

The factory takes `weth` in its constructor and passes a native launch's raw quote (`address(0)`) to the vault as WETH. The vault compares `quoteToken == weth` to know it is receiving native BNB, so one balance-delta baseline covers both cases.

---

## The StakeMine Example: a Vault that takes the reserve

[`StakeMineVaultFactory`](src/vault/StakeMineVaultFactory.sol) is the example for a Vault whose economics depend on the launch's reserve. The launch hands the vault 80% of the supply (`Distribution.target == VAULT`), and the factory **refuses any launch that is not shaped that way** before it deploys anything: the target must be `VAULT`, the amount exactly 80% of the supply, and the pool must hold the other 20%.

[`StakeMineVault`](src/vault/StakeMineVault.sol) then:

- docks **all** of the reserve in the Token Dock through `TokenDockRouter`, so terminals see a labeled reserve instead of one giant unknown holder. Until Flap whitelists the vault the reserve sits in the open dock, and it moves to the verified dock on its own afterwards; the vault never caches the router and never sees the switch;
- vests 1% of the supply to the dev, linearly over 30 days, pulled with `claimDevVested`;
- mines the other 79% to stakers over 90 days, in proportion to weight (`amount × tier multiplier`: 30 days x1, 90 days x1.5, 180 days x2 by default);
- splits quote revenue on arrival: 20% to the dev until it has recouped 1.5x the quote it seeded, the rest to the token's dividend tracker through the permissionless `flushDividends`. The factory therefore refuses a launch that has no DIVIDEND slot, or one that pays in another asset than the quote.

---

## The Crowd Pair: a Launcher and a Vault

[`CrowdLauncher`](src/launcher-vault/CrowdLauncher.sol) raises BNB from many contributors. When the target is met, the contribution that reaches it launches the token in the same transaction. Contributors then claim half of the supply pro rata, and also share the token's tax revenue through a paired [`CrowdVault`](src/launcher-vault/CrowdVault.sol). If the target is missed, everyone is refunded.

```
creator ──Portal.newLauncher(CrowdLauncherFactory, config)──▶ CrowdLauncher   (locks its own salt)
contributors ──contribute()──▶ CrowdLauncher
        the last contribution reaches the target
CrowdLauncher ──launchTaxTokenV2(...)──▶ Portal ──newVault(...)──▶ CrowdVaultFactory ──deploys──▶ CrowdVault
                                         Portal ──initializeDistribution(...)──▶ CrowdLauncher   (the reserved half)
```

The two factories are locked together, so a Vault only ever serves its paired Launcher:

- `CrowdLauncherFactory` accepts only its own `CrowdVaultFactory` in the config.
- `CrowdVaultFactory.newVault` checks that the caller is a Launcher created by that Launcher factory (read from the Portal's record), that `vaultData` names the calling Launcher, and that the Launcher is mid-launch with the full raise in.

---

## The Launcher Interfaces

A Launcher factory implements `ILauncherFactory` ([`ILauncher.sol`](src/flap/ILauncher.sol)). The Portal calls it from `Portal.newLauncher(factory, data)`.

| Function | Requirement |
|---|---|
| `newLauncher(creator, data)` | Deploy and initialize the Launcher in one call. Called by the Portal only (`onlyHub`). `creator` is the wallet that called the Portal; `data` is yours to define. |
| `factorySpecVersion()` | Returns `"lf-v1"`. |
| `launcherDataSchema()` | Describes your `data` bytes so Flap.sh can render the creation form. |
| `upgradeVaultImplementation(newImpl)` | Upgrades every Launcher of this factory. **Guardian-only.** A factory with immutable Launchers reverts. |

[`LauncherFactoryBase`](src/flap/LauncherFactoryBase.sol) and [`LauncherBase`](src/flap/LauncherBase.sol) are storage-free bases. `LauncherFactoryBase` applies `onlyHub` to `newLauncher` and fixes `factorySpecVersion`; `LauncherBase` gives your Launcher `_getHub()`, `onlyHub`, `onlyGuardian`, `_launchOnHub(...)` and `description()` (implement `_description()`; `LauncherHelper` renders it as the v1 JSON the Portal folds into `FlapNewLauncherCreated`).

Things a Launcher must get right:

- **Lock the salt from the Launcher when you use a lock (recommended).** `Portal.lockSalt` records `msg.sender` as the locker. A lock taken by the factory makes the launch revert.
- **Launch once.** The Portal allows one launch per Launcher.
- **Pass exactly the right value.** For a native quote, `msg.value` of the launch must equal `poolQuote + creatorBuyQuote`.
- **Let the Guardian use every privileged function.** This includes any manual launch, pause, withdrawal or parameter change you add.
- **Show the real creator.** The Launcher calls the Portal, so `FlapDirectLaunched.creator` would be the Launcher. Declare the user instead:

  ```solidity
  (p.extensionID, p.extensionData) = LaunchExtensionHelper.encodeCreator(creator);
  ```

  It changes only the `creator` field of the launch event. The vault, salt lock and payment still use the Launcher. Only a Launcher created through `Portal.newLauncher` may use it.
- **Keep `description()` under 4 KB.** The Portal reads at most 4,096 bytes and silently stores `""` past it, so an oversized JSON disappears with no revert and no error. The fixed copy in these examples is 0.7–1 KB, which leaves about 3 KB for the user's `name` and `symbol`; a launcher that renders more should cap those fields. `description()` is display-only: it never affects gating, accounting or payments, and a broken one must not break the launch.

[`MintLauncher`](src/launcher/MintLauncher.sol) is the smallest example: raise a fixed amount, launch once, distribute the reserve to contributors.

---

## Recommended Deployment Pattern: Beacon-Upgradeable Vaults

- **The factory is immutable.** To change it, deploy a new factory.
- **The vaults are upgradeable** through a solady `UpgradeableBeacon` owned by the factory, with one `LibClone.deployDeterministicERC1967BeaconProxy` per launch, keyed by the token address. One beacon upgrade retargets every launched vault.
- Give the vault implementation a `version()` and bump it on each upgrade.

### Upgrade authority: Guardian only

For the low-risk badge, **`upgradeVaultImplementation` must be callable by the Flap Guardian only** (`onlyGuardian`), and there must be no other upgrade path: no owner, proxy admin, beacon owner, upgrader role, multisig or deployer EOA. A factory that wants no upgrades at all may revert unconditionally.

Every other permissioned vault function must **also accept the Guardian**, e.g. `if (msg.sender != creator && msg.sender != _getGuardian()) revert`.

> **The Guardian address is controlled by the Flap security team.** If you need an upgrade, for example to patch a bug, contact us. The security team needs about **24 hours** to assess the request, verify the change, and execute it if approved. Do not design your vault to depend on upgrading unilaterally or on short notice.

---

## Optional Features

### Receiving the dev-reserved token remainder

A Pool Launch seeds `p.poolToken` of the supply into the pool. Any remainder (`totalSupply - poolToken`) must be handed off in the same launch transaction through the `Distribution` argument. With `Distribution.target = VAULT`, the Hub sends it to this launch's vault by calling:

```solidity
IStrategy(vault).initializeDistribution(token, amount, configData, salt);
```

If your vault accepts the remainder, implement [`IStrategy`](src/flap/IStrategy.sol), gate it with `onlyHub`, allow it to run only once, check `token == taxToken`, pull exactly `amount` with `transferFrom` (the Hub has approved exactly that much and reverts `AllowanceNotFullyConsumed` if any allowance is left), verify the balance delta, and emit `FlapDistributionInitialized`. Your factory sees the full `Distribution` in `newVault` and should validate it there (e.g. `target == VAULT`, `amount == totalSupply × reserveBps / 10000`, `poolToken + amount == totalSupply`).

The remainder policy runs for every launch: a residual of at most 1 token is burned as dust; anything larger reverts `ExcessiveRemainder`. There is no post-launch distribution entry point.

### Token Dock: holding reserved tokens

Reserved tokens should be held in the shared **Token Dock**, not in the vault itself. Always go through `_getTokenDockRouter()` and call `deposit` / `withdraw` / `balanceOf` on it:

- **Never cache the dock address.** The router sends deposits to the labeled `VerifiedTokenDock` once the Hub has whitelisted `(vault, token)`, and to the unlabeled `OpenTokenDock` before that. It migrates the balance transparently.
- `withdraw` is never gated.
- Don't move a reserve into a dock until both docks are excluded from the token's dividends. Until then, keep it in the vault (the Hub excludes the vault).

### Computed dividend token

If the launch's DIVIDEND slot uses `MAGIC_DIVIDEND_COMPUTED`, the Hub asks the vault factory which token to distribute through [`IVaultFactoryDividend.resolveDividendToken`](src/flap/ILaunchVaultSpec.sol). Launches that request it from a factory without that function are rejected. In the current release a non-quote dividend asset is only allowed when the DIVIDEND slot has `bps == 0` (tracker-only); with `bps > 0` the launch reverts.

---

## How to Build Your Own Vault

### A Vault

1. **Vault**: inherit `DirectLaunchVaultBase`, then implement `description()`, `vaultUISchema()`, an initializer, and your revenue logic (balance-delta accounting, see above).
2. **Factory**: inherit `DirectLaunchVaultFactoryBase`, then implement `newVault` (`onlyHub`, call `_validateLaunch` first), `isQuoteTokenSupported`, `vaultDataSchema`, `tokenCreationPolicies`, and `upgradeVaultImplementation` (`onlyGuardian`).
3. **Test**: see below.
4. **Deploy your factory** to BNB Chain:

   ```bash
   forge create src/vault/YourVaultFactory.sol:YourVaultFactory \
       --rpc-url https://bsc-dataseed.bnbchain.org --account deployer --broadcast
   ```

5. **Launch**: put your factory into the launch's VAULT fee slot:

   ```solidity
   p.feeConfigs[i] = IPortalTypes.FeeConfig({
       feeType: IPortalTypes.FeeSlotType.VAULT,
       bps: 7000,
       configData: abi.encode(IPortalTypes.FeeConfigVault({
           vaultFactory: address(yourFactory),
           vaultData: abi.encode(/* your vaultData */)
       }))
   });
   IPortal(DIRECT_LAUNCH_PORTAL).launchTaxTokenV2{value: ...}(p, distribution, creatorBuy);
   ```

### A Launcher

1. **Launcher**: inherit `LauncherBase`. Keep the Portal address in your own storage and return it from `_getHub()`. Implement `_description()` with the values users should see next to the Launcher. Locking the salt in your initializer is recommended. Let the Guardian call every privileged function you add. When the mechanism completes, call `_launchOnHub(p, distribution, creatorBuy)`.
2. **Factory**: inherit `LauncherFactoryBase`, then implement `_newLauncher(creator, data)`, `launcherDataSchema()` and `upgradeVaultImplementation` (`onlyGuardian`).
3. **Pair it with a Vault** if the launch needs one, as the Crowd pair does.
4. **Test** against the live Portal on a fork, see below.

Per-chain addresses (see [`LaunchVaultAddresses.sol`](src/flap/LaunchVaultAddresses.sol)):

| | BNB Chain (56) | BNB Testnet (97) |
|---|---|---|
| Direct Launch Portal (Hub) | `0x000042108465206185A077Edc3F3fd2b49060000` | `0x000042108465206185A077Edc3F3fd2b49060000` |
| Guardian | `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b` | `0x00004d58290854c5E9880F4b5B1993c6Ad8b0000` |
| TokenDockRouter | `0x000048E888aBf09f690a952E1b386b2D031a0000` | `0x000048E888aBf09f690a952E1b386b2D031a0000` |

---

## Testing Before Audit

```bash
forge install            # or: git submodule update --init --recursive
```

The tests are fork tests: [`test/`](test/README.md) has fork tests that run each example against the **live Portal** on BNB Chain and BNB Testnet, with nothing mocked. The Vault reference tests lift the creation pause to test the vaults separately:

  | Mode | You build | Example | Test |
  |---|---|---|---|
  | **Vault reference** | a Vault plugged into a launch behind a Launcher | `SplitVault` | [`vault/SplitVault`](test/vault/SplitVault.fork.t.sol) |
  | **Vault reference, takes the reserve** | a Vault that is handed 80% of the supply and docks it | `StakeMineVault` | [`vault/StakeMine`](test/vault/StakeMine.fork.t.sol) |
  | **Launcher only** | a Launcher that raises, then launches | `MintLauncher` | [`launcher/MintLauncher`](test/launcher/MintLauncher.fork.t.sol) |
  | **Launcher + Vault** | both, locked together | `CrowdLauncher` + `CrowdVault` | [`launcher-vault/Crowd`](test/launcher-vault/Crowd.fork.t.sol) |

  [`test/README.md`](test/README.md) explains the three modes, what each test covers and how to run one mode or one chain. The short version:

  ```bash
  cp .env.example .env        # fill in your own RPC URLs, see the note in the file
  set -a && . ./.env && set +a
  forge test --match-path "test/**/*.fork.t.sol"
  ```

At minimum your test suite should cover:

| # | Scenario | What to assert |
|---|---|---|
| 1 | Hub calls `newVault` | Vault deployed at the expected address, initialized with the right token / quote / params |
| 2 | Non-Hub calls `newVault` | Reverts (`NotHub`) |
| 3 | Invalid `vaultData` / unsupported quote / unsupported `launchKind` | `newVault` reverts **before** deploying |
| 4 | Native revenue arrives via `receive()` | Credited correctly |
| 5 | ERC20 revenue + zero-value ping, and a spurious second ping | Credited once (idempotent) |
| 6 | Every outflow | Baseline decremented; no double counting |
| 7 | Core vault action (e.g. `claim()`) and its gating | Expected payout; invalid calls revert |
| 8 | `upgradeVaultImplementation` | Guardian succeeds; everyone else reverts; state survives the upgrade |
| 9 | (if used) `initializeDistribution` | Hub-only; pulls exactly `amount` |

Always use `vm.startPrank(user)` / `vm.stopPrank()` instead of bare `vm.prank(user)`, so multi-call helpers don't silently run as the wrong sender.

---

## Going Live: Flap Audit

Every factory must be audited by Flap before it is used for launches. Once your tests pass, **reach out to us to start the audit.** During the beta Flap enables LauncherFactories only; a Vault Factory may also need a floor multiplier when a launchpad template uses one. Until audit, vaults show as **UNVERIFIED** on Flap.sh.

Do this before you launch your token: after launch you may not be able to change the vault, and some issues may no longer be fixable.
