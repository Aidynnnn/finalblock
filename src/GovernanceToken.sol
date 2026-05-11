// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title  GovernanceToken
/// @notice ERC-20 governance token with on-chain vote-weight checkpointing (ERC20Votes)
///         and gasless off-chain approval signatures (ERC20Permit / EIP-2612).
///
///         Design decisions:
///         ─────────────────
///         • ERC20Votes  – records voting power snapshots at every transfer/delegate so
///           the Governor can query historical balances and resist flash-loan attacks.
///         • ERC20Permit – lets users approve in one meta-transaction (no pre-approve tx),
///           improving UX and reducing gas cost for first-time depositors into the vault.
///         • Ownable     – only the initial owner (deployer / Timelock after handoff) may
///           mint new tokens; there is no public mint; the cap is soft (no hard ERC-20 cap
///           is enforced here, but the DAO can govern the minting policy via the Timelock).
///
///         Storage layout (relevant for UUPS proxy variant in V2):
///         ─────────────────────────────────────────────────────────
///         All state lives in the OpenZeppelin base contracts:
///           - ERC20           : _balances, _allowances, _totalSupply, _name, _symbol
///           - ERC20Votes      : _delegatee, _checkpoints, _totalSupplyCheckpoints
///           - ERC20Permit     : (none beyond Nonces) _nonces inherited from Nonces
///           - Ownable         : _owner
///
/// @custom:security-contact security@yourprotocol.xyz
contract GovernanceToken is ERC20, ERC20Permit, ERC20Votes, Ownable {
    // ────────────────────────────────────────────────────────────────
    // Custom errors  (cheaper than require strings – saves ~50 gas ea.)
    // ────────────────────────────────────────────────────────────────

    /// @dev Reverts when a zero-address is supplied where one is not valid.
    error GovernanceToken__ZeroAddress();

    /// @dev Reverts when a mint amount of zero is supplied.
    error GovernanceToken__ZeroAmount();

    // ────────────────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────────────────

    /// @notice Emitted on every mint call, recording recipient and amount.
    event TokensMinted(address indexed to, uint256 amount);

    // ────────────────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────────────────

    /// @param initialOwner  Address that receives the Ownable role (should be the
    ///                      deployer; ownership is expected to be transferred to the
    ///                      TimelockController after the DAO is live).
    /// @param initialSupply Tokens minted to `initialOwner` at construction time
    ///                      (expressed in whole tokens; scaled by 1e18 internally).
    ///                      Pass 0 if you want an empty initial supply.
    constructor(address initialOwner, uint256 initialSupply)
        ERC20("DeFiApp Governance Token", "DGOV")
        ERC20Permit("DeFiApp Governance Token") // domain separator uses this name
        Ownable(initialOwner)
    {
        if (initialOwner == address(0)) revert GovernanceToken__ZeroAddress();

        if (initialSupply > 0) {
            // Mint to owner; votes are automatically checkpointed by ERC20Votes._update.
            _mint(initialOwner, initialSupply * 1e18);
            emit TokensMinted(initialOwner, initialSupply * 1e18);
        }
    }

    // ────────────────────────────────────────────────────────────────
    // Owner-gated mint
    // ────────────────────────────────────────────────────────────────

    /// @notice Mints `amount` tokens to `to`.
    /// @dev    Only callable by the current owner (expected to be the Timelock after
    ///         governance is live). Follows CEI: checks first, then effects (_mint).
    ///
    /// @param to     Recipient address.
    /// @param amount Raw token amount (already in 1e18 decimals; caller scales).
    function mint(address to, uint256 amount) external onlyOwner {
        // ── Checks ──────────────────────────────────────────────────
        if (to == address(0)) revert GovernanceToken__ZeroAddress();
        if (amount == 0) revert GovernanceToken__ZeroAmount();

        // ── Effects ─────────────────────────────────────────────────
        _mint(to, amount); // ERC20Votes._update is called inside, updating checkpoints
        emit TokensMinted(to, amount);

        // ── Interactions ─────────────────────────────────────────────
        // (none — _mint is internal; no external calls are made)
    }

    // ────────────────────────────────────────────────────────────────
    // EIP-6372: timestamp-based clock  (must match ProtocolGovernor)
    // ────────────────────────────────────────────────────────────────
    // Votes.sol defaults to block.number.  ProtocolGovernor hard-overrides
    // clock() to block.timestamp.  Both sides MUST agree, otherwise
    // getPastVotes(voter, snapshotTimestamp) looks up a block-number key
    // that doesn't exist and returns 0 — making all proposals fail quorum.

    /// @notice Returns the current clock value as a Unix timestamp.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice EIP-6372 clock descriptor — signals timestamp mode to off-chain tools.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // ────────────────────────────────────────────────────────────────
    // Required overrides
    // ────────────────────────────────────────────────────────────────
    // Solidity requires us to explicitly resolve the diamond when multiple
    // bases define the same virtual function.

    /// @inheritdoc ERC20
    /// @dev Both ERC20Votes and ERC20 define _update; ERC20Votes overrides it to
    ///      record checkpoint data.  We route through ERC20Votes so vote weights
    ///      are always up to date.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    /// @inheritdoc Nonces
    /// @dev ERC20Permit and ERC20Votes both inherit Nonces. The compiler forces us
    ///      to override to remove ambiguity; we simply call super.
    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
