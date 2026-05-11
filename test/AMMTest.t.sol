// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ConstantProductAMM} from "../src/AMM.sol";

// ═══════════════════════════════════════════════════════════════════
// MOCK ERC-20  — minimal token used across all AMM tests
// ═══════════════════════════════════════════════════════════════════

/// @dev Bare-bones ERC-20 with a public mint.  Only used in tests.
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) { return _dec; }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ═══════════════════════════════════════════════════════════════════
// BASE FIXTURE
// ═══════════════════════════════════════════════════════════════════

/// @dev Shared state and helpers for every AMM test contract.
abstract contract AMMTestBase is Test {
    // ── Actors ───────────────────────────────────────────────────────
    address internal constant LP      = address(0xAA01);
    address internal constant TRADER  = address(0xAA02);
    address internal constant LP2     = address(0xAA03);

    // ── Tokens (sorted so tokenA < tokenB ensures token0/token1 ordering) ──
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    // ── System under test ────────────────────────────────────────────
    ConstantProductAMM internal amm;

    // ── Convenience references (set after sort) ───────────────────────
    MockERC20 internal tok0; // amm.token0()
    MockERC20 internal tok1; // amm.token1()

    // ── Seed amounts ────────────────────────────────────────────────
    uint256 internal constant INITIAL_0   = 100_000e18;
    uint256 internal constant INITIAL_1   = 200_000e18;  // 1:2 price ratio
    uint256 internal constant TRADER_BAL  = 10_000e18;

    function setUp() public virtual {
        // Deploy two tokens and sort them so test helpers know which is token0.
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        // Deploy AMM — tokens sorted inside constructor.
        amm = new ConstantProductAMM(address(tokenA), address(tokenB));

        // Resolve sort order.
        tok0 = MockERC20(address(amm.token0()));
        tok1 = MockERC20(address(amm.token1()));

        // Fund LP and TRADER.
        tok0.mint(LP,     INITIAL_0 * 10);
        tok1.mint(LP,     INITIAL_1 * 10);
        tok0.mint(LP2,    INITIAL_0 * 10);
        tok1.mint(LP2,    INITIAL_1 * 10);
        tok0.mint(TRADER, TRADER_BAL);
        tok1.mint(TRADER, TRADER_BAL);
    }

    // ─── Helper: approve + addLiquidity from `who` ───────────────────
    function _addLiquidity(
        address who,
        uint256 amt0,
        uint256 amt1
    ) internal returns (uint256 a0, uint256 a1, uint256 lp) {
        vm.startPrank(who);
        tok0.approve(address(amm), amt0);
        tok1.approve(address(amm), amt1);
        (a0, a1, lp) = amm.addLiquidity(
            amt0, amt1,
            0, 0,          // no slippage protection for setup helpers
            who,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    // ─── Helper: seed pool with canonical initial liquidity ──────────
    function _seedPool() internal returns (uint256 lp) {
        (,, lp) = _addLiquidity(LP, INITIAL_0, INITIAL_1);
    }

    // ─── Helper: approve + swap ───────────────────────────────────────
    function _swap(
        address who,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut
    ) internal returns (uint256 amountOut) {
        vm.startPrank(who);
        MockERC20(tokenIn).approve(address(amm), amountIn);
        amountOut = amm.swap(
            tokenIn,
            amountIn,
            minOut,
            who,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    // ─── Helper: compute expected amountOut using the 0.3% formula ───
    function _expectedOut(
        uint256 amountIn,
        uint256 rIn,
        uint256 rOut
    ) internal pure returns (uint256) {
        uint256 withFee = amountIn * 997;
        return (withFee * rOut) / (rIn * 1000 + withFee);
    }

    // ─── Helper: read both reserves ──────────────────────────────────
    function _reserves() internal view returns (uint256 r0, uint256 r1) {
        (r0, r1) = amm.getReserves();
    }
}

// ═══════════════════════════════════════════════════════════════════
// 1.  CONSTRUCTOR & DEPLOYMENT
// ═══════════════════════════════════════════════════════════════════

contract AMM_Constructor_Test is AMMTestBase {

    function test_constructor_tokensAreSorted() public view {
        // token0 must have the lower address.
        assertTrue(address(amm.token0()) < address(amm.token1()),
            "token0 should be the lower-address token");
    }

    function test_constructor_lpTokenMetadata() public view {
        assertEq(amm.name(),   "DeFiApp LP Token");
        assertEq(amm.symbol(), "DLPT");
    }

    function test_constructor_initialReservesAreZero() public view {
        (uint256 r0, uint256 r1) = amm.getReserves();
        assertEq(r0, 0);
        assertEq(r1, 0);
    }

    function test_constructor_revert_zeroAddressTokenA() public {
        vm.expectRevert(ConstantProductAMM.AMM__ZeroAddress.selector);
        new ConstantProductAMM(address(0), address(tokenB));
    }

    function test_constructor_revert_zeroAddressTokenB() public {
        vm.expectRevert(ConstantProductAMM.AMM__ZeroAddress.selector);
        new ConstantProductAMM(address(tokenA), address(0));
    }

    function test_constructor_revert_identicalTokens() public {
        vm.expectRevert(ConstantProductAMM.AMM__IdenticalTokens.selector);
        new ConstantProductAMM(address(tokenA), address(tokenA));
    }
}

// ═══════════════════════════════════════════════════════════════════
// 2.  ADD LIQUIDITY
// ═══════════════════════════════════════════════════════════════════

contract AMM_AddLiquidity_Test is AMMTestBase {

    // ── Initial deposit ───────────────────────────────────────────────

    function test_addLiquidity_firstDeposit_mintsLpTokens() public {
        (uint256 a0, uint256 a1, uint256 lp) = _addLiquidity(LP, INITIAL_0, INITIAL_1);

        // LP tokens minted = sqrt(INITIAL_0 * INITIAL_1) - MINIMUM_LIQUIDITY
        uint256 expectedLp = _sqrt(INITIAL_0 * INITIAL_1) - amm.MINIMUM_LIQUIDITY();
        assertEq(lp, expectedLp, "initial lp minted mismatch");
        assertEq(amm.balanceOf(LP), lp, "lp balance mismatch");

        // Deposited amounts should equal desired amounts for first deposit.
        assertEq(a0, INITIAL_0);
        assertEq(a1, INITIAL_1);
    }

    function test_addLiquidity_firstDeposit_locksMinimumLiquidity() public {
        _addLiquidity(LP, INITIAL_0, INITIAL_1);
        // address(1) must hold exactly MINIMUM_LIQUIDITY permanently.
        assertEq(amm.balanceOf(address(1)), amm.MINIMUM_LIQUIDITY());
    }

    function test_addLiquidity_firstDeposit_updatesReserves() public {
        _addLiquidity(LP, INITIAL_0, INITIAL_1);
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, INITIAL_0);
        assertEq(r1, INITIAL_1);
    }

    function test_addLiquidity_firstDeposit_emitsEvent() public {
        vm.startPrank(LP);
        tok0.approve(address(amm), INITIAL_0);
        tok1.approve(address(amm), INITIAL_1);

        vm.expectEmit(true, false, false, false, address(amm));
        emit ConstantProductAMM.LiquidityAdded(LP, INITIAL_0, INITIAL_1, 0);

        amm.addLiquidity(INITIAL_0, INITIAL_1, 0, 0, LP, block.timestamp + 1);
        vm.stopPrank();
    }

    // ── Subsequent deposits ───────────────────────────────────────────

    function test_addLiquidity_subsequentDeposit_maintainsRatio() public {
        _seedPool();

        // LP2 wants to deposit INITIAL_0 of token0 — the AMM should require
        // proportionally INITIAL_1 of token1 (same 1:2 ratio).
        (uint256 a0, uint256 a1,) = _addLiquidity(LP2, INITIAL_0, INITIAL_1 * 2);

        // Both amounts should be consumed at the ratio exactly.
        assertEq(a0, INITIAL_0,     "token0 deposit should equal desired");
        assertEq(a1, INITIAL_1,     "token1 deposit should be proportional");
    }

    function test_addLiquidity_subsequentDeposit_lpSharesProportional() public {
        _seedPool();
        uint256 totalBefore = amm.totalSupply();

        (, , uint256 lp2) = _addLiquidity(LP2, INITIAL_0, INITIAL_1);

        // LP2's share should equal LP's share (same deposit in same ratio).
        // totalSupply includes minimum_liquidity, so LP2 share = lp2 / (totalBefore + lp2).
        uint256 totalAfter = amm.totalSupply();
        // LP2 should receive exactly lp2 tokens equal to the proportional amount.
        assertApproxEqAbs(
            lp2 * 1e18 / totalAfter,
            (totalBefore - amm.MINIMUM_LIQUIDITY()) * 1e18 / totalAfter,
            1e12,   // dust tolerance for integer rounding
            "LP shares should be proportional"
        );
    }

    function test_addLiquidity_subsequentDeposit_token1Scarce() public {
        _seedPool();
        // Provide excess token0 but constrained token1 — should use token1 as the scarce side.
        uint256 excessToken0 = INITIAL_0 * 3;
        uint256 constrainedToken1 = INITIAL_1 / 2;  // only half the token1 required

        (uint256 a0, uint256 a1,) = _addLiquidity(LP2, excessToken0, constrainedToken1);

        // The AMM should have used only constrainedToken1 and proportional token0.
        assertEq(a1, constrainedToken1, "should deposit all of token1");
        // Proportional token0 = constrainedToken1 * r0 / r1 = half of INITIAL_0
        assertApproxEqAbs(a0, INITIAL_0 / 2, 1, "token0 should be proportional");
    }

    // ── Revert paths ──────────────────────────────────────────────────

    /// @dev REVERT PATH 1: expired deadline
    function test_addLiquidity_revert_deadlineExpired() public {
        vm.warp(1000);
        vm.prank(LP);
        tok0.approve(address(amm), INITIAL_0);
        tok1.approve(address(amm), INITIAL_1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ConstantProductAMM.AMM__DeadlineExpired.selector,
                999,        // deadline in the past
                1000        // current timestamp
            )
        );
        vm.prank(LP);
        amm.addLiquidity(INITIAL_0, INITIAL_1, 0, 0, LP, 999);
    }

    /// @dev REVERT PATH 2: zero receiver address
    function test_addLiquidity_revert_zeroReceiver() public {
        vm.prank(LP);
        tok0.approve(address(amm), INITIAL_0);
        tok1.approve(address(amm), INITIAL_1);

        vm.expectRevert(ConstantProductAMM.AMM__ZeroAddress.selector);
        vm.prank(LP);
        amm.addLiquidity(INITIAL_0, INITIAL_1, 0, 0, address(0), block.timestamp + 1);
    }

    /// @dev REVERT PATH 3: zero amount0Desired
    function test_addLiquidity_revert_zeroAmount0() public {
        vm.expectRevert(ConstantProductAMM.AMM__ZeroAmount.selector);
        vm.prank(LP);
        amm.addLiquidity(0, INITIAL_1, 0, 0, LP, block.timestamp + 1);
    }

    /// @dev REVERT PATH 4: zero amount1Desired
    function test_addLiquidity_revert_zeroAmount1() public {
        vm.expectRevert(ConstantProductAMM.AMM__ZeroAmount.selector);
        vm.prank(LP);
        amm.addLiquidity(INITIAL_0, 0, 0, 0, LP, block.timestamp + 1);
    }

    /// @dev REVERT PATH 5: slippage on token1 exceeded
    function test_addLiquidity_revert_slippageToken1() public {
        _seedPool();

        // Pool ratio is 1:2 — depositing INITIAL_0 token0 needs INITIAL_1 token1.
        // Set amount1Min higher than the optimal amount to trigger slippage revert.
        uint256 tooHighMin1 = INITIAL_1 + 1;

        vm.startPrank(LP2);
        tok0.approve(address(amm), INITIAL_0);
        tok1.approve(address(amm), INITIAL_1 * 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                ConstantProductAMM.AMM__SlippageExceeded.selector,
                INITIAL_1,      // optimal amount1
                tooHighMin1     // min required
            )
        );
        amm.addLiquidity(INITIAL_0, INITIAL_1 * 2, 0, tooHighMin1, LP2, block.timestamp + 1);
        vm.stopPrank();
    }

    /// @dev REVERT PATH 6: dust deposit produces zero LP tokens after first deposit
    function test_addLiquidity_revert_insufficientLiquidityMinted_dustDeposit() public {
        // Deposit so small that sqrt(a*b) <= MINIMUM_LIQUIDITY.
        // sqrt(1 * 1) = 1 <= 1000 → revert.
        tok0.mint(LP, 1);
        tok1.mint(LP, 1);
        vm.startPrank(LP);
        tok0.approve(address(amm), 1);
        tok1.approve(address(amm), 1);
        vm.expectRevert(ConstantProductAMM.AMM__InsufficientLiquidityMinted.selector);
        amm.addLiquidity(1, 1, 0, 0, LP, block.timestamp + 1);
        vm.stopPrank();
    }
}

// ═══════════════════════════════════════════════════════════════════
// 3.  REMOVE LIQUIDITY
// ═══════════════════════════════════════════════════════════════════

contract AMM_RemoveLiquidity_Test is AMMTestBase {

    uint256 internal lpBalance;

    function setUp() public override {
        super.setUp();
        (,, lpBalance) = _addLiquidity(LP, INITIAL_0, INITIAL_1);
    }

    function test_removeLiquidity_burnsLpAndReturnsTokens() public {
        uint256 tok0Before = tok0.balanceOf(LP);
        uint256 tok1Before = tok1.balanceOf(LP);

        vm.startPrank(LP);
        (uint256 a0, uint256 a1) = amm.removeLiquidity(
            lpBalance,
            0, 0,
            LP,
            block.timestamp + 1
        );
        vm.stopPrank();

        assertGt(a0, 0, "should return token0");
        assertGt(a1, 0, "should return token1");
        assertEq(tok0.balanceOf(LP), tok0Before + a0, "tok0 balance mismatch");
        assertEq(tok1.balanceOf(LP), tok1Before + a1, "tok1 balance mismatch");
        assertEq(amm.balanceOf(LP), 0, "LP tokens should be fully burned");
    }

    function test_removeLiquidity_proportionalWithdrawal() public {
        uint256 totalLp = amm.totalSupply();
        (uint256 r0, uint256 r1) = _reserves();

        uint256 halfLp = lpBalance / 2;
        uint256 exp0   = (halfLp * r0) / totalLp;
        uint256 exp1   = (halfLp * r1) / totalLp;

        vm.startPrank(LP);
        (uint256 a0, uint256 a1) = amm.removeLiquidity(halfLp, 0, 0, LP, block.timestamp + 1);
        vm.stopPrank();

        assertEq(a0, exp0, "token0 withdrawal not proportional");
        assertEq(a1, exp1, "token1 withdrawal not proportional");
    }

    function test_removeLiquidity_updatesReserves() public {
        (uint256 r0Before, uint256 r1Before) = _reserves();
        uint256 totalLp = amm.totalSupply();

        uint256 exp0 = (lpBalance * r0Before) / totalLp;
        uint256 exp1 = (lpBalance * r1Before) / totalLp;

        vm.startPrank(LP);
        amm.removeLiquidity(lpBalance, 0, 0, LP, block.timestamp + 1);
        vm.stopPrank();

        (uint256 r0After, uint256 r1After) = _reserves();
        assertEq(r0After, r0Before - exp0, "reserve0 not updated correctly");
        assertEq(r1After, r1Before - exp1, "reserve1 not updated correctly");
    }

    function test_removeLiquidity_emitsEvent() public {
        vm.startPrank(LP);
        vm.expectEmit(true, false, false, false, address(amm));
        emit ConstantProductAMM.LiquidityRemoved(LP, 0, 0, lpBalance);
        amm.removeLiquidity(lpBalance, 0, 0, LP, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_removeLiquidity_partialRemoval_lpRemainsProportional() public {
        uint256 totalBefore = amm.totalSupply();
        uint256 thirdLp     = lpBalance / 3;

        vm.startPrank(LP);
        amm.removeLiquidity(thirdLp, 0, 0, LP, block.timestamp + 1);
        vm.stopPrank();

        assertEq(amm.balanceOf(LP), lpBalance - thirdLp, "remaining LP balance wrong");
        assertEq(amm.totalSupply(), totalBefore - thirdLp, "total supply wrong");
    }

    // ── Revert paths ──────────────────────────────────────────────────

    /// @dev REVERT PATH 7: expired deadline on remove
    function test_removeLiquidity_revert_deadlineExpired() public {
        vm.warp(2000);
        vm.prank(LP);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConstantProductAMM.AMM__DeadlineExpired.selector,
                1999,
                2000
            )
        );
        amm.removeLiquidity(lpBalance, 0, 0, LP, 1999);
    }

    /// @dev REVERT PATH 8: zero receiver
    function test_removeLiquidity_revert_zeroReceiver() public {
        vm.prank(LP);
        vm.expectRevert(ConstantProductAMM.AMM__ZeroAddress.selector);
        amm.removeLiquidity(lpBalance, 0, 0, address(0), block.timestamp + 1);
    }

    /// @dev REVERT PATH 9: zero liquidity burned
    function test_removeLiquidity_revert_zeroLiquidity() public {
        vm.prank(LP);
        vm.expectRevert(ConstantProductAMM.AMM__ZeroAmount.selector);
        amm.removeLiquidity(0, 0, 0, LP, block.timestamp + 1);
    }

    /// @dev REVERT PATH 10: caller has insufficient LP balance
    function test_removeLiquidity_revert_insufficientLpBalance() public {
        vm.prank(TRADER); // TRADER holds no LP tokens
        vm.expectRevert(ConstantProductAMM.AMM__InsufficientLiquidity.selector);
        amm.removeLiquidity(1e18, 0, 0, TRADER, block.timestamp + 1);
    }

    /// @dev REVERT PATH 11: slippage on token0 exceeded during removal
    function test_removeLiquidity_revert_slippageToken0() public {
        uint256 totalLp = amm.totalSupply();
        (uint256 r0,)   = _reserves();
        uint256 expected0 = (lpBalance * r0) / totalLp;

        vm.prank(LP);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConstantProductAMM.AMM__SlippageExceeded.selector,
                expected0,
                expected0 + 1   // min set 1 wei above received
            )
        );
        amm.removeLiquidity(lpBalance, expected0 + 1, 0, LP, block.timestamp + 1);
    }
}

