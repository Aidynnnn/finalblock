import {
  assert,
  describe,
  test,
  clearStore,
  beforeAll,
  afterAll
} from "matchstick-as/assembly/index"
import { Address, BigInt } from "@graphprotocol/graph-ts"
import { CreationPauseToggled } from "../generated/schema"
import { CreationPauseToggled as CreationPauseToggledEvent } from "../generated/AMMPool/AMMPool"
import { handleCreationPauseToggled } from "../src/amm-pool"
import { createCreationPauseToggledEvent } from "./amm-pool-utils"

// Tests structure (matchstick-as >=0.5.0)
// https://thegraph.com/docs/en/subgraphs/developing/creating/unit-testing-framework/#tests-structure

describe("Describe entity assertions", () => {
  beforeAll(() => {
    let paused = "boolean Not implemented"
    let newCreationPauseToggledEvent = createCreationPauseToggledEvent(paused)
    handleCreationPauseToggled(newCreationPauseToggledEvent)
  })

  afterAll(() => {
    clearStore()
  })

  // For more test scenarios, see:
  // https://thegraph.com/docs/en/subgraphs/developing/creating/unit-testing-framework/#write-a-unit-test

  test("CreationPauseToggled created and stored", () => {
    assert.entityCount("CreationPauseToggled", 1)

    // 0xa16081f360e3847006db660bae1c6d1b2e17ec2a is the default address used in newMockEvent() function
    assert.fieldEquals(
      "CreationPauseToggled",
      "0xa16081f360e3847006db660bae1c6d1b2e17ec2a-1",
      "paused",
      "boolean Not implemented"
    )

    // More assert options:
    // https://thegraph.com/docs/en/subgraphs/developing/creating/unit-testing-framework/#asserts
  })
})
