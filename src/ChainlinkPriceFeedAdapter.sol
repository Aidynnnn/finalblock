// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// ═══════════════════════════════════════════════════════════════════
// INTERFACES
// ═══════════════════════════════════════════════════════════════════

/// @title  IAggregatorV3
/// @notice Minimal interface for a Chainlink AggregatorV3-compatible price feed.
///         Defining a local interface (rather than importing the full Chainlink
///         package) keeps the dependency footprint small and lets us swap in a
///         mock aggregator during testing with zero code changes.
interface IAggregatorV3 {
    /// @notice Returns the number of decimals in the feed's answer.
    function decimals() external view returns (uint8);

    /// @notice Returns a human-readable description of the feed (e.g. "ETH / USD").
    function description() external view returns (string memory);

    /// @notice Returns the latest round data from the aggregator.
    /// @return roundId          The round ID of this answer.
    /// @return answer           The raw price value (signed; may be negative for some feeds).
    /// @return startedAt        Timestamp when the round started.
    /// @return updatedAt        Timestamp of the last price update (used for staleness check).
    /// @return answeredInRound  The round in which the answer was computed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title  IPriceFeedAdapter
/// @notice Public interface that the rest of the protocol (Vault, AMM keeper, etc.)
///         uses to consume prices.  Coding against this interface rather than the
///         concrete adapter makes it trivial to swap Chainlink for Pyth, Redstone,
///         or a TWAP adapter in a future upgrade without touching callers.
interface IPriceFeedAdapter {
    /// @notice Returns the latest validated price, normalised to 18 decimals.
    /// @param  feed  The feed identifier (address of the AggregatorV3 contract).
    /// @return price Price in WAD (1e18 = $1.00 for a USD feed).
    function getPrice(address feed) external view returns (uint256 price);

    /// @notice Returns the number of decimals the raw feed uses.
    function getFeedDecimals(address feed) external view returns (uint8);
}

// ═══════════════════════════════════════════════════════════════════
// MAIN CONTRACT
// ═══════════════════════════════════════════════════════════════════

/// @title  ChainlinkPriceFeedAdapter
/// @notice Adapter that wraps one or more Chainlink AggregatorV3 feeds, performs
///         all required safety checks, and normalises prices to 18 decimal WAD
///         format for use throughout the DeFi Super-App protocol.
///
///         Safety checks performed on every call:
///         ──────────────────────────────────────
///         1. answeredInRound ≥ roundId   — the answer belongs to the current round
///            (detects a round that was started but not yet answered, which can
///            happen during Chainlink node downtime).
///         2. answer > 0                  — negative or zero prices are invalid for
///            asset valuation.
///         3. updatedAt ≠ 0               — the round has been initialised.
///         4. block.timestamp - updatedAt ≤ heartbeat — staleness guard; each feed
///            has its own configurable heartbeat (e.g. 3600 s for ETH/USD on L2s,
///            86400 s for some less-active feeds).
///
///         Price normalisation:
///         ─────────────────────
///         Chainlink feeds use varying decimal counts (8 for most USD feeds, 18
///         for some ETH feeds).  This adapter normalises every answer to 18
///         decimals so callers never need to handle scaling:
///           if feedDecimals < 18: price = answer * 10^(18 - feedDecimals)
///           if feedDecimals = 18: price = answer
///           if feedDecimals > 18: price = answer / 10^(feedDecimals - 18)
///         The last case is rare in practice but handled for completeness.
///
///         Feed registration:
///         ──────────────────
///         Feeds must be explicitly registered by the owner (expected to be the
///         TimelockController after governance is live).  Unregistered feeds revert
///         immediately, preventing accidental use of un-validated aggregator addresses.
///
/// @custom:security-contact security@yourprotocol.xyz
contract ChainlinkPriceFeedAdapter is IPriceFeedAdapter, Ownable {
    // ────────────────────────────────────────────────────────────────
    // Custom errors
    // ────────────────────────────────────────────────────────────────

    /// @dev Feed address has not been registered via registerFeed().
    error PriceFeed__NotRegistered(address feed);

    /// @dev Feed is already registered; use updateHeartbeat() to change it.
    error PriceFeed__AlreadyRegistered(address feed);

    /// @dev The raw answer returned by the aggregator is ≤ 0.
    error PriceFeed__InvalidPrice(address feed, int256 answer);

    /// @dev The round has not been answered yet (answeredInRound < roundId).
    error PriceFeed__RoundNotComplete(address feed, uint80 roundId, uint80 answeredInRound);

    /// @dev The updatedAt timestamp is zero; the round was never initialised.
    error PriceFeed__InvalidRoundTimestamp(address feed);

    /// @dev Price data is older than the registered heartbeat for this feed.
    error PriceFeed__StalePrice(address feed, uint256 updatedAt, uint256 currentTimestamp, uint256 heartbeat);

    /// @dev A zero-address was supplied where one is not valid.
    error PriceFeed__ZeroAddress();

    /// @dev Heartbeat of zero is not valid (would make every price immediately stale).
    error PriceFeed__ZeroHeartbeat();

    // ────────────────────────────────────────────────────────────────
    // Storage
    // ────────────────────────────────────────────────────────────────

    /// @dev Per-feed configuration stored compactly.
    struct FeedConfig {
        /// @notice Maximum age (in seconds) of the last update before the price
        ///         is considered stale and the call reverts.
        ///         Typical values: 3600 (1 h) for ETH/USD on Arbitrum/Optimism,
        ///                         86400 (24 h) for some less-frequently-updated pairs.
        uint256 heartbeat;
        /// @notice Decimal count reported by the aggregator (cached at registration
        ///         to save a cold STATICCALL on every price read).
        uint8 decimals;
        /// @notice True once the feed has been registered.
        bool registered;
    }

    /// @dev Mapping from AggregatorV3 address to its configuration.
    mapping(address => FeedConfig) private _feedConfigs;

    // ────────────────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────────────────

    /// @notice Emitted when a new feed is registered.
    event FeedRegistered(address indexed feed, uint256 heartbeat, uint8 decimals);

    /// @notice Emitted when a feed's heartbeat is updated.
    event HeartbeatUpdated(address indexed feed, uint256 oldHeartbeat, uint256 newHeartbeat);

    /// @notice Emitted when a feed is deregistered (e.g. deprecated aggregator).
    event FeedDeregistered(address indexed feed);

    // ────────────────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────────────────

    /// @param initialOwner Address that receives Ownable control.  Should be
    ///                     transferred to the TimelockController after deployment.
    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert PriceFeed__ZeroAddress();
    }

