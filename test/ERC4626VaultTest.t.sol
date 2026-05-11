// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ConstantProductAMM} from "../src/AMM.sol";
import {ERC4626Vault} from "../src/ERC4626Vault.sol";

// ═══════════════════════════════════════════════════════════════════
// MOCK ERC-20
// ═══════════════════════════════════════════════════════════════════

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

// ═══════════════════════════════════════════════════════════════════
// BASE FIXTURE
// ═══════════════════════════════════════════════════════════════════

abstract contract VaultTestBase is Test {
    using Math for uint256;

    // ── Actors ───────────────────────────────────────────────────────
    address internal constant OWNER = address(0xBE01);
    address internal constant ALICE = address(0xBE02);
    address internal constant BOB = address(0xBE03);
    address internal constant CHARLIE = address(0xBE04);

    // ── Contracts ────────────────────────────────────────────────────
    MockERC20 internal tokenX;
    MockERC20 internal tokenY;
    ConstantProductAMM internal amm;
    ERC4626Vault internal vault;

    // ── LP token reference (= IERC20(amm)) ──────────────────────────
    IERC20 internal lpToken;

    // ── Seed amounts ────────────────────────────────────────────────
    uint256 internal constant POOL_X = 500_000e18;
    uint256 internal constant POOL_Y = 500_000e18;
    uint256 internal constant LP_SEED = 10_000e18; // LP tokens given to Alice/Bob

    // ── ERC-4626 virtual offset (matches vault constant) ─────────────
    uint256 internal constant OFFSET = 6; // DECIMALS_OFFSET

    function setUp() public virtual {
        // Deploy tokens, sort.
        tokenX = new MockERC20("Token X", "TKX");
        tokenY = new MockERC20("Token Y", "TKY");

        // Deploy AMM.
        amm = new ConstantProductAMM(address(tokenX), address(tokenY));
        lpToken = IERC20(address(amm));

        // Deploy vault; OWNER is the initial owner.
        vault = new ERC4626Vault(
            address(amm), // lpToken = asset
            address(amm), // ammAddress for reserve queries
            address(0), // no price feed adapter in unit tests
            OWNER
        );

        // Seed AMM pool so LP tokens exist.
        _seedPool(OWNER, POOL_X, POOL_Y);

        // Give Alice and Bob some LP tokens by adding liquidity.
        _giveLpTokens(ALICE, LP_SEED);
        _giveLpTokens(BOB, LP_SEED);
        _giveLpTokens(CHARLIE, LP_SEED);
    }

    // ─── Helper: add liquidity and give resulting LP to actor ────────
    function _seedPool(address actor, uint256 x, uint256 y) internal {
        MockERC20 t0 = MockERC20(address(amm.token0()));
        MockERC20 t1 = MockERC20(address(amm.token1()));
        t0.mint(actor, x);
        t1.mint(actor, y);
        vm.startPrank(actor);
        t0.approve(address(amm), x);
        t1.approve(address(amm), y);
        amm.addLiquidity(x, y, 0, 0, actor, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function _giveLpTokens(address actor, uint256 lpDesired) internal {
        // Deposit enough underlying to get ~lpDesired LP tokens.
        // We over-deposit and then the AMM gives us proportional LP.
        uint256 bigX = lpDesired * 2;
        uint256 bigY = lpDesired * 2;
        _seedPool(actor, bigX, bigY);
    }

    // ─── Helper: approve LP tokens and deposit into vault ────────────
    function _deposit(address actor, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(actor);
        lpToken.approve(address(vault), assets);
        shares = vault.deposit(assets, actor);
        vm.stopPrank();
    }

    // ─── Helper: redeem vault shares ─────────────────────────────────
    function _redeem(address actor, uint256 shares) internal returns (uint256 assets) {
        vm.startPrank(actor);
        assets = vault.redeem(shares, actor, actor);
        vm.stopPrank();
    }

    // ─── Helper: withdraw exact assets from vault ─────────────────────
    function _withdraw(address actor, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(actor);
        shares = vault.withdraw(assets, actor, actor);
        vm.stopPrank();
    }

    // ─── Helper: compute expected shares using OZ virtual offset math ─
    /// convertToShares rounds DOWN: shares = assets * (supply + 10^offset) / (totalAssets + 1)
    function _expectedShares(uint256 assets) internal view returns (uint256) {
        uint256 supply = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();
        uint256 offset = 10 ** OFFSET;

        return assets.mulDiv(supply + offset, totalAssets + 1, Math.Rounding.Floor);
    }

    /// convertToAssets rounds DOWN: assets = shares * (totalAssets + 1) / (supply + 10^offset)
    function _expectedAssets(uint256 shares) internal view returns (uint256) {
        uint256 supply = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();
        uint256 offset = 10 ** OFFSET;

        return shares.mulDiv(totalAssets + 1, supply + offset, Math.Rounding.Floor);
    }
}

// ═══════════════════════════════════════════════════════════════════
// 1.  CONSTRUCTOR & METADATA
// ═══════════════════════════════════════════════════════════════════

contract Vault_Constructor_Test is VaultTestBase {
    function test_constructor_assetIsLpToken() public view {
        assertEq(vault.asset(), address(amm), "asset should be LP token");
    }

    function test_constructor_nameAndSymbol() public view {
        assertEq(vault.name(), "DeFiApp Vault Share");
        assertEq(vault.symbol(), "DVLT");
    }

    function test_constructor_decimalsEqualLpPlusOffset() public view {
        // LP token decimals = 18; vault decimals = 18 + DECIMALS_OFFSET = 24.
        uint8 lpDec = 18;
        uint8 expected = lpDec + vault.DECIMALS_OFFSET();
        assertEq(vault.decimals(), expected, "vault decimals mismatch");
    }

    function test_constructor_ownerSet() public view {
        assertEq(vault.owner(), OWNER);
    }

    function test_constructor_initialSharesZero() public view {
        assertEq(vault.totalSupply(), 0, "initial share supply must be zero");
    }

    function test_constructor_revert_zeroLpToken() public {
        vm.expectRevert(ERC4626Vault.Vault__ZeroAddress.selector);
        new ERC4626Vault(address(0), address(amm), address(0), OWNER);
    }

    function test_constructor_revert_zeroAmm() public {
        vm.expectRevert(ERC4626Vault.Vault__ZeroAddress.selector);
        new ERC4626Vault(address(amm), address(0), address(0), OWNER);
    }

    function test_constructor_revert_zeroOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new ERC4626Vault(address(amm), address(amm), address(0), address(0));
    }
}

// ═══════════════════════════════════════════════════════════════════
// 2.  DEPOSIT — UNIT TESTS
// ═══════════════════════════════════════════════════════════════════

contract Vault_Deposit_Unit_Test is VaultTestBase {
    function test_deposit_mintsSharesCorrectly() public {
        uint256 assets = lpToken.balanceOf(ALICE) / 2;
        uint256 expShares = _expectedShares(assets);

        uint256 shares = _deposit(ALICE, assets);

        assertEq(shares, expShares, "shares minted mismatch");
        assertEq(vault.balanceOf(ALICE), shares, "Alice share balance mismatch");
    }

    function test_deposit_transfersLpToVault() public {
        uint256 assets = lpToken.balanceOf(ALICE) / 2;
        uint256 vaultBefore = lpToken.balanceOf(address(vault));

        _deposit(ALICE, assets);

        assertEq(lpToken.balanceOf(address(vault)), vaultBefore + assets, "vault LP balance should increase by assets");
    }

    function test_deposit_multipleDepositors_sharesProportional() public {
        uint256 aliceAssets = lpToken.balanceOf(ALICE) / 2;
        uint256 bobAssets = lpToken.balanceOf(BOB) / 2;

        uint256 aliceShares = _deposit(ALICE, aliceAssets);
        uint256 bobShares = _deposit(BOB, bobAssets);

        // Both deposited the same LP amount → should receive the same shares
        // (within 1 unit of rounding tolerance).
        assertApproxEqAbs(aliceShares, bobShares, 1, "equal deposits should produce equal shares");
    }

    function test_deposit_totalAssetsIncrements() public {
        uint256 assets = lpToken.balanceOf(ALICE) / 4;
        uint256 taBefore = vault.totalAssets();

        _deposit(ALICE, assets);

        assertEq(vault.totalAssets(), taBefore + assets, "totalAssets should increase");
    }

    function test_deposit_revert_zeroAssets() public {
        vm.prank(ALICE);
        vm.expectRevert(ERC4626Vault.Vault__ZeroAmount.selector);
        vault.deposit(0, ALICE);
    }

    function test_deposit_revert_zeroReceiver() public {
        uint256 assets = lpToken.balanceOf(ALICE) / 2;
        vm.startPrank(ALICE);
        lpToken.approve(address(vault), assets);
        vm.expectRevert(ERC4626Vault.Vault__ZeroAddress.selector);
        vault.deposit(assets, address(0));
        vm.stopPrank();
    }

    function test_deposit_withSlippageParam_revert_minSharesNotMet() public {
        uint256 assets = lpToken.balanceOf(ALICE) / 2;
        uint256 expShares = _expectedShares(assets);

        vm.startPrank(ALICE);
        lpToken.approve(address(vault), assets);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Vault.Vault__MinSharesNotMet.selector,
                expShares,
                expShares + 1 // require 1 more than we'll get
            )
        );
        vault.deposit(assets, ALICE, expShares + 1);
        vm.stopPrank();
    }

    function test_deposit_withSlippageParam_succeeds() public {
        uint256 assets = lpToken.balanceOf(ALICE) / 2;
        uint256 expShares = _expectedShares(assets);

        vm.startPrank(ALICE);
        lpToken.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, ALICE, expShares);
        vm.stopPrank();

        assertGe(shares, expShares, "should receive at least minShares");
    }
}

