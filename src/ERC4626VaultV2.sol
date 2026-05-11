// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626VaultV1} from "./ERC4626VaultV1.sol";

/// @title  ERC4626VaultV2
/// @notice Demonstration of a valid V1 → V2 UUPS upgrade path.
///
/// ════════════════════════════════════════════════════════════════════
/// WHAT CHANGES IN V2
/// ════════════════════════════════════════════════════════════════════
///
///   1. Performance Fee
///      A `performanceFee` (basis points, 0 – 10 000) can be set by the
///      owner.  The getter is live immediately after upgrade; no
///      re-initializer is required because the fee defaults to 0.
///
///   2. New ERC-7201 storage namespace
///      V2 state lives in its own slot, derived from the namespace
///      `"bcht2.storage.ERC4626VaultV2"`.  This is completely disjoint
///      from the V1 slot, so upgrading never overwrites V1 storage.
///
///   3. `version()` override
///      Returns "2.0.0" so integrators can detect the running version.
///
///   4. `initializeV2()` reinitializer  (optional, called via upgradeToAndCall)
///      Guards against re-execution using `reinitializer(2)`.  Because V2
///      introduces no mandatory state migration, calling it is optional —
///      the contract is fully functional without it (fee stays at 0).
///
/// ════════════════════════════════════════════════════════════════════
/// STORAGE SAFETY
/// ════════════════════════════════════════════════════════════════════
///
///   • V1 storage struct (at its own ERC-7201 slot) is not touched.
///   • V2 adds a brand-new struct at a different ERC-7201 slot.
///   • No slot-0 inheritance storage is introduced (V1 and V2 both
///     inherit only `Initializable` and `UUPSUpgradeable`, which carry
///     no mutable slot-0 state).
///
/// @custom:security-contact security@yourprotocol.xyz
contract ERC4626VaultV2 is ERC4626VaultV1 {

    // ────────────────────────────────────────────────────────────────
    // Constants
    // ────────────────────────────────────────────────────────────────

    uint16 public constant MAX_FEE_BPS = 10_000; // 100 %

    // ────────────────────────────────────────────────────────────────
    // ERC-7201 Namespaced Storage  (V2-exclusive, disjoint from V1)
    // ────────────────────────────────────────────────────────────────

    /// @custom:storage-location erc7201:bcht2.storage.ERC4626VaultV2
    struct VaultV2Storage {
        /// @dev Performance fee in basis points (0 = disabled, 10000 = 100 %).
        uint16 performanceFee;
    }

    /// @dev Returns a pointer to the V2 storage struct.
    ///      Slot = keccak256(abi.encode(uint256(keccak256("bcht2.storage.ERC4626VaultV2")) - 1))
    ///             & ~bytes32(uint256(0xff))
    function _getVaultV2Storage() private pure returns (VaultV2Storage storage $) {
        bytes32 slot = keccak256(
            abi.encode(uint256(keccak256("bcht2.storage.ERC4626VaultV2")) - 1)
        ) & ~bytes32(uint256(0xff));
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := slot
        }
    }

    // ────────────────────────────────────────────────────────────────
    // Errors / Events
    // ────────────────────────────────────────────────────────────────

    error VaultV2__FeeTooHigh(uint16 fee, uint16 max);

    event PerformanceFeeUpdated(uint16 oldFee, uint16 newFee);

    // ────────────────────────────────────────────────────────────────
    // Constructor — chains up to V1's `_disableInitializers()`
    // ────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() ERC4626VaultV1() {}

    // ────────────────────────────────────────────────────────────────
    // Optional V2 reinitializer
    // ────────────────────────────────────────────────────────────────

    /// @notice Optional post-upgrade hook.  Pass this as `data` to
    ///         `upgradeToAndCall` if you want a non-zero initial fee.
    ///         Guards with `reinitializer(2)` so it can only run once.
    ///
    /// @param initialFeeBps  Starting performance fee in basis points.
    function initializeV2(uint16 initialFeeBps) external reinitializer(2) {
        if (initialFeeBps > MAX_FEE_BPS) revert VaultV2__FeeTooHigh(initialFeeBps, MAX_FEE_BPS);
        VaultV2Storage storage $ = _getVaultV2Storage();
        emit PerformanceFeeUpdated($.performanceFee, initialFeeBps);
        $.performanceFee = initialFeeBps;
    }

    // ────────────────────────────────────────────────────────────────
    // Version override
    // ────────────────────────────────────────────────────────────────

    function version() public pure override returns (string memory) {
        return "2.0.0";
    }

    // ────────────────────────────────────────────────────────────────
    // Performance Fee: getter / setter
    // ────────────────────────────────────────────────────────────────

    /// @notice Returns the current performance fee in basis points.
    ///         Defaults to 0 until explicitly set.
    function getPerformanceFee() external view returns (uint16) {
        return _getVaultV2Storage().performanceFee;
    }

    /// @notice Owner-only setter for the performance fee.
    /// @param newFeeBps Fee in basis points (0 – 10 000).
    function setPerformanceFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert VaultV2__FeeTooHigh(newFeeBps, MAX_FEE_BPS);
        VaultV2Storage storage $ = _getVaultV2Storage();
        emit PerformanceFeeUpdated($.performanceFee, newFeeBps);
        $.performanceFee = newFeeBps;
    }
}
