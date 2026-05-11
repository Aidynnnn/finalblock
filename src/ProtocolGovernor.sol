// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title  ProtocolGovernor
/// @notice Production-grade OpenZeppelin v5 Governor stack for the DeFi Super-App.
///
/// ════════════════════════════════════════════════════════════════════
/// SPECIFICATION PARAMETERS  (Section 3.1 of the project syllabus)
/// ════════════════════════════════════════════════════════════════════
///
///   Parameter            Value         Stored as
///   ─────────────────    ───────────   ────────────────────────────────
///   Voting delay         1 day         86 400 seconds  (timestamp clock)
///   Voting period        1 week        604 800 seconds (timestamp clock)
///   Quorum fraction      4%            GovernorVotesQuorumFraction(4)
///   Proposal threshold   1% of supply  dynamic override — see proposalThreshold()
///   Timelock delay       2 days        enforced by ProtocolTimelock (MIN_DELAY)
///
/// ════════════════════════════════════════════════════════════════════
/// CLOCK MODE  (EIP-6372 — "mode=timestamp")
/// ════════════════════════════════════════════════════════════════════
///
///   This Governor uses block.timestamp (not block.number) for two reasons:
///
///   1. L2 compatibility: Arbitrum / Optimism / Base / zkSync produce blocks at
///      irregular intervals (sometimes sub-second).  Block-counting would yield
///      wildly different real-world durations per chain; timestamp-counting gives
///      consistent "1 day", "1 week" semantics everywhere.
///
///   2. Token clock alignment: GovernanceToken (ERC20Votes, OZ v5) defaults to
///      timestamp mode.  EIP-6372 requires the Governor and the token to use the
///      SAME clock.  If they disagree, getPastVotes() queries use the wrong unit
///      and the entire voting system is broken.  Both contracts use timestamps.
///
///   NOTE: block.timestamp is used here exclusively as a time-window reference.
///   It is NEVER used as a source of randomness or entropy.  Miner/sequencer
///   manipulation of timestamps is bounded (L1: ±15 s; L2: typically < 2 s)
///   and is negligible relative to 1-day / 1-week governance windows.
///
/// ════════════════════════════════════════════════════════════════════
/// INHERITANCE DIAMOND  (Solidity C3 linearisation order)
/// ════════════════════════════════════════════════════════════════════
///
///   Governor                  ← abstract base; owns proposal storage, vote casting
///     GovernorSettings        ← stores votingDelay / votingPeriod / threshold
///     GovernorCountingSimple  ← For / Against / Abstain vote tally
///     GovernorVotes           ← IVotes token reference, _getVotes()
///     GovernorVotesQuorumFraction  ← quorum = numerator% of getPastTotalSupply()
///     GovernorTimelockControl ← queue / execute routed through TimelockController
///
///   Every virtual function declared in more than one base is explicitly overridden
///   in this contract with an exhaustive override(...) specifier, satisfying the
///   Solidity compiler and providing a clear audit trail of the routing decision.
///
/// ════════════════════════════════════════════════════════════════════
/// FULL PROPOSAL LIFECYCLE
/// ════════════════════════════════════════════════════════════════════
///
///   Step  Function          Who calls it        What happens
///   ────  ────────────────  ──────────────────  ───────────────────────────────
///   1     propose()         Any token holder    Validates proposalThreshold (≥1%
///                           with ≥ 1% supply    supply).  Records targets/values/
///                                               calldatas/description.  Snapshot
///                                               is set to clock() + votingDelay.
///
///   2     [voting delay]    —                   1 day passes.  Token holders can
///                                               acquire / delegate before snapshot.
///
///   3     castVote()        Token holders       For / Against / Abstain.
///         castVoteWithReason()                  Votes weighted by getPastVotes()
///         castVoteBySig()                       at the proposal snapshot.
///
///   4     [voting period]   —                   1 week passes.
///
///   5     queue()           Anyone              Requires ProposalState.Succeeded.
///                                               Encodes operation in Timelock via
///                                               scheduleBatch().  Sets ETA = now
///                                               + ProtocolTimelock.MIN_DELAY.
///
///   6     [timelock delay]  —                   2 days pass.  Community observes;
///                                               guardian can cancel if malicious.
///
///   7     execute()         Anyone              Requires ProposalState.Queued and
///                                               Timelock operation in Ready state.
///                                               Relays calls through Timelock;
///                                               msg.sender to targets = Timelock.
///
/// ════════════════════════════════════════════════════════════════════
/// GOVERNANCE ATTACK ANALYSIS
/// ════════════════════════════════════════════════════════════════════
///
///   Flash-loan governance:
///     getPastVotes() reads the snapshot at block (proposalSnapshot), which is
///     set to clock() at propose() + votingDelay (1 day).  Tokens borrowed and
///     returned within a single block have zero historical voting power and cannot
///     influence quorum or vote counts.
///
///   Whale / majority attack:
///     An attacker with >50% of voting supply still faces the 1-week voting window
///     (giving minority holders time to counter-delegate or sell) and the 2-day
///     Timelock window (giving the community time to exit or the guardian to cancel).
///
///   Proposal spam:
///     The 1% dynamic threshold requires meaningful skin in the game.  A proposer
///     who creates a defeated proposal does not lose their tokens, but the economic
///     cost of acquiring and locking 1% of supply deters casual spam.
///
///   Quorum dilution via post-snapshot minting:
///     quorum() calls getPastTotalSupply(proposalSnapshot), not current supply.
///     Tokens minted after the snapshot do not lower the quorum requirement for
///     that proposal.
///
///   Timelock bypass:
///     Only addresses holding PROPOSER_ROLE on the Timelock can call schedule().
///     The deployment script grants PROPOSER_ROLE exclusively to this Governor.
///     There is no path to execute an unqueued operation.
///
/// @custom:security-contact security@yourprotocol.xyz
contract ProtocolGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    // ─────────────────────────────────────────────────────────────────
    // Named spec constants
    // ─────────────────────────────────────────────────────────────────

    /// @notice Voting delay: seconds between proposal creation and vote snapshot.
    ///         1 day = 86 400 seconds.  Passed to GovernorSettings constructor.
    uint48 public constant VOTING_DELAY_SECONDS = uint48(1 days);

    /// @notice Voting period: duration of the open voting window in seconds.
    ///         1 week = 604 800 seconds.  Passed to GovernorSettings constructor.
    uint32 public constant VOTING_PERIOD_SECONDS = uint32(1 weeks);

    /// @notice Quorum numerator fed to GovernorVotesQuorumFraction.
    ///         OZ uses denominator = 100, so this represents exactly 4%.
    uint256 public constant QUORUM_NUMERATOR_PCT = 4;

    /// @notice Divisor applied to total supply to compute the proposal threshold.
    ///         totalSupply / 100 = 1% of supply.
    uint256 public constant PROPOSAL_THRESHOLD_DIVISOR = 100;

    // ─────────────────────────────────────────────────────────────────
    // Custom errors
    // ─────────────────────────────────────────────────────────────────

    /// @dev Reverts when either the token or the timelock address is address(0).
    error Governor__ZeroAddress();

    // ─────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────

    /// @notice Deploys the ProtocolGovernor, wiring it to the governance token
    ///         and the ProtocolTimelock.
    ///
    /// @param governanceToken  Address of GovernanceToken.sol.
    ///                         Must implement IVotes (ERC20Votes) with timestamp clock.
    ///                         The Governor reads getPastVotes() and getPastTotalSupply()
    ///                         from this contract for vote weighting and quorum.
    ///
    /// @param timelock         Address of ProtocolTimelock.sol.
    ///                         This Governor must hold PROPOSER_ROLE + CANCELLER_ROLE
    ///                         on that Timelock (granted in the deployment script).
    ///                         All executed proposal calls are relayed through it.
    constructor(IVotes governanceToken, TimelockController timelock)
        Governor("ProtocolGovernor")
        GovernorSettings(
            VOTING_DELAY_SECONDS, // 86 400 s  — stored as uint48 in GovernorSettings
            VOTING_PERIOD_SECONDS, // 604 800 s — stored as uint32 in GovernorSettings
            0 // stored proposalThreshold; dynamically overridden
            // below so this stored value is intentionally 0
        )
        GovernorVotes(governanceToken)
        GovernorVotesQuorumFraction(QUORUM_NUMERATOR_PCT)
        GovernorTimelockControl(timelock)
    {
        if (address(governanceToken) == address(0)) {
            revert Governor__ZeroAddress();
        }
        if (address(timelock) == address(0)) revert Governor__ZeroAddress();
    }

    // ─────────────────────────────────────────────────────────────────
    // EIP-6372: timestamp-based clock
    // ─────────────────────────────────────────────────────────────────

    /// @notice Returns the current clock value.
    ///         Overrides Governor's default (block.number) with block.timestamp for
    ///         L2 compatibility and human-readable governance windows.
    ///
    /// @return Current Unix timestamp cast to uint48.
    ///         uint48 safely represents timestamps until the year 8 921 556.
    function clock() public view override(Governor, GovernorVotes) returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice EIP-6372 clock mode descriptor string.
    ///         Returning "mode=timestamp" signals to all off-chain tooling (Tally,
    ///         Snapshot, ethers.js governance utilities) that delay and period values
    ///         are in seconds, not block numbers.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override(Governor, GovernorVotes) returns (string memory) {
        return "mode=timestamp";
    }

    // ─────────────────────────────────────────────────────────────────
    // Dynamic proposal threshold — 1% of current total supply
    // ─────────────────────────────────────────────────────────────────

    /// @notice Returns the minimum voting power (in token base units) a caller
    ///         must hold to successfully call propose().
    ///
    ///         The threshold is computed as 1% of the governance token's current
    ///         total supply at the time propose() is called.  This is dynamic rather
    ///         than a fixed constant so that the barrier scales with network growth:
    ///         as the DAO mints more DGOV, 1% remains a meaningful economic stake.
    ///
    ///         Override chain resolution:
    ///           Governor          — declares proposalThreshold() as virtual, returns 0.
    ///           GovernorSettings  — overrides it to return the stored _proposalThreshold.
    ///           ProtocolGovernor  — overrides both; ignores the stored value (which is 0)
    ///                              and computes dynamically.
    ///
    ///         Edge cases:
    ///           • totalSupply = 0   → threshold = 0  (anyone can propose on empty chain)
    ///           • totalSupply < 100 → threshold = 0  (integer floor of tiny supply)
    ///           These are acceptable for testnet deployments.  On mainnet the supply
    ///           is expected to be orders of magnitude above 100 DGOV.
    ///
    /// @return threshold Minimum votes in token base units (1e18 scale) to open a proposal.
    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256 threshold) {
        // token() is exposed by GovernorVotes and returns the IVotes reference set
        // in the constructor.  IVotes does not include totalSupply(), so we issue a
        // low-level staticcall to read it without importing a separate interface.
        // This is the same pattern used by OZ internally for duck-typed calls.
        address tokenAddr = address(token());

        // staticcall is side-effect-free and cannot modify state.
        // abi.encodeWithSignature produces the standard 4-byte selector for totalSupply().
        (bool success, bytes memory returndata) = tokenAddr.staticcall(abi.encodeWithSignature("totalSupply()"));

        // Defensive fallback: if the staticcall fails for any reason (a hypothetical
        // bug in the token contract, or the token being replaced by an incompatible
        // upgrade), fall through to GovernorSettings' stored value (which is 0 at
        // deploy time).  This prevents a total DoS on propose() and allows governance
        // to recover by submitting an emergency proposal from any address.
        if (!success || returndata.length < 32) {
            return super.proposalThreshold();
        }

        uint256 supply = abi.decode(returndata, (uint256));

        // 1% of total supply, rounded DOWN by integer division.
        // Rounding down is the safe direction: it makes the threshold slightly
        // lower than the true 1%, which is permissive rather than restrictive.
        threshold = supply / PROPOSAL_THRESHOLD_DIVISOR;
    }

    // ─────────────────────────────────────────────────────────────────
    // Public view overrides — multi-base resolution
    // ─────────────────────────────────────────────────────────────────

    /// @notice Returns the delay between proposal creation and the vote snapshot.
    ///         Reads the value stored by GovernorSettings (VOTING_DELAY_SECONDS).
    ///
    ///         Override required: both Governor and GovernorSettings declare this virtual.
    ///
    /// @return delay Voting delay in seconds (86 400 = 1 day).
    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    /// @notice Returns the duration of the open voting window.
    ///         Reads the value stored by GovernorSettings (VOTING_PERIOD_SECONDS).
    ///
    ///         Override required: both Governor and GovernorSettings declare this virtual.
    ///
    /// @return period Voting period in seconds (604 800 = 1 week).
    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    /// @notice Returns the minimum vote weight required for a proposal to succeed.
    ///         Computed by GovernorVotesQuorumFraction as:
    ///             quorumNumerator * getPastTotalSupply(timepoint) / quorumDenominator
    ///         where quorumNumerator = 4 and quorumDenominator = 100 (OZ default).
    ///
    ///         `timepoint` is the proposal snapshot, so post-snapshot minting
    ///         cannot dilute the quorum requirement for an in-progress vote.
    ///
    ///         Override required: both Governor and GovernorVotesQuorumFraction declare virtual.
    ///
    /// @param  timepoint  The clock value (Unix timestamp) of the proposal snapshot.
    /// @return minimumVotes Minimum total votes (For + Abstain) for the proposal to be valid.
    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(timepoint);
    }

    /// @notice Returns the current state of a proposal.
    ///
    ///         GovernorTimelockControl extends the base state machine with two
    ///         additional states — Queued (operation scheduled in Timelock) and
    ///         Expired (Timelock grace period elapsed without execution).
    ///         Routing through super ensures both states are surfaced correctly.
    ///
    ///         Override required: both Governor and GovernorTimelockControl declare virtual.
    ///
    /// @param  proposalId  The unique ID of the proposal (keccak256 of its parameters).
    /// @return ProposalState enum value.
    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    // ─────────────────────────────────────────────────────────────────
    // Public state-mutating overrides — multi-base resolution
    // ─────────────────────────────────────────────────────────────────

    /// @notice Creates a new governance proposal.
    ///
    ///         Caller must hold at least proposalThreshold() voting power
    ///         (i.e. ≥ 1% of total supply) at the current clock value.
    ///
    ///         GovernorTimelockControl overrides propose() to pre-compute and store
    ///         the Timelock operation hash (timelockId) that will be used later by
    ///         queue() and execute().  Routing through super ensures that mapping
    ///         is populated before queue() is ever called; skipping it would cause
    ///         queue() to revert with "unknown proposal id".
    ///
    ///         Override required: both Governor and GovernorTimelockControl declare virtual.
    ///
    /// @param  targets      Array of contract addresses to call on execution.
    /// @param  values       Array of ETH values (wei) to send with each call.
    /// @param  calldatas    Array of ABI-encoded function calls for each target.
    /// @param  description  Human-readable description of the proposal (used to
    ///                      compute the descriptionHash for queue/execute/cancel).
    /// @return proposalId   Unique ID = keccak256(targets, values, calldatas, descriptionHash).
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256) {
        return super.propose(targets, values, calldatas, description);
    }

    /// @notice Queues a succeeded proposal into the ProtocolTimelock.
    ///
    ///         Callable by anyone once the proposal has reached ProposalState.Succeeded
    ///         (quorum ≥ 4% and For > Against).
    ///
    ///         Internally calls Timelock.scheduleBatch(), which stores the operation
    ///         with an eta of block.timestamp + MIN_DELAY (2 days).
    ///         The proposal state transitions from Succeeded → Queued.
    ///
    ///         Override required: both Governor and GovernorTimelockControl declare virtual.
    ///
    /// @param  targets         Same arrays passed to propose().
    /// @param  values          Same arrays passed to propose().
    /// @param  calldatas       Same arrays passed to propose().
    /// @param  descriptionHash keccak256(description) — must match the original.
    /// @return proposalId      The queued proposal's ID.
    function queue(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public override returns (uint256) {
        return super.queue(targets, values, calldatas, descriptionHash);
    }

    /// @notice Executes a matured proposal by relaying its calls through the Timelock.
    ///
    ///         Callable by anyone once the proposal is Queued and the Timelock
    ///         operation is in the Ready state (eta has elapsed).
    ///
    ///         The Timelock is msg.sender for all downstream calls.  Target contracts
    ///         therefore need to grant their admin/owner roles to address(timelock),
    ///         not address(governor).
    ///
    ///         `payable` because proposals may include ETH transfers to target contracts.
    ///
    ///         Override required: both Governor and GovernorTimelockControl declare virtual.
    ///
    /// @param  targets         Same arrays passed to propose().
    /// @param  values          Same arrays passed to propose().
    /// @param  calldatas       Same arrays passed to propose().
    /// @param  descriptionHash keccak256(description) — must match the original.
    /// @return proposalId      The executed proposal's ID.
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable override returns (uint256) {
        return super.execute(targets, values, calldatas, descriptionHash);
    }

    /// @notice Cancels a proposal and its corresponding Timelock operation.
    ///
    ///         Who can cancel and when:
    ///           • The original proposer may cancel while the proposal is Pending
    ///             (before the vote snapshot has been taken).
    ///           • Any address holding CANCELLER_ROLE on the ProtocolTimelock can
    ///             cancel a Queued proposal before its eta elapses.  In production,
    ///             the guardian multisig holds this role as a last-resort mechanism.
    ///
    ///         After cancellation the proposalId is moved to ProposalState.Canceled,
    ///         and the Timelock operation (if scheduled) is also removed.
    ///
    ///         Override required: both Governor and GovernorTimelockControl declare virtual.
    ///
    /// @param  targets         Same arrays passed to propose().
    /// @param  values          Same arrays passed to propose().
    /// @param  calldatas       Same arrays passed to propose().
    /// @param  descriptionHash keccak256(description).
    /// @return proposalId      The cancelled proposal's ID.
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public override returns (uint256) {
        return super.cancel(targets, values, calldatas, descriptionHash);
    }

    // ─────────────────────────────────────────────────────────────────
    // Internal overrides — GovernorTimelockControl routing
    // ─────────────────────────────────────────────────────────────────

    /// @notice Schedules the proposal's operations in the ProtocolTimelock.
    ///
    ///         Called internally by queue().  Encodes all targets/values/calldatas
    ///         into a single Timelock.scheduleBatch() call.
    ///
    ///         Override required: both Governor and GovernorTimelockControl declare virtual.
    ///
    /// @param  proposalId      The proposal being queued.
    /// @param  targets         Call targets.
    /// @param  values          ETH values per call.
    /// @param  calldatas       Encoded calldata per call.
    /// @param  descriptionHash keccak256 of description; used to derive timelockId.
    /// @return etaSeconds      The earliest timestamp (Unix) at which the operations
    ///                         can be executed (block.timestamp + MIN_DELAY).
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @notice Executes the Timelock operations for the proposal.
    ///
    ///         Called internally by execute().  Calls Timelock.executeBatch(), which
    ///         verifies the operation is in Ready state and fires the encoded calls.
    ///         All calls are made from address(timelock) as msg.sender.
    ///
    ///         Override required: both Governor and GovernorTimelockControl declare virtual.
    ///
    /// @param  proposalId      The proposal being executed.
    /// @param  targets         Call targets.
    /// @param  values          ETH values per call.
    /// @param  calldatas       Encoded calldata per call.
    /// @param  descriptionHash keccak256 of description.
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @notice Cancels both the Governor proposal record and the Timelock operation.
    ///
    ///         Called internally by cancel().  If the proposal is Queued (i.e. its
    ///         Timelock operation was already scheduled), Timelock.cancel() is also
    ///         invoked so the operation is removed from the Timelock queue.
    ///
    ///         Override required: both Governor and GovernorTimelockControl declare virtual.
    ///
    /// @param  targets         Call targets.
    /// @param  values          ETH values per call.
    /// @param  calldatas       Encoded calldata per call.
    /// @param  descriptionHash keccak256 of description.
    /// @return proposalId      The cancelled proposal's ID.
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /// @notice Returns the address that executes proposal calls.
    ///
    ///         GovernorTimelockControl overrides this to return address(timelock).
    ///         The base Governor returns address(this).
    ///         Routing through super ensures the Timelock (not the Governor) is the
    ///         executor and therefore the msg.sender seen by target contracts.
    ///
    ///         Override required: both Governor and GovernorTimelockControl declare virtual.
    ///
    /// @return The ProtocolTimelock contract address.
    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    // ─────────────────────────────────────────────────────────────────
    // IERC165 introspection
    // ─────────────────────────────────────────────────────────────────

    /// @notice Indicates which interfaces this contract implements.
    ///
    ///         GovernorTimelockControl adds support for IGovernorTimelock (the
    ///         queue() / timelock() interface), on top of the base IGovernor and
    ///         IERC165 support declared by Governor.
    ///
    ///         Override required: both Governor and GovernorTimelockControl declare virtual.
    ///
    /// @param  interfaceId  ERC165 interface selector to query.
    /// @return True if this contract implements the requested interface.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        virtual
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }
}