// ═══════════════════════════════════════════════════════════════════
// 3.  MINT — UNIT TESTS
// ═══════════════════════════════════════════════════════════════════

contract Vault_Mint_Unit_Test is VaultTestBase {
    function test_mint_correctAssetCost() public {
        uint256 sharesToMint = 1_000 * (10 ** vault.decimals());
        uint256 expectedCost = vault.previewMint(sharesToMint);

        uint256 aliceLp = lpToken.balanceOf(ALICE);
        vm.assume(expectedCost <= aliceLp);

        vm.startPrank(ALICE);
        lpToken.approve(address(vault), expectedCost);
        uint256 assetsPaid = vault.mint(sharesToMint, ALICE);
        vm.stopPrank();

        assertEq(assetsPaid, expectedCost, "assets paid != previewMint");
        assertEq(vault.balanceOf(ALICE), sharesToMint, "share balance mismatch");
    }

    function test_mint_revert_zeroShares() public {
        vm.prank(ALICE);
        vm.expectRevert(ERC4626Vault.Vault__ZeroAmount.selector);
        vault.mint(0, ALICE);
    }

    function test_mint_withMaxAssetsParam_revert_tooExpensive() public {
        uint256 sharesToMint = 1_000 * (10 ** vault.decimals());
        uint256 cost = vault.previewMint(sharesToMint);

        vm.startPrank(ALICE);
        lpToken.approve(address(vault), cost);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Vault.Vault__MinAssetsNotMet.selector,
                cost,
                cost - 1 // maxAssets set below actual cost
            )
        );
        vault.mint(sharesToMint, ALICE, cost - 1);
        vm.stopPrank();
    }
}

