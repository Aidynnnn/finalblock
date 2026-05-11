// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {GovernanceToken} from "../src/GovernanceToken.sol";
import {ProtocolTimelock} from "../src/ProtocolTimelock.sol";
import {ProtocolGovernor} from "../src/ProtocolGovernor.sol";

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

// ─────────────────────────────────────────────────────────────────────────────
// MockTarget — a simple privileged contract owned by the Timelock.
// Represents any protocol component (vault, AMM, adapter) whose admin role
// has been transferred to the Timelock so that parameter changes must pass
// through governance.
// ─────────────────────────────────────────────────────────────────────────────
contract MockTarget {
    address public immutable TIMELOCK;
    uint256 public param;

    error MockTarget__Unauthorized();

    constructor(address timelock) {
        TIMELOCK = timelock;
    }

    function setParam(uint256 value) external {
        if (msg.sender != TIMELOCK) revert MockTarget__Unauthorized();
        param = value;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// GovernanceLifecycleTest
//
// Demonstrates and verifies the complete DAO lifecycle:
//
//   Propose → [1-day delay] → Vote → [1-week window] →
//   Succeeded → Queue → [2-day timelock] → Execute → Effect verified
//
// Parameter summary (matching project spec):
//   Voting delay      : 1 day   (86 400 s)
//   Voting period     : 1 week  (604 800 s)
//   Quorum fraction   : 4 %     of getPastTotalSupply at snapshot
//   Proposal threshold: 1 %     of totalSupply at propose() time
//   Timelock delay    : 2 days  (172 800 s)  — ProtocolTimelock.MIN_DELAY
// ─────────────────────────────────────────────────────────────────────────────
contract GovernanceLifecycleTest is Test {
    // ── Governance stack ────────────────────────────────────────────
    GovernanceToken internal token;
    ProtocolTimelock internal timelock;
    ProtocolGovernor internal governor;
    MockTarget internal target;

    // ── Actors ──────────────────────────────────────────────────────
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice"); // large holder – proposes & votes For
    address internal bob = makeAddr("bob"); // medium holder – votes For
    address internal carol = makeAddr("carol"); // small holder – votes Against in some tests
    address internal stranger = makeAddr("stranger"); // holds no tokens

    // ── Token distribution ──────────────────────────────────────────
    // Total initial supply : 1 000 000 DGOV  (scaled by 1e18 in the constructor)
    // alice  : 100 000 (10 %)   > 1 % threshold, > 4 % quorum alone
    // bob    :  50 000 (5 %)    > 4 % quorum alone
    // carol  :   5 000 (0.5 %)  below 1 % threshold (cannot propose)
    // deployer: 845 000 (remainder) – self-delegated but does not vote in tests
    uint256 internal constant INITIAL_SUPPLY = 1_000_000; // whole tokens
    uint256 internal constant ALICE_TOKENS = 100_000e18;
    uint256 internal constant BOB_TOKENS = 50_000e18;
    uint256 internal constant CAROL_TOKENS = 5_000e18;

    // ── Governance timing (mirrors contract constants) ───────────────
    uint256 internal constant VOTING_DELAY = 1 days;
    uint256 internal constant VOTING_PERIOD = 1 weeks;
    uint256 internal constant TIMELOCK_DELAY = 2 days;

    // ── Vote support constants ───────────────────────────────────────
    uint8 internal constant AGAINST = 0;
    uint8 internal constant FOR = 1;
    uint8 internal constant ABSTAIN = 2;

    // ────────────────────────────────────────────────────────────────
    // setUp — deploys and wires the full governance stack
    // ────────────────────────────────────────────────────────────────
    function setUp() public {
        vm.startPrank(deployer);

        // 1. Governance token — initial supply minted to deployer.
        token = new GovernanceToken(deployer, INITIAL_SUPPLY);

        // 2. Timelock — no proposers yet (governor address unknown).
        //    address(0) as executor → open execution (anyone can call execute()).
        //    deployer is the temporary admin so it can grant roles after deployment.
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new ProtocolTimelock(proposers, executors, deployer);

        // 3. Governor — wired to the token and the timelock.
        governor = new ProtocolGovernor(token, timelock);

        // 4. Wire roles: grant PROPOSER_ROLE + CANCELLER_ROLE to the Governor.
        //    The Timelock will schedule / execute proposals only via the Governor.
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // 5. Renounce the deployer's TIMELOCK_ADMIN_ROLE.
        //    From this point on, the Timelock is self-governed: any configuration
        //    change must itself pass through a governance proposal.
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        // 6. Transfer GovernanceToken ownership to the Timelock so that
        //    token.mint() can only be triggered by a passed governance proposal.
        token.transferOwnership(address(timelock));

        // 7. Deploy MockTarget with Timelock as its owner.
        //    Represents any protocol component (vault, AMM) under DAO control.
        target = new MockTarget(address(timelock));

        // 8. Distribute tokens.
        token.transfer(alice, ALICE_TOKENS);
        token.transfer(bob, BOB_TOKENS);
        token.transfer(carol, CAROL_TOKENS);
        // deployer retains the remainder (845 000 DGOV)

        vm.stopPrank();

        // 9. Self-delegate — activates ERC20Votes checkpointing for each holder.
        //    Must happen BEFORE any proposal snapshot is taken.
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);
        vm.prank(carol);
        token.delegate(carol);
        vm.prank(deployer);
        token.delegate(deployer);

        // 10. Advance 1 second so that delegation checkpoints are in the past.
        //     Governor.propose() reads getVotes(proposer, clock()-1), so the
        //     checkpoint timestamp must be strictly before the propose() call.
        vm.warp(block.timestamp + 1);
    }

    // ────────────────────────────────────────────────────────────────
    // Helper: build single-call proposal arrays
    // ────────────────────────────────────────────────────────────────
    function _buildProposal(address tgt, bytes memory data)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = tgt;
        values[0] = 0;
        calldatas[0] = data;
    }

    // ────────────────────────────────────────────────────────────────
    // Helper: advance through the entire propose→vote→queue→execute
    //         lifecycle, returning the final proposalId.
    // ────────────────────────────────────────────────────────────────
    function _runFullLifecycle(
        address proposer,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId) {
        // Propose
        vm.prank(proposer);
        proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        // Warp past voting delay → Active
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        // Alice and bob vote For (combined 150k = 15 % > 4 % quorum)
        vm.prank(alice);
        governor.castVote(proposalId, FOR);
        vm.prank(bob);
        governor.castVote(proposalId, FOR);

        // Warp past voting period → Succeeded
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        // Queue into the Timelock
        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        // Warp past Timelock delay → Ready
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Execute
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 1 — Full happy-path lifecycle: parameter change via governance
    // ════════════════════════════════════════════════════════════════
    /// @notice Verifies the complete Propose → Vote → Queue → Execute flow.
    ///         The proposal calls MockTarget.setParam(999), which only the
    ///         Timelock is allowed to call.  After execution we confirm param == 999.
    function test_FullGovernanceLifecycle_ParameterChange() public {
        string memory description = "Proposal #1: Set MockTarget.param to 999";

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildProposal(address(target), abi.encodeCall(MockTarget.setParam, (999)));

        assertEq(target.param(), 0, "param should start at 0");

        uint256 proposalId = _runFullLifecycle(alice, targets, values, calldatas, description);

        // ── Verify the on-chain effect ────────────────────────────────
        assertEq(target.param(), 999, "param must be 999 after execution");

        console2.log("[LIFECYCLE] proposalId:", proposalId);
        console2.log("[LIFECYCLE] MockTarget.param after execution:", target.param());
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 2 — Full happy-path lifecycle: mint tokens via governance
    //          (demonstrates Timelock as the ultimate treasury controller)
    // ════════════════════════════════════════════════════════════════
    /// @notice The Timelock owns GovernanceToken (ownership transferred in setUp).
    ///         A passed proposal can trigger token.mint(), proving that minting
    ///         new tokens requires a successful DAO vote.
    function test_FullGovernanceLifecycle_MintTokensViaTimelock() public {
        address recipient = makeAddr("recipient");
        uint256 mintAmount = 42_000e18;

        string memory description = "Proposal #2: Mint 42 000 DGOV to protocol reserve";

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildProposal(address(token), abi.encodeCall(GovernanceToken.mint, (recipient, mintAmount)));

        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(recipient);

        _runFullLifecycle(alice, targets, values, calldatas, description);

        assertEq(token.balanceOf(recipient), balanceBefore + mintAmount, "recipient should have received minted tokens");
        assertEq(token.totalSupply(), supplyBefore + mintAmount, "total supply must increase by minted amount");

        console2.log("[MINT] total supply after:", token.totalSupply());
        console2.log("[MINT] recipient balance after:", token.balanceOf(recipient));
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 3 — Proposal fails when quorum is not reached
    // ════════════════════════════════════════════════════════════════
    /// @notice Carol holds only 0.5 % of supply (below the 1 % threshold)
    ///         so she cannot propose.  Alice proposes but carol is the only
    ///         one who votes — 0.5 % < 4 % quorum → proposal is Defeated.
    function test_ProposalDefeated_QuorumNotReached() public {
        string memory description = "Proposal #3: Quorum failure test";

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildProposal(address(target), abi.encodeCall(MockTarget.setParam, (1)));

        // Alice proposes (10 % > threshold)
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // Warp past delay → Active
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Only carol votes For (0.5 % — below 4 % quorum)
        vm.prank(carol);
        governor.castVote(proposalId, FOR);

        // Warp past period
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // State must be Defeated (quorum not met)
        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Defeated),
            "proposal must be Defeated when quorum not reached"
        );

        console2.log("[QUORUM] carol votes:", carol.balance);
        console2.log("[QUORUM] quorum required:", governor.quorum(governor.proposalSnapshot(proposalId)));
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 4 — Proposal defeated by majority Against votes
    // ════════════════════════════════════════════════════════════════
    /// @notice Alice (10 %) votes For, but deployer (84.5 %) votes Against.
    ///         Quorum is met (>4 %), but For < Against → Defeated.
    function test_ProposalDefeated_MajorityAgainst() public {
        string memory description = "Proposal #4: Majority against test";

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildProposal(address(target), abi.encodeCall(MockTarget.setParam, (2)));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice); // 100k For
        governor.castVote(proposalId, FOR);
        vm.prank(deployer); // 845k Against
        governor.castVote(proposalId, AGAINST);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Defeated),
            "proposal must be Defeated when For < Against"
        );
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 5 — Proposal threshold: low-power holder cannot propose
    // ════════════════════════════════════════════════════════════════
    /// @notice Carol holds 5 000 DGOV (0.5 % of 1 000 000).
    ///         The dynamic threshold is totalSupply / 100 = 10 000 DGOV.
    ///         carol.votingPower (5 000) < threshold (10 000) → revert.
    function test_ProposalThreshold_BelowThresholdReverts() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildProposal(address(target), abi.encodeCall(MockTarget.setParam, (3)));

        // GovernorInsufficientProposerVotes is a custom error in the Governor base
        vm.prank(carol);
        vm.expectRevert(); // any revert is sufficient; exact selector is an OZ internal
        governor.propose(targets, values, calldatas, "Carol low-power proposal");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 6 — Cannot vote before the voting delay has elapsed
    // ════════════════════════════════════════════════════════════════
    /// @notice Votes cast while the proposal is still Pending (before the
    ///         vote snapshot) must revert.  The Governor enforces the state
    ///         machine strictly.
    function test_CannotVote_BeforeVotingDelay() public {
        string memory description = "Proposal #6: Early vote test";

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildProposal(address(target), abi.encodeCall(MockTarget.setParam, (4)));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        // Attempt to vote while still Pending — must revert
        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(proposalId, FOR);
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 7 — Cannot execute before the 2-day timelock delay elapses
    // ════════════════════════════════════════════════════════════════
    /// @notice After queue(), the Timelock stores the operation with an ETA
    ///         of block.timestamp + 2 days.  Calling execute() before that
    ///         ETA must revert (TimelockUnexpectedOperationState).
    function test_CannotExecute_BeforeTimelockDelay() public {
        string memory description = "Proposal #7: Premature execute test";

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildProposal(address(target), abi.encodeCall(MockTarget.setParam, (5)));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governor.castVote(proposalId, FOR);
        vm.prank(bob);
        governor.castVote(proposalId, FOR);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        // Proposal is Queued — but Timelock ETA has not arrived yet
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        // Do NOT warp — attempt to execute immediately → must revert
        vm.expectRevert();
        governor.execute(targets, values, calldatas, descriptionHash);

        // Confirm state is still Queued and the effect was NOT applied
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
        assertEq(target.param(), 0, "param must remain 0 - execution was blocked");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 8 — Proposer can cancel a Pending proposal before voting starts
    // ════════════════════════════════════════════════════════════════
    function test_ProposerCanCancel_PendingProposal() public {
        string memory description = "Proposal #8: Cancellation test";

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildProposal(address(target), abi.encodeCall(MockTarget.setParam, (6)));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        // Alice (original proposer) cancels before the voting delay elapses
        bytes32 descriptionHash = keccak256(bytes(description));
        vm.prank(alice);
        governor.cancel(targets, values, calldatas, descriptionHash);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Canceled),
            "proposal must be in Canceled state after proposer cancels"
        );
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 9 — Non-proposer cannot cancel another account's pending proposal
    // ════════════════════════════════════════════════════════════════
    function test_CannotCancel_OtherAccountsProposal() public {
        string memory description = "Proposal #9: Cancel authorization test";

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildProposal(address(target), abi.encodeCall(MockTarget.setParam, (7)));

        // Alice proposes
        vm.prank(alice);
        governor.propose(targets, values, calldatas, description);

        // Bob (not the proposer) tries to cancel — must revert
        bytes32 descriptionHash = keccak256(bytes(description));
        vm.prank(bob);
        vm.expectRevert();
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 10 — Timelock delay is enforced at exactly the 2-day boundary
    // ════════════════════════════════════════════════════════════════
    /// @notice Warps to exactly the ETA-1 second (still locked) and then to
    ///         ETA (unlocked) to confirm the boundary is enforced precisely.
    function test_TimelockDelay_ExactBoundary() public {
        string memory description = "Proposal #10: Exact timelock boundary test";

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildProposal(address(target), abi.encodeCall(MockTarget.setParam, (100)));

        vm.prank(alice);
        governor.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governor.castVote(_hashProposal(targets, values, calldatas, description), FOR);
        vm.prank(bob);
        governor.castVote(_hashProposal(targets, values, calldatas, description), FOR);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        bytes32 descriptionHash = keccak256(bytes(description));
        uint256 queuedAt = block.timestamp;
        governor.queue(targets, values, calldatas, descriptionHash);

        // TimelockController stores ETA = queuedAt + TIMELOCK_DELAY and checks
        // block.timestamp >= ETA.  One second before ETA must still revert.
        vm.warp(queuedAt + TIMELOCK_DELAY - 1);
        vm.expectRevert();
        governor.execute(targets, values, calldatas, descriptionHash);

        // At exactly ETA (>=) the operation is Ready — must succeed.
        vm.warp(queuedAt + TIMELOCK_DELAY);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(target.param(), 100);
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 11 — Quorum calculation uses getPastTotalSupply at snapshot
    // ════════════════════════════════════════════════════════════════
    /// @notice Confirms the quorum amount returned by the Governor matches
    ///         4 % of the token supply captured at the proposal snapshot,
    ///         not at execution time.
    function test_QuorumIsComputedAtSnapshot() public {
        string memory description = "Proposal #11: Quorum snapshot test";

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildProposal(address(target), abi.encodeCall(MockTarget.setParam, (8)));

        vm.prank(alice);
        uint256 propId = governor.propose(targets, values, calldatas, description);

        uint256 snapshot = governor.proposalSnapshot(propId);
        uint256 totalSup = token.totalSupply(); // 1 000 000e18 at snapshot time

        // Warp to snapshot + 1 (so query is in the past)
        vm.warp(snapshot + 1);

        uint256 quorumAtSnapshot = governor.quorum(snapshot);
        uint256 expectedQuorum = totalSup * 4 / 100; // 40 000e18

        assertEq(quorumAtSnapshot, expectedQuorum, "quorum must be exactly 4 % of totalSupply at snapshot");

        console2.log("[QUORUM] totalSupply at snapshot:", totalSup);
        console2.log("[QUORUM] required quorum (4 %):", quorumAtSnapshot);
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 12 — Governor constants match spec values exactly
    // ════════════════════════════════════════════════════════════════
    function test_GovernorConstants_MatchSpec() public view {
        assertEq(governor.votingDelay(), 1 days, "voting delay must be 1 day");
        assertEq(governor.votingPeriod(), 1 weeks, "voting period must be 1 week");
        assertEq(governor.quorumNumerator(), 4, "quorum numerator must be 4 (= 4 %)");
        assertEq(timelock.getMinDelay(), 2 days, "timelock min delay must be 2 days");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 13 — Proposal threshold is 1 % of total supply (dynamic)
    // ════════════════════════════════════════════════════════════════
    function test_ProposalThreshold_Is1PctOfSupply() public view {
        uint256 supply = token.totalSupply(); // 1 000 000e18
        uint256 threshold = governor.proposalThreshold();
        assertEq(threshold, supply / 100, "threshold must be 1 % of total supply");
        // Alice (100 000e18) > threshold (10 000e18) ✓
        assertGt(token.getVotes(alice), threshold, "alice must exceed threshold");
        // Carol (5 000e18)  < threshold (10 000e18) ✓
        assertLt(token.getVotes(carol), threshold, "carol must be below threshold");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 14 — Clock mode is timestamp (EIP-6372 alignment check)
    // ════════════════════════════════════════════════════════════════
    function test_ClockMode_IsTimestamp() public view {
        assertEq(token.CLOCK_MODE(), "mode=timestamp", "token clock must be timestamp");
        assertEq(governor.CLOCK_MODE(), "mode=timestamp", "governor clock must be timestamp");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 15 — Timelock role wiring is correct after setUp
    // ════════════════════════════════════════════════════════════════
    function test_TimelockRoles_CorrectlyWired() public view {
        // Governor has PROPOSER_ROLE and CANCELLER_ROLE
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));

        // address(0) has EXECUTOR_ROLE (open execution)
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));

        // Deployer no longer has TIMELOCK_ADMIN_ROLE (renounced in setUp)
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));

        // GovernanceToken is owned by the Timelock
        assertEq(token.owner(), address(timelock));
    }

    // ────────────────────────────────────────────────────────────────
    // Internal helper — reproduce hashProposal without importing internals
    // ────────────────────────────────────────────────────────────────
    function _hashProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(targets, values, calldatas, keccak256(bytes(description)))));
    }
}
