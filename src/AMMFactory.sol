// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ConstantProductAMM} from "./AMM.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title  AMMFactory
/// @notice Factory that deploys ConstantProductAMM pair contracts.
///
///         Two deployment modes are supported:
///         ──────────────────────────────────
///         A) CREATE2  (createPair)
///            Produces a deterministic address derived from the two token addresses
///            and the factory's own address.  The same token pair will always resolve
///            to the same pool address on any network that has the factory deployed at
///            the same address — critical for cross-L2 tooling and front-end routing.
///
///         B) CREATE   (createPairVanilla)
///            Produces a nonce-based address.  Useful for testing, staging networks,
///            or scenarios where you deliberately want multiple pools for the same
///            token pair (e.g. different fee tiers in a future upgrade).
///
///         Salt construction (CREATE2):
///         ────────────────────────────
///         Tokens are sorted before hashing so that (A, B) and (B, A) produce
///         the same address — avoiding duplicate pools for the same pair.
///         salt = keccak256(abi.encodePacked(token0, token1))  (sorted, token0 < token1)
///
///         Address prediction:
///         ────────────────────
///         computePairAddress() lets anyone predict the CREATE2 address off-chain or
///         from another contract before deployment, enabling router contracts to route
///         through a not-yet-deployed pool without a registry lookup.
///
///         Access control:
///         ───────────────
///         Anyone may call createPair / createPairVanilla — the factory is permissionless.
///         The owner role exists only to pause pair creation (circuit breaker) and to
///         collect protocol fees in future versions.  Pair deployment itself is not gated.
///
/// @custom:security-contact security@yourprotocol.xyz
contract AMMFactory is Ownable {
    // ────────────────────────────────────────────────────────────────
    // Custom errors
    // ────────────────────────────────────────────────────────────────

    /// @dev Reverts when either token address supplied is the zero address.
    error Factory__ZeroAddress();

    /// @dev Reverts when tokenA == tokenB.
    error Factory__IdenticalTokens();

    /// @dev Reverts when a CREATE2 pair for this token combination already exists.
    error Factory__PairAlreadyExists(address token0, address token1, address pair);

    /// @dev Reverts when pair creation is paused by the owner.
    error Factory__CreationPaused();

    /// @dev Reverts when the inline assembly CREATE2 deployment returns address(0),
    ///      which indicates the deployment failed (e.g. insufficient gas, salt collision).
    error Factory__DeploymentFailed();

    // ────────────────────────────────────────────────────────────────
    // Storage
    // ────────────────────────────────────────────────────────────────

    /// @notice True when pair creation is paused (circuit breaker).
    bool public creationPaused;

    /// @notice Canonical CREATE2 pair registry.
    ///         getPair[token0][token1] == getPair[token1][token0] (always sorted internally).
    ///         Returns address(0) if no CREATE2 pair exists yet.
    mapping(address => mapping(address => address)) public getPair;

    /// @notice Ordered list of all CREATE2 pairs ever deployed by this factory.
    address[] private _allPairs;

    /// @notice Ordered list of all CREATE pairs (vanilla nonce-based deploys).
    address[] private _allVanillaPairs;

    // ────────────────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────────────────

    /// @notice Emitted on every CREATE2 pair deployment.
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256 totalPairs
    );

    /// @notice Emitted on every vanilla CREATE pair deployment.
    event VanillaPairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256 totalVanillaPairs
    );

    /// @notice Emitted when the circuit breaker is toggled.
    event CreationPauseToggled(bool paused);

    // ────────────────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────────────────

    /// @param initialOwner Receives the Ownable role.  Expected to be transferred
    ///                     to the TimelockController after governance is live.
    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert Factory__ZeroAddress();
    }

    // ────────────────────────────────────────────────────────────────
    // View helpers
    // ────────────────────────────────────────────────────────────────

    /// @notice Returns the total number of CREATE2 pairs deployed by this factory.
    function allPairsLength() external view returns (uint256) {
        return _allPairs.length;
    }

    /// @notice Returns the CREATE2 pair at index `index` in deployment order.
    function allPairs(uint256 index) external view returns (address) {
        return _allPairs[index];
    }

    /// @notice Returns the total number of vanilla CREATE pairs.
    function allVanillaPairsLength() external view returns (uint256) {
        return _allVanillaPairs.length;
    }

    /// @notice Returns the vanilla CREATE pair at index `index`.
    function allVanillaPairs(uint256 index) external view returns (address) {
        return _allVanillaPairs[index];
    }

    // ────────────────────────────────────────────────────────────────
    // Address prediction
    // ────────────────────────────────────────────────────────────────

    /// @notice Computes the deterministic CREATE2 address for a given token pair
    ///         WITHOUT deploying the contract.
    ///
    ///         This mirrors the exact salt and initcode used in createPair(), so the
    ///         result is guaranteed to match what createPair() would deploy.
    ///
    /// @param tokenA One of the two tokens (order-independent).
    /// @param tokenB The other token.
    /// @return pair  The address where the pair would/will live.
    function computePairAddress(address tokenA, address tokenB)
        external
        view
        returns (address pair)
    {
        if (tokenA == address(0) || tokenB == address(0)) revert Factory__ZeroAddress();
        if (tokenA == tokenB) revert Factory__IdenticalTokens();

        (address t0, address t1) = _sortTokens(tokenA, tokenB);

        bytes32 salt       = _computeSalt(t0, t1);
        bytes32 initcodeHash = keccak256(_encodedCreationCode(t0, t1));

        // Standard CREATE2 address formula:
        //   address(keccak256(0xff ++ factory ++ salt ++ keccak256(initcode))[12:])
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            initcodeHash
                        )
                    )
                )
            )
        );
    }

    // ────────────────────────────────────────────────────────────────
    // Pair deployment — CREATE2 (deterministic)
    // ────────────────────────────────────────────────────────────────

    /// @notice Deploys a new ConstantProductAMM pair for `tokenA` / `tokenB`
    ///         using CREATE2 for a deterministic address.
    ///
    ///         Only one CREATE2 pair per token combination is allowed.
    ///         Token order is irrelevant; they are sorted internally.
    ///
    /// @param tokenA One of the two pool tokens.
    /// @param tokenB The other pool token.
    /// @return pair  The address of the newly deployed ConstantProductAMM.
    function createPair(address tokenA, address tokenB)
        external
        returns (address pair)
    {
        // ── Checks ───────────────────────────────────────────────────
        if (creationPaused) revert Factory__CreationPaused();
        if (tokenA == address(0) || tokenB == address(0)) revert Factory__ZeroAddress();
        if (tokenA == tokenB) revert Factory__IdenticalTokens();

        (address token0, address token1) = _sortTokens(tokenA, tokenB);

        // Enforce uniqueness in the canonical registry.
        address existing = getPair[token0][token1];
        if (existing != address(0)) revert Factory__PairAlreadyExists(token0, token1, existing);

        // ── Effects ─────────────────────────────────────────────────
        bytes memory creationCode = _encodedCreationCode(token0, token1);
        bytes32 salt              = _computeSalt(token0, token1);

        // Inline Yul assembly for CREATE2.
        // Using assembly allows us to pass an arbitrary salt, which the high-level
        // `new Contract{salt: s}(...)` syntax also supports in Solidity ≥0.8, but
        // the assembly version makes the mechanic explicit for audit clarity and
        // fulfils the course requirement for inline Yul.
        //
        // Memory layout of creationCode:
        //   [0x00..0x1f]  : length prefix (ABI encoding of bytes)
        //   [0x20..]      : raw bytecode
        //
        // mload(creationCode) reads the first 32 bytes, which IS the length.
        // add(creationCode, 0x20) skips the length to reach the raw bytecode start.
        assembly {
            pair := create2(
                0,                             // value (ETH) sent with deployment = 0
                add(creationCode, 0x20),       // pointer to raw bytecode
                mload(creationCode),           // length of bytecode
                salt                           // deterministic salt
            )
        }

        // create2 returns address(0) on failure (e.g. the address is already occupied,
        // insufficient gas, or initcode reverted).
        if (pair == address(0)) revert Factory__DeploymentFailed();

        // Update registry and array AFTER confirming deployment succeeded.
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // reverse mapping for convenience
        _allPairs.push(pair);

        // ── Interactions ─────────────────────────────────────────────
        // (none — constructor call is embedded in create2; no external calls needed)

        emit PairCreated(token0, token1, pair, _allPairs.length);
    }

    // ────────────────────────────────────────────────────────────────
    // Pair deployment — CREATE (nonce-based / vanilla)
    // ────────────────────────────────────────────────────────────────

    /// @notice Deploys a new ConstantProductAMM pair using a standard CREATE opcode.
    ///         The address is determined by the factory's nonce and is NOT predictable.
    ///
    ///         Use this when you need a second pool for an existing pair (e.g. for
    ///         testing) or when a deterministic address is not required.
    ///
    ///         NOTE: This function does NOT check for duplicates in getPair —
    ///         multiple vanilla pools for the same token pair are allowed by design.
    ///         Callers are responsible for tracking the returned address.
    ///
    /// @param tokenA One of the two pool tokens.
    /// @param tokenB The other pool token.
    /// @return pair  The address of the newly deployed ConstantProductAMM.
    function createPairVanilla(address tokenA, address tokenB)
        external
        returns (address pair)
    {
        // ── Checks ───────────────────────────────────────────────────
        if (creationPaused) revert Factory__CreationPaused();
        if (tokenA == address(0) || tokenB == address(0)) revert Factory__ZeroAddress();
        if (tokenA == tokenB) revert Factory__IdenticalTokens();

        (address token0, address token1) = _sortTokens(tokenA, tokenB);

        // ── Effects ─────────────────────────────────────────────────
        bytes memory creationCode = _encodedCreationCode(token0, token1);

        // Inline Yul assembly for CREATE (nonce-based deployment).
        // Identical memory conventions to the CREATE2 block above, minus the salt.
        assembly {
            pair := create(
                0,                             // value (ETH) sent = 0
                add(creationCode, 0x20),       // raw bytecode pointer
                mload(creationCode)            // bytecode length
            )
        }

        if (pair == address(0)) revert Factory__DeploymentFailed();

        _allVanillaPairs.push(pair);

        // ── Interactions ─────────────────────────────────────────────
        // (none)

        emit VanillaPairCreated(token0, token1, pair, _allVanillaPairs.length);
    }

    // ────────────────────────────────────────────────────────────────
    // Circuit breaker (owner only)
    // ────────────────────────────────────────────────────────────────

    /// @notice Pauses or unpauses the creation of new pairs.
    ///         Designed as a last-resort circuit breaker for the governance multisig.
    ///         Existing pairs are NOT affected; only new deployments are blocked.
    function toggleCreationPause() external onlyOwner {
        creationPaused = !creationPaused;
        emit CreationPauseToggled(creationPaused);
    }

    // ────────────────────────────────────────────────────────────────
    // Internal helpers
    // ────────────────────────────────────────────────────────────────

    /// @dev Sorts two token addresses in ascending order.
    ///      All callers must use sorted tokens before hashing or deploying.
    function _sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @dev Computes the CREATE2 salt for a sorted token pair.
    ///      Using abi.encodePacked (not abi.encode) is safe here because both
    ///      values are fixed-size address types; there is no ambiguity in packing.
    function _computeSalt(address token0, address token1)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(token0, token1));
    }

    /// @dev Returns the complete constructor-encoded creation bytecode for a
    ///      ConstantProductAMM(token0, token1) deployment.
    ///
    ///      type(ConstantProductAMM).creationCode returns the raw bytecode of the
    ///      contract without constructor arguments.  abi.encodePacked appends the
    ///      ABI-encoded constructor arguments so the EVM can execute the full init.
    ///
    ///      This helper is used by BOTH createPair (CREATE2) and computePairAddress
    ///      to guarantee that the predicted hash matches the actual deployment.
    function _encodedCreationCode(address token0, address token1)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(ConstantProductAMM).creationCode,
            abi.encode(token0, token1)
        );
    }
}