// ═══════════════════════════════════════════════════════════════════
// 4.  WITHDRAW — UNIT TESTS
// ═══════════════════════════════════════════════════════════════════

contract Vault_Withdraw_Unit_Test is VaultTestBase {
    uint256 internal aliceShares;
    uint256 internal depositedAssets;

    function setUp() public override {
        super.setUp();
        depositedAssets = lpToken.balanceOf(ALICE) / 2;
        aliceShares = _deposit(ALICE, depositedAssets);
    }

    function test_withdraw_exactAssets_correctSharesBurned() public {
        uint256 withdrawAssets = vault.convertToAssets(aliceShares) / 2;
        uint256 expectedShares = vault.previewWithdraw(withdrawAssets);

        uint256 sharesBurned = _withdraw(ALICE, withdrawAssets);

        assertEq(sharesBurned, expectedShares, "shares burned != previewWithdraw");
        assertEq(vault.balanceOf(ALICE), aliceShares - sharesBurned, "remaining share balance mismatch");
    }

    function test_withdraw_returnsLpToReceiver() public {
        uint256 aliceLpBefore = lpToken.balanceOf(ALICE);
        uint256 toWithdraw = vault.convertToAssets(aliceShares) / 2;

        _withdraw(ALICE, toWithdraw);

        assertEq(lpToken.balanceOf(ALICE), aliceLpBefore + toWithdraw, "Alice should receive LP tokens back");
    }

    function test_withdraw_revert_zeroAssets() public {
        vm.prank(ALICE);
        vm.expectRevert(ERC4626Vault.Vault__ZeroAmount.selector);
        vault.withdraw(0, ALICE, ALICE);
    }

    function test_withdraw_revert_zeroReceiver() public {
        vm.prank(ALICE);
        vm.expectRevert(ERC4626Vault.Vault__ZeroAddress.selector);
        vault.withdraw(1e18, address(0), ALICE);
    }

    function test_withdraw_withMaxSharesParam_revert_tooExpensive() public {
        uint256 toWithdraw = vault.convertToAssets(aliceShares) / 4;
        uint256 requiredShares = vault.previewWithdraw(toWithdraw);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Vault.Vault__MinSharesNotMet.selector,
                requiredShares,
                requiredShares - 1 // maxShares set below actual requirement
            )
        );
        vault.withdraw(toWithdraw, ALICE, ALICE, requiredShares - 1);
    }

    function test_withdraw_totalAssetsDecreases() public {
        uint256 taBefore = vault.totalAssets();
        uint256 toWithdraw = taBefore / 4;

        _withdraw(ALICE, toWithdraw);

        assertEq(vault.totalAssets(), taBefore - toWithdraw, "totalAssets should decrease by withdrawn amount");
    }
}

