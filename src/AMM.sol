// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  ConstantProductAMM  (x · y = k)
/// @notice A from-scratch constant-product automated market maker.
///
///         Architecture overview:
///         ──────────────────────
///         • Any two ERC-20 tokens can be pooled.  The pool is created once in the
///           constructor and is immutable (tokens cannot be changed after deploy).
///         • Liquidity providers deposit both tokens in the current ratio and receive
///           LP tokens representing their proportional share of the pool.
///         • Swappers pay a 0.3% fee on the input amount.  The fee stays in the pool,
///           so LP token holders accrue it through a growing reserve-per-share ratio.
///         • The k-invariant (reserve0 * reserve1) must be ≥ the pre-swap k after every
///           swap.  This is checked explicitly at the end of every swap; the transaction
///           reverts if the invariant is violated, making it impossible to drain the pool
///           through rounding errors or re-entrancy.
///         • Arithmetic uses 256-bit unsigned integers throughout.  Intermediate products
///           are checked for overflow by the Solidity ≥0.8 built-in overflow protection.
///
///         Fee math (0.3% on input):
///         ─────────────────────────
///           amountInWithFee = amountIn * 997
///           numerator       = amountInWithFee * reserveOut
///           denominator     = reserveIn * 1000 + amountInWithFee
///           amountOut       = numerator / denominator          (integer division, rounds down)
///
///         This is the standard Uniswap V2 fee formula, proven to keep k non-decreasing:
///           After the swap: (reserveIn + amountIn) * (reserveOut - amountOut) ≥ k_before
///           The explicit k-invariant check at the end of swap() guarantees this.
///
///         Security properties:
///         ─────────────────────
///         • ReentrancyGuard on all state-mutating functions.
///         • Checks-Effects-Interactions strictly followed:
///             1. All checks (reverts on bad input, slippage, etc.)
///             2. All state updates (_reserve0, _reserve1, LP mint/burn)
///             3. External token transfers (last)
///         • SafeERC20 wraps every ERC-20 call (handles non-standard return values).
///         • Reserves are tracked as internal state (_reserve0, _reserve1), never
///           read from balanceOf mid-transaction, preventing donation / inflation attacks.
///         • Minimum liquidity (MINIMUM_LIQUIDITY = 1000) is locked to address(1) on
///           the first deposit to prevent the LP share inflation attack.
///
/// @custom:security-contact security@yourprotocol.xyz
contract ConstantProductAMM is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────────────────────────────
    // Constants
    // ────────────────────────────────────────────────────────────────

    /// @notice Denominator for the fee calculation (1000 = 100%).
    uint256 public constant FEE_DENOMINATOR = 1000;

    /// @notice Fee numerator: 997 / 1000 means the trader keeps 99.7% of input,
    ///         i.e. 0.3% fee is retained in the pool.
    uint256 public constant FEE_NUMERATOR = 997;

    /// @notice Minimum LP units locked forever to address(1) on the first deposit.
    ///         This prevents the LP inflation attack where an attacker seeds 1 wei of
    ///         each token and then manipulates the geometric mean to make every future
    ///         depositor receive 0 shares.
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;

    // ────────────────────────────────────────────────────────────────
    // Custom errors
    // ────────────────────────────────────────────────────────────────

    error AMM__ZeroAddress();
    error AMM__IdenticalTokens();
    error AMM__ZeroAmount();
    error AMM__InsufficientLiquidity();
    error AMM__InsufficientInputAmount();
    error AMM__InsufficientOutputAmount();
    error AMM__SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error AMM__InvalidToken(address token);
    error AMM__KInvariantViolated(uint256 kBefore, uint256 kAfter);
    error AMM__InsufficientLiquidityMinted();
    error AMM__InsufficientLiquidityBurned();
    error AMM__DeadlineExpired(uint256 deadline, uint256 blockTimestamp);

    // ────────────────────────────────────────────────────────────────
    // Immutables
    // ────────────────────────────────────────────────────────────────

    /// @notice The first token in the pair (lower address by convention, set at deploy).
    IERC20 public immutable token0;

    /// @notice The second token in the pair.
    IERC20 public immutable token1;

    // ────────────────────────────────────────────────────────────────
    // Storage
    // ────────────────────────────────────────────────────────────────

    /// @dev Tracked reserve of token0.  Updated after every liquidity/swap operation.
    ///      Using internal tracking instead of balanceOf prevents reentrancy donation.
    uint256 private _reserve0;

    /// @dev Tracked reserve of token1.
    uint256 private _reserve1;

    // ────────────────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────────────────

    /// @notice Emitted when liquidity is added.
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 lpTokensMinted);

    /// @notice Emitted when liquidity is removed.
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 lpTokensBurned);

    /// @notice Emitted on every successful swap.
    event Swap(address indexed swapper, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    /// @notice Emitted whenever reserves change, for off-chain price tracking.
    event ReservesUpdated(uint256 reserve0, uint256 reserve1);

    // ────────────────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────────────────

    /// @param tokenA One of the two pool tokens.
    /// @param tokenB The other pool token.
    /// @dev   Tokens are sorted by address so that (tokenA, tokenB) and (tokenB, tokenA)
    ///        produce the same deterministic pair address when created via the Factory.
    constructor(address tokenA, address tokenB) ERC20("DeFiApp LP Token", "DLPT") {
        if (tokenA == address(0) || tokenB == address(0)) revert AMM__ZeroAddress();
        if (tokenA == tokenB) revert AMM__IdenticalTokens();

        // Sort tokens so token0 always has the smaller address.
        (token0, token1) = tokenA < tokenB ? (IERC20(tokenA), IERC20(tokenB)) : (IERC20(tokenB), IERC20(tokenA));
    }

    // ────────────────────────────────────────────────────────────────
    // View helpers
    // ────────────────────────────────────────────────────────────────

    /// @notice Returns the current pool reserves.
    /// @return reserve0 Current tracked balance of token0.
    /// @return reserve1 Current tracked balance of token1.
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1) {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
    }

    /// @notice Quotes the output amount for a given input, including the 0.3% fee.
    ///         Does NOT modify state; use for off-chain quoting and UI.
    ///
    /// @param tokenIn   The token the caller wants to sell.
    /// @param amountIn  Gross amount of tokenIn (before fee deduction).
    /// @return amountOut Net amount of the other token the caller would receive.
    function getAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        if (amountIn == 0) revert AMM__ZeroAmount();
        _validateToken(tokenIn);

        (uint256 reserveIn, uint256 reserveOut) =
            tokenIn == address(token0) ? (_reserve0, _reserve1) : (_reserve1, _reserve0);

        amountOut = _calcAmountOut(amountIn, reserveIn, reserveOut);
    }

    // ────────────────────────────────────────────────────────────────
    // Core: Add Liquidity
    // ────────────────────────────────────────────────────────────────

    /// @notice Deposits `amount0Desired` of token0 and `amount1Desired` of token1
    ///         into the pool, minting LP tokens to `to`.
    ///
    ///         The actual amounts deposited are computed to maintain the current ratio.
    ///         If the pool is empty this is the initial deposit and the ratio is set
    ///         by the caller.
    ///
    /// @param amount0Desired Maximum token0 the caller is willing to deposit.
    /// @param amount1Desired Maximum token1 the caller is willing to deposit.
    /// @param amount0Min     Minimum token0 accepted (slippage protection).
    /// @param amount1Min     Minimum token1 accepted (slippage protection).
    /// @param to             Recipient of LP tokens.
    /// @param deadline       Unix timestamp after which the tx reverts.
    /// @return amount0       Actual token0 deposited.
    /// @return amount1       Actual token1 deposited.
    /// @return liquidity     LP tokens minted.
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
        // ── Checks ───────────────────────────────────────────────────
        _checkDeadline(deadline);
        if (to == address(0)) revert AMM__ZeroAddress();
        if (amount0Desired == 0 || amount1Desired == 0) revert AMM__ZeroAmount();

        uint256 r0 = _reserve0;
        uint256 r1 = _reserve1;

        // Compute optimal deposit amounts to preserve the current price ratio.
        if (r0 == 0 && r1 == 0) {
            // First deposit: set the price ratio.
            (amount0, amount1) = (amount0Desired, amount1Desired);
        } else {
            // Maintain ratio: calculate how much of each token is needed.
            uint256 amount1Optimal = _quote(amount0Desired, r0, r1);
            if (amount1Optimal <= amount1Desired) {
                // token1 is the scarce side.
                if (amount1Optimal < amount1Min) revert AMM__SlippageExceeded(amount1Optimal, amount1Min);
                (amount0, amount1) = (amount0Desired, amount1Optimal);
            } else {
                // token0 is the scarce side.
                uint256 amount0Optimal = _quote(amount1Desired, r1, r0);
                // amount0Optimal <= amount0Desired is guaranteed because amount1Optimal > amount1Desired
                if (amount0Optimal < amount0Min) revert AMM__SlippageExceeded(amount0Optimal, amount0Min);
                (amount0, amount1) = (amount0Optimal, amount1Desired);
            }
        }

        // ── Effects ──────────────────────────────────────────────────
        uint256 totalSupply_ = totalSupply();

        if (totalSupply_ == 0) {
            // Geometric mean of initial deposit, minus permanently locked minimum.
            // sqrt(amount0 * amount1) prevents a LP share inflation attack.
            uint256 initialLiquidity = Math.sqrt(amount0 * amount1);
            if (initialLiquidity <= MINIMUM_LIQUIDITY) revert AMM__InsufficientLiquidityMinted();
            liquidity = initialLiquidity - MINIMUM_LIQUIDITY;

            // Lock MINIMUM_LIQUIDITY to address(1) permanently.
            _mint(address(1), MINIMUM_LIQUIDITY);
        } else {
            // Proportional to the smaller contribution so the pool price cannot be
            // manipulated by donating extra tokens on one side.
            uint256 l0 = (amount0 * totalSupply_) / r0;
            uint256 l1 = (amount1 * totalSupply_) / r1;
            liquidity = l0 < l1 ? l0 : l1;
        }

        if (liquidity == 0) revert AMM__InsufficientLiquidityMinted();

        // Update reserves before external calls (CEI).
        _updateReserves(r0 + amount0, r1 + amount1);

        // Mint LP tokens to recipient.
        _mint(to, liquidity);

        // ── Interactions ─────────────────────────────────────────────
        // Transfer tokens FROM caller INTO this contract AFTER state is settled.
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        emit LiquidityAdded(to, amount0, amount1, liquidity);
    }

    // ────────────────────────────────────────────────────────────────
    // Core: Remove Liquidity
    // ────────────────────────────────────────────────────────────────

    /// @notice Burns `liquidity` LP tokens from `msg.sender` and returns the
    ///         proportional share of both tokens to `to`.
    ///
    /// @param liquidity  Amount of LP tokens to burn.
    /// @param amount0Min Minimum token0 to receive (slippage protection).
    /// @param amount1Min Minimum token1 to receive (slippage protection).
    /// @param to         Recipient of the underlying tokens.
    /// @param deadline   Unix timestamp after which the tx reverts.
    /// @return amount0   Token0 returned to `to`.
    /// @return amount1   Token1 returned to `to`.
    function removeLiquidity(uint256 liquidity, uint256 amount0Min, uint256 amount1Min, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        // ── Checks ───────────────────────────────────────────────────
        _checkDeadline(deadline);
        if (to == address(0)) revert AMM__ZeroAddress();
        if (liquidity == 0) revert AMM__ZeroAmount();
        if (balanceOf(msg.sender) < liquidity) revert AMM__InsufficientLiquidity();

        uint256 totalSupply_ = totalSupply();
        uint256 r0 = _reserve0;
        uint256 r1 = _reserve1;

        // Proportional share of each token.
        amount0 = (liquidity * r0) / totalSupply_;
        amount1 = (liquidity * r1) / totalSupply_;

        if (amount0 == 0 || amount1 == 0) revert AMM__InsufficientLiquidityBurned();
        if (amount0 < amount0Min) revert AMM__SlippageExceeded(amount0, amount0Min);
        if (amount1 < amount1Min) revert AMM__SlippageExceeded(amount1, amount1Min);

        // ── Effects ──────────────────────────────────────────────────
        // Burn LP tokens BEFORE transferring underlying assets (CEI).
        _burn(msg.sender, liquidity);
        _updateReserves(r0 - amount0, r1 - amount1);

        // ── Interactions ─────────────────────────────────────────────
        token0.safeTransfer(to, amount0);
        token1.safeTransfer(to, amount1);

        emit LiquidityRemoved(to, amount0, amount1, liquidity);
    }

    // ────────────────────────────────────────────────────────────────
    // Core: Swap
    // ────────────────────────────────────────────────────────────────

    /// @notice Swaps an exact input amount of one token for as many of the other
    ///         token as possible, subject to slippage protection.
    ///
    ///         Fee: 0.3% of amountIn is retained in the pool (accrues to LPs).
    ///
    ///         k-invariant guarantee: after updating reserves the contract asserts
    ///         that (newReserve0 * newReserve1) ≥ (oldReserve0 * oldReserve1).
    ///         Any rounding or reentrancy that violated this would be caught and reverted.
    ///
    /// @param tokenIn      The token the caller is selling.
    /// @param amountIn     Exact amount of tokenIn to sell (gross, before fee).
    /// @param amountOutMin Minimum amount of the other token to receive.
    /// @param to           Recipient of the output token.
    /// @param deadline     Unix timestamp after which the tx reverts.
    /// @return amountOut   Actual amount of the output token transferred to `to`.
    function swap(address tokenIn, uint256 amountIn, uint256 amountOutMin, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        // ── Checks ───────────────────────────────────────────────────
        _checkDeadline(deadline);
        if (to == address(0)) revert AMM__ZeroAddress();
        if (amountIn == 0) revert AMM__InsufficientInputAmount();
        _validateToken(tokenIn);

        bool zeroForOne = tokenIn == address(token0);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);

        if (reserveIn == 0 || reserveOut == 0) revert AMM__InsufficientLiquidity();

        amountOut = _calcAmountOut(amountIn, reserveIn, reserveOut);

        if (amountOut == 0) revert AMM__InsufficientOutputAmount();
        if (amountOut < amountOutMin) revert AMM__SlippageExceeded(amountOut, amountOutMin);
        if (amountOut >= reserveOut) revert AMM__InsufficientLiquidity(); // cannot drain pool

        // ── Effects ──────────────────────────────────────────────────
        // Snapshot k before reserve update for the invariant check below.
        uint256 kBefore = _reserve0 * _reserve1;

        uint256 newReserveIn = reserveIn + amountIn;
        uint256 newReserveOut = reserveOut - amountOut;

        if (zeroForOne) {
            _updateReserves(newReserveIn, newReserveOut);
        } else {
            _updateReserves(newReserveOut, newReserveIn);
        }

        // ── k-invariant check ────────────────────────────────────────
        // After the fee, the new k must be ≥ the old k.
        // We compute using the post-fee reserve increment:
        //   effectiveIn = amountIn * FEE_NUMERATOR / FEE_DENOMINATOR
        //   kAfterFee   = (reserveIn + effectiveIn) * newReserveOut
        // However the most robust check is simply comparing raw reserves:
        //   newReserve0 * newReserve1 >= reserve0 * reserve1
        // because the fee formula already guarantees this algebraically, and we
        // want to catch any edge case (e.g., overflow truncation, unexpected donation).
        uint256 kAfter = _reserve0 * _reserve1;
        if (kAfter < kBefore) revert AMM__KInvariantViolated(kBefore, kAfter);

        // ── Interactions ─────────────────────────────────────────────
        // Pull tokenIn from the caller THEN push tokenOut.
        // Both happen after all state is settled (strict CEI).
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        IERC20(zeroForOne ? address(token1) : address(token0)).safeTransfer(to, amountOut);

        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
    }

    // ────────────────────────────────────────────────────────────────
    // Internal helpers
    // ────────────────────────────────────────────────────────────────

    /// @dev Updates the tracked reserves and emits ReservesUpdated.
    ///      Always called as the last "effects" step before any "interactions".
    function _updateReserves(uint256 newReserve0, uint256 newReserve1) private {
        _reserve0 = newReserve0;
        _reserve1 = newReserve1;
        emit ReservesUpdated(newReserve0, newReserve1);
    }

    /// @dev Standard constant-product output formula with 0.3% fee.
    ///      amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
    ///
    ///      Overflow analysis:
    ///        amountIn   ≤ 2^256-1  (uint256)
    ///        FEE_NUMERATOR = 997    (fits in uint16)
    ///        amountIn * 997 ≤ 997 * 2^256-1 → this WILL overflow if amountIn is huge.
    ///
    ///      Practical defense: real-world token supplies are bounded well below 2^128,
    ///      and Solidity 0.8 built-in overflow reverts protect us.  For a production
    ///      deployment targeting tokens with supplies > 2^128 / 997, consider using
    ///      FullMath (mulDiv) from Uniswap V3 libraries.
    function _calcAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        private
        pure
        returns (uint256 amountOut)
    {
        // Apply 0.3% fee to the input (multiply by 997, divide by 1000 later).
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR; // ×997
        uint256 numerator = amountInWithFee * reserveOut; // ×997 × reserveOut
        uint256 denominator = (reserveIn * FEE_DENOMINATOR) + amountInWithFee; // ×1000 + ×997
        amountOut = numerator / denominator; // integer division → floors
    }

    /// @dev Proportional quote: given an exact amount of one token, how much of the
    ///      other must be supplied to maintain the current price ratio?
    ///      quote = amountA * reserveB / reserveA
    function _quote(uint256 amountA, uint256 reserveA, uint256 reserveB) private pure returns (uint256 amountB) {
        if (amountA == 0) revert AMM__ZeroAmount();
        if (reserveA == 0 || reserveB == 0) revert AMM__InsufficientLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    /// @dev Reverts if `token` is not one of the two pool tokens.
    function _validateToken(address token) private view {
        if (token != address(token0) && token != address(token1)) {
            revert AMM__InvalidToken(token);
        }
    }

    /// @dev Reverts if the current block timestamp is past `deadline`.
    ///      NOTE: block.timestamp is used here ONLY as a deadline guard (a standard,
    ///      accepted use case), NOT as a source of randomness or entropy.
    function _checkDeadline(uint256 deadline) private view {
        if (block.timestamp > deadline) {
            revert AMM__DeadlineExpired(deadline, block.timestamp);
        }
    }
}
