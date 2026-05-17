// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {GovernanceToken} from "../src/GovernanceToken.sol";
import {ChainlinkPriceFeedAdapter} from "../src/ChainlinkPriceFeedAdapter.sol";
import {ProtocolTimelock} from "../src/ProtocolTimelock.sol";
import {ProtocolGovernor} from "../src/ProtocolGovernor.sol";
import {AMMFactory} from "../src/AMMFactory.sol";
import {ERC4626VaultV1} from "../src/ERC4626VaultV1.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

// ═══════════════════════════════════════════════════════════════════════════
// Deploy
//
// Deployment order (strict dependency chain):
//   1. GovernanceToken          — no external deps; deployer is initial owner
//   2. ChainlinkPriceFeedAdapter — no external deps; deployer is initial owner
//   3. ProtocolTimelock         — no external deps; deployer is temporary admin
//   4. ProtocolGovernor         — depends on GovernanceToken + ProtocolTimelock
//   5. Wire governance roles    — grant PROPOSER/CANCELLER to Governor; renounce admin
//   6. Transfer ownerships      — GovernanceToken + Adapter → Timelock
//   7. AMMFactory               — no external deps; Timelock is owner
//   8. ERC4626VaultV1 impl      — no-arg; just the bare implementation for proxies
//   9. VaultFactory             — depends on ERC4626VaultV1 impl; Timelock is owner
//
// Usage:
//   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
//
// Required environment variables:
//   PRIVATE_KEY  - hex-encoded private key of the deployer (without 0x prefix or with)
// ═══════════════════════════════════════════════════════════════════════════
contract Deploy is Script {
    // 1 000 000 DGOV minted to the deployer at launch (whole-token units;
    // the GovernanceToken constructor scales by ×1e18 internally).
    uint256 private constant INITIAL_SUPPLY = 1_000_000;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("==================================================");
        console.log(" DeFi Super-App - Full Protocol Deployment");
        console.log("==================================================");
        console.log("Deployer:   ", deployer);
        console.log("Chain ID:   ", block.chainid);
        console.log("Block:      ", block.number);
        console.log("");

        vm.startBroadcast(privateKey);

        // ── 1. GovernanceToken ────────────────────────────────────────────────
        // ERC-20 + ERC20Votes + ERC20Permit.  Deployer receives INITIAL_SUPPLY
        // whole tokens and is set as the Ownable owner (transferred to Timelock
        // in step 6 once the governance stack is fully wired).
        GovernanceToken govToken = new GovernanceToken(deployer, INITIAL_SUPPLY);

        // ── 2. ChainlinkPriceFeedAdapter ──────────────────────────────────────
        // Ownable oracle wrapper.  Ownership transferred to the Timelock in step 6
        // so that feed registration requires a governance vote post-launch.
        ChainlinkPriceFeedAdapter adapter = new ChainlinkPriceFeedAdapter(deployer);

        // ── 3. ProtocolTimelock ───────────────────────────────────────────────
        // • proposers: empty array — the Governor is not deployed yet.
        //              PROPOSER_ROLE is granted explicitly in step 5.
        // • executors: [address(0)] — OZ sentinel for "anyone may execute."
        //              Prevents a single privileged executor from becoming a
        //              centralisation risk after the timelock delay elapses.
        // • admin:     deployer — temporary TIMELOCK_ADMIN_ROLE so step 5 can
        //              call grantRole before the deployer renounces the role.
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        ProtocolTimelock timelock = new ProtocolTimelock(proposers, executors, deployer);

        // ── 4. ProtocolGovernor ───────────────────────────────────────────────
        // Wires to the governance token (ERC20Votes / IVotes) and the Timelock.
        // Configured with:
        //   • 1-day  voting delay   (VOTING_DELAY_SECONDS  = 86 400 s)
        //   • 1-week voting period  (VOTING_PERIOD_SECONDS = 604 800 s)
        //   • 4%     quorum fraction
        //   • 1%     dynamic proposal threshold (computed at propose() time)
        ProtocolGovernor governor = new ProtocolGovernor(
            IVotes(address(govToken)),
            TimelockController(payable(address(timelock)))
        );

        // ── 5. Wire governance roles ──────────────────────────────────────────
        // The Timelock was deployed without any proposers so that we could first
        // deploy the Governor and obtain its address.  Now we grant it the roles
        // it needs, then permanently strip the deployer of admin access.
        //
        // After renounceRole() below:
        //   DEFAULT_ADMIN_ROLE  → address(this) [the Timelock itself] only
        //   PROPOSER_ROLE       → governor
        //   CANCELLER_ROLE      → governor
        //   EXECUTOR_ROLE       → address(0)  [anyone]
        //
        // Any future change to these roles must itself pass a full 2-day
        // governance proposal — no EOA can short-circuit this.
        bytes32 proposerRole   = timelock.PROPOSER_ROLE();
        bytes32 cancellerRole  = timelock.CANCELLER_ROLE();
        // OZ v5 TimelockController uses DEFAULT_ADMIN_ROLE (bytes32(0)) from
        // AccessControl instead of the v4 TIMELOCK_ADMIN_ROLE constant.
        bytes32 adminRole      = timelock.DEFAULT_ADMIN_ROLE();

        timelock.grantRole(proposerRole,  address(governor));
        timelock.grantRole(cancellerRole, address(governor));

        // Renounce last — any earlier renounce would prevent grantRole calls above.
        timelock.renounceRole(adminRole, deployer);

        // ── 6. Transfer protocol ownerships to the Timelock ───────────────────
        // From this point, minting DGOV or registering Chainlink feeds requires
        // a successful governance proposal to pass through the 2-day timelock.
        govToken.transferOwnership(address(timelock));
        adapter.transferOwnership(address(timelock));

        // ── 7. AMMFactory ─────────────────────────────────────────────────────
        // Permissionless pair creation; the Timelock holds the owner role to
        // toggle the creation-pause circuit breaker if needed.
        AMMFactory ammFactory = new AMMFactory(address(timelock));

        // ── 8. ERC4626VaultV1 implementation ─────────────────────────────────
        // Bare implementation contract — NOT a usable vault on its own.
        // The constructor calls _disableInitializers() so it cannot be initialised
        // directly.  Proxies deployed by VaultFactory will delegate to this address.
        ERC4626VaultV1 vaultImpl = new ERC4626VaultV1();

        // ── 9. VaultFactory ───────────────────────────────────────────────────
        // Deploys ERC1967 UUPS proxies (each a separate vault instance) pointing
        // to vaultImpl.  The Timelock owns the factory so only a governance vote
        // can update the canonical implementation address (e.g. to V2).
        VaultFactory vaultFactory = new VaultFactory(address(vaultImpl), address(timelock));

        vm.stopBroadcast();

        // ── Deployment Summary ────────────────────────────────────────────────
        console.log("==================================================");
        console.log(" Deployed Addresses");
        console.log("==================================================");
        console.log("GovernanceToken (DGOV)       :", address(govToken));
        console.log("ChainlinkPriceFeedAdapter    :", address(adapter));
        console.log("ProtocolTimelock             :", address(timelock));
        console.log("ProtocolGovernor             :", address(governor));
        console.log("AMMFactory                   :", address(ammFactory));
        console.log("ERC4626VaultV1 (impl)        :", address(vaultImpl));
        console.log("VaultFactory                 :", address(vaultFactory));
        console.log("==================================================");
        console.log("");
        console.log("Next steps:");
        console.log("  ammFactory.createPair(tokenA, tokenB)");
        console.log("  vaultFactory.deployVault(lpToken, amm, adapter, owner)");
        console.log("  Register Chainlink feeds via governance proposal.");
    }
}
