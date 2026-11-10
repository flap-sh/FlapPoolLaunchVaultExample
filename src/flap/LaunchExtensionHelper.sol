// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title LaunchExtensionHelper
/// @notice Standalone helper for the Flap Pool Launch creator-display extension.
/// @dev No imports on purpose: copy this file into your project and use it as-is. It covers the
///      creator extension only — other extensions (e.g. the signed quote-price fallback) have their
///      own ids and payloads.
///
///      Usage (where to put it, how to call it): see `LaunchExtensionHelper.md` next to this file.
///
///      The Portal accepts two encodings:
///        * single extension: extensionID = creatorExtensionId(), extensionData = abi.encode(address)
///        * extension array:  extensionID = extensionArrayId(),  extensionData = abi.encode(Extension[])
///
///      The declared creator only affects the `creator` field of `FlapDirectLaunched`. It is honored
///      only for operator-granted callers; vault resolution, the factory permission policy, the salt
///      lock and the payment path always use msg.sender.
library LaunchExtensionHelper {
    /// @notice One entry of the launch's extension array. Layout matches the Portal's
    ///         `IPortalTypes.Extension`.
    struct Extension {
        bytes32 extensionId;
        bytes extensionData;
    }

    /// @dev Inner id for the creator-display extension.
    bytes32 internal constant CREATOR_EXTENSION_ID = keccak256("flap.extension.creator.v1");
    /// @dev Outer marker for the extension-array encoding.
    bytes32 internal constant EXTENSION_ARRAY_ID = keccak256("flap.extensions.v1");

    /// @notice The id to pass as `CreateTaxTokenParams.extensionID` for the single form.
    function creatorExtensionId() internal pure returns (bytes32) {
        return CREATOR_EXTENSION_ID;
    }

    /// @notice The id to pass as `CreateTaxTokenParams.extensionID` for the array form.
    function extensionArrayId() internal pure returns (bytes32) {
        return EXTENSION_ARRAY_ID;
    }

    /// @notice Single-extension form: the whole `extensionData` is the creator.
    /// @param creator The address to show as the launch creator.
    /// @return extensionID `creatorExtensionId()`.
    /// @return extensionData `abi.encode(creator)`.
    function encodeCreator(address creator) internal pure returns (bytes32 extensionID, bytes memory extensionData) {
        return (CREATOR_EXTENSION_ID, abi.encode(creator));
    }

    /// @notice Array form: one creator entry, ready to combine with other extensions later.
    /// @param creator The address to show as the launch creator.
    /// @return extensionID `extensionArrayId()`.
    /// @return extensionData `abi.encode(Extension[])` with a single creator entry.
    function encodeCreatorInArray(address creator)
        internal
        pure
        returns (bytes32 extensionID, bytes memory extensionData)
    {
        Extension[] memory exts = new Extension[](1);
        exts[0] = Extension({extensionId: CREATOR_EXTENSION_ID, extensionData: abi.encode(creator)});
        return (EXTENSION_ARRAY_ID, abi.encode(exts));
    }

    /// @notice Read the declared creator back from either encoding.
    /// @param extensionID The launch's `extensionID`.
    /// @param extensionData The launch's `extensionData`.
    /// @return found Whether the creator extension is present.
    /// @return creator The declared creator (address(0) when absent).
    function decodeCreator(bytes32 extensionID, bytes memory extensionData)
        internal
        pure
        returns (bool found, address creator)
    {
        if (extensionID != EXTENSION_ARRAY_ID) {
            if (extensionID != CREATOR_EXTENSION_ID) return (false, address(0));
            return (true, abi.decode(extensionData, (address)));
        }

        Extension[] memory exts = abi.decode(extensionData, (Extension[]));
        uint256 len = exts.length;
        for (uint256 i; i < len; ++i) {
            if (exts[i].extensionId == CREATOR_EXTENSION_ID) {
                return (true, abi.decode(exts[i].extensionData, (address)));
            }
        }
    }
}