// ═══════════════════════════════════════════════════════════════════
// 4.  SWAP — UNIT TESTS
// ═══════════════════════════════════════════════════════════════════

contract AMM_Swap_Unit_Test is AMMTestBase {

    function setUp() public override {
        super.setUp();
        _seedPool(); // INITIAL_0 : INITIAL_1 = 100k : 200k
    }

    function test_swap_token0ForToken1_correctOutput() public {
        uint256 amountIn = 1_000e18;
        (uint256 r0, uint256 r1) = _reserves();
        uint256 expected = _expectedOut(amountIn, r0, r1);

        uint256 out = _swap(TRADER, address(tok0), amountIn, 0);

        assertEq(out, expected, "swap output mismatch");
    }

    function test_swap_token1ForToken0_correctOutput() public {
        uint256 amountIn = 2_000e18;
        (uint256 r0, uint256 r1) = _reserves();
        uint256 expected = _expectedOut(amountIn, r1, r0);

        uint256 out = _swap(TRADER, address(tok1), amountIn, 0);

        assertEq(out, expected, "reverse swap output mismatch");
    }

    function test_swap_transfersTokensCorrectly() public {
        uint256 amountIn = 500e18;
        uint256 traderTok0Before = tok0.balanceOf(TRADER);
        uint256 traderTok1Before = tok1.balanceOf(TRADER);

        uint256 out = _swap(TRADER, address(tok0), amountIn, 0);

        assertEq(tok0.balanceOf(TRADER), traderTok0Before - amountIn, "trader tok0 should decrease");
        assertEq(tok1.balanceOf(TRADER), traderTok1Before + out,      "trader tok1 should increase");
    }

    function test_swap_updatesReservesCorrectly() public {
        uint256 amountIn = 1_000e18;
        (uint256 r0Before, uint256 r1Before) = _reserves();
        uint256 out = _swap(TRADER, address(tok0), amountIn, 0);

        (uint256 r0After, uint256 r1After) = _reserves();
        assertEq(r0After, r0Before + amountIn, "reserve0 should increase by amountIn");
        assertEq(r1After, r1Before - out,       "reserve1 should decrease by amountOut");
    }

    function test_swap_kInvariantNonDecreasing() public {
        (uint256 r0Before, uint256 r1Before) = _reserves();
        uint256 kBefore = r0Before * r1Before;

        _swap(TRADER, address(tok0), 1_000e18, 0);

        (uint256 r0After, uint256 r1After) = _reserves();
        uint256 kAfter = r0After * r1After;

        assertGe(kAfter, kBefore, "k invariant decreased after swap");
    }

    function test_swap_feeAccruesToPool() public {
        // After a round-trip swap, LP token holders should be able to
        // extract more total value than was initially deposited.
        uint256 amountIn = 10_000e18;

        // LP checks token balances before.
        uint256 lpTok0Before = tok0.balanceOf(LP);
        uint256 lpTok1Before = tok1.balanceOf(LP);

        // TRADER swaps tok0 → tok1, then tok1 → tok0.
        uint256 out1 = _swap(TRADER, address(tok0), amountIn, 0);
        // Give TRADER the tok1 received, swap back.
        uint256 out2 = _swap(TRADER, address(tok1), out1, 0);

        // Round-trip should lose value for trader (fees captured by pool).
        assertLt(out2, amountIn, "trader should lose value on round-trip (fee captured)");

        // LP removes all liquidity and should receive more than they put in.
        uint256 lpBal = amm.balanceOf(LP);
        vm.startPrank(LP);
        amm.removeLiquidity(lpBal, 0, 0, LP, block.timestamp + 1);
        vm.stopPrank();

        uint256 lpTok0After = tok0.balanceOf(LP);
        uint256 lpTok1After = tok1.balanceOf(LP);

        // Total value extracted (at original price ratio 1:2) should be >= deposited.
        // We compare in tok0-equivalent units: total = tok0 + tok1/2
        uint256 valueBefore = lpTok0Before + lpTok1Before / 2;
        uint256 valueAfter  = lpTok0After  + lpTok1After  / 2;
        assertGe(valueAfter, valueBefore, "LP should accrue fees");
    }

    function test_swap_emitsEvent() public {
        uint256 amountIn = 500e18;

        vm.startPrank(TRADER);
        tok0.approve(address(amm), amountIn);

        vm.expectEmit(true, true, false, false, address(amm));
        emit ConstantProductAMM.Swap(TRADER, address(tok0), amountIn, 0);

        amm.swap(address(tok0), amountIn, 0, TRADER, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_swap_getAmountOut_matchesActualSwap() public {
        uint256 amountIn = 750e18;
        uint256 quoted   = amm.getAmountOut(address(tok0), amountIn);
        uint256 actual   = _swap(TRADER, address(tok0), amountIn, 0);
        assertEq(quoted, actual, "getAmountOut preview should match swap result");
    }

    // ── Revert paths ──────────────────────────────────────────────────

    /// @dev REVERT PATH 12: zero amountIn
    function test_swap_revert_zeroAmountIn() public {
        vm.prank(TRADER);
        vm.expectRevert(ConstantProductAMM.AMM__InsufficientInputAmount.selector);
        amm.swap(address(tok0), 0, 0, TRADER, block.timestamp + 1);
    }

    /// @dev REVERT PATH 13: invalid token address
    function test_swap_revert_invalidToken() public {
        address rogue = address(0xDEAD);
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(ConstantProductAMM.AMM__InvalidToken.selector, rogue)
        );
        amm.swap(rogue, 1e18, 0, TRADER, block.timestamp + 1);
    }

    /// @dev REVERT PATH 14: slippage threshold not met
    function test_swap_revert_slippageExceeded() public {
        uint256 amountIn   = 1_000e18;
        (uint256 r0, uint256 r1) = _reserves();
        uint256 expectedOut = _expectedOut(amountIn, r0, r1);

        vm.startPrank(TRADER);
        tok0.approve(address(amm), amountIn);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConstantProductAMM.AMM__SlippageExceeded.selector,
                expectedOut,
                expectedOut + 1
            )
        );
        amm.swap(address(tok0), amountIn, expectedOut + 1, TRADER, block.timestamp + 1);
        vm.stopPrank();
    }

    /// @dev REVERT PATH 15: deadline expired
    function test_swap_revert_deadlineExpired() public {
        vm.warp(5000);
        vm.startPrank(TRADER);
        tok0.approve(address(amm), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConstantProductAMM.AMM__DeadlineExpired.selector,
                4999,
                5000
            )
        );
        amm.swap(address(tok0), 1e18, 0, TRADER, 4999);
        vm.stopPrank();
    }

    /// @dev REVERT PATH 16: zero receiver address
    function test_swap_revert_zeroReceiver() public {
        vm.startPrank(TRADER);
        tok0.approve(address(amm), 1e18);
        vm.expectRevert(ConstantProductAMM.AMM__ZeroAddress.selector);
        amm.swap(address(tok0), 1e18, 0, address(0), block.timestamp + 1);
        vm.stopPrank();
    }

    /// @dev REVERT PATH 17: swap on empty pool (no liquidity)
    function test_swap_revert_emptyPool() public {
        ConstantProductAMM emptyAmm = new ConstantProductAMM(address(tok0), address(tok1));
        tok0.mint(TRADER, 1e18);
        vm.startPrank(TRADER);
        tok0.approve(address(emptyAmm), 1e18);
        vm.expectRevert(ConstantProductAMM.AMM__InsufficientLiquidity.selector);
        emptyAmm.swap(address(tok0), 1e18, 0, TRADER, block.timestamp + 1);
        vm.stopPrank();
    }
}

