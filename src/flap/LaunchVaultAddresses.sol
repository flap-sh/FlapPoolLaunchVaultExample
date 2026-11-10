// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title LaunchVaultAddresses
/// @author The Flap Team
/// @notice Per-chain addresses that every Pool Launch (Direct Launch) vault and vault factory needs.
///         Shared by `DirectLaunchVaultBase` and `DirectLaunchVaultFactoryBase`, so the two can never
///         drift apart.
///
///      | Getter                | BNB Chain (56)       | BNB Testnet (97)     | Robinhood (4663) |
///      |-----------------------|----------------------|----------------------|------------------|
///      | `hub()`               | 0x00004210…0000      | 0x00004210…0000      | TBD → reverts    |
///      | `guardian()`          | 0x9e27098d…8a4b      | 0x00004d58…0000      | 0x00004d58…0000  |
///      | `verifiedTokenDock()` | 0x00004B06…0000      | 0x00004B06…0000      | TBD → reverts    |
///      | `openTokenDock()`     | 0x0000E34C…0000      | 0x0000E34C…0000      | TBD → reverts    |
///      | `tokenDockRouter()`   | 0x000048E8…0000      | 0x000048E8…0000      | TBD → reverts    |
///
///      - "Direct Launch Portal" (DLP) is the flap-launcher `Portal` proxy. It is NOT the Bonding Curve
///        Portal (BCP). Never call this a bare "portal".
///      - The two Token Docks (and the router) are deployed deterministically: the same salt + initcode
///        land on the same address on every chain that shares the dock logic.
///      - Each dock getter returns the TransparentUpgradeableProxy address (the dock implementation is
///        behind a dedicated ProxyAdmin, owned by the deployer and renounced once verified).
///      - Every consumer reads these through an `internal view virtual` wrapper, so test harnesses (and
///        fork tests with a freshly deployed DLP) can override them.
library LaunchVaultAddresses {
    /// @notice The current chain has no Direct Launch Portal.
    /// @param chainId The `block.chainid` that was looked up.
    error UnsupportedChain(uint256 chainId);

    /// @notice The Direct Launch Portal (DLP) on the current chain: the only allowed caller of
    ///         `IDirectLaunchVaultFactory.newVault` and of `IStrategy.initializeDistribution`.
    /// @dev Reverts `UnsupportedChain` on any chain without a DLP (including Robinhood until its DLP
    ///      address is known), so an unconfigured deployment rejects every caller instead of accepting
    ///      a zero address.
    /// @return The DLP proxy address.
    function hub() internal view returns (address) {
        uint256 id = block.chainid;
        if (id == 56 || id == 97) return 0x000042108465206185A077Edc3F3fd2b49060000;
        revert UnsupportedChain(id);
    }

    /// @notice The Flap Guardian on the current chain. For the low-risk badge it is the ONLY upgrade
    ///         authority of a factory's vaults, and every permissioned vault function also accepts it.
    /// @dev BNB Chain uses the bonding-curve Guardian; every other chain uses `0x00004d58…0000`.
    /// @return The Guardian address.
    function guardian() internal view returns (address) {
        if (block.chainid == 56) return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b; // BNB Chain
        return 0x00004d58290854c5E9880F4b5B1993c6Ad8b0000; // every other chain
    }

    /// @notice The labeled `VerifiedTokenDock` singleton, resolved per chain.
    /// @dev Deterministically deployed: the same salt + initcode land on the same address on every chain
    ///      that shares this dock's logic. A chain that needs different dock logic gets its own branch
    ///      here, so adding logic on a new chain never affects the others. Reverts `UnsupportedChain`
    ///      elsewhere.
    /// @return The VerifiedTokenDock address.
    function verifiedTokenDock() internal view returns (address) {
        uint256 id = block.chainid;
        if (id == 56 || id == 97) return 0x00004B06D90Df7a39491264744BF187D90Df0000;
        revert UnsupportedChain(id); // add a branch per chain with its own dock
    }

    /// @notice The unlabeled, permissionless `OpenTokenDock` singleton, resolved per chain.
    /// @dev See `verifiedTokenDock` for the per-chain / deterministic-deploy notes.
    /// @return The OpenTokenDock address.
    function openTokenDock() internal view returns (address) {
        uint256 id = block.chainid;
        if (id == 56 || id == 97) return 0x0000E34C74b9eC7b52F35528249Aa9C4AdE00000;
        revert UnsupportedChain(id); // add a branch per chain with its own dock
    }

    /// @notice The `TokenDockRouter` singleton: the single dock entry a vault uses. It
    ///         routes to the verified/open dock and migrates on whitelisting.
    /// @dev See `verifiedTokenDock` for the per-chain / deterministic-deploy notes.
    /// @return The TokenDockRouter address.
    function tokenDockRouter() internal view returns (address) {
        uint256 id = block.chainid;
        if (id == 56 || id == 97) return 0x000048E888aBf09f690a952E1b386b2D031a0000;
        revert UnsupportedChain(id); // add a branch per chain with its own dock
    }
}
