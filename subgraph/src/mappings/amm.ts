import { BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  Swap as SwapEvent,
  LiquidityAdded,
  LiquidityRemoved,
  ReservesUpdated,
  ConstantProductAMM,
} from "../../../generated/ConstantProductAMM/ConstantProductAMM";
import { Pool, Swap, LiquidityEvent, ProtocolDayData } from "../../../generated/schema";

// ─────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────

function loadOrCreatePool(address: string, timestamp: BigInt, block: BigInt): Pool {
  let pool = Pool.load(address);
  if (pool == null) {
    // First event ever from this pool — bootstrap from contract state.
    let contract = ConstantProductAMM.bind(
      changetype<import("@graphprotocol/graph-ts").Address>(
        Bytes.fromHexString(address)
      )
    );
    pool = new Pool(address);
    let reserves = contract.getReserves();
    pool.token0             = contract.token0();
    pool.token1             = contract.token1();
    pool.reserve0           = reserves.value0;
    pool.reserve1           = reserves.value1;
    pool.totalVolumeToken0  = BigInt.zero();
    pool.totalVolumeToken1  = BigInt.zero();
    pool.swapCount          = BigInt.zero();
    pool.txCount            = BigInt.zero();
    pool.updatedAtBlock     = block;
    pool.updatedAtTimestamp = timestamp;
  }
  return pool as Pool;
}

function dayId(timestamp: BigInt): string {
  // Round down to UTC day start: timestamp / 86400 * 86400
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

export function handleSwap(event: SwapEvent): void {
  let poolAddress = event.address.toHexString();
  let pool = loadOrCreatePool(
    poolAddress,
    event.block.timestamp,
    event.block.number
  );

  // Determine direction and update cumulative volumes.
  let token0 = pool.token0.toHexString();
  let tokenIn = event.params.tokenIn.toHexString();
  if (tokenIn == token0) {
    pool.totalVolumeToken0 = pool.totalVolumeToken0.plus(event.params.amountIn);
  } else {
    pool.totalVolumeToken1 = pool.totalVolumeToken1.plus(event.params.amountIn);
  }

  pool.swapCount          = pool.swapCount.plus(BigInt.fromI32(1));
  pool.txCount            = pool.txCount.plus(BigInt.fromI32(1));
  pool.updatedAtBlock     = event.block.number;
  pool.updatedAtTimestamp = event.block.timestamp;
  pool.save();

  // Immutable swap record.
  let swapId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
  let swap = new Swap(swapId);
  swap.pool            = poolAddress;
  swap.swapper         = event.params.swapper;
  swap.tokenIn         = event.params.tokenIn;
  swap.amountIn        = event.params.amountIn;
  swap.amountOut       = event.params.amountOut;
  swap.blockNumber     = event.block.number;
  swap.timestamp       = event.block.timestamp;
  swap.transactionHash = event.transaction.hash;
  swap.save();

  // Daily roll-up.
  let day = loadOrCreateDayData(event.block.timestamp);
  day.dailySwapCount = day.dailySwapCount.plus(BigInt.fromI32(1));
  if (tokenIn == token0) {
    day.dailyVolumeToken0 = day.dailyVolumeToken0.plus(event.params.amountIn);
  } else {
    day.dailyVolumeToken1 = day.dailyVolumeToken1.plus(event.params.amountIn);
  }
  day.save();
}

export function handleLiquidityAdded(event: LiquidityAdded): void {
  let poolAddress = event.address.toHexString();
  let pool = loadOrCreatePool(
    poolAddress,
    event.block.timestamp,
    event.block.number
  );

  pool.txCount            = pool.txCount.plus(BigInt.fromI32(1));
  pool.updatedAtBlock     = event.block.number;
  pool.updatedAtTimestamp = event.block.timestamp;
  pool.save();

  let evtId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
  let liqEvt = new LiquidityEvent(evtId);
  liqEvt.pool            = poolAddress;
  liqEvt.provider        = event.params.provider;
  liqEvt.amount0         = event.params.amount0;
  liqEvt.amount1         = event.params.amount1;
  liqEvt.lpTokensDelta   = event.params.lpTokensMinted;  // positive: minted
  liqEvt.eventType       = "ADD";
  liqEvt.blockNumber     = event.block.number;
  liqEvt.timestamp       = event.block.timestamp;
  liqEvt.transactionHash = event.transaction.hash;
  liqEvt.save();
}

export function handleLiquidityRemoved(event: LiquidityRemoved): void {
  let poolAddress = event.address.toHexString();
  let pool = loadOrCreatePool(
    poolAddress,
    event.block.timestamp,
    event.block.number
  );

  pool.txCount            = pool.txCount.plus(BigInt.fromI32(1));
  pool.updatedAtBlock     = event.block.number;
  pool.updatedAtTimestamp = event.block.timestamp;
  pool.save();

  let evtId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
  let liqEvt = new LiquidityEvent(evtId);
  liqEvt.pool            = poolAddress;
  liqEvt.provider        = event.params.provider;
  liqEvt.amount0         = event.params.amount0;
  liqEvt.amount1         = event.params.amount1;
  // Negative delta: tokens burned on remove.
  liqEvt.lpTokensDelta   = event.params.lpTokensBurned.neg();
  liqEvt.eventType       = "REMOVE";
  liqEvt.blockNumber     = event.block.number;
  liqEvt.timestamp       = event.block.timestamp;
  liqEvt.transactionHash = event.transaction.hash;
  liqEvt.save();
}

// ReservesUpdated fires after every state-changing call; keeps Pool reserves in sync.
export function handleReservesUpdated(event: ReservesUpdated): void {
  let poolAddress = event.address.toHexString();
  let pool = Pool.load(poolAddress);
  if (pool == null) return;  // should not happen after bootstrap, guard anyway

  pool.reserve0           = event.params.reserve0;
  pool.reserve1           = event.params.reserve1;
  pool.updatedAtBlock     = event.block.number;
  pool.updatedAtTimestamp = event.block.timestamp;
  pool.save();
}
