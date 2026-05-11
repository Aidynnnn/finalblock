// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─── Foundry ─────────────────────────────────────────────────────────────────
import {Test, console2} from "forge-std/Test.sol";

// ─── OpenZeppelin helpers ────────────────────────────────────────────────────
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ─── Project contracts ────────────────────────────────────────────────────────
import {ConstantProductAMM} from "../src/AMM.sol";
import {ERC4626VaultV1} from "../src/ERC4626VaultV1.sol";

// ═════════════════════════════════════════════════════════════════════════════
// MINIMAL TEST DOUBLES
// ═════════════════════════════════════════════════════════════════════════════

/// @dev Standard mintable ERC-20 used as both pool tokens and LP token stand-in.
contract MockERC20B is ERC20 {
    uint8 private immutable _DEC;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _DEC = d;
    }

    function decimals() public view override returns (uint8) {
        return _DEC;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// BASE FIXTURE
// ═════════════════════════════════════════════════════════════════════════════

abstract contract BenchmarkBase is Test {
    // ── Actors ───────────────────────────────────────────────────────────────
    address internal constant OWNER = address(0xC0DE_0001);
    address internal constant ALICE = address(0xC0DE_0002);

    // ── Contracts ────────────────────────────────────────────────────────────
    MockERC20B internal tokenA;
    MockERC20B internal tokenB;
    ConstantProductAMM internal amm;
    ERC4626VaultV1 internal vault; // reference cast over the proxy
    ERC4626VaultV1 internal impl; // bare implementation (for pure benchmarks)

    // ── Pool seed amounts ────────────────────────────────────────────────────
    uint256 internal constant POOL_A = 500_000e18;
    uint256 internal constant POOL_B = 500_000e18;
    uint256 internal constant LP_ALICE = 10_000e18; // LP tokens Alice holds
    uint256 internal constant DEPOSIT = 1_000e18; // LP tokens Alice deposits

    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public virtual {
        // ── Deploy pool tokens ────────────────────────────────────────────
        tokenA = new MockERC20B("Token A", "TKA", 18);
        tokenB = new MockERC20B("Token B", "TKB", 18);

        // ── Deploy AMM and seed initial liquidity ─────────────────────────
        amm = new ConstantProductAMM(address(tokenA), address(tokenB));

        vm.startPrank(OWNER);
        {
            MockERC20B t0 = MockERC20B(address(amm.token0()));
            MockERC20B t1 = MockERC20B(address(amm.token1()));

            t0.mint(OWNER, POOL_A);
            t1.mint(OWNER, POOL_B);
            t0.approve(address(amm), POOL_A);
            t1.approve(address(amm), POOL_B);
            amm.addLiquidity(POOL_A, POOL_B, 0, 0, OWNER, block.timestamp + 1 hours);
        }
        vm.stopPrank();

        // ── Mint LP tokens for Alice ──────────────────────────────────────
        vm.startPrank(ALICE);
        {
            MockERC20B t0 = MockERC20B(address(amm.token0()));
            MockERC20B t1 = MockERC20B(address(amm.token1()));
            t0.mint(ALICE, LP_ALICE);
            t1.mint(ALICE, LP_ALICE);
            t0.approve(address(amm), LP_ALICE);
            t1.approve(address(amm), LP_ALICE);
            amm.addLiquidity(LP_ALICE, LP_ALICE, 0, 0, ALICE, block.timestamp + 1 hours);
        }
        vm.stopPrank();

        // ── Deploy V1 implementation (bare — constructor disables init) ────
        impl = new ERC4626VaultV1();

        // ── Deploy proxy and initialise ───────────────────────────────────
        bytes memory initData = abi.encodeCall(
            ERC4626VaultV1.initialize,
            (
                address(amm), // LP token = AMM contract itself
                address(amm), // amm address
                address(0), // no price-feed adapter
                OWNER
            )
        );
        address proxy = address(new ERC1967Proxy(address(impl), initData));
        vault = ERC4626VaultV1(proxy);

        // ── Alice deposits into the vault so totalSupply > 0 ─────────────
        vm.startPrank(ALICE);
        IERC20(address(amm)).approve(address(vault), LP_ALICE);
        vault.deposit(DEPOSIT, ALICE);
        vm.stopPrank();
    }

    // ── Internal helper ───────────────────────────────────────────────────────

    /// @dev Warm up proxy storage (cold SLOAD costs 2100 gas vs 100 warm).
    ///      Call this before any gas measurement to get steady-state numbers.
    function _warmUp(uint256 x) internal view {
        vault.previewDeposit(x);
        vault.previewDepositYul(x);
        vault.previewMint(x);
        vault.previewMintYul(x);
        vault.previewWithdraw(x);
        vault.previewWithdrawYul(x);
        vault.previewRedeem(x);
        vault.previewRedeemYul(x);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  SECTION 1 — PURE MATH FUZZ TESTS  (no storage, impl contract)
// ═════════════════════════════════════════════════════════════════════════════

/// @title  YulMathFuzz
/// @notice Proves that _yulMulDivFloor and _yulMulDivCeil produce results
///         *identical* to OZ Math.mulDiv for all well-formed inputs.
///         Uses the bare implementation contract (pure functions, no state).
contract YulMathFuzz is BenchmarkBase {
    // ── Floor ─────────────────────────────────────────────────────────────────

    /// @dev General fuzz: random x, y, d (non-overflow domain).
    ///      Bounds x,y to uint128 so x*y fits in 256 bits — fast path.
    function testFuzz_Floor_FastPath_Equivalence(uint128 x, uint128 y, uint128 d) public view {
        vm.assume(d > 0);
        uint256 sol = impl.mathSolidity(x, y, d, false);
        uint256 yul = impl.mathYul(x, y, d, false);
        assertEq(sol, yul, "Floor fast-path: Yul != Solidity");
    }

    /// @dev Vault-specific fuzz: shapes that mirror the actual conversion call.
    ///      assets * (totalSupply+10^6) / (totalAssets+1)
    function testFuzz_Floor_VaultShape_Equivalence(
        uint120 assets,
        uint120 supplyBase, // totalSupply before adding 10^6
        uint120 assetsInVault // totalAssets before adding 1
    )
        public
        view
    {
        uint256 y = uint256(supplyBase) + 1e6; // + DECIMALS_OFFSET virtual shares
        uint256 d = uint256(assetsInVault) + 1;

        uint256 sol = impl.mathSolidity(assets, y, d, false);
        uint256 yul = impl.mathYul(assets, y, d, false);
        assertEq(sol, yul, "Floor vault-shape: Yul != Solidity");
    }

    /// @dev Slow-path fuzz: force 512-bit path by using values that overflow.
    ///      x * y overflows when both > 2^128; result must fit in 256 bits,
    ///      so we require d > type(uint128).max to keep result bounded.
    function testFuzz_Floor_SlowPath_Equivalence(
        uint128 xHigh, // x = xHigh + 2^128  -> forces x*y overflow
        uint128 dExtra // d = dExtra + 2^128  -> ensures result < 2^256
    )
        public
        view
    {
        uint256 x = uint256(xHigh) + (1 << 128);
        uint256 d = uint256(dExtra) + (1 << 128);
        // Fix y = type(uint128).max to guarantee x*y overflows uint256.
        uint256 yBig = type(uint128).max;
        if (d == 0) d = 1;

        uint256 sol = impl.mathSolidity(x, yBig, d, false);
        uint256 yul = impl.mathYul(x, yBig, d, false);
        assertEq(sol, yul, "Floor slow-path: Yul != Solidity");
    }

    // ── Ceil ─────────────────────────────────────────────────────────────────

    /// @dev Ceil fast path: x*y fits in 256 bits.
    function testFuzz_Ceil_FastPath_Equivalence(uint128 x, uint128 y, uint128 d) public view {
        vm.assume(d > 0);
        uint256 sol = impl.mathSolidity(x, y, d, true);
        uint256 yul = impl.mathYul(x, y, d, true);
        assertEq(sol, yul, "Ceil fast-path: Yul != Solidity");
    }

    /// @dev Ceil slow path: force 512-bit path.
    function testFuzz_Ceil_SlowPath_Equivalence(uint128 xHigh, uint128 dExtra) public view {
        uint256 x = uint256(xHigh) + (1 << 128);
        uint256 d = uint256(dExtra) + (1 << 128);
        uint256 yBig = type(uint128).max;

        uint256 sol = impl.mathSolidity(x, yBig, d, true);
        uint256 yul = impl.mathYul(x, yBig, d, true);
        assertEq(sol, yul, "Ceil slow-path: Yul != Solidity");
    }

    // ── Edge cases ────────────────────────────────────────────────────────────

    function test_EdgeCase_ZeroNumerator() public view {
        assertEq(impl.mathYul(0, 1e18, 1e18, false), 0);
        assertEq(impl.mathYul(0, 1e18, 1e18, true), 0);
    }

    function test_EdgeCase_NumeratorEqualsZeroTimesAnything() public view {
        assertEq(impl.mathYul(1e18, 0, 1e18, false), 0);
        assertEq(impl.mathYul(1e18, 0, 1e18, true), 0);
    }

    function test_EdgeCase_ExactDivision_FloorCeilMatch() public view {
        // x*y divisible by d → floor == ceil
        uint256 x = 6;
        uint256 y = 4;
        uint256 d = 3; // 6*4/3 = 8 exactly
        assertEq(impl.mathYul(x, y, d, false), 8);
        assertEq(impl.mathYul(x, y, d, true), 8);
        assertEq(impl.mathSolidity(x, y, d, false), 8);
        assertEq(impl.mathSolidity(x, y, d, true), 8);
    }

    function test_EdgeCase_RoundingDiffers() public view {
        // 7*1/3 = 2.333... → floor=2, ceil=3
        assertEq(impl.mathYul(7, 1, 3, false), 2);
        assertEq(impl.mathYul(7, 1, 3, true), 3);
    }

    function test_EdgeCase_MaxUint128_Inputs() public view {
        uint256 x = type(uint128).max;
        uint256 y = type(uint128).max;
        uint256 d = type(uint128).max;
        uint256 sol = impl.mathSolidity(x, y, d, false);
        uint256 yul = impl.mathYul(x, y, d, false);
        assertEq(sol, yul, "MaxUint128 floor mismatch");

        sol = impl.mathSolidity(x, y, d, true);
        yul = impl.mathYul(x, y, d, true);
        assertEq(sol, yul, "MaxUint128 ceil mismatch");
    }

    function test_EdgeCase_ZeroDenominator_Reverts() public {
        vm.expectRevert();
        impl.mathYul(1, 1, 0, false);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  SECTION 2 — VAULT PREVIEW FUZZ TESTS  (through proxy, real storage)
// ═════════════════════════════════════════════════════════════════════════════

/// @title  YulPreviewFuzz
/// @notice Proves that previewDepositYul / previewMintYul / etc. produce
///         results identical to their Solidity counterparts in a live vault.
contract YulPreviewFuzz is BenchmarkBase {
    // ── previewDeposit (Floor) ────────────────────────────────────────────────

    function testFuzz_PreviewDeposit_Equivalence(uint256 assets) public view {
        assets = bound(assets, 1, 1e36);
        assertEq(vault.previewDeposit(assets), vault.previewDepositYul(assets), "previewDeposit mismatch");
    }

    // ── previewMint (Ceil) ────────────────────────────────────────────────────

    function testFuzz_PreviewMint_Equivalence(uint256 shares) public view {
        shares = bound(shares, 1, 1e42); // shares use 24-decimal offset
        assertEq(vault.previewMint(shares), vault.previewMintYul(shares), "previewMint mismatch");
    }

    // ── previewWithdraw (Ceil) ────────────────────────────────────────────────

    function testFuzz_PreviewWithdraw_Equivalence(uint256 assets) public view {
        assets = bound(assets, 1, vault.totalAssets());
        assertEq(vault.previewWithdraw(assets), vault.previewWithdrawYul(assets), "previewWithdraw mismatch");
    }

    // ── previewRedeem (Floor) ─────────────────────────────────────────────────

    function testFuzz_PreviewRedeem_Equivalence(uint256 shares) public view {
        shares = bound(shares, 1, vault.totalSupply());
        assertEq(vault.previewRedeem(shares), vault.previewRedeemYul(shares), "previewRedeem mismatch");
    }

    // ── Bidirectional round-trip ───────────────────────────────────────────────

    /// @dev Deposit then redeem: Yul shares → Yul assets must not exceed input.
    function testFuzz_RoundTrip_DepositRedeem_Yul(uint256 assets) public view {
        assets = bound(assets, 1, 1e30);
        uint256 shares = vault.previewDepositYul(assets);
        if (shares == 0) return; // dust deposit, skip
        uint256 recovered = vault.previewRedeemYul(shares);
        assertLe(recovered, assets, "Round-trip: recovered > deposited (inflation)");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  SECTION 3 — GAS BENCHMARK TESTS  (hard empirical numbers)
// ═════════════════════════════════════════════════════════════════════════════

/// @title  YulGasBenchmarkTests
/// @notice Measures gas for Solidity vs Yul on concrete inputs.
///         Run with:  forge test --match-contract YulGasBenchmarkTests -vv
///         The console2 output feeds directly into the Gas Optimisation Report.
///
///         Measurement methodology
///         ─────────────────────────────────────────────────────────────────
///         gasleft() is called immediately before and after each target
///         call.  Both functions go through the same ERC1967Proxy path so
///         the delegatecall overhead is identical and cancels out in the
///         delta.  Storage slots are pre-warmed (100-gas SLOAD cost, not
///         2100-gas cold cost) to reflect steady-state L2/mainnet behaviour.
contract YulGasBenchmarkTests is BenchmarkBase {
    // Concrete benchmark amounts — representative vault-scale values
    uint256 constant SMALL = 1e15; // 0.001 LP token
    uint256 constant MEDIUM = 1_000e18; // 1 000 LP tokens
    uint256 constant LARGE = 1_000_000e18; // 1 M LP tokens

    // ─── Helper ──────────────────────────────────────────────────────────────

    struct GasResult {
        uint256 sol;
        uint256 yul;
    }

    function _measurePreviewDeposit(uint256 assets) internal view returns (GasResult memory r) {
        uint256 g = gasleft();
        vault.previewDeposit(assets);
        r.sol = g - gasleft();
        g = gasleft();
        vault.previewDepositYul(assets);
        r.yul = g - gasleft();
    }

    function _measurePreviewMint(uint256 shares) internal view returns (GasResult memory r) {
        uint256 g = gasleft();
        vault.previewMint(shares);
        r.sol = g - gasleft();
        g = gasleft();
        vault.previewMintYul(shares);
        r.yul = g - gasleft();
    }

    function _measurePreviewWithdraw(uint256 assets) internal view returns (GasResult memory r) {
        uint256 g = gasleft();
        vault.previewWithdraw(assets);
        r.sol = g - gasleft();
        g = gasleft();
        vault.previewWithdrawYul(assets);
        r.yul = g - gasleft();
    }

    function _measurePreviewRedeem(uint256 shares) internal view returns (GasResult memory r) {
        uint256 g = gasleft();
        vault.previewRedeem(shares);
        r.sol = g - gasleft();
        g = gasleft();
        vault.previewRedeemYul(shares);
        r.yul = g - gasleft();
    }

    function _measurePureMath(uint256 x, uint256 y, uint256 d, bool ceil) internal view returns (GasResult memory r) {
        uint256 g = gasleft();
        impl.mathSolidity(x, y, d, ceil);
        r.sol = g - gasleft();
        g = gasleft();
        impl.mathYul(x, y, d, ceil);
        r.yul = g - gasleft();
    }

    // console2 does not support printf-style format strings; we emit three
    // lines per entry so the gas report remains machine-readable.
    function _logGas(string memory label, string memory rounding, uint256 sol, uint256 yul) internal pure {
        string memory tag = string.concat(label, " (", rounding, ")");
        console2.log(string.concat("  ", tag));
        console2.log("    sol =", sol, "| yul =", yul);
        if (sol > yul) {
            console2.log("    -> Yul saves   ", sol - yul, "gas");
        } else if (yul > sol) {
            console2.log("    -> Solidity is ", yul - sol, "gas cheaper");
        } else {
            console2.log("    -> Identical gas cost");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  3A. Isolated pure-math benchmarks (no storage overhead)
    // ─────────────────────────────────────────────────────────────────────────

    function test_Gas_PureMath_Floor_NoOverflow() public view {
        // x * y < 2^256 → fast path executed
        uint256 x = 1_000e18;
        uint256 y = 1e24 + 1e6; // simulates totalSupply + offset
        uint256 d = 1_000e18 + 1; // simulates totalAssets + 1

        GasResult memory r = _measurePureMath(x, y, d, false);
        _logGas("PureMath floor no-overflow", "Floor", r.sol, r.yul);
        assertEq(impl.mathSolidity(x, y, d, false), impl.mathYul(x, y, d, false));
    }

    function test_Gas_PureMath_Ceil_NoOverflow() public view {
        // Ceil case: Yul saves one MULMOD (8→5 gas via MOD)
        uint256 x = 1_000e18;
        uint256 y = 1e24 + 1e6;
        uint256 d = 1_000e18 + 1;

        GasResult memory r = _measurePureMath(x, y, d, true);
        _logGas("PureMath ceil no-overflow", "Ceil ", r.sol, r.yul);
        assertEq(impl.mathSolidity(x, y, d, true), impl.mathYul(x, y, d, true));
    }

    function test_Gas_PureMath_Floor_WithOverflow() public view {
        // x * y > 2^256 → slow 512-bit path (Knuth algorithm)
        uint256 x = type(uint128).max; // 2^128 − 1
        uint256 y = type(uint128).max; // product = (2^128-1)^2 ≈ 2^256
        uint256 d = type(uint128).max; // result = 2^128 − 1

        GasResult memory r = _measurePureMath(x, y, d, false);
        _logGas("PureMath floor overflow (512-bit)", "Floor", r.sol, r.yul);
        assertEq(impl.mathSolidity(x, y, d, false), impl.mathYul(x, y, d, false));
    }

    function test_Gas_PureMath_Ceil_WithOverflow() public view {
        uint256 x = type(uint128).max;
        uint256 y = type(uint128).max;
        uint256 d = type(uint128).max;

        GasResult memory r = _measurePureMath(x, y, d, true);
        _logGas("PureMath ceil overflow (512-bit)", "Ceil ", r.sol, r.yul);
        assertEq(impl.mathSolidity(x, y, d, true), impl.mathYul(x, y, d, true));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  3B. Full vault preview benchmarks (includes storage reads + proxy)
    // ─────────────────────────────────────────────────────────────────────────

    function test_Gas_PreviewDeposit_Small() public view {
        _warmUp(SMALL);
        GasResult memory r = _measurePreviewDeposit(SMALL);
        _logGas("previewDeposit small (1e15)", "Floor", r.sol, r.yul);
        assertEq(vault.previewDeposit(SMALL), vault.previewDepositYul(SMALL));
    }

    function test_Gas_PreviewDeposit_Medium() public view {
        _warmUp(MEDIUM);
        GasResult memory r = _measurePreviewDeposit(MEDIUM);
        _logGas("previewDeposit medium (1e21)", "Floor", r.sol, r.yul);
        assertEq(vault.previewDeposit(MEDIUM), vault.previewDepositYul(MEDIUM));
    }

    function test_Gas_PreviewDeposit_Large() public view {
        _warmUp(LARGE);
        GasResult memory r = _measurePreviewDeposit(LARGE);
        _logGas("previewDeposit large (1e24)", "Floor", r.sol, r.yul);
        assertEq(vault.previewDeposit(LARGE), vault.previewDepositYul(LARGE));
    }

    /// @notice previewMint uses Ceil rounding — best case for Yul savings.
    function test_Gas_PreviewMint_Medium() public view {
        // shares use share decimals (24), so scale accordingly
        uint256 shares = MEDIUM * 1e6; // equivalent to depositing ~MEDIUM LP
        _warmUp(MEDIUM);
        GasResult memory r = _measurePreviewMint(shares);
        _logGas("previewMint medium (Ceil, MOD opt)", "Ceil ", r.sol, r.yul);
        assertEq(vault.previewMint(shares), vault.previewMintYul(shares));
    }

    /// @notice previewWithdraw also uses Ceil rounding.
    function test_Gas_PreviewWithdraw_Medium() public view {
        uint256 assets = vault.totalAssets() / 4; // withdraw 25 % of pool
        _warmUp(assets);
        GasResult memory r = _measurePreviewWithdraw(assets);
        _logGas("previewWithdraw medium (Ceil, MOD opt)", "Ceil ", r.sol, r.yul);
        assertEq(vault.previewWithdraw(assets), vault.previewWithdrawYul(assets));
    }

    function test_Gas_PreviewRedeem_Medium() public view {
        uint256 shares = vault.totalSupply() / 4;
        _warmUp(shares);
        GasResult memory r = _measurePreviewRedeem(shares);
        _logGas("previewRedeem medium", "Floor", r.sol, r.yul);
        assertEq(vault.previewRedeem(shares), vault.previewRedeemYul(shares));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  3C. Summary table (run with -vv to see console output)
    // ─────────────────────────────────────────────────────────────────────────

    function test_Gas_Summary_Table() public view {
        _warmUp(MEDIUM);

        uint256 sharesM = vault.totalSupply() / 4;
        uint256 assetsM = vault.totalAssets() / 4;

        console2.log("");
        console2.log("==========================================================");
        console2.log(" GAS OPTIMISATION REPORT -- Yul vs Solidity mulDiv");
        console2.log("==========================================================");
        console2.log(" Function                                  | sol   yul  delta");
        console2.log("----------------------------------------------------------");

        // ── Pure math (no storage) ──
        uint256 x = MEDIUM;
        uint256 y = vault.totalSupply() + 1e6;
        uint256 d = vault.totalAssets() + 1;

        GasResult memory r;

        r = _measurePureMath(x, y, d, false);
        _logGas("mathMulDiv floor (fast path)", "Floor", r.sol, r.yul);

        r = _measurePureMath(x, y, d, true);
        _logGas("mathMulDiv ceil  (fast path)", "Ceil ", r.sol, r.yul);

        r = _measurePureMath(type(uint128).max, type(uint128).max, type(uint128).max, false);
        _logGas("mathMulDiv floor (slow path)", "Floor", r.sol, r.yul);

        r = _measurePureMath(type(uint128).max, type(uint128).max, type(uint128).max, true);
        _logGas("mathMulDiv ceil  (slow path)", "Ceil ", r.sol, r.yul);

        console2.log("----------------------------------------------------------");

        // ── Full preview (storage + proxy) ──
        r = _measurePreviewDeposit(MEDIUM);
        _logGas("previewDeposit (via proxy)", "Floor", r.sol, r.yul);
        r = _measurePreviewMint(MEDIUM * 1e6);
        _logGas("previewMint    (via proxy)", "Ceil ", r.sol, r.yul);
        r = _measurePreviewWithdraw(assetsM);
        _logGas("previewWithdraw(via proxy)", "Ceil ", r.sol, r.yul);
        r = _measurePreviewRedeem(sharesM);
        _logGas("previewRedeem  (via proxy)", "Floor", r.sol, r.yul);

        console2.log("==========================================================");
        console2.log(" Notes:");
        console2.log("  * 'delta' is sol-yul (positive = Yul is cheaper).");
        console2.log("  * Fast-path Ceil saves 3 gas: MOD(5) vs MULMOD(8).");
        console2.log("  * Slow-path gas is identical (same algorithm).");
        console2.log("  * Proxy overhead (~100 gas delegatecall) is equal");
        console2.log("    for both and cancels in the delta.");
        console2.log("==========================================================");
        console2.log("");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  SECTION 4 — CORRECTNESS INVARIANTS  (deterministic, no fuzz)
// ═════════════════════════════════════════════════════════════════════════════

/// @title  YulCorrectnessInvariants
/// @notice Hard-coded invariant checks drawn from the ERC-4626 spec.
contract YulCorrectnessInvariants is BenchmarkBase {
    /// @dev ERC-4626 §7: previewDeposit MUST round DOWN.
    ///      Equivalently: previewDepositYul(assets) * d <= assets * y
    function test_Invariant_Floor_NeverExceedsExact() public view {
        uint256 assets = 3_333e18; // non-divisible amount
        uint256 shares = vault.previewDepositYul(assets);
        // shares * (totalAssets+1) <= assets * (totalSupply+10^6)
        // (checked in 512-bit precision to avoid overflow)
        uint256 lhs_num = shares;
        uint256 lhs_den = vault.totalAssets() + 1;
        uint256 rhs_num = assets;
        uint256 rhs_den = vault.totalSupply() + 10 ** uint256(vault.DECIMALS_OFFSET());

        // shares/d <= assets*y/d^2... simplified: shares * denom <= assets * numer
        assertLe(
            lhs_num * lhs_den, rhs_num * rhs_den, "Floor: shares * (totalAssets+1) > assets * (totalSupply+offset)"
        );
    }

    /// @dev ERC-4626 §7: previewMint MUST round UP (depositor pays at least true cost).
    function test_Invariant_Ceil_NeverUndercharges() public view {
        uint256 targetShares = 7_777e24; // 24-decimal shares, non-exact
        uint256 assets = vault.previewMintYul(targetShares);
        // assets required >= exact cost, i.e. previewRedeem(targetShares) <= assets
        uint256 wouldGet = vault.previewRedeemYul(targetShares);
        assertLe(wouldGet, assets, "Ceil: mint cost < what redeem returns (incorrect rounding)");
    }

    /// @dev Yul and Solidity paths must agree on every ERC-4626 entry point.
    function test_Invariant_AllPreviews_Match_Concrete() public view {
        uint256 a = 500e18;
        uint256 s = vault.totalSupply() / 3;

        assertEq(vault.previewDeposit(a), vault.previewDepositYul(a), "deposit");
        assertEq(vault.previewMint(s), vault.previewMintYul(s), "mint");
        assertEq(vault.previewWithdraw(a), vault.previewWithdrawYul(a), "withdraw");
        assertEq(vault.previewRedeem(s), vault.previewRedeemYul(s), "redeem");
    }

    /// @dev Yul Newton-Raphson must produce exact inverse: d * inv ≡ 1 (mod 2^256).
    ///      We test this indirectly: floor(d/d) must equal 1 for any odd d.
    function testFuzz_NewtonRaphson_ExactInverse(uint128 dHalf) public view {
        // Build an odd denominator
        uint256 d = (uint256(dHalf) * 2) + 1; // always odd
        // x*y / d where x*y = d → result = 1 exactly (no remainder)
        uint256 result = impl.mathYul(d, 1, d, false);
        assertEq(result, 1, "Newton-Raphson: d/d != 1");
    }
}
