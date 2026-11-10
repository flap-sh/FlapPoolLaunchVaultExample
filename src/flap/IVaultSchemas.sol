// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title IVaultSchemas
/// @notice Shared, on-chain UI-discovery structs for Flap Launcher vaults and vault factories.
/// @dev Ported from the bonding-contract `FlapVaultExample` repo's `IVaultSchemasV1` and adapted to the
///      launcher spec. The launcher has no VaultPortal: a vault factory is a plain
///      `IDirectLaunchVaultFactory` (see `src/interfaces/ILaunchVaultSpec.sol`) that Portal's create
///      facets invoke once, and the vault
///      it returns becomes the token's VAULT fee-slot recipient (provenance recorded via the embedded
///      `VaultLaunch` facet). Because anyone may publish a factory, a generic UI has no compile-time
///      knowledge of a vault's parameters or user-facing methods. The structs below let a vault
///      self-describe:
///        - `DirectLaunchVaultFactoryBase.vaultDataSchema()` describes the `vaultData` bytes a factory expects
///          (so the UI can render a creation form), and
///        - `DirectLaunchVaultBase.vaultUISchema()` describes the vault's user-facing view/write methods
///          (so the UI can render an interaction page).
///
///      This is complementary to the on-chain `VaultLaunch` UI-artifact registry (`BindingScope` /
///      `resolveArtifact`): the artifact registry points a token/vault/factory at an off-chain UI
///      bundle, while these schemas let the UI build a page from scratch for a vault it has never
///      seen before.

// ──────────────────────────────────────────────────────────────────────────────
//  Shared leaf type
// ──────────────────────────────────────────────────────────────────────────────

/// @notice Describes a single field: a method parameter, a return value, or one component of the
///         `vaultData` tuple.
/// @param name        Machine-readable field name (e.g. "amount", "recipient", "bps").
/// @param fieldType   Solidity ABI type string: "string" | "address" | "uint16" | "uint256" |
///                    "uint128" | "bool" | "bytes" | "bytes32". The special value "time" is an alias
///                    for "uint256" holding a Unix timestamp (rendered as a date picker / countdown).
///                    The special value "msg.value" marks a native-currency input that is NOT
///                    ABI-encoded but sent as the call's `value` (write methods only).
/// @param description Human-readable label/tooltip shown in the UI.
/// @param decimals    Numeric scaling hint. As a factory input, the UI multiplies the user's entry by
///                    10^decimals before encoding; as a vault output, the UI divides the raw value by
///                    10^decimals for display. Always 0 for non-numeric fields.
struct FieldDescriptor {
    string name;
    string fieldType;
    string description;
    uint8 decimals;
}

// ──────────────────────────────────────────────────────────────────────────────
//  Factory side: VaultDataSchema
// ──────────────────────────────────────────────────────────────────────────────

/// @notice Describes the shape of the opaque `vaultData` bytes a factory's `newVault()` expects.
/// @dev A UI calls `factory.vaultDataSchema()`, renders one input per field, and ABI-encodes the result
///      as `abi.encode(tuple)` (or `abi.encode(tuple[])` when `isArray`). Empty `fields` + `isArray ==
///      false` means the factory ignores `vaultData` entirely.
/// @param description Free-form explanation shown to the user.
/// @param fields      Ordered components of the ABI-encoded tuple.
/// @param isArray     True if `vaultData` is an array of the tuple described by `fields`.
struct VaultDataSchema {
    string description;
    FieldDescriptor[] fields;
    bool isArray;
}

/// @notice Describes the shape of the opaque `data` bytes a LauncherFactory's `newLauncher()` expects.
/// @dev Same layout as `VaultDataSchema`.
/// @param description Free-form explanation shown to the user.
/// @param fields      Ordered components of the ABI-encoded tuple.
/// @param isArray     True if `data` is an array of the tuple described by `fields`.
struct LauncherDataSchema {
    string description;
    FieldDescriptor[] fields;
    bool isArray;
}

// ──────────────────────────────────────────────────────────────────────────────
//  Vault side: VaultUISchema & supporting types
// ──────────────────────────────────────────────────────────────────────────────

/// @notice An ERC-20 approval the UI must execute before calling a write method. The spender is always
///         the vault itself.
/// @dev Known `tokenType` values: "taxToken" (resolved via `vault.taxToken()`) and "lpToken"
///      (resolved via `vault.lpToken()`). The UI MUST ignore unknown token types (forward-compatible).
/// @param tokenType       Which token to approve (e.g. "taxToken", "lpToken").
/// @param amountFieldName The `name` of the write method's input field whose (already-scaled) value is
///                        the approve amount (e.g. "amount").
struct ApproveAction {
    string tokenType;
    string amountFieldName;
}

/// @notice Describes one view or write method the UI should render for a vault.
/// @param name          Solidity method name (e.g. "stake", "claim", "stakedBalance").
/// @param description   Human-readable explanation.
/// @param inputs        Ordered input fields (empty for no-arg methods).
/// @param outputs       Ordered return fields (empty for write methods).
/// @param approvals     ERC-20 approvals to run before the write transaction.
/// @param isInputArray  True if the input is an array of tuples (UI renders "Add Row").
/// @param isOutputArray True if the return value is an array of tuples (UI renders a table).
/// @param isWriteMethod True for state-changing methods, false for views.
struct VaultMethodSchema {
    string name;
    string description;
    FieldDescriptor[] inputs;
    FieldDescriptor[] outputs;
    ApproveAction[] approvals;
    bool isInputArray;
    bool isOutputArray;
    bool isWriteMethod;
}

/// @notice Top-level schema describing a vault's entire UI surface, returned by `DirectLaunchVaultBase.vaultUISchema()`.
/// @param vaultType   Human-readable vault type badge (e.g. "StakingVault", "SplitVault").
/// @param description Overall explanation of the vault.
/// @param methods     Ordered methods the UI renders in sequence.
struct VaultUISchema {
    string vaultType;
    string description;
    VaultMethodSchema[] methods;
}

// ──────────────────────────────────────────────────────────────────────────────
//  Factory side: FactoryPolicy (informational)
// ──────────────────────────────────────────────────────────────────────────────

/// @notice A single informational constraint a factory places on launch parameters, for proactive UI
///         validation hints. NOT the enforcement mechanism — enforcement lives in the factory's own
///         logic (e.g. `isQuoteTokenSupported`).
/// @dev `operator` ∈ {"eq","neq","gt","gte","lt","lte","in","notIn"}; unknown operators MUST be ignored
///      by the UI (forward-compatible). `value` is the ABI-encoded expected value for `target`.
/// @param target      Field name the constraint applies to (e.g. "quoteToken").
/// @param operator    Comparison operator.
/// @param value       ABI-encoded expected value (a dynamic array for "in"/"notIn").
/// @param description Human-readable explanation.
struct FactoryPolicy {
    string target;
    string operator;
    bytes value;
    string description;
}