// ═══════════════════════════════════════════════════════════════════
// 5.  REDEEM — UNIT TESTS
// ═══════════════════════════════════════════════════════════════════

contract Vault_Redeem_Unit_Test is VaultTestBase {
    uint256 internal aliceShares;

    function setUp() public override {
        super.setUp();
        uint256 assets = lpToken.balanceOf(ALICE) / 2;
        aliceShares = _deposit(ALICE, assets);
    }

    function test_redeem_burnsSharesAndReturnsAssets() public {
        uint256 lpBefore = lpToken.balanceOf(ALICE);
        uint256 expected = vault.previewRedeem(aliceShares);

        uint256 returned = _redeem(ALICE, aliceShares);

        assertEq(returned, expected, "returned assets != previewRedeem");
        assertEq(lpToken.balanceOf(ALICE), lpBefore + returned, "LP balance mismatch");
        assertEq(vault.balanceOf(ALICE), 0, "all shares should be burned");
    }

    function test_redeem_revert_zeroShares() public {
        vm.prank(ALICE);
        vm.expectRevert(ERC4626Vault.Vault__ZeroAmount.selector);
        vault.redeem(0, ALICE, ALICE);
    }

    function test_redeem_withMinAssetsParam_revert_tooLow() public {
        uint256 expected = vault.previewRedeem(aliceShares);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Vault.Vault__MinAssetsNotMet.selector,
                expected,
                expected + 1 // minAssets set 1 above what we'll receive
            )
        );
        vault.redeem(aliceShares, ALICE, ALICE, expected + 1);
    }

    function test_redeem_revert_zeroReceiver() public {
        vm.prank(ALICE);
        vm.expectRevert(ERC4626Vault.Vault__ZeroAddress.selector);
        vault.redeem(aliceShares, address(0), ALICE);
    }
}

