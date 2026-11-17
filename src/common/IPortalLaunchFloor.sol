// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Read-only Portal calls used to check a planned launch before its Launcher exists.
/// @dev Kept outside src/flap because that directory contains the immutable Flap specification.
///      The Launcher is not registered yet, so the preview cannot include a Launcher Factory discount;
///      these examples expect the Launcher Factory to be enabled at 1x. The Portal checks the live
///      quote price and factory settings again at launch, so the refund path remains necessary.
interface IPortalLaunchFloor {
    struct GraduationFloorParams {
        address quoteToken;
        uint256 quotePriceUsd;
        uint256 poolQuote;
        uint256 poolToken;
        uint256 totalSupply;
        address vaultFactory;
    }

    struct GraduationFloorResultV2 {
        bool meetsFloor;
        uint256 floorUsdWad;
        uint256 quoteUsdWad;
        uint16 multiplierBps;
        bool meetsCreateFloor;
        uint256 createFloorUsdWad;
    }

    function launchQuoteConfig(uint8 kind, address quoteToken)
        external
        view
        returns (bool enabled, uint256 quotePriceUsd);

    function graduationFloorV2(GraduationFloorParams calldata params)
        external
        view
        returns (GraduationFloorResultV2 memory);
}
