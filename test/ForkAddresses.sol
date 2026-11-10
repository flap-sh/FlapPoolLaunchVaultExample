// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title ForkAddresses
/// @notice Every address the live-fork tests depend on, for BNB Chain (56) and BNB Testnet (97), in one place.
/// @dev The Portal, its ProxyAdmin and the tax token implementation are deterministic deployments, so they are the
///      same on both chains. The Guardian, WBNB and the V2 router differ. `hub` and `guardian` must agree with
///      `src/flap/LaunchVaultAddresses.sol`, which the factories resolve at run time; the fork tests assert it, so a
///      drift between the two fails loudly instead of testing the wrong thing.
library ForkAddresses {
    struct Addrs {
        string name;
        /// @dev Name of the environment variable that holds the chain's RPC URL.
        string rpcEnv;
        uint256 chainId;
        /// @dev The Direct Launch Portal (the "Hub").
        address portal;
        /// @dev Owner is the Flap admin that holds the Portal's admin, manage and auditor roles.
        address proxyAdmin;
        address guardian;
        /// @dev The tax token implementation the Portal clones: a launch's token is CREATE2(impl, salt, portal).
        address tokenImpl;
        address wbnb;
        address v2Router;
    }

    address internal constant PORTAL = 0x000042108465206185A077Edc3F3fd2b49060000;
    address internal constant PORTAL_PROXY_ADMIN = 0x0000Ed588dfc01749C20bA69b5f8c77d706E0000;
    address internal constant TOKEN_IMPL = 0x7777c57ff7dc441c1715b2e36fa581c48B782222;

    /// @notice BNB Chain mainnet.
    function bsc() internal pure returns (Addrs memory a) {
        a.name = "BNB Chain";
        a.rpcEnv = "BSC_RPC_URL";
        a.chainId = 56;
        a.portal = PORTAL;
        a.proxyAdmin = PORTAL_PROXY_ADMIN;
        a.guardian = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        a.tokenImpl = TOKEN_IMPL;
        a.wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        a.v2Router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    }

    /// @notice BNB Testnet.
    function bscTest() internal pure returns (Addrs memory a) {
        a.name = "BNB Testnet";
        a.rpcEnv = "BSC_TESTNET_RPC_URL";
        a.chainId = 97;
        a.portal = PORTAL;
        a.proxyAdmin = PORTAL_PROXY_ADMIN;
        a.guardian = 0x00004d58290854c5E9880F4b5B1993c6Ad8b0000;
        a.tokenImpl = TOKEN_IMPL;
        a.wbnb = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
        a.v2Router = 0xc9D63ddCB9549578057EAB6A83a543DdFEE2b8c3;
    }
}