// ═══════════════════════════════════════════════════════════════════
// 6.  PAUSE / UNPAUSE
// ═══════════════════════════════════════════════════════════════════

contract Vault_Pause_Test is VaultTestBase {
    uint256 internal aliceShares;

    function setUp() public override {
        super.setUp();
        uint256 assets = lpToken.balanceOf(ALICE) / 2;
        aliceShares = _deposit(ALICE, assets);
    }

    function test_pause_blocksDeposit() public {
        vm.prank(OWNER);
        vault.pause();

        uint256 assets = lpToken.balanceOf(BOB) / 2;
        vm.startPrank(BOB);
        lpToken.approve(address(vault), assets);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(assets, BOB);
        vm.stopPrank();
    }

    function test_pause_blocksMint() public {
        vm.prank(OWNER);
        vault.pause();

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.mint(1e18, BOB);
    }

    function test_pause_doesNotBlockWithdraw() public {
        vm.prank(OWNER);
        vault.pause();

        // Alice can still withdraw while paused (asymmetric pause design).
        uint256 toWithdraw = vault.convertToAssets(aliceShares / 2);
        _withdraw(ALICE, toWithdraw); // must not revert
        assertEq(lpToken.balanceOf(ALICE) > 0, true);
    }

    function test_pause_doesNotBlockRedeem() public {
        vm.prank(OWNER);
        vault.pause();

        // Redeem must still work while paused.
        _redeem(ALICE, aliceShares);
        assertEq(vault.balanceOf(ALICE), 0, "shares should be burned");
    }

    function test_unpause_restoresDeposit() public {
        vm.prank(OWNER);
        vault.pause();

        vm.prank(OWNER);
        vault.unpause();

        uint256 assets = lpToken.balanceOf(BOB) / 2;
        _deposit(BOB, assets); // must succeed after unpause
        assertGt(vault.balanceOf(BOB), 0, "Bob should have shares after unpause");
    }

    function test_pause_revert_notOwner() public {
        vm.expectRevert(); // OZ Ownable reverts with OwnableUnauthorizedAccount
        vm.prank(ALICE);
        vault.pause();
    }
}

// ═══════════════════════════════════════════════════════════════════
// 7.  FUZZ — DEPOSIT / REDEEM ROUND TRIP
// ═══════════════════════════════════════════════════════════════════

contract Vault_Fuzz_DepositRedeem_Test is VaultTestBase {
    function testFuzz_depositThenRedeem_assetConservation(uint256 assets) public {
        uint256 aliceLp = lpToken.balanceOf(ALICE);
        assets = bound(assets, 1, aliceLp);

        uint256 lpBefore = lpToken.balanceOf(ALICE);

        uint256 shares = _deposit(ALICE, assets);
        uint256 returned = _redeem(ALICE, shares);

        uint256 lpAfter = lpToken.balanceOf(ALICE);

        assertLe(lpBefore - lpAfter, 1, "fuzz: round-trip deposit/redeem lost more than 1 wei");
        assertGe(returned, 0, "fuzz: returned assets must be non-negative");
    }

    function testFuzz_equalDeposits_equalShares(uint256 assets) public {
        uint256 aliceLp = lpToken.balanceOf(ALICE);
        uint256 bobLp = lpToken.balanceOf(BOB);
        uint256 maxDeposit = aliceLp < bobLp ? aliceLp : bobLp;

        assets = bound(assets, 1e12, maxDeposit / 2);

        uint256 aliceShares = _deposit(ALICE, assets);
        uint256 bobShares = _deposit(BOB, assets);

        assertApproxEqAbs(
            aliceShares, bobShares, 2, "fuzz: equal deposits should produce equal shares (within 2 units)"
        );
    }

    function testFuzz_convertRoundTrip_neverExceedsInput(uint256 assets) public {
        uint256 seed = lpToken.balanceOf(ALICE) / 3;
        _deposit(ALICE, seed);

        uint256 bobLp = lpToken.balanceOf(BOB);
        assets = bound(assets, 1, bobLp);

        uint256 shares = vault.convertToShares(assets);
        uint256 back = vault.convertToAssets(shares);

        assertLe(back, assets, "fuzz: convertToAssets(convertToShares(x)) > x (ERC-4626 violation)");
    }

    function testFuzz_previewDeposit_neverOverestimates(uint256 assets) public {
        uint256 seed = lpToken.balanceOf(ALICE) / 3;
        _deposit(ALICE, seed);

        uint256 bobLp = lpToken.balanceOf(BOB);
        assets = bound(assets, 1, bobLp);

        uint256 previewed = vault.previewDeposit(assets);
        uint256 actual = _deposit(BOB, assets);

        assertLe(
            previewed,
            actual + 1, // +1 tolerance for rounding
            "fuzz: previewDeposit overestimated actual shares"
        );
    }

    function testFuzz_previewRedeem_neverOverestimates(uint256 assets) public {
        uint256 bobLp = lpToken.balanceOf(BOB);
        assets = bound(assets, 1, bobLp);

        uint256 shares = _deposit(BOB, assets);
        if (shares == 0) return; // skip degenerate case

        uint256 previewed = vault.previewRedeem(shares);
        uint256 actual = _redeem(BOB, shares);

        assertLe(previewed, actual + 1, "fuzz: previewRedeem overestimated actual assets");
    }
}

