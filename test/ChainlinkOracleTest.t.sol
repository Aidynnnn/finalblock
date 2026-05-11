// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20}          from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ChainlinkPriceFeedAdapter} from "../src/ChainlinkPriceFeedAdapter.sol";
import {ERC4626Vault}              from "../src/ERC4626Vault.sol";
import {ConstantProductAMM}        from "../src/AMM.sol";
import {MockV3Aggregator}          from "./mocks/MockV3Aggregator.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal ERC-20 for integration tests
// ─────────────────────────────────────────────────────────────────────────────
contract MockERC20Oracle is ERC20 {
    constructor(string memory name_, string memory sym_) ERC20(name_, sym_) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ─────────────────────────────────────────────────────────────────────────────
// ChainlinkOracleTest
//
// Tests the full oracle consumer path:
//
//   MockV3Aggregator  (controllable Chainlink stub)
//          ↓  latestRoundData()
//   ChainlinkPriceFeedAdapter  (all 4 safety checks + 18-decimal normalisation)
//          ↓  getPrice()
//   ERC4626Vault.getUsdValueOfShares()  (integration)
//
// Safety checks verified:
//   [1] answeredInRound < roundId  → PriceFeed__RoundNotComplete
//   [2] answer <= 0               → PriceFeed__InvalidPrice
//   [3] updatedAt == 0            → PriceFeed__InvalidRoundTimestamp
//   [4] age > heartbeat           → PriceFeed__StalePrice
// ─────────────────────────────────────────────────────────────────────────────
contract ChainlinkOracleTest is Test {

    // ── Actors ───────────────────────────────────────────────────────
    address internal constant OWNER   = address(0xBE01);
    address internal constant ALICE   = address(0xBE02);
    address internal constant ATTACKER = address(0xDEAD);

    // ── Heartbeat used for all single-feed unit tests ─────────────────
    uint256 internal constant HEARTBEAT = 3600; // 1 hour — typical L2 ETH/USD

    // ── Typical Chainlink values ──────────────────────────────────────
    // USD feeds use 8 decimals; e.g. ETH/USD at $2000 = 200000000000
    int256  internal constant ETH_USD_PRICE_8DEC  = 2_000e8;   // $2 000.00
    int256  internal constant BTC_USD_PRICE_8DEC  = 60_000e8;  // $60 000.00

    // ── Contracts ─────────────────────────────────────────────────────
    ChainlinkPriceFeedAdapter internal adapter;
    MockV3Aggregator          internal ethFeed;
    MockV3Aggregator          internal btcFeed;

    // ─────────────────────────────────────────────────────────────────
    // setUp
    // ─────────────────────────────────────────────────────────────────
    function setUp() public {
        // Use a realistic starting timestamp so staleness math is sensible.
        vm.warp(1_700_000_000);

        vm.startPrank(OWNER);

        // Deploy the adapter (owner = OWNER, to be transferred to Timelock in prod).
        adapter = new ChainlinkPriceFeedAdapter(OWNER);

        // Deploy mock aggregators — 8 decimals, typical USD feed prices.
        ethFeed = new MockV3Aggregator(8, ETH_USD_PRICE_8DEC);
        btcFeed = new MockV3Aggregator(8, BTC_USD_PRICE_8DEC);

        // Register both feeds with a 1-hour heartbeat.
        adapter.registerFeed(address(ethFeed), HEARTBEAT);
        adapter.registerFeed(address(btcFeed), HEARTBEAT);

        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════
    // SECTION A — Feed registration & admin
    // ═════════════════════════════════════════════════════════════════

    function test_RegisterFeed_Succeeds() public view {
        assertTrue(adapter.isRegistered(address(ethFeed)), "ETH feed must be registered");
        assertTrue(adapter.isRegistered(address(btcFeed)), "BTC feed must be registered");
        assertEq(adapter.getFeedDecimals(address(ethFeed)), 8);
        assertEq(adapter.getHeartbeat(address(ethFeed)), HEARTBEAT);
    }

    function test_RegisterFeed_Reverts_ZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceFeedAdapter.PriceFeed__ZeroAddress.selector);
        adapter.registerFeed(address(0), HEARTBEAT);
    }

    function test_RegisterFeed_Reverts_ZeroHeartbeat() public {
        MockV3Aggregator newFeed = new MockV3Aggregator(8, 1e8);
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceFeedAdapter.PriceFeed__ZeroHeartbeat.selector);
        adapter.registerFeed(address(newFeed), 0);
    }

    function test_RegisterFeed_Reverts_Duplicate() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceFeedAdapter.PriceFeed__AlreadyRegistered.selector,
                address(ethFeed)
            )
        );
        adapter.registerFeed(address(ethFeed), HEARTBEAT);
    }

    function test_RegisterFeed_Reverts_Unauthorized() public {
        MockV3Aggregator newFeed = new MockV3Aggregator(8, 1e8);
        vm.prank(ATTACKER);
        vm.expectRevert();
        adapter.registerFeed(address(newFeed), HEARTBEAT);
    }

    function test_UpdateHeartbeat_Succeeds() public {
        uint256 newHb = 7200;
        vm.prank(OWNER);
        adapter.updateHeartbeat(address(ethFeed), newHb);
        assertEq(adapter.getHeartbeat(address(ethFeed)), newHb);
    }

    function test_UpdateHeartbeat_Reverts_ZeroHeartbeat() public {
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkPriceFeedAdapter.PriceFeed__ZeroHeartbeat.selector);
        adapter.updateHeartbeat(address(ethFeed), 0);
    }

    function test_UpdateHeartbeat_Reverts_NotRegistered() public {
        address ghost = makeAddr("ghost");
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceFeedAdapter.PriceFeed__NotRegistered.selector, ghost)
        );
        adapter.updateHeartbeat(ghost, HEARTBEAT);
    }

    function test_DeregisterFeed_Succeeds() public {
        vm.prank(OWNER);
        adapter.deregisterFeed(address(btcFeed));
        assertFalse(adapter.isRegistered(address(btcFeed)));
    }

    function test_DeregisterFeed_Reverts_NotRegistered() public {
        address ghost = makeAddr("ghost");
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceFeedAdapter.PriceFeed__NotRegistered.selector, ghost)
        );
        adapter.deregisterFeed(ghost);
    }

    function test_GetPrice_Reverts_UnregisteredFeed() public {
        address ghost = makeAddr("ghost");
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceFeedAdapter.PriceFeed__NotRegistered.selector, ghost)
        );
        adapter.getPrice(ghost);
    }

    // ═════════════════════════════════════════════════════════════════
    // SECTION B — Valid price acceptance & 18-decimal normalisation
    // ═════════════════════════════════════════════════════════════════

    /// @notice 8-decimal feed → multiply by 10^10 to reach 18 decimals.
    ///         ETH/USD at $2000 (raw = 2000e8) → normalised = 2000e18.
    function test_GetPrice_Valid_8DecimalFeed() public view {
        uint256 price = adapter.getPrice(address(ethFeed));
        // 2_000e8 * 10^10 = 2_000e18
        assertEq(price, uint256(ETH_USD_PRICE_8DEC) * 1e10,
            "8-decimal feed must be scaled to 18 decimals");
    }

    /// @notice 18-decimal feed → no scaling, price returned as-is.
    function test_GetPrice_Valid_18DecimalFeed() public {
        MockV3Aggregator feed18 = new MockV3Aggregator(18, 3_000e18);
        vm.prank(OWNER);
        adapter.registerFeed(address(feed18), HEARTBEAT);

        uint256 price = adapter.getPrice(address(feed18));
        assertEq(price, uint256(3_000e18), "18-decimal feed must not be scaled");
    }

    /// @notice Feed with more than 18 decimals → divide to reach 18.
    ///         A 20-decimal feed priced at 1e20 should yield 1e18.
    function test_GetPrice_Valid_20DecimalFeed_ScaleDown() public {
        MockV3Aggregator feed20 = new MockV3Aggregator(20, 1e20);
        vm.prank(OWNER);
        adapter.registerFeed(address(feed20), HEARTBEAT);

        uint256 price = adapter.getPrice(address(feed20));
        assertEq(price, 1e18, "20-decimal feed must be scaled DOWN to 18 decimals");
    }

    /// @notice Updating the mock answer is immediately reflected.
    function test_GetPrice_UpdateAnswer_Reflected() public {
        int256 newRaw = 2_500e8; // $2 500
        ethFeed.updateAnswer(newRaw);

        uint256 price = adapter.getPrice(address(ethFeed));
        assertEq(price, uint256(newRaw) * 1e10);
    }

    // ═════════════════════════════════════════════════════════════════
    // SECTION C — Safety check [2]: invalid (zero / negative) price
    // ═════════════════════════════════════════════════════════════════

    function test_GetPrice_Reverts_ZeroAnswer() public {
        ethFeed.setAnswer(0);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceFeedAdapter.PriceFeed__InvalidPrice.selector,
                address(ethFeed),
                int256(0)
            )
        );
        adapter.getPrice(address(ethFeed));
    }

    function test_GetPrice_Reverts_NegativeAnswer() public {
        int256 badAnswer = -1;
        ethFeed.setAnswer(badAnswer);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceFeedAdapter.PriceFeed__InvalidPrice.selector,
                address(ethFeed),
                badAnswer
            )
        );
        adapter.getPrice(address(ethFeed));
    }

    function test_GetPrice_Reverts_LargeNegativeAnswer() public {
        ethFeed.setAnswer(type(int256).min);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceFeedAdapter.PriceFeed__InvalidPrice.selector,
                address(ethFeed),
                type(int256).min
            )
        );
        adapter.getPrice(address(ethFeed));
    }

    // ═════════════════════════════════════════════════════════════════
    // SECTION D — Safety check [4]: staleness heartbeat guard
    // ═════════════════════════════════════════════════════════════════

    /// @notice Price that is exactly 1 second old must be accepted.
    function test_GetPrice_Fresh_OneSecondOld() public {
        vm.warp(block.timestamp + 1);
        uint256 price = adapter.getPrice(address(ethFeed));
        assertGt(price, 0, "1-second-old price must be accepted");
    }

    /// @notice Price exactly at the heartbeat boundary (age == heartbeat) must succeed.
    function test_GetPrice_AtExactHeartbeatBoundary_Succeeds() public {
        vm.warp(block.timestamp + HEARTBEAT);
        // age = HEARTBEAT — adapter checks age > heartbeat, so == does NOT revert
        uint256 price = adapter.getPrice(address(ethFeed));
        assertGt(price, 0, "price at exact heartbeat boundary must be accepted");
    }

    /// @notice One second past the heartbeat must revert.
    ///         Reads updatedAt from the mock directly so the expected error
    ///         matches the exact value the adapter sees, regardless of warp timing.
    function test_GetPrice_Reverts_PastHeartbeat() public {
        // Read the feed's actual updatedAt before warping.
        (,,,uint256 feedUpdatedAt,) = ethFeed.latestRoundData();

        vm.warp(block.timestamp + HEARTBEAT + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceFeedAdapter.PriceFeed__StalePrice.selector,
                address(ethFeed),
                feedUpdatedAt,   // what latestRoundData() returns as updatedAt
                block.timestamp, // current time after warp
                HEARTBEAT
            )
        );
        adapter.getPrice(address(ethFeed));
    }

    /// @notice Far-future warp — very stale price must revert.
    function test_GetPrice_Reverts_VeryStalePrice() public {
        (,,,uint256 feedUpdatedAt,) = ethFeed.latestRoundData();

        vm.warp(block.timestamp + 7 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceFeedAdapter.PriceFeed__StalePrice.selector,
                address(ethFeed),
                feedUpdatedAt,
                block.timestamp,
                HEARTBEAT
            )
        );
        adapter.getPrice(address(ethFeed));
    }

    /// @notice Updating the mock answer resets updatedAt — feed is fresh again.
    function test_GetPrice_StaleAfterWarp_FreshAfterUpdate() public {
        // Make price stale
        vm.warp(block.timestamp + HEARTBEAT + 1);
        vm.expectRevert();
        adapter.getPrice(address(ethFeed));

        // Refreshing the feed makes it valid again
        ethFeed.updateAnswer(2_100e8);
        uint256 price = adapter.getPrice(address(ethFeed));
        assertEq(price, uint256(2_100e8) * 1e10);
    }

    // ═════════════════════════════════════════════════════════════════
    // SECTION E — Safety check [3]: uninitialised round (updatedAt == 0)
    // ═════════════════════════════════════════════════════════════════

    function test_GetPrice_Reverts_ZeroUpdatedAt() public {
        // Force updatedAt to 0 — simulates an uninitialised or corrupted round.
        ethFeed.updateRoundData(5, ETH_USD_PRICE_8DEC, block.timestamp, 0, 5);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceFeedAdapter.PriceFeed__InvalidRoundTimestamp.selector,
                address(ethFeed)
            )
        );
        adapter.getPrice(address(ethFeed));
    }

    // ═════════════════════════════════════════════════════════════════
    // SECTION F — Safety check [1]: incomplete round
    // ═════════════════════════════════════════════════════════════════

    /// @notice answeredInRound < roundId means nodes have not reached consensus
    ///         yet for the new round; the stored answer is from the previous round.
    function test_GetPrice_Reverts_IncompleteRound_AnsweredInRoundLower() public {
        // roundId = 10, answeredInRound = 9 → stale answer from round 9
        ethFeed.updateRoundData(10, ETH_USD_PRICE_8DEC, block.timestamp, block.timestamp, 9);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceFeedAdapter.PriceFeed__RoundNotComplete.selector,
                address(ethFeed),
                uint80(10),
                uint80(9)
            )
        );
        adapter.getPrice(address(ethFeed));
    }

    /// @notice answeredInRound == roundId is the normal, valid case.
    function test_GetPrice_Valid_AnsweredInRoundEqualsRoundId() public {
        ethFeed.updateRoundData(10, ETH_USD_PRICE_8DEC, block.timestamp, block.timestamp, 10);
        uint256 price = adapter.getPrice(address(ethFeed));
        assertEq(price, uint256(ETH_USD_PRICE_8DEC) * 1e10);
    }

    // ═════════════════════════════════════════════════════════════════
    // SECTION G — Fuzz: normalisation correctness over a range of values
    // ═════════════════════════════════════════════════════════════════

    /// @notice For any valid 8-decimal price, the normalised result must be exactly
    ///         rawPrice * 1e10, and must be > 0.
    function testFuzz_Normalisation_8Decimal(uint64 rawPrice) public {
        // Bound to a realistic price range; int256 safe-cast requires > 0.
        vm.assume(rawPrice > 0);

        ethFeed.updateAnswer(int256(uint256(rawPrice)));

        uint256 normalised = adapter.getPrice(address(ethFeed));
        assertEq(normalised, uint256(rawPrice) * 1e10,
            "normalised must be rawPrice * 10^(18-8)");
    }

    /// @notice For any valid 18-decimal price, the normalised result must equal rawPrice.
    function testFuzz_Normalisation_18Decimal(uint128 rawPrice) public {
        vm.assume(rawPrice > 0);

        MockV3Aggregator feed18 = new MockV3Aggregator(18, 1e18); // dummy initial
        vm.prank(OWNER);
        adapter.registerFeed(address(feed18), HEARTBEAT);

        feed18.updateAnswer(int256(uint256(rawPrice)));
        uint256 normalised = adapter.getPrice(address(feed18));
        assertEq(normalised, uint256(rawPrice));
    }

    // ═════════════════════════════════════════════════════════════════
    // SECTION H — Fuzz: staleness boundary
    // ═════════════════════════════════════════════════════════════════

    /// @notice price must be accepted whenever age <= heartbeat,
    ///         and must revert whenever age > heartbeat.
    function testFuzz_Staleness_Boundary(uint256 age) public {
        // Bound to a manageable warp range (up to 10x heartbeat).
        age = bound(age, 0, HEARTBEAT * 10);

        // Read the feed's updatedAt before warping so the expected error
        // uses the exact value the adapter will put in the revert.
        (,,,uint256 feedUpdatedAt,) = ethFeed.latestRoundData();

        vm.warp(block.timestamp + age);

        if (age <= HEARTBEAT) {
            // Should succeed
            uint256 price = adapter.getPrice(address(ethFeed));
            assertGt(price, 0);
        } else {
            // Should revert with StalePrice carrying the feed's own updatedAt.
            vm.expectRevert(
                abi.encodeWithSelector(
                    ChainlinkPriceFeedAdapter.PriceFeed__StalePrice.selector,
                    address(ethFeed),
                    feedUpdatedAt,
                    block.timestamp,
                    HEARTBEAT
                )
            );
            adapter.getPrice(address(ethFeed));
        }
    }

    // ═════════════════════════════════════════════════════════════════
    // SECTION I — Integration: ERC4626Vault.getUsdValueOfShares()
    // ═════════════════════════════════════════════════════════════════

    /// @notice End-to-end test demonstrating the oracle path used by the vault.
    ///         Sets up: two ERC-20 tokens → ConstantProductAMM → LP token →
    ///         ERC4626Vault → ChainlinkPriceFeedAdapter → two MockV3Aggregators.
    ///         Verifies that getUsdValueOfShares() returns a value consistent
    ///         with the simulated prices.
    function test_Integration_VaultUsdValuation_ValidPrices() public {
        // ── Deploy token pair ─────────────────────────────────────────
        MockERC20Oracle tokenA = new MockERC20Oracle("Token A", "TKA");
        MockERC20Oracle tokenB = new MockERC20Oracle("Token B", "TKB");

        // ── Deploy AMM (will sort tokens) ─────────────────────────────
        ConstantProductAMM amm = new ConstantProductAMM(address(tokenA), address(tokenB));

        // ── Seed liquidity (50 000 each token) ───────────────────────
        uint256 seed = 50_000e18;
        tokenA.mint(OWNER, seed);
        tokenB.mint(OWNER, seed);

        vm.startPrank(OWNER);
        tokenA.approve(address(amm), seed);
        tokenB.approve(address(amm), seed);
        amm.addLiquidity(seed, seed, 0, 0, OWNER, block.timestamp + 1 hours);

        // ── Deploy vault wired to adapter ─────────────────────────────
        ERC4626Vault vault = new ERC4626Vault(
            address(amm),      // lpToken = asset
            address(amm),      // amm
            address(adapter),  // Chainlink adapter
            OWNER
        );

        // ── Create mock feeds for the two pool tokens ─────────────────
        // token0 / token1 may be sorted differently by the AMM constructor.
        address t0 = address(amm.token0());
        address t1 = address(amm.token1());

        // $1.00 per TKA, $2.00 per TKB — both 8-decimal feeds
        MockV3Aggregator feedA = new MockV3Aggregator(8, 1e8);  // $1
        MockV3Aggregator feedB = new MockV3Aggregator(8, 2e8);  // $2

        // Register both feeds
        adapter.registerFeed(address(feedA), HEARTBEAT);
        adapter.registerFeed(address(feedB), HEARTBEAT);

        // Assign feeds to the pool tokens in the correct order.
        // t0 is the AMM-sorted token0; match it to the appropriate feed.
        address feed0 = (t0 == address(tokenA)) ? address(feedA) : address(feedB);
        address feed1 = (t1 == address(tokenA)) ? address(feedA) : address(feedB);
        vault.setFeeds(feed0, feed1);

        // ── Deposit LP tokens into vault ──────────────────────────────
        // OWNER holds LP tokens from addLiquidity(); deposit half.
        uint256 lpBalance = amm.balanceOf(OWNER);
        uint256 depositAmt = lpBalance / 2;

        ERC20(address(amm)).approve(address(vault), depositAmt);
        uint256 shares = vault.deposit(depositAmt, OWNER);
        vm.stopPrank();

        // ── Query USD value ───────────────────────────────────────────
        uint256 usdValue = vault.getUsdValueOfShares(shares);

        // Rough sanity check: value must be > 0.
        // With 50k tokens each at $1 and $2, and half the pool deposited,
        // the USD value should be in the range [0, ~150 000e18].
        assertGt(usdValue, 0, "USD value must be positive");
        assertLt(usdValue, 200_000e18, "USD value sanity cap");

        console2.log("[VAULT ORACLE] shares deposited:", shares);
        console2.log("[VAULT ORACLE] USD value (WAD):", usdValue);
    }

    /// @notice When one of the feeds is stale, getUsdValueOfShares() must revert.
    ///         This confirms the vault does NOT serve stale valuations.
    function test_Integration_VaultUsdValuation_Reverts_OnStaleFeed() public {
        // ── Minimal setup ─────────────────────────────────────────────
        MockERC20Oracle tokenA = new MockERC20Oracle("Token A", "TKA");
        MockERC20Oracle tokenB = new MockERC20Oracle("Token B", "TKB");
        ConstantProductAMM amm = new ConstantProductAMM(address(tokenA), address(tokenB));

        uint256 seed = 10_000e18;
        tokenA.mint(OWNER, seed);
        tokenB.mint(OWNER, seed);

        vm.startPrank(OWNER);
        tokenA.approve(address(amm), seed);
        tokenB.approve(address(amm), seed);
        amm.addLiquidity(seed, seed, 0, 0, OWNER, block.timestamp + 1 hours);

        ERC4626Vault vault = new ERC4626Vault(address(amm), address(amm), address(adapter), OWNER);

        MockV3Aggregator feedA = new MockV3Aggregator(8, 1e8);
        MockV3Aggregator feedB = new MockV3Aggregator(8, 1e8);
        adapter.registerFeed(address(feedA), HEARTBEAT);
        adapter.registerFeed(address(feedB), HEARTBEAT);

        address t0 = address(amm.token0());
        address feed0 = (t0 == address(tokenA)) ? address(feedA) : address(feedB);
        address feed1 = (t0 == address(tokenA)) ? address(feedB) : address(feedA);
        vault.setFeeds(feed0, feed1);

        uint256 lpBalance = amm.balanceOf(OWNER);
        ERC20(address(amm)).approve(address(vault), lpBalance / 2);
        uint256 shares = vault.deposit(lpBalance / 2, OWNER);
        vm.stopPrank();

        // ── Make feedA stale by warping past the heartbeat ────────────
        vm.warp(block.timestamp + HEARTBEAT + 1);

        // getUsdValueOfShares() must revert because the oracle data is stale.
        vm.expectRevert();
        vault.getUsdValueOfShares(shares);
    }

    /// @notice getUsdValueOfShares() must revert if the adapter is not set.
    function test_Integration_VaultUsdValuation_Reverts_NoAdapter() public {
        MockERC20Oracle tokenA = new MockERC20Oracle("Token A", "TKA");
        MockERC20Oracle tokenB = new MockERC20Oracle("Token B", "TKB");
        ConstantProductAMM amm = new ConstantProductAMM(address(tokenA), address(tokenB));

        uint256 seed = 5_000e18;
        tokenA.mint(OWNER, seed);
        tokenB.mint(OWNER, seed);

        vm.startPrank(OWNER);
        tokenA.approve(address(amm), seed);
        tokenB.approve(address(amm), seed);
        amm.addLiquidity(seed, seed, 0, 0, OWNER, block.timestamp + 1 hours);

        // Deploy vault with NO adapter (address(0))
        ERC4626Vault vault = new ERC4626Vault(address(amm), address(amm), address(0), OWNER);

        uint256 lpBal = amm.balanceOf(OWNER);
        ERC20(address(amm)).approve(address(vault), lpBal / 2);
        uint256 shares = vault.deposit(lpBal / 2, OWNER);
        vm.stopPrank();

        // Must revert with Vault__FeedNotSet
        vm.expectRevert();
        vault.getUsdValueOfShares(shares);
    }

    // ═════════════════════════════════════════════════════════════════
    // SECTION J — Cumulative / combined error scenarios
    // ═════════════════════════════════════════════════════════════════

    /// @notice All four bad-data conditions applied simultaneously.
    ///         The adapter must revert on the FIRST check it encounters —
    ///         either round-complete or price check depending on order.
    ///         We test each condition in isolation to confirm individual paths.
    function test_AllFourGuards_EachRevertIndependently() public {
        // ── [1] Incomplete round ──────────────────────────────────────
        ethFeed.updateRoundData(20, ETH_USD_PRICE_8DEC, block.timestamp, block.timestamp, 19);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceFeedAdapter.PriceFeed__RoundNotComplete.selector,
                address(ethFeed), uint80(20), uint80(19)
            )
        );
        adapter.getPrice(address(ethFeed));

        // ── [2] Zero price ────────────────────────────────────────────
        ethFeed.updateRoundData(21, 0, block.timestamp, block.timestamp, 21);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceFeedAdapter.PriceFeed__InvalidPrice.selector,
                address(ethFeed), int256(0)
            )
        );
        adapter.getPrice(address(ethFeed));

        // ── [3] updatedAt == 0 ────────────────────────────────────────
        ethFeed.updateRoundData(22, ETH_USD_PRICE_8DEC, block.timestamp, 0, 22);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceFeedAdapter.PriceFeed__InvalidRoundTimestamp.selector,
                address(ethFeed)
            )
        );
        adapter.getPrice(address(ethFeed));

        // ── [4] Stale ────────────────────────────────────────────────
        uint256 staleAt = block.timestamp - HEARTBEAT - 1;
        ethFeed.updateRoundData(23, ETH_USD_PRICE_8DEC, staleAt, staleAt, 23);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceFeedAdapter.PriceFeed__StalePrice.selector,
                address(ethFeed), staleAt, block.timestamp, HEARTBEAT
            )
        );
        adapter.getPrice(address(ethFeed));
    }
}
