# Fork tests

**English** | [中文](README.zh-CN.md)

These tests run the examples against the **live Portal** on BNB Chain and BNB Testnet, with nothing mocked. They do what you will do: deploy the factories, have Flap open them, launch, trade on the real pool so tax flows, then collect.

## Why there are three modes

What you build decides who calls whom, and so what has to be opened and what can go wrong. There are three shapes, and each has its own test:

| Mode | What you build | Who calls whom | Example | Test |
|---|---|---|---|---|
| **Vault only** | A Vault that receives a share of a token's tax revenue | A user launches as usual; the **Portal calls your Vault factory** to create the vault | `SplitVault` | [`vault/SplitVault`](vault/SplitVault.fork.t.sol) |
| **Vault only, takes the reserve** | A Vault that is also handed the launch's reserved tokens | Same, but the Portal also hands the vault 80% of the supply | `StakeMineVault` | [`vault/StakeMine`](vault/StakeMine.fork.t.sol) |
| **Launcher only** | A Launcher that raises or sells first, then launches | Users talk to your Launcher; **your Launcher calls the Portal** | `MintLauncher` | [`launcher/MintLauncher`](launcher/MintLauncher.fork.t.sol) |
| **Launcher + Vault** | Both, locked together | The Launcher calls the Portal, the Portal calls the Vault factory, and each factory only accepts the other | `CrowdLauncher` + `CrowdVault` | [`launcher-vault/Crowd`](launcher-vault/Crowd.fork.t.sol) |

In short:

- With a **Vault**, you are the one being called. Your factory must refuse any launch that is not the exact shape your vault serves.
- With a **Launcher**, you are the one calling. Your Launcher must lock its own salt, launch once and pass exactly the right value.
- With **both**, the two must trust each other and nothing else, so a stranger cannot pose as your Launcher.

What Flap does for each is different too: a Vault factory is audited and opened; a Launcher factory is audited and opened. For a pair, the Launcher is what the Portal judges: since Portal `v1.1.2` a recorded Launcher is covered by its own Launcher factory alone, and the Vault factory's `enabled` flag only sets the liquidity-floor multiplier. A test for each mode keeps those differences visible instead of blurring them into one generic scenario.

## What each test covers

- **`SplitVault`**: an ordinary launch, tax from trading on the real pool, and every recipient's claim.
- **`StakeMine`**: a launch that does not hand over the reserve is refused; the full reserve sits in the Token Dock; staking in two tiers weighs x1 and x2 and mining follows the weights; the lock holds, then releases; the dev's 1% vests; revenue goes 20% to the dev and the rest to the holders; only the Guardian upgrades.
- **`MintLauncher`**: a factory that is not opened is refused; contributions until the target; the launch shows the real creator; claims; a refund when the target is missed; one launch per Launcher; `description()` renders the v1 JSON and the Portal folds the very same string into `FlapNewLauncherCreated`.
- **`Crowd`**: the Launcher factory alone covers the launch while the Vault side stays closed, and a disabled Launcher factory blocks it even with the Vault side open; the full journey with trading, tax and every claim; a stranger Launcher is refused by the Vault factory; `description()` and its event payload are checked here too.
- **`LauncherDescription`**: the display surface without a chain: the exact v1 JSON, escaping of `name`/`symbol`, and that the rendered string stays inside the Portal's 4 KB read limit.

## Layout

```
test/
├── ForkBase.sol            what every test shares: the live Portal, funded accounts, opening a factory,
│                           mining a salt, trading, dispatching tax
├── ForkAddresses.sol       every address, for both chains
├── LauncherDescription.t.sol  the v1 display JSON, no chain needed
├── vault/                  SplitVault.*  StakeMine.*
├── launcher/               MintLauncher.*
└── launcher-vault/         Crowd.*
```

Each example has three files:

| File | Role |
|---|---|
| `<Example>.fork.t.sol` | The scenarios, as an abstract contract. |
| `<Example>.BSC.fork.t.sol` | Runs them on BNB Chain (`BSC_RPC_URL`). |
| `<Example>.BSCTest.fork.t.sol` | Runs them on BNB Testnet (`BSC_TESTNET_RPC_URL`). |

A test is skipped when its RPC variable is not set.

## Run

Put your RPC URLs in a `.env` (it is git-ignored) and run:

```bash
cp .env.example .env       # then fill in BSC_RPC_URL and BSC_TESTNET_RPC_URL
set -a && . ./.env && set +a
forge test --match-path "test/**/*.fork.t.sol"
```

**Use your own node or a provider key.** A fork test reads thousands of storage slots (everything the launch, the pool and the trades touch), and the free public endpoints rate limit and prune old state, so a run is slow and can fail halfway for reasons that have nothing to do with your contracts. Any BNB Chain provider key, or your own node, avoids that. The public endpoints in [`.env.example`](../.env.example) are fine for trying a single test.

One mode or one chain:

```bash
forge test --match-path "test/launcher/*"          # Launcher only, both chains
forge test --match-path "test/**/*.BSCTest.*"      # BNB Testnet, every mode
```

## Notes

- The Portal, its ProxyAdmin and the tax token implementation are the same on both chains. The Guardian, WBNB and the V2 router differ, and `ForkAddresses` holds both sets. `setUp` asserts that its Hub and Guardian agree with `LaunchVaultAddresses`, which the factories resolve at run time, so the two cannot drift apart unnoticed.
- The tests use plain accounts, not `makeAddr`: a hashed address can collide with a live mainnet account, and one of them carried EIP-7702 code and forwarded a refund away.
- To add a chain: one function in `ForkAddresses` and one thin class per example.
- Both chains run Portal **`v1.1.2`**, which emits `FlapNewLauncherCreated` with the Launcher's `description()` folded in as a fourth argument. `setUp` asserts the version, so a chain that later moves off `v1.1.2` fails with a stated reason instead of a confusing assertion. The suites compare the event payload with `description()` itself.
