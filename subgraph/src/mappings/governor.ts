import { BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  ProposalCreated,
  ProposalQueued,
  ProposalExecuted,
  ProposalCanceled,
  VoteCast,
} from "../../../generated/ProtocolGovernor/ProtocolGovernor";
import { Proposal, Vote, ProtocolDayData } from "../../../generated/schema";

// ─────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────

function dayId(timestamp: BigInt): string {
  let dayStart = timestamp.div(BigInt.fromI32(86400)).times(BigInt.fromI32(86400));
  return dayStart.toString();
}

function loadOrCreateDayData(timestamp: BigInt): ProtocolDayData {
  let id = dayId(timestamp);
  let data = ProtocolDayData.load(id);
  if (data == null) {
    data = new ProtocolDayData(id);
    let dayStart = timestamp.div(BigInt.fromI32(86400)).times(BigInt.fromI32(86400));
    data.date                = dayStart;
    data.dailySwapCount      = BigInt.zero();
    data.dailyVolumeToken0   = BigInt.zero();
    data.dailyVolumeToken1   = BigInt.zero();
    data.dailyDepositCount   = BigInt.zero();
    data.dailyWithdrawalCount= BigInt.zero();
    data.dailyProposalCount  = BigInt.zero();
    data.dailyVoteCount      = BigInt.zero();
  }
  return data as ProtocolDayData;
}

// ─────────────────────────────────────────────────────────────────
// Event handlers
// ─────────────────────────────────────────────────────────────────

export function handleProposalCreated(event: ProposalCreated): void {
  let proposalId = event.params.proposalId;
  // Use hex string as ID to avoid BigInt overflow in string form.
  let id = proposalId.toHexString();

  let proposal = new Proposal(id);
  proposal.proposalId        = proposalId;
  proposal.proposer          = event.params.proposer;

  // Coerce address[] → Bytes[] for the schema field type.
  let rawTargets = event.params.targets;
  let targets = new Array<Bytes>(rawTargets.length);
  for (let i = 0; i < rawTargets.length; i++) {
    targets[i] = rawTargets[i];
  }
  proposal.targets   = targets;
  proposal.values    = event.params.values;

  // calldatas is bytes[] in the ABI — store as-is.
  proposal.calldatas   = event.params.calldatas;
  proposal.description = event.params.description;
  proposal.voteStart   = event.params.voteStart;
  proposal.voteEnd     = event.params.voteEnd;

  // Initial state: all transitions pending.
  proposal.queued      = false;
  proposal.etaSeconds  = null;
  proposal.executed    = false;
  proposal.canceled    = false;

  // Zero tallies — incremented as VoteCast events arrive.
  proposal.forVotes     = BigInt.zero();
  proposal.againstVotes = BigInt.zero();
  proposal.abstainVotes = BigInt.zero();
  proposal.voterCount   = BigInt.zero();

  proposal.createdAtBlock     = event.block.number;
  proposal.createdAtTimestamp = event.block.timestamp;
  proposal.save();

  let day = loadOrCreateDayData(event.block.timestamp);
  day.dailyProposalCount = day.dailyProposalCount.plus(BigInt.fromI32(1));
  day.save();
}

export function handleProposalQueued(event: ProposalQueued): void {
  let id = event.params.proposalId.toHexString();
  let proposal = Proposal.load(id);
  if (proposal == null) return;

  proposal.queued     = true;
  proposal.etaSeconds = event.params.etaSeconds;
  proposal.save();
}

export function handleProposalExecuted(event: ProposalExecuted): void {
  let id = event.params.proposalId.toHexString();
  let proposal = Proposal.load(id);
  if (proposal == null) return;

  proposal.executed = true;
  proposal.save();
}

export function handleProposalCanceled(event: ProposalCanceled): void {
  let id = event.params.proposalId.toHexString();
  let proposal = Proposal.load(id);
  if (proposal == null) return;

  proposal.canceled = true;
  proposal.save();
}

export function handleVoteCast(event: VoteCast): void {
  let proposalId = event.params.proposalId.toHexString();
  let proposal = Proposal.load(proposalId);
  if (proposal == null) return;

  let voter  = event.params.voter;
  let weight = event.params.weight;
  // support: 0 = Against, 1 = For, 2 = Abstain
  let support = event.params.support;

  if (support == 0) {
    proposal.againstVotes = proposal.againstVotes.plus(weight);
  } else if (support == 1) {
    proposal.forVotes = proposal.forVotes.plus(weight);
  } else {
    proposal.abstainVotes = proposal.abstainVotes.plus(weight);
  }
  proposal.voterCount = proposal.voterCount.plus(BigInt.fromI32(1));
  proposal.save();

  // Vote ID is proposalId-voterAddress (unique per voter per proposal — re-voting blocked by OZ).
  let voteId = proposalId + "-" + voter.toHexString();
  let vote = new Vote(voteId);
  vote.proposal        = proposalId;
  vote.voter           = voter;
  vote.support         = support;
  vote.weight          = weight;
  vote.reason          = event.params.reason;
  vote.blockNumber     = event.block.number;
  vote.timestamp       = event.block.timestamp;
  vote.transactionHash = event.transaction.hash;
  vote.save();

  let day = loadOrCreateDayData(event.block.timestamp);
  day.dailyVoteCount = day.dailyVoteCount.plus(BigInt.fromI32(1));
  day.save();
}