    // ────────────────────────────────────────────────────────────────
    // Admin: feed lifecycle
    // ────────────────────────────────────────────────────────────────

    /// @notice Registers a new Chainlink aggregator feed.
    /// @dev    Reads `decimals()` from the live aggregator and caches it so that
    ///         subsequent price reads incur only one STATICCALL (latestRoundData).
    ///
    /// @param  feed       Address of the AggregatorV3 contract on the current network.
    /// @param  heartbeat  Maximum acceptable age (seconds) for the price answer.
    function registerFeed(address feed, uint256 heartbeat) external onlyOwner {
        // ── Checks ──────────────────────────────────────────────────
        if (feed == address(0)) revert PriceFeed__ZeroAddress();
        if (heartbeat == 0) revert PriceFeed__ZeroHeartbeat();
        if (_feedConfigs[feed].registered) revert PriceFeed__AlreadyRegistered(feed);

        // ── Effects ─────────────────────────────────────────────────
        // Cache decimals from the live feed to avoid a repeated external call later.
        uint8 feedDecimals = IAggregatorV3(feed).decimals();

        _feedConfigs[feed] = FeedConfig({heartbeat: heartbeat, decimals: feedDecimals, registered: true});

        emit FeedRegistered(feed, heartbeat, feedDecimals);
    }

    /// @notice Updates the heartbeat for an already-registered feed.
    ///         Use this when Chainlink changes the update frequency for a pair.
    ///
    /// @param feed          Address of the registered aggregator.
    /// @param newHeartbeat  New maximum acceptable age in seconds.
    function updateHeartbeat(address feed, uint256 newHeartbeat) external onlyOwner {
        // ── Checks ──────────────────────────────────────────────────
        if (!_feedConfigs[feed].registered) revert PriceFeed__NotRegistered(feed);
        if (newHeartbeat == 0) revert PriceFeed__ZeroHeartbeat();

        // ── Effects ─────────────────────────────────────────────────
        uint256 oldHeartbeat = _feedConfigs[feed].heartbeat;
        _feedConfigs[feed].heartbeat = newHeartbeat;

        emit HeartbeatUpdated(feed, oldHeartbeat, newHeartbeat);
    }

