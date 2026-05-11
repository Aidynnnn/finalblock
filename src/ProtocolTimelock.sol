// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title  ProtocolTimelock
/// @notice A thin, hardened wrapper around OpenZeppelin's TimelockController that
///         enforces a strict 2-day minimum execution delay on every governance
///         operation for the DeFi Super-App protocol.
///
/// ════════════════════════════════════════════════════════════════════
/// ROLE MODEL  (inherited from OZ TimelockController v5)
/// ════════════════════════════════════════════════════════════════════
///
///   TIMELOCK_ADMIN_ROLE
///     ├── Granted to: address(this)  [always — self-administered]
///     └── Granted to: `admin` constructor arg  [deployer, renounced after setup]
///         After the deployment script has wired the Governor and renounced the
///         deployer's admin role, only the Timelock itself can call admin functions
///         (e.g. updateDelay, grantRole).  This means any change to the Timelock's
///         own configuration must itself pass through a 2-day queued proposal.
///
///   PROPOSER_ROLE  +  CANCELLER_ROLE
///     └── Granted to: ProtocolGovernor  [set in the deployment script]
///         Only the Governor may schedule (propose) or cancel operations.
///         Optionally, a guardian multisig can also receive CANCELLER_ROLE as a
///         last-resort circuit breaker — this is handled in the deployment script,
///         not hardcoded here, to keep deployment flexibility.
///
///   EXECUTOR_ROLE
///     └── Granted to: address(0)  [open execution — set in deployment script]
///         address(0) is the OZ sentinel meaning "anyone may call execute()."
///         This prevents a single privileged executor from becoming a centralisation
///         risk; once the timelock delay has elapsed any EOA or keeper can trigger
///         execution.
///
/// ════════════════════════════════════════════════════════════════════
/// DELAY ENFORCEMENT
/// ════════════════════════════════════════════════════════════════════
///
///   MIN_DELAY = 2 days = 172 800 seconds
///
///   Every call to schedule() or scheduleBatch() is stored with an executable
///   timestamp of block.timestamp + delay, where delay >= MIN_DELAY.
///   Calls to execute() / executeBatch() revert if the timestamp has not elapsed.
///
///   The delay itself can be changed via updateDelay(), but updateDelay() is
///   protected by the TIMELOCK_ADMIN_ROLE which is only held by address(this).
///   Therefore changing the delay requires a full governance cycle (propose → vote
///   → queue → wait 2 days → execute), preventing an emergency delay reduction.
///
/// ════════════════════════════════════════════════════════════════════
/// TREASURY OWNERSHIP
/// ════════════════════════════════════════════════════════════════════
///
///   The following contracts should have their owner / admin roles transferred
///   to address(this) after deployment:
///     • GovernanceToken.sol       — controls mint()
///     • ChainlinkPriceFeedAdapter.sol — controls registerFeed() / updateHeartbeat()
///     • ERC4626Vault.sol          — controls pause() / setPriceFeedAdapter()
///     • AMMFactory.sol            — controls toggleCreationPause()
///     • Protocol treasury wallet  — any ETH or ERC-20 reserves
///
///   Since the Timelock is msg.sender for all executed calls, target contracts
///   must grant their privileged roles to address(timelock), not address(governor).
///
/// ════════════════════════════════════════════════════════════════════
/// GOVERNANCE ATTACK ANALYSIS
/// ════════════════════════════════════════════════════════════════════
///
///   Timelock bypass:
///     Impossible without PROPOSER_ROLE.  The only path to schedule() is via
///     the Governor's queue() function, which itself requires a successful vote.
///
///   Proposal spam through Timelock:
///     Mitigated upstream by the 1% proposal threshold in ProtocolGovernor.
///     The Timelock itself has no spam protection — it relies on the Governor.
///
///   Malicious executor:
///     Mitigated by open execution (address(0) as executor).  No single address
///     can refuse to execute a matured operation — any party can call execute().
///
///   Admin key compromise:
///     After the deployer renounces TIMELOCK_ADMIN_ROLE, no EOA holds that role.
///     An attacker who compromises the deployer key post-setup gains nothing.
///
/// @custom:security-contact security@yourprotocol.xyz
contract ProtocolTimelock is TimelockController {

    // ─────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────

    /// @notice The minimum delay between scheduling and executing any operation.
    ///         Hardcoded to 2 days (172 800 seconds) per the project specification.
    ///         Cannot be set lower at construction time; increasing it later requires
    ///         a full governance cycle through this same Timelock.
    uint256 public constant MIN_DELAY = 2 days;

    // ─────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────

    /// @notice Deploys the ProtocolTimelock with a hardcoded 2-day minimum delay.
    ///
    /// @param proposers  Addresses that receive PROPOSER_ROLE and CANCELLER_ROLE.
    ///                   In production: [address(governor)].
    ///                   Can be an empty array if the Governor address is not yet
    ///                   known at Timelock deploy time; the deployment script must
    ///                   then call grantRole(PROPOSER_ROLE, governor) afterward.
    ///
    /// @param executors  Addresses that receive EXECUTOR_ROLE.
    ///                   Pass [address(0)] to permit open execution (recommended).
    ///
    /// @param admin      Address that receives TIMELOCK_ADMIN_ROLE in addition to
    ///                   address(this).  Set to the deployer during setup so that
    ///                   roles can be granted before the deployer renounces access.
    ///                   The deployment script MUST call
    ///                   renounceRole(TIMELOCK_ADMIN_ROLE, deployer) as its final step.
    ///                   Pass address(0) to skip the temporary admin grant entirely
    ///                   (advanced use — requires all roles to be wired atomically).
    constructor(
        address[] memory proposers,
        address[] memory executors,
        address           admin
    )
        TimelockController(
            MIN_DELAY,   // minDelay — 2 days; the OZ constructor enforces delay >= minDelay
            proposers,   // PROPOSER_ROLE + CANCELLER_ROLE recipients
            executors,   // EXECUTOR_ROLE recipients; address(0) = open execution
            admin        // temporary TIMELOCK_ADMIN_ROLE holder (deployer)
        )
    {
        // The OZ TimelockController constructor performs all initialisation:
        //   1. Sets _minDelay = MIN_DELAY and emits MinDelayChange(0, MIN_DELAY).
        //   2. Grants TIMELOCK_ADMIN_ROLE to address(this) and to `admin`.
        //   3. Grants PROPOSER_ROLE + CANCELLER_ROLE to each address in `proposers`.
        //   4. Grants EXECUTOR_ROLE to each address in `executors`.
        //
        // No further setup is required in this constructor.
        // All post-deploy wiring (grantRole, renounceRole) belongs in deploy.s.sol.
    }

    // ─────────────────────────────────────────────────────────────────
    // No additional functions
    // ─────────────────────────────────────────────────────────────────
    //
    // All operational functions (schedule, scheduleBatch, execute, executeBatch,
    // cancel, updateDelay) and all role management functions (grantRole,
    // revokeRole, renounceRole) are fully implemented in the OZ base contract.
    //
    // We deliberately add no new functions here.  Every protocol-specific
    // behaviour is enforced either in ProtocolGovernor.sol (voting rules) or in
    // the individual target contracts (access control).  Keeping the Timelock
    // minimal reduces its attack surface to the audited OZ code alone.
}