// ═══════════════════════════════════════════════════════════════════
// 5.  FUZZ TEST — SWAP
// ═══════════════════════════════════════════════════════════════════

contract AMM_Swap_Fuzz_Test is AMMTestBase {

    function setUp() public override {
        super.setUp();
        // Seed a large pool so most fuzz inputs are valid.
        tok0.mint(LP, type(uint128).max);
        tok1.mint(LP, type(uint128).max);
        _addLiquidity(LP, 1_000_000e18, 1_000_000e18);
    }

    /// @notice Property: for any valid amountIn in [1, reserveIn/2], the swap
    ///          succeeds, produces positive output, and the k-invariant is preserved.
    ///
    ///          We bound amountIn to reserveIn/2 to stay well clear of the
    ///          AMM__InsufficientLiquidity guard (amountOut >= reserveOut).
    function testFuzz_swap_kInvariantAndPositiveOutput(uint256 amountIn) public {
        // Использован безопасный bound вместо vm.bound
        amountIn = bound(amountIn, 1000, 1e24);
        (uint256 r0, uint256 r1) = _reserves();

        // Bound amountIn to [1, reserveIn/2] to guarantee a valid swap.
        amountIn = bound(amountIn, 1, r0 / 2);

        uint256 kBefore = r0 * r1;

        // Give TRADER enough tok0 and approve.
        tok0.mint(TRADER, amountIn);

        vm.startPrank(TRADER);
        tok0.approve(address(amm), amountIn);
        uint256 amountOut = amm.swap(
            address(tok0),
            amountIn,
            0,           // no slippage floor — testing math, not UX
            TRADER,
            block.timestamp + 1
        );
        vm.stopPrank();

        // Output must be strictly positive.
        assertGt(amountOut, 0, "fuzz: swap produced zero output");

        // k must be non-decreasing.
        (uint256 r0After, uint256 r1After) = _reserves();
        uint256 kAfter = r0After * r1After;
        assertGe(kAfter, kBefore, "fuzz: k decreased after swap");
    }

    /// @notice Property: swapping token1→token0 also preserves k and produces
    ///          positive output, proving symmetry of the formula.
    function testFuzz_swap_reverseDirection_kInvariant(uint256 amountIn) public {
        // Использован безопасный bound вместо vm.bound
        amountIn = bound(amountIn, 1000, 1e24);
        (uint256 r0, uint256 r1) = _reserves();
        amountIn = bound(amountIn, 1, r1 / 2);

        uint256 kBefore = r0 * r1;
        tok1.mint(TRADER, amountIn);

        vm.startPrank(TRADER);
        tok1.approve(address(amm), amountIn);
        uint256 amountOut = amm.swap(
            address(tok1),
            amountIn,
            0,
            TRADER,
            block.timestamp + 1
        );
        vm.stopPrank();

        assertGt(amountOut, 0, "fuzz reverse: zero output");

        (uint256 r0After, uint256 r1After) = _reserves();
        assertGe(r0After * r1After, kBefore, "fuzz reverse: k decreased");
    }

    /// @notice Property: getAmountOut() always equals the actual output of swap()
    ///          for the same amountIn (preview must match execution).
    function testFuzz_swap_previewMatchesExecution(uint256 amountIn) public {
        // Использован безопасный bound вместо vm.bound
        amountIn = bound(amountIn, 1000, 1e24);
        (uint256 r0,) = _reserves();
        amountIn = bound(amountIn, 1, r0 / 2);

        uint256 quoted = amm.getAmountOut(address(tok0), amountIn);

        tok0.mint(TRADER, amountIn);
        vm.startPrank(TRADER);
        tok0.approve(address(amm), amountIn);
        uint256 actual = amm.swap(address(tok0), amountIn, 0, TRADER, block.timestamp + 1);
        vm.stopPrank();

        assertEq(quoted, actual, "fuzz: preview != execution");
    }
}

