import {
  CreationPauseToggled as CreationPauseToggledEvent,
  OwnershipTransferred as OwnershipTransferredEvent,
  PairCreated as PairCreatedEvent,
  VanillaPairCreated as VanillaPairCreatedEvent,
} from "../generated/AMMPool/AMMPool"
import {
  CreationPauseToggled,
  OwnershipTransferred,
  PairCreated,
  VanillaPairCreated,
} from "../generated/schema"

export function handleCreationPauseToggled(
  event: CreationPauseToggledEvent,
): void {
  let entity = new CreationPauseToggled(
    event.transaction.hash.concatI32(event.logIndex.toI32()),
  )
  entity.paused = event.params.paused

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleOwnershipTransferred(
  event: OwnershipTransferredEvent,
): void {
  let entity = new OwnershipTransferred(
    event.transaction.hash.concatI32(event.logIndex.toI32()),
  )
  entity.previousOwner = event.params.previousOwner
  entity.newOwner = event.params.newOwner

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handlePairCreated(event: PairCreatedEvent): void {
  let entity = new PairCreated(
    event.transaction.hash.concatI32(event.logIndex.toI32()),
  )
  entity.token0 = event.params.token0
  entity.token1 = event.params.token1
  entity.pair = event.params.pair
  entity.totalPairs = event.params.totalPairs

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleVanillaPairCreated(event: VanillaPairCreatedEvent): void {
  let entity = new VanillaPairCreated(
    event.transaction.hash.concatI32(event.logIndex.toI32()),
  )
  entity.token0 = event.params.token0
  entity.token1 = event.params.token1
  entity.pair = event.params.pair
  entity.totalVanillaPairs = event.params.totalVanillaPairs

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}