    /// @notice Removes a feed from the registry (e.g. when Chainlink deprecates an
    ///         aggregator address and migrates to a new proxy).
    ///
    /// @param feed Address of the feed to deregister.
    function deregisterFeed(address feed) external onlyOwner {
        // ── Checks ──────────────────────────────────────────────────
        if (!_feedConfigs[feed].registered) revert PriceFeed__NotRegistered(feed);

        // ── Effects ─────────────────────────────────────────────────
        delete _feedConfigs[feed];

        emit FeedDeregistered(feed);
    }

    // ────────────────────────────────────────────────────────────────
    // IPriceFeedAdapter implementation
    // ────────────────────────────────────────────────────────────────

    /// @inheritdoc IPriceFeedAdapter
    /// @dev Performs ALL four safety checks before returning.
    ///      Reverts on any validation failure — callers must handle the case
    ///      where this function reverts (e.g. the Vault should pause rather than
    ///      operate on a stale or invalid price).
    function getPrice(address feed) external view override returns (uint256 price) {
        price = _getValidatedPrice(feed);
    }

    /// @inheritdoc IPriceFeedAdapter
    function getFeedDecimals(address feed) external view override returns (uint8) {
        if (!_feedConfigs[feed].registered) revert PriceFeed__NotRegistered(feed);
        return _feedConfigs[feed].decimals;
    }

    /// @notice Returns the registered heartbeat for a feed (useful for off-chain monitoring).
    function getHeartbeat(address feed) external view returns (uint256) {
        if (!_feedConfigs[feed].registered) revert PriceFeed__NotRegistered(feed);
        return _feedConfigs[feed].heartbeat;
    }

    /// @notice Returns true if `feed` has been registered.
    function isRegistered(address feed) external view returns (bool) {
        return _feedConfigs[feed].registered;
    }

    // ────────────────────────────────────────────────────────────────
    // Internal helpers
    // ────────────────────────────────────────────────────────────────

    /// @dev Core validation and normalisation logic, extracted so it can be
    ///      reused without re-checking the registration flag from different entry points.
    function _getValidatedPrice(address feed) internal view returns (uint256 normalised) {
        // ── Check registration ───────────────────────────────────────
        FeedConfig memory cfg = _feedConfigs[feed];
        if (!cfg.registered) revert PriceFeed__NotRegistered(feed);

        // ── Fetch raw round data ─────────────────────────────────────
        (
            uint80 roundId,
            int256 answer,, // startedAt — not used in our validation logic
            uint256 updatedAt,
            uint80 answeredInRound
        ) = IAggregatorV3(feed).latestRoundData();

        // ── Safety check 1: round completeness ──────────────────────
        // answeredInRound < roundId means a new round started but the nodes have
        // not yet reached consensus; the cached answer from a previous round is
        // being returned, which could be arbitrarily stale.
        if (answeredInRound < roundId) {
            revert PriceFeed__RoundNotComplete(feed, roundId, answeredInRound);
        }

        // ── Safety check 2: positive price ──────────────────────────
        // Chainlink uses int256 for historical compatibility; negative values
        // and zero are always invalid for asset pricing.
        if (answer <= 0) revert PriceFeed__InvalidPrice(feed, answer);

        // ── Safety check 3: initialised round ───────────────────────
        // updatedAt == 0 indicates the round struct was never written, which
        // can occur on freshly deployed proxy contracts.
        if (updatedAt == 0) revert PriceFeed__InvalidRoundTimestamp(feed);

        // ── Safety check 4: staleness (the N-second heartbeat check) ─
        // block.timestamp is used here only as a deadline/age comparison —
        // an accepted use case distinct from using it as randomness.
        // The unchecked subtraction is safe: updatedAt ≤ block.timestamp
        // is implied by check 3 (updatedAt > 0) and L1/L2 consensus rules.
        uint256 age = block.timestamp - updatedAt;
        if (age > cfg.heartbeat) {
            revert PriceFeed__StalePrice(feed, updatedAt, block.timestamp, cfg.heartbeat);
        }

        // ── Normalise to 18 decimals ─────────────────────────────────
        // Cast is safe: answer > 0 was verified in check 2.
        uint256 rawPrice = uint256(answer);

        if (cfg.decimals < 18) {
            // Scale up: e.g. 8-decimal feed → multiply by 10^10.
            normalised = rawPrice * (10 ** (18 - cfg.decimals));
        } else if (cfg.decimals > 18) {
            // Scale down (rare): e.g. a hypothetical 20-decimal feed.
            normalised = rawPrice / (10 ** (cfg.decimals - 18));
        } else {
            // Already 18 decimals; no scaling needed.
            normalised = rawPrice;
        }
    }
}