// ═══════════════════════════════════════════════════════════════════
// 6.  GETAMOUNTOUT VIEW
// ═══════════════════════════════════════════════════════════════════

contract AMM_GetAmountOut_Test is AMMTestBase {

    function setUp() public override {
        super.setUp();
        _seedPool();
    }

    function test_getAmountOut_revert_zeroAmount() public {
        vm.expectRevert(ConstantProductAMM.AMM__ZeroAmount.selector);
        amm.getAmountOut(address(tok0), 0);
    }

    function test_getAmountOut_revert_invalidToken() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ConstantProductAMM.AMM__InvalidToken.selector,
                address(0xBEEF)
            )
        );
        amm.getAmountOut(address(0xBEEF), 1e18);
    }

    function test_getAmountOut_consistentWithFormula() public view {
        uint256 amountIn = 5_000e18;
        (uint256 r0, uint256 r1) = _reserves();
        uint256 expected = _expectedOut(amountIn, r0, r1);
        uint256 actual   = amm.getAmountOut(address(tok0), amountIn);
        assertEq(actual, expected);
    }
}

// ═══════════════════════════════════════════════════════════════════
// INTERNAL MATH HELPER
// ═══════════════════════════════════════════════════════════════════

/// @dev Babylonian integer square root (same as OZ Math.sqrt).
function _sqrt(uint256 x) pure returns (uint256 y) {
    if (x == 0) return 0;
    uint256 z = (x + 1) / 2;
    y = x;
    while (z < y) {
        y = z;
        z = (x / z + z) / 2;
    }
}
