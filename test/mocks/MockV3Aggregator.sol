// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  MockV3Aggregator
/// @notice A fully controllable drop-in replacement for a Chainlink AggregatorV3
///         price feed, designed for Foundry test environments.
///
///         Mirrors the Chainlink MockV3Aggregator pattern but adds explicit setters
///         for every individual return field of latestRoundData() so tests can
///         exercise every staleness / round-completeness guard in the adapter
///         without time-traveling or forking mainnet.
///
///         Interface implemented (matches ChainlinkPriceFeedAdapter's IAggregatorV3):
///           • decimals()
///           • description()
///           • latestRoundData() → (roundId, answer, startedAt, updatedAt, answeredInRound)
///
/// @dev    NEVER deploy to mainnet — test-only contract.
contract MockV3Aggregator {

    // ─────────────────────────────────────────────────────────────────
    // Stored state (mirrors a real Chainlink round)
    // ─────────────────────────────────────────────────────────────────

    uint8  public _decimals;
    string public _description;

    uint80  public _roundId;
    int256  public _answer;
    uint256 public _startedAt;
    uint256 public _updatedAt;
    uint80  public _answeredInRound;

    // ─────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────

    /// @param decimals_      Feed decimal count (e.g. 8 for most USD feeds).
    /// @param initialAnswer  Initial price answer in raw feed units.
    constructor(uint8 decimals_, int256 initialAnswer) {
        _decimals     = decimals_;
        _description  = "Mock Feed";

        _roundId         = 1;
        _answer          = initialAnswer;
        _startedAt       = block.timestamp;
        _updatedAt       = block.timestamp;
        _answeredInRound = 1;
    }

    // ─────────────────────────────────────────────────────────────────
    // AggregatorV3Interface
    // ─────────────────────────────────────────────────────────────────

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80  roundId,
            int256  answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80  answeredInRound
        )
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    // ─────────────────────────────────────────────────────────────────
    // Test control helpers
    // ─────────────────────────────────────────────────────────────────

    /// @notice Updates the price answer and auto-advances the round ID.
    ///         Mirrors the most common test pattern: set a new price, verify the
    ///         adapter accepts it.  Sets updatedAt = block.timestamp so the price
    ///         is always fresh unless the test warps time afterward.
    function updateAnswer(int256 answer) external {
        _roundId        += 1;
        _answer          = answer;
        _startedAt       = block.timestamp;
        _updatedAt       = block.timestamp;
        _answeredInRound = _roundId;
    }

    /// @notice Full manual override of all round fields.
    ///         Use this to construct adversarial scenarios:
    ///           - answeredInRound < roundId  → incomplete round
    ///           - updatedAt = 0              → uninitialised round
    ///           - far-past updatedAt         → stale price
    ///           - answer <= 0               → invalid price
    function updateRoundData(
        uint80  roundId_,
        int256  answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80  answeredInRound_
    ) external {
        _roundId         = roundId_;
        _answer          = answer_;
        _startedAt       = startedAt_;
        _updatedAt       = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    /// @notice Sets only the updatedAt field.
    ///         Useful for staleness-boundary tests without touching the price.
    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    /// @notice Sets only the answer field (does NOT advance the round).
    ///         Useful for injecting a bad price while preserving round metadata.
    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }
}
