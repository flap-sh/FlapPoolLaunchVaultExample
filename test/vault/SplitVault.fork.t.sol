// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";
import {LibClone} from "solady/utils/LibClone.sol";

import {IPortalTypes} from "src/flap/IPortal.sol";
import {Distribution} from "src/flap/Distribution.sol";
import {SplitVault} from "src/vault/SplitVault.sol";
import {SplitVaultFactory} from "src/vault/SplitVaultFactory.sol";
import {ForkBase} from "test/ForkBase.sol";

/// @notice VAULT REFERENCE, not a launch mode: `SplitVault` is plugged into a launch through the VAULT fee slot
///         and splits the token's tax revenue between recipients.
///
///   `_unpause` only isolates the vault; the beta requires a Launcher for an actual launch. The test then runs
///   trading, tax and the claim on the real pool.
abstract contract SplitVaultFork is ForkBase {
    function test_08_split_ordinaryLaunchThenClaim() public {
        _unpause();
        SplitVaultFactory factory = new SplitVaultFactory(wbnb);

        SplitVault.Recipient[] memory r = new SplitVault.Recipient[](2);
        r[0] = SplitVault.Recipient({recipient: alice, bps: 6000});
        r[1] = SplitVault.Recipient({recipient: bob, bps: 4000});

        IPortalTypes.FeeConfig[] memory fees = new IPortalTypes.FeeConfig[](2);
        fees[0] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.DEFLATION, bps: 1000, configData: ""});
        fees[1] = IPortalTypes.FeeConfig({
            feeType: IPortalTypes.FeeSlotType.VAULT,
            bps: 9000,
            configData: abi.encode(
                IPortalTypes.FeeConfigVault({vaultFactory: address(factory), vaultData: abi.encode(r)})
            )
        });

        IPortalTypes.CreateTaxTokenParams memory p;
        p.name = "Split Example";
        p.symbol = "SPLITX";
        p.meta = "bafkreig4y5nwb4izyilbbmiydumvkld446d4k7j4ohg3x3q2lfel3fo4yq";
        p.totalSupply = 1_000_000 ether;
        p.salt = _mineSalt("split-example");
        p.poolQuote = 10 ether;
        p.poolToken = 1_000_000 ether;
        p.buyTaxRate = 300;
        p.sellTaxRate = 500;
        p.taxDuration = 30 days;
        p.antiFarmerDuration = 1 days;
        p.feeConfigs = fees;
        Distribution memory d;
        IPortalTypes.CreatorBuyParams memory noBuy;

        vm.prank(creator);
        (address token,) = portal.launchTaxTokenV2{value: 10 ether}(p, d, noBuy);

        (address vaultAddr, address vaultFactoryAddr) = portal.getLaunchVault(token);
        assertEq(vaultFactoryAddr, address(factory));
        assertEq(
            vaultAddr,
            LibClone.predictDeterministicAddressERC1967BeaconProxy(
                factory.beacon(), bytes32(uint256(uint160(token))), address(factory)
            ),
            "vault at the deterministic address"
        );

        vm.recordLogs();
        _generateTaxAndDispatch(token);

        // Every payment the vault recognized is split on its own: alice gets floor(60%), bob the remainder. Sum
        // them from the events, so the expected shares are exact and do not depend on how the amounts round.
        uint256 total;
        uint256 expectedAlice;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != vaultAddr || logs[i].topics[0] != SplitVault.FlapSplitVaultReceived.selector) {
                continue;
            }
            uint256 amount = abi.decode(logs[i].data, (uint256));
            total += amount;
            expectedAlice += amount * 6000 / 10_000;
        }
        assertGt(total, 0, "the vault recognized revenue");

        SplitVault sv = SplitVault(payable(vaultAddr));

        // description() discloses every recipient and its share, as the spec requires.
        string memory desc = sv.description();
        assertTrue(_contains(desc, string.concat(Strings.toHexString(alice), "=6000bps")), "description lists alice");
        assertTrue(_contains(desc, string.concat(Strings.toHexString(bob), "=4000bps")), "description lists bob");

        uint256 ca = sv.claimable(alice);
        uint256 cb = sv.claimable(bob);
        assertEq(ca, expectedAlice, "alice: 60% of every payment, rounded down");
        assertEq(cb, total - expectedAlice, "bob: the rest, including the rounding dust");
        assertGt(ca, 0, "alice has a share");

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        sv.claim();
        assertEq(alice.balance - aliceBefore, ca, "alice received exactly her claimable share");

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        sv.claim();
        assertEq(bob.balance - bobBefore, cb, "bob received exactly his claimable share");

        assertEq(sv.claimable(alice), 0, "alice has nothing left to claim");
        assertEq(sv.claimable(bob), 0, "bob has nothing left to claim");
        assertEq(sv.claimed(alice) + sv.claimed(bob), total, "everything recognized was paid out");
        assertEq(address(sv).balance, 0, "the vault holds nothing");
        assertEq(sv.accountedQuote(), 0, "the baseline is back to zero");
    }
}