// ═══════════════════════════════════════════════════════════════════
// 8.  FUZZ — INFLATION ATTACK RESISTANCE
// ═══════════════════════════════════════════════════════════════════

contract Vault_Fuzz_InflationAttack_Test is VaultTestBase {
    function testFuzz_inflationAttack_victimAlwaysReceivesShares(uint256 donation, uint256 victimDeposit) public {
        address attacker = address(0xDEAD01);
        address victim = address(0xDEAD02);

        // 1. Даем атакующему LP токены напрямую (минуя addLiquidity пула, чтобы не ломать резервы)
        uint256 attackerLp = 10_000_000e18;
        deal(address(lpToken), attacker, attackerLp);

        // Шаг 1: Атакующий вносит ровно 1 wei и получает микро-долю
        vm.startPrank(attacker);
        lpToken.approve(address(vault), 1);
        vault.deposit(1, attacker);
        vm.stopPrank();

        // Шаг 2: Атакующий донатит LP-токены напрямую на контракт хранилища
        // Ограничиваем донат разумным, но огромным пределом (например, 1,000,000 LP)
        donation = bound(donation, 1e18, 1_000_000e18);

        vm.prank(attacker);
        lpToken.transfer(address(vault), donation);

        // 2. Даем жертве фиксированный большой баланс LP токенов напрямую
        uint256 maxVictimLp = 10_000e18;
        deal(address(lpToken), victim, maxVictimLp);

        // Шаг 3: Жертва делает обычный, "бытовой" депозит
        // Зажимаем строго от 10 LP до 10,000 LP
        victimDeposit = bound(victimDeposit, 10e18, maxVictimLp);

        vm.startPrank(victim);
        lpToken.approve(address(vault), victimDeposit);
        uint256 shares = vault.deposit(victimDeposit, victim);
        vm.stopPrank();

        // Шаг 4: Проверяем, что благодаря виртуальным оффсетам (DECIMALS_OFFSET = 6)
        // жертва успешно получила свои доли, и округление в 0 её не обокрало.
        assertGt(shares, 0, "inflation attack: victim received 0 shares despite non-trivial deposit");
    }

    function testFuzz_emptyVault_alwaysMintsPositiveShares(uint256 assets) public {
        uint256 available = lpToken.balanceOf(ALICE);
        assets = bound(assets, 1, available);

        uint256 shares = _deposit(ALICE, assets);

        assertGt(shares, 0, "fuzz: deposit into empty vault returned 0 shares");
    }
}

// ═══════════════════════════════════════════════════════════════════
// 9.  FUZZ — WITHDRAW MATH SCALING
// ═══════════════════════════════════════════════════════════════════

