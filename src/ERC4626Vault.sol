// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20}            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata}    from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20}             from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20}         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626}           from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math}              from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard}   from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable}           from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable}          from "@openzeppelin/contracts/utils/Pausable.sol";

import {IPriceFeedAdapter} from "./ChainlinkPriceFeedAdapter.sol";
import {ConstantProductAMM} from "./AMM.sol";

/// @title  ERC4626Vault
/// @notice A yield-bearing vault that accepts AMM LP tokens as the underlying asset
///         and issues vault shares representing a proportional claim on those LP tokens.
///
/// ════════════════════════════════════════════════════════════════════
/// ERC-4626 STANDARD COMPLIANCE
/// ════════════════════════════════════════════════════════════════════
///
/// This contract inherits OpenZeppelin's ERC4626 base, which correctly implements the
/// entire EIP-4626 interface.  The critical area of compliance is rounding:
///
///   EIP-4626 mandates:
///     • convertToShares  → round DOWN  (favours the vault, protects existing holders)
///     • convertToAssets  → round DOWN  (favours the vault, protects existing holders)
///     • previewDeposit   → round DOWN  (must not over-deliver shares to depositors)
///     • previewMint      → round UP    (depositor must supply ≥ the true cost)
///     • previewWithdraw  → round UP    (depositor must burn ≥ the true share cost)
///     • previewRedeem    → round DOWN  (must not over-deliver assets to redeemers)
///
///   OZ ERC4626 handles this via Math.mulDiv with the correct rounding direction on
///   every conversion.  We do NOT override _convertToShares / _convertToAssets unless
///   we have a specific reason, ensuring compliance is inherited, not re-implemented.
///
/// ════════════════════════════════════════════════════════════════════
/// INFLATION ATTACK MITIGATION  (EIP-4626 §6)
/// ════════════════════════════════════════════════════════════════════
///
/// The classic "share price inflation" attack works by:
///   1. Attacker deposits 1 wei → receives 1 share.
///   2. Attacker donates a large amount of the underlying asset to the vault,
///      inflating totalAssets() without issuing shares.
///   3. The next depositor's `shares = assets * totalSupply / totalAssets` rounds
///      to 0, so the attacker steals their assets on the next step.
///
/// Our defence (virtual offset method, used by OZ ERC4626 ≥ v5):
///   _decimalsOffset() returns DECIMALS_OFFSET = 6, causing the share/asset
///   ratio to be computed as if the vault already holds 10^6 virtual assets and
///   has issued 1 virtual share.  Concretely:
///
///     shares = assets * (totalSupply + 10^offset) / (totalAssets + 1)
///
///   A dust-layer attack now requires the attacker to donate 10^6 times the target
///   deposit to move the rounding by 1, making the attack economically unviable.
///
/// ════════════════════════════════════════════════════════════════════
/// PRICE FEED INTEGRATION
/// ════════════════════════════════════════════════════════════════════
///
/// The vault integrates an optional Chainlink price feed adapter to report the
/// USD-denominated value of vault shares (for front-end display, risk scoring, etc.).
/// Price data is NEVER used in the deposit / withdrawal / share-conversion math —
/// those paths depend only on LP token balances, which are fully on-chain.
/// This separation is intentional: oracle failure never blocks withdrawals.
///
/// ════════════════════════════════════════════════════════════════════
/// SECURITY PROPERTIES
/// ════════════════════════════════════════════════════════════════════
///
///   • ReentrancyGuard on all state-mutating entry points (deposit, mint,
///     withdraw, redeem) as a belt-and-suspenders guard alongside CEI.
///   • Pausable circuit breaker (owner / Timelock) halts deposits and mints;
///     withdrawals and redeems are intentionally NOT paused so users can
///     always exit.
///   • SafeERC20 wraps every ERC-20 call (non-standard return values handled).
///   • No tx.origin usage.  No transfer()/send() (no ETH in vault).
///   • All access-controlled functions use Ownable; no unguarded admin paths.
///
/// @custom:security-contact security@yourprotocol.xyz
contract ERC4626Vault is ERC4626, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ────────────────────────────────────────────────────────────────
    // Constants
    // ────────────────────────────────────────────────────────────────

    /// @notice Decimal offset used by the virtual shares inflation-attack defence.
    ///         A value of 6 means 10^6 virtual underlying assets are assumed to exist,
    ///         raising the attack cost by a factor of 1,000,000.
    uint8 public constant DECIMALS_OFFSET = 6;

    // ────────────────────────────────────────────────────────────────
    // Custom errors
    // ────────────────────────────────────────────────────────────────

    /// @dev Minted shares were below the caller's minimum acceptable amount.
    error Vault__MinSharesNotMet(uint256 shares, uint256 minShares);

    /// @dev Assets returned were below the caller's minimum acceptable amount.
    error Vault__MinAssetsNotMet(uint256 assets, uint256 minAssets);

    /// @dev A zero-address was supplied where one is not allowed.
    error Vault__ZeroAddress();

    /// @dev An operation involving zero assets or shares was attempted.
    error Vault__ZeroAmount();

    /// @dev The caller tried to deposit or mint while the vault is paused.
    error Vault__Paused();

    /// @dev The price feed for the given asset has not been configured.
    error Vault__FeedNotSet(address asset);

    // ────────────────────────────────────────────────────────────────
    // Storage
    // ────────────────────────────────────────────────────────────────

    /// @notice The AMM whose LP token is the vault's underlying asset.
    ///         Stored for convenient access to pool reserves in USD valuation.
    ConstantProductAMM public immutable amm;

    /// @notice The Chainlink price feed adapter used for USD valuations.
    ///         NOT used in share math — only for external reporting.
    IPriceFeedAdapter public priceFeedAdapter;

    /// @notice Optional Chainlink feed addresses for token0 and token1 of the AMM.
    ///         Set by the owner; used only in getUsdValueOfShares().
    address public token0Feed;
    address public token1Feed;

    // ────────────────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────────────────

    /// @notice Emitted when the price feed adapter is updated.
    event PriceFeedAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    /// @notice Emitted when token0 or token1 feed addresses are set.
    event FeedsSet(address indexed token0Feed, address indexed token1Feed);

    // ────────────────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────────────────

    /// @param lpToken         The ConstantProductAMM LP token that is the vault asset.
    /// @param ammAddress      Address of the ConstantProductAMM (for reserve queries).
    /// @param adapter         Address of the ChainlinkPriceFeedAdapter (may be address(0)
    ///                        initially; set later via setPriceFeedAdapter).
    /// @param initialOwner    Receives the Ownable role.
    constructor(
        address lpToken,
        address ammAddress,
        address adapter,
        address initialOwner
    )
        ERC4626(IERC20(lpToken))
        ERC20("DeFiApp Vault Share", "DVLT")
        Ownable(initialOwner)
    {
        if (lpToken == address(0) || ammAddress == address(0)) revert Vault__ZeroAddress();
        if (initialOwner == address(0)) revert Vault__ZeroAddress();

        amm = ConstantProductAMM(ammAddress);

        // Adapter is optional at deploy time; can be address(0) until set.
        if (adapter != address(0)) {
            priceFeedAdapter = IPriceFeedAdapter(adapter);
        }
    }

    // ────────────────────────────────────────────────────────────────
    // ERC-4626 overrides: entry points with reentrancy + pause guards
    // ────────────────────────────────────────────────────────────────
    //
    // OZ ERC4626 base provides correct _deposit / _withdraw implementations.
    // We wrap the four public entry points with nonReentrant and (for writes)
    // the pause check, then delegate to super.
    //
    // CEI is upheld inside OZ's _deposit / _withdraw:
    //   1. Checks  — amount > 0, receiver != 0 (asserted by callers below)
    //   2. Effects — _mint / _burn share tokens
    //   3. Interactions — SafeERC20 transfer of the underlying asset
    //
    // We add explicit slippage parameters (minShares / minAssets) on top of the
    // standard EIP-4626 interface so integrators do not need a separate preview call.

    /// @notice Deposits `assets` LP tokens and mints vault shares to `receiver`.
    ///
    /// @param assets    Amount of LP tokens to deposit.
    /// @param receiver  Address that receives vault shares.
    /// @param minShares Minimum shares the caller accepts (slippage guard).
    /// @return shares   Actual shares minted.
    function deposit(uint256 assets, address receiver, uint256 minShares)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        // ── Checks ───────────────────────────────────────────────────
        if (assets == 0)          revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();

        shares = previewDeposit(assets);
        if (shares < minShares) revert Vault__MinSharesNotMet(shares, minShares);

        // ── Effects + Interactions ───────────────────────────────────
        // Delegate to OZ ERC4626._deposit which handles _mint then safeTransferFrom.
        // Passing `shares` computed above avoids a second previewDeposit call inside super.
        super.deposit(assets, receiver);
        // Note: super.deposit() calls previewDeposit() internally; the result matches
        // because no state changed between our call and super's call.
    }

    /// @notice Standard ERC-4626 deposit (no slippage param) kept for interface compliance.
    ///         Overridden to add reentrancy and pause guards.
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        shares = super.deposit(assets, receiver);
    }

    /// @notice Mints exactly `shares` vault shares by depositing the required assets.
    ///
    /// @param shares    Exact number of shares to mint.
    /// @param receiver  Recipient of the shares.
    /// @param maxAssets Maximum LP tokens the caller is willing to spend.
    /// @return assets   Actual LP tokens consumed.
    function mint(uint256 shares, address receiver, uint256 maxAssets)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        // ── Checks ───────────────────────────────────────────────────
        if (shares == 0)            revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();

        assets = previewMint(shares);
        if (assets > maxAssets) revert Vault__MinAssetsNotMet(assets, maxAssets);

        // ── Effects + Interactions ───────────────────────────────────
        super.mint(shares, receiver);
    }

    /// @notice Standard ERC-4626 mint — reentrancy + pause guard.
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (shares == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        assets = super.mint(shares, receiver);
    }

    /// @notice Withdraws exactly `assets` LP tokens by burning the required shares.
    ///         Withdrawals are NOT paused — users can always exit.
    ///
    /// @param assets    Exact LP tokens the caller wants back.
    /// @param receiver  Recipient of the LP tokens.
    /// @param owner_    Address whose shares are burned.
    /// @param maxShares Maximum shares the caller is willing to burn.
    /// @return shares   Actual shares burned.
    function withdraw(uint256 assets, address receiver, address owner_, uint256 maxShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        // ── Checks ───────────────────────────────────────────────────
        if (assets == 0)            revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();

        shares = previewWithdraw(assets);
        if (shares > maxShares) revert Vault__MinSharesNotMet(shares, maxShares);

        // ── Effects + Interactions ───────────────────────────────────
        super.withdraw(assets, receiver, owner_);
    }

    /// @notice Standard ERC-4626 withdraw — reentrancy guard only (no pause).
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        shares = super.withdraw(assets, receiver, owner_);
    }

    /// @notice Redeems exactly `shares` vault tokens for the corresponding LP tokens.
    ///         Redeems are NOT paused — users can always exit.
    ///
    /// @param shares    Exact shares to redeem.
    /// @param receiver  Recipient of the LP tokens.
    /// @param owner_    Address whose shares are burned.
    /// @param minAssets Minimum LP tokens the caller accepts.
    /// @return assets   Actual LP tokens returned.
    function redeem(uint256 shares, address receiver, address owner_, uint256 minAssets)
        external
        nonReentrant
        returns (uint256 assets)
    {
        // ── Checks ───────────────────────────────────────────────────
        if (shares == 0)            revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();

        assets = previewRedeem(shares);
        if (assets < minAssets) revert Vault__MinAssetsNotMet(assets, minAssets);

        // ── Effects + Interactions ───────────────────────────────────
        super.redeem(shares, receiver, owner_);
    }

    /// @notice Standard ERC-4626 redeem — reentrancy guard only (no pause).
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        assets = super.redeem(shares, receiver, owner_);
    }

    // ────────────────────────────────────────────────────────────────
    // ERC-4626 required overrides
    // ────────────────────────────────────────────────────────────────

    /// @inheritdoc ERC4626
    /// @dev Returns DECIMALS_OFFSET so OZ's share-conversion math uses the virtual
    ///      offset defence against LP share inflation attacks.
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    /// @notice Returns the share token's decimals.
    ///         EIP-4626 recommends share decimals = asset decimals + offset.
    function decimals()
        public
        view
        override
        returns (uint8)
    {
        // LP token decimals (18) + DECIMALS_OFFSET (6) = 24.
        // This is intentional and matches the offset used in share math.
        return IERC20Metadata(asset()).decimals() + DECIMALS_OFFSET;
    }

    // ────────────────────────────────────────────────────────────────
    // USD valuation (view only — NOT used in share math)
    // ────────────────────────────────────────────────────────────────

    /// @notice Returns the approximate USD value (18-decimal WAD) of `shares`
    ///         vault shares, using the Chainlink price feeds for the AMM's tokens.
    ///
    ///         Math:
    ///         ──────
    ///         1. Compute underlying LP tokens for `shares` via convertToAssets().
    ///         2. LP tokens represent a proportional share of the AMM pool:
    ///              lpFraction = lpAmount / lpTotalSupply
    ///         3. token0Value = lpFraction * reserve0 * price0
    ///            token1Value = lpFraction * reserve1 * price1
    ///         4. totalUsdValue = token0Value + token1Value
    ///
    ///         This function REVERTS if the price feed adapter is not set,
    ///         or if either feed reverts (stale price, round not complete, etc.).
    ///         Callers must handle the revert gracefully (e.g. display "N/A" in UI).
    ///
    /// @param shares    Number of vault shares to value.
    /// @return usdValue USD value in WAD (1e18 = $1.00).
    function getUsdValueOfShares(uint256 shares)
        external
        view
        returns (uint256 usdValue)
    {
        if (address(priceFeedAdapter) == address(0)) revert Vault__FeedNotSet(address(0));
        if (token0Feed == address(0)) revert Vault__FeedNotSet(address(amm.token0()));
        if (token1Feed == address(0)) revert Vault__FeedNotSet(address(amm.token1()));

        // Step 1: LP tokens corresponding to `shares`.
        uint256 lpAmount = convertToAssets(shares);
        if (lpAmount == 0) return 0;

        // Step 2: Pool reserves and LP total supply.
        (uint256 reserve0, uint256 reserve1) = amm.getReserves();
        uint256 lpSupply = IERC20(asset()).totalSupply();
        if (lpSupply == 0) return 0;

        // Step 3: Prices (already normalised to 18 decimals by the adapter).
        uint256 price0 = priceFeedAdapter.getPrice(token0Feed);
        uint256 price1 = priceFeedAdapter.getPrice(token1Feed);

        // Step 4: USD value.
        // All intermediate math uses WAD (1e18) scaling.
        // lpFraction is expressed as lpAmount * 1e18 / lpSupply (to keep precision).
        uint256 value0 = (lpAmount * reserve0).mulDiv(price0, lpSupply * 1e18, Math.Rounding.Floor);
        uint256 value1 = (lpAmount * reserve1).mulDiv(price1, lpSupply * 1e18, Math.Rounding.Floor);

        usdValue = value0 + value1;
    }

    // ────────────────────────────────────────────────────────────────
    // Admin: oracle configuration
    // ────────────────────────────────────────────────────────────────

    /// @notice Updates the price feed adapter address.
    ///         Expected to be called by the Timelock after a governance vote.
    ///
    /// @param adapter New ChainlinkPriceFeedAdapter address.
    function setPriceFeedAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert Vault__ZeroAddress();
        address old = address(priceFeedAdapter);
        priceFeedAdapter = IPriceFeedAdapter(adapter);
        emit PriceFeedAdapterUpdated(old, adapter);
    }

    /// @notice Sets the Chainlink feed addresses for the AMM's two tokens.
    ///         These feeds must be registered in the ChainlinkPriceFeedAdapter.
    ///
    /// @param _token0Feed AggregatorV3 address for token0 (e.g. ETH / USD).
    /// @param _token1Feed AggregatorV3 address for token1 (e.g. USDC / USD).
    function setFeeds(address _token0Feed, address _token1Feed) external onlyOwner {
        if (_token0Feed == address(0) || _token1Feed == address(0)) revert Vault__ZeroAddress();
        token0Feed = _token0Feed;
        token1Feed = _token1Feed;
        emit FeedsSet(_token0Feed, _token1Feed);
    }

    // ────────────────────────────────────────────────────────────────
    // Admin: circuit breaker
    // ────────────────────────────────────────────────────────────────

    /// @notice Pauses deposits and mints.  Withdrawals and redeems remain active.
    ///         Intended for emergency use by the owner (Timelock or multisig).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses deposits and mints.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ────────────────────────────────────────────────────────────────
    // Internal: pause guard hook
    // ────────────────────────────────────────────────────────────────

    /// @dev OZ ERC4626 calls _deposit for deposit() and mint().
    ///      We intercept here to enforce the pause on the base implementation path
    ///      (the overridden public functions already check whenNotPaused; this catches
    ///      any direct super calls that might bypass the modifier in edge cases).
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
    {
        if (paused()) revert Vault__Paused();
        super._deposit(caller, receiver, assets, shares);
    }

    // ────────────────────────────────────────────────────────────────
    // ERC-4626 rounding invariants — documentation
    // ────────────────────────────────────────────────────────────────
    //
    // The following ERC-4626 rounding invariants are guaranteed by OZ ERC4626 v5
    // and are NOT overridden here.  They are documented for audit purposes:
    //
    //   convertToShares(assets) rounds DOWN
    //     → shares = assets * (totalSupply + 10^offset) / (totalAssets + 1)
    //       Rounding: Math.Rounding.Floor
    //
    //   convertToAssets(shares) rounds DOWN
    //     → assets = shares * (totalAssets + 1) / (totalSupply + 10^offset)
    //       Rounding: Math.Rounding.Floor
    //
    //   previewDeposit(assets) = convertToShares(assets)       [rounds DOWN]
    //   previewMint(shares)    = convertToAssets(shares) + 1   [rounds UP via Ceil]
    //   previewWithdraw(assets)= convertToShares(assets) + 1   [rounds UP via Ceil]
    //   previewRedeem(shares)  = convertToAssets(shares)       [rounds DOWN]
    //
    // The +1 on Ceil paths ensures the vault is never short-changed: depositors
    // always pay slightly more than the theoretical cost, and redeemers always
    // receive slightly less than the theoretical return.  This is required by EIP-4626.
    //
    // The virtual offset (10^DECIMALS_OFFSET in the denominator/numerator) raises
    // the cost of a LP share inflation attack to economically impractical levels.
}
