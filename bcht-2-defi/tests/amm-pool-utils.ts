import { newMockEvent } from "matchstick-as"
import { ethereum, Address, BigInt } from "@graphprotocol/graph-ts"
import {
  CreationPauseToggled,
  OwnershipTransferred,
  PairCreated,
  VanillaPairCreated
} from "../generated/AMMPool/AMMPool"

export function createCreationPauseToggledEvent(
  paused: boolean
): CreationPauseToggled {
  let creationPauseToggledEvent =
    changetype<CreationPauseToggled>(newMockEvent())

  creationPauseToggledEvent.parameters = new Array()

  creationPauseToggledEvent.parameters.push(
    new ethereum.EventParam("paused", ethereum.Value.fromBoolean(paused))
  )

  return creationPauseToggledEvent
}

export function createOwnershipTransferredEvent(
  previousOwner: Address,
  newOwner: Address
): OwnershipTransferred {
  let ownershipTransferredEvent =
    changetype<OwnershipTransferred>(newMockEvent())

  ownershipTransferredEvent.parameters = new Array()

  ownershipTransferredEvent.parameters.push(
    new ethereum.EventParam(
      "previousOwner",
      ethereum.Value.fromAddress(previousOwner)
    )
  )
  ownershipTransferredEvent.parameters.push(
    new ethereum.EventParam("newOwner", ethereum.Value.fromAddress(newOwner))
  )

  return ownershipTransferredEvent
}

export function createPairCreatedEvent(
  token0: Address,
  token1: Address,
  pair: Address,
  totalPairs: BigInt
): PairCreated {
  let pairCreatedEvent = changetype<PairCreated>(newMockEvent())

  pairCreatedEvent.parameters = new Array()

  pairCreatedEvent.parameters.push(
    new ethereum.EventParam("token0", ethereum.Value.fromAddress(token0))
  )
  pairCreatedEvent.parameters.push(
    new ethereum.EventParam("token1", ethereum.Value.fromAddress(token1))
  )
  pairCreatedEvent.parameters.push(
    new ethereum.EventParam("pair", ethereum.Value.fromAddress(pair))
  )
  pairCreatedEvent.parameters.push(
    new ethereum.EventParam(
      "totalPairs",
      ethereum.Value.fromUnsignedBigInt(totalPairs)
    )
  )

  return pairCreatedEvent
}

export function createVanillaPairCreatedEvent(
  token0: Address,
  token1: Address,
  pair: Address,
  totalVanillaPairs: BigInt
): VanillaPairCreated {
  let vanillaPairCreatedEvent = changetype<VanillaPairCreated>(newMockEvent())

  vanillaPairCreatedEvent.parameters = new Array()

  vanillaPairCreatedEvent.parameters.push(
    new ethereum.EventParam("token0", ethereum.Value.fromAddress(token0))
  )
  vanillaPairCreatedEvent.parameters.push(
    new ethereum.EventParam("token1", ethereum.Value.fromAddress(token1))
  )
  vanillaPairCreatedEvent.parameters.push(
    new ethereum.EventParam("pair", ethereum.Value.fromAddress(pair))
  )
  vanillaPairCreatedEvent.parameters.push(
    new ethereum.EventParam(
      "totalVanillaPairs",
      ethereum.Value.fromUnsignedBigInt(totalVanillaPairs)
    )
  )

  return vanillaPairCreatedEvent
}