contract Vault_Fuzz_WithdrawMath_Test is VaultTestBase {
    function testFuzz_withdraw_exactAmount_burnedSharesMatchPreview(uint256 assets) public {
        uint256 available = lpToken.balanceOf(ALICE) / 2;
        uint256 seed = available / 2;
        _deposit(ALICE, seed);

        uint256 bobLp = lpToken.balanceOf(BOB);
        assets = bound(assets, 1, bobLp / 2);

        _deposit(BOB, assets);

        uint256 preview = vault.previewWithdraw(assets);
        uint256 burned = _withdraw(BOB, assets);

        assertEq(burned, preview, "fuzz: burned shares != previewWithdraw");
    }

    function testFuzz_redeem_assetsWithinOneWeiOfConvert(uint256 assets) public {
        uint256 available = lpToken.balanceOf(ALICE);
        assets = bound(assets, 1, available);

        uint256 shares = _deposit(ALICE, assets);
        if (shares == 0) return;

        uint256 expected = vault.convertToAssets(shares);
        uint256 actual = _redeem(ALICE, shares);

        assertApproxEqAbs(actual, expected, 1, "fuzz: redeem assets differ from convertToAssets by more than 1 wei");
    }

    function testFuzz_fullCycleConsistency(uint256 assets) public {
        uint256 available = lpToken.balanceOf(ALICE);
        assets = bound(assets, 2e18, available);

        uint256 lpBefore = lpToken.balanceOf(ALICE);

        uint256 shares = _deposit(ALICE, assets);
        assertGt(shares, 0, "fuzz lifecycle: no shares minted");

        uint256 halfAssets = assets / 2;
        uint256 burnedForHalf = _withdraw(ALICE, halfAssets);
        assertGt(burnedForHalf, 0, "fuzz lifecycle: no shares burned for partial withdraw");

        uint256 remaining = vault.balanceOf(ALICE);
        uint256 returned = _redeem(ALICE, remaining);
        assertGe(returned, 0, "fuzz lifecycle: negative return");

        uint256 lpAfter = lpToken.balanceOf(ALICE);

        assertGe(lpBefore, lpAfter - 2, "fuzz lifecycle: recovered more than deposited (vault gave free tokens)");
    }
}

// ═══════════════════════════════════════════════════════════════════
// 10. ERC-4626 ROUNDING INVARIANTS (view-function only)
// ═══════════════════════════════════════════════════════════════════

contract Vault_ERC4626_RoundingInvariants_Test is VaultTestBase {
    function setUp() public override {
        super.setUp();
        _deposit(ALICE, lpToken.balanceOf(ALICE) / 3);
        _deposit(BOB, lpToken.balanceOf(BOB) / 3);
    }

    function testFuzz_convertToShares_roundsDown(uint256 assets) public view {
        uint256 available = vault.totalAssets();
        assets = bound(assets, 1, available * 2);

        uint256 shares = vault.convertToShares(assets);

        uint256 supply = vault.totalSupply();
        uint256 ta = vault.totalAssets();
        uint256 offset = 10 ** vault.DECIMALS_OFFSET();

        uint256 lhs = shares * (ta + 1);
        uint256 rhs = assets * (supply + offset);

        assertLe(lhs, rhs, "convertToShares did not round down (ERC-4626 violation)");
    }

    function testFuzz_previewMint_roundsUp(uint256 shares) public view {
        uint256 totalShares = vault.totalSupply();
        shares = bound(shares, 1, totalShares == 0 ? 1e24 : totalShares);

        uint256 preview = vault.previewMint(shares);
        uint256 converted = vault.convertToAssets(shares);

        assertGe(preview, converted, "previewMint must be >= convertToAssets (should round UP)");
    }

    function testFuzz_previewWithdraw_roundsUp(uint256 assets) public view {
        uint256 ta = vault.totalAssets();
        assets = bound(assets, 1, ta);

        uint256 preview = vault.previewWithdraw(assets);
        uint256 converted = vault.convertToShares(assets);

        assertGe(preview, converted, "previewWithdraw must be >= convertToShares (should round UP)");
    }
}
