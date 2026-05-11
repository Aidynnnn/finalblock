// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─── OpenZeppelin non-upgradeable utilities (already in lib/) ────────────────
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// ─── UUPS infrastructure (in lib/openzeppelin-contracts/contracts/proxy/) ─────
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

// ─── Project contracts ────────────────────────────────────────────────────────
import {IPriceFeedAdapter} from "./ChainlinkPriceFeedAdapter.sol";
import {ConstantProductAMM} from "./AMM.sol";

/// @title  ERC4626VaultV1
/// @notice UUPS-upgradeable ERC-4626 vault wrapping AMM LP tokens.
///
/// ════════════════════════════════════════════════════════════════════
/// UPGRADE ARCHITECTURE
/// ════════════════════════════════════════════════════════════════════
///
/// Because `openzeppelin-contracts-upgradeable` is not a project dependency,
/// this contract adopts the modern ERC-7201 namespaced-storage pattern used
/// by OZ's own upgradeable contracts internally:
///
///   • All mutable state lives in a single `VaultV1Storage` struct mapped to
///     a unique ERC-7201 storage slot.  No inheritance from storage-bearing
///     base contracts (ERC20, ERC4626, Ownable …) — those are implemented
///     directly via the struct.
///
///   • `Initializable` and `UUPSUpgradeable` are imported from the existing
///     non-upgradeable OZ package — they carry no mutable slot-0 state and
///     are safe to use as UUPS infrastructure.
///
///   • The implementation constructor calls `_disableInitializers()` so the
///     bare implementation can never be used directly.
///
///   • V2 (and later) upgrades add their own storage namespace at a different
///     ERC-7201 slot, leaving V1's layout untouched.
///
/// ════════════════════════════════════════════════════════════════════
/// ERC-4626 COMPLIANCE & INFLATION-ATTACK MITIGATION
/// ════════════════════════════════════════════════════════════════════
///
///   Rounding is identical to the original non-upgradeable vault:
///     convertToShares  / previewDeposit   → Floor
///     convertToAssets  / previewRedeem    → Floor
///     previewMint      / previewWithdraw  → Ceil
///
///   Virtual-offset defence: DECIMALS_OFFSET = 6 means the share/asset ratio
///   is computed as if 10^6 virtual assets exist, raising the donation cost
///   for a share-inflation attack by a factor of 1,000,000.
///
/// @custom:security-contact security@yourprotocol.xyz
contract ERC4626VaultV1 is Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ────────────────────────────────────────────────────────────────
    // Constants
    // ────────────────────────────────────────────────────────────────

    uint8 public constant DECIMALS_OFFSET = 6;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ────────────────────────────────────────────────────────────────
    // ERC-7201 Namespaced Storage
    // ────────────────────────────────────────────────────────────────

    /// @custom:storage-location erc7201:bcht2.storage.ERC4626VaultV1
    struct VaultV1Storage {
        // ── ERC-20 ────────────────────────────────────────────────────
        string name;
        string symbol;
        uint256 totalSupply;
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;

        // ── ERC-4626 ──────────────────────────────────────────────────
        IERC20 asset;
        uint8 underlyingDecimals;

        // ── Ownable ───────────────────────────────────────────────────
        address owner;

        // ── Pausable ──────────────────────────────────────────────────
        bool paused;

        // ── ReentrancyGuard ───────────────────────────────────────────
        uint256 reentrancyStatus;

        // ── Vault-specific ────────────────────────────────────────────
        ConstantProductAMM amm;
        IPriceFeedAdapter priceFeedAdapter;
        address token0Feed;
        address token1Feed;
    }

    /// @dev Returns a pointer to the V1 storage struct.
    ///      Slot = keccak256(abi.encode(uint256(keccak256("bcht2.storage.ERC4626VaultV1")) - 1))
    ///             & ~bytes32(uint256(0xff))   — ERC-7201 formula.
    ///      Computing it in a `pure` function (valid: no state reads) avoids
    ///      needing to pre-compute and hard-code a hex constant.
    function _getVaultStorage() internal pure returns (VaultV1Storage storage $) {
        bytes32 slot =
            keccak256(abi.encode(uint256(keccak256("bcht2.storage.ERC4626VaultV1")) - 1)) & ~bytes32(uint256(0xff));
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := slot
        }
    }

    // ────────────────────────────────────────────────────────────────
    // Custom Errors
    // ────────────────────────────────────────────────────────────────

    // Vault-level
    error Vault__MinSharesNotMet(uint256 shares, uint256 minShares);
    error Vault__MinAssetsNotMet(uint256 assets, uint256 minAssets);
    error Vault__ZeroAddress();
    error Vault__ZeroAmount();
    error Vault__Paused();
    error Vault__NotPaused();
    error Vault__Unauthorized();
    error Vault__FeedNotSet(address asset);
    error Vault__ReentrantCall();

    // ERC-20 (mirrors OZ draft-IERC6093)
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);

    // ERC-4626 (mirrors OZ draft-IERC6093)
    error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
    error ERC4626ExceededMaxMint(address receiver, uint256 shares, uint256 max);
    error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

    // ────────────────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────────────────

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Unpaused(address account);

    event PriceFeedAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event FeedsSet(address indexed token0Feed, address indexed token1Feed);

    // ────────────────────────────────────────────────────────────────
    // Modifiers
    // ────────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != _getVaultStorage().owner) revert Vault__Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (_getVaultStorage().paused) revert Vault__Paused();
        _;
    }

    modifier nonReentrant() {
        VaultV1Storage storage $ = _getVaultStorage();
        if ($.reentrancyStatus == _ENTERED) revert Vault__ReentrantCall();
        $.reentrancyStatus = _ENTERED;
        _;
        $.reentrancyStatus = _NOT_ENTERED;
    }

    // ────────────────────────────────────────────────────────────────
    // Constructor — disables the implementation from being initialized
    // ────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ────────────────────────────────────────────────────────────────
    // Initializer (called once via the proxy constructor)
    // ────────────────────────────────────────────────────────────────

    /// @notice Initialises the vault proxy.  Must be called exactly once,
    ///         atomically with proxy deployment (via ERC1967Proxy's `_data` arg).
    ///
    /// @param lpToken       ERC-20 LP token that is the vault's underlying asset.
    /// @param ammAddress    ConstantProductAMM address (for reserve queries).
    /// @param adapter       Chainlink price-feed adapter; pass address(0) to skip.
    /// @param initialOwner  Address that receives the Owner role.
    function initialize(address lpToken, address ammAddress, address adapter, address initialOwner)
        external
        initializer
    {
        if (lpToken == address(0) || ammAddress == address(0)) revert Vault__ZeroAddress();
        if (initialOwner == address(0)) revert Vault__ZeroAddress();

        VaultV1Storage storage $ = _getVaultStorage();

        // ERC-20
        $.name = "DeFiApp Vault Share";
        $.symbol = "DVLT";

        // ERC-4626
        $.asset = IERC20(lpToken);
        $.underlyingDecimals = _tryGetAssetDecimals(IERC20Metadata(lpToken));

        // Ownable
        $.owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);

        // ReentrancyGuard
        $.reentrancyStatus = _NOT_ENTERED;

        // Vault-specific
        $.amm = ConstantProductAMM(ammAddress);
        if (adapter != address(0)) {
            $.priceFeedAdapter = IPriceFeedAdapter(adapter);
        }
    }

    // ────────────────────────────────────────────────────────────────
    // UUPS: upgrade authorisation
    // ────────────────────────────────────────────────────────────────

    /// @notice Restricts upgrade execution to the current owner / timelock.
    /// @dev    Called by `upgradeToAndCall` in `UUPSUpgradeable`.
    function _authorizeUpgrade(
        address /*newImplementation*/
    )
        internal
        override
        onlyOwner
    {}

    // ────────────────────────────────────────────────────────────────
    // Version
    // ────────────────────────────────────────────────────────────────

    function version() public pure virtual returns (string memory) {
        return "1.0.0";
    }

    // ════════════════════════════════════════════════════════════════
    // ERC-20 Interface
    // ════════════════════════════════════════════════════════════════

    function name() public view returns (string memory) {
        return _getVaultStorage().name;
    }

    function symbol() public view returns (string memory) {
        return _getVaultStorage().symbol;
    }

    /// @notice Share decimals = underlying LP decimals + DECIMALS_OFFSET.
    function decimals() public view returns (uint8) {
        return _getVaultStorage().underlyingDecimals + DECIMALS_OFFSET;
    }

    function totalSupply() public view returns (uint256) {
        return _getVaultStorage().totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _getVaultStorage().balances[account];
    }

    function allowance(address owner_, address spender) public view returns (uint256) {
        return _getVaultStorage().allowances[owner_][spender];
    }

    function transfer(address to, uint256 value) public returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    // ════════════════════════════════════════════════════════════════
    // ERC-4626 View Functions
    // ════════════════════════════════════════════════════════════════

    function asset() public view returns (address) {
        return address(_getVaultStorage().asset);
    }

    function totalAssets() public view returns (uint256) {
        return _getVaultStorage().asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function maxDeposit(address) public view virtual returns (uint256) {
        return _getVaultStorage().paused ? 0 : type(uint256).max;
    }

    function maxMint(address) public view virtual returns (uint256) {
        return _getVaultStorage().paused ? 0 : type(uint256).max;
    }

    function maxWithdraw(address owner_) public view returns (uint256) {
        return _convertToAssets(balanceOf(owner_), Math.Rounding.Floor);
    }

    function maxRedeem(address owner_) public view returns (uint256) {
        return balanceOf(owner_);
    }

    // ════════════════════════════════════════════════════════════════
    // ERC-4626 Deposit / Mint  (with + without slippage guard)
    // ════════════════════════════════════════════════════════════════

    /// @notice Deposit `assets` LP tokens; revert if minted shares < `minShares`.
    function deposit(uint256 assets, address receiver, uint256 minShares)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        shares = previewDeposit(assets);
        if (shares < minShares) revert Vault__MinSharesNotMet(shares, minShares);
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Standard ERC-4626 deposit (no slippage param).
    function deposit(uint256 assets, address receiver) public nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Mint exactly `shares`; revert if required assets > `maxAssets`.
    function mint(uint256 shares, address receiver, uint256 maxAssets)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (shares == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        assets = previewMint(shares);
        if (assets > maxAssets) revert Vault__MinAssetsNotMet(assets, maxAssets);
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Standard ERC-4626 mint (no slippage param).
    function mint(uint256 shares, address receiver) public nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        assets = previewMint(shares);
        _deposit(msg.sender, receiver, assets, shares);
    }

    // ════════════════════════════════════════════════════════════════
    // ERC-4626 Withdraw / Redeem  (intentionally NOT paused)
    // ════════════════════════════════════════════════════════════════

    /// @notice Withdraw `assets` LP tokens; revert if shares burned > `maxShares`.
    function withdraw(uint256 assets, address receiver, address owner_, uint256 maxShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        shares = previewWithdraw(assets);
        if (shares > maxShares) revert Vault__MinSharesNotMet(shares, maxShares);
        _withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @notice Standard ERC-4626 withdraw (no slippage param).
    function withdraw(uint256 assets, address receiver, address owner_) public nonReentrant returns (uint256 shares) {
        if (assets == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        uint256 maxAssets = maxWithdraw(owner_);
        if (assets > maxAssets) revert ERC4626ExceededMaxWithdraw(owner_, assets, maxAssets);
        shares = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @notice Redeem `shares`; revert if assets received < `minAssets`.
    function redeem(uint256 shares, address receiver, address owner_, uint256 minAssets)
        external
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        assets = previewRedeem(shares);
        if (assets < minAssets) revert Vault__MinAssetsNotMet(assets, minAssets);
        _withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @notice Standard ERC-4626 redeem (no slippage param).
    function redeem(uint256 shares, address receiver, address owner_) public nonReentrant returns (uint256 assets) {
        if (shares == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();
        uint256 maxShares = maxRedeem(owner_);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(owner_, shares, maxShares);
        assets = previewRedeem(shares);
        _withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    // ════════════════════════════════════════════════════════════════
    // USD Valuation  (view-only, oracle-dependent — NOT used in share math)
    // ════════════════════════════════════════════════════════════════

    /// @notice Approximate USD value (18-decimal WAD) of `shares` vault shares.
    ///         Reverts if price feeds are not configured or stale.
    function getUsdValueOfShares(uint256 shares) external view returns (uint256 usdValue) {
        VaultV1Storage storage $ = _getVaultStorage();
        if (address($.priceFeedAdapter) == address(0)) revert Vault__FeedNotSet(address(0));
        if ($.token0Feed == address(0)) revert Vault__FeedNotSet(address($.amm.token0()));
        if ($.token1Feed == address(0)) revert Vault__FeedNotSet(address($.amm.token1()));

        uint256 lpAmount = convertToAssets(shares);
        if (lpAmount == 0) return 0;

        (uint256 reserve0, uint256 reserve1) = $.amm.getReserves();
        uint256 lpSupply = IERC20(asset()).totalSupply();
        if (lpSupply == 0) return 0;

        uint256 price0 = $.priceFeedAdapter.getPrice($.token0Feed);
        uint256 price1 = $.priceFeedAdapter.getPrice($.token1Feed);

        uint256 value0 = (lpAmount * reserve0).mulDiv(price0, lpSupply * 1e18, Math.Rounding.Floor);
        uint256 value1 = (lpAmount * reserve1).mulDiv(price1, lpSupply * 1e18, Math.Rounding.Floor);
        usdValue = value0 + value1;
    }

    // ════════════════════════════════════════════════════════════════
    // Ownable
    // ════════════════════════════════════════════════════════════════

    function owner() public view returns (address) {
        return _getVaultStorage().owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Vault__ZeroAddress();
        VaultV1Storage storage $ = _getVaultStorage();
        emit OwnershipTransferred($.owner, newOwner);
        $.owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        VaultV1Storage storage $ = _getVaultStorage();
        emit OwnershipTransferred($.owner, address(0));
        $.owner = address(0);
    }

    // ════════════════════════════════════════════════════════════════
    // Pausable
    // ════════════════════════════════════════════════════════════════

    function paused() public view returns (bool) {
        return _getVaultStorage().paused;
    }

    /// @notice Pauses deposits and mints.  Withdrawals always remain open.
    function pause() external onlyOwner {
        VaultV1Storage storage $ = _getVaultStorage();
        if ($.paused) revert Vault__Paused();
        $.paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        VaultV1Storage storage $ = _getVaultStorage();
        if (!$.paused) revert Vault__NotPaused();
        $.paused = false;
        emit Unpaused(msg.sender);
    }

    // ════════════════════════════════════════════════════════════════
    // Admin: Oracle Configuration
    // ════════════════════════════════════════════════════════════════

    function amm() external view returns (ConstantProductAMM) {
        return _getVaultStorage().amm;
    }

    function priceFeedAdapter() external view returns (IPriceFeedAdapter) {
        return _getVaultStorage().priceFeedAdapter;
    }

    function token0Feed() external view returns (address) {
        return _getVaultStorage().token0Feed;
    }

    function token1Feed() external view returns (address) {
        return _getVaultStorage().token1Feed;
    }

    function setPriceFeedAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert Vault__ZeroAddress();
        VaultV1Storage storage $ = _getVaultStorage();
        address old = address($.priceFeedAdapter);
        $.priceFeedAdapter = IPriceFeedAdapter(adapter);
        emit PriceFeedAdapterUpdated(old, adapter);
    }

    function setFeeds(address _token0Feed, address _token1Feed) external onlyOwner {
        if (_token0Feed == address(0) || _token1Feed == address(0)) revert Vault__ZeroAddress();
        VaultV1Storage storage $ = _getVaultStorage();
        $.token0Feed = _token0Feed;
        $.token1Feed = _token1Feed;
        emit FeedsSet(_token0Feed, _token1Feed);
    }

    // ════════════════════════════════════════════════════════════════
    // Internal: ERC-20 primitives
    // ════════════════════════════════════════════════════════════════

    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) revert ERC20InvalidSender(from);
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        _update(from, to, value);
    }

    function _mint(address account, uint256 value) internal {
        if (account == address(0)) revert ERC20InvalidReceiver(account);
        _update(address(0), account, value);
    }

    function _burn(address account, uint256 value) internal {
        if (account == address(0)) revert ERC20InvalidSender(account);
        _update(account, address(0), value);
    }

    function _update(address from, address to, uint256 value) internal {
        VaultV1Storage storage $ = _getVaultStorage();
        if (from == address(0)) {
            $.totalSupply += value;
        } else {
            uint256 bal = $.balances[from];
            if (bal < value) revert ERC20InsufficientBalance(from, bal, value);
            unchecked {
                $.balances[from] = bal - value;
            }
        }
        if (to == address(0)) {
            unchecked {
                $.totalSupply -= value;
            }
        } else {
            unchecked {
                $.balances[to] += value;
            }
        }
        emit Transfer(from, to, value);
    }

    function _approve(address owner_, address spender, uint256 value) internal {
        if (owner_ == address(0)) revert ERC20InvalidApprover(owner_);
        if (spender == address(0)) revert ERC20InvalidSpender(spender);
        _getVaultStorage().allowances[owner_][spender] = value;
        emit Approval(owner_, spender, value);
    }

    function _spendAllowance(address owner_, address spender, uint256 value) internal {
        uint256 current = allowance(owner_, spender);
        if (current != type(uint256).max) {
            if (current < value) revert ERC20InsufficientAllowance(spender, current, value);
            unchecked {
                _approve(owner_, spender, current - value);
            }
        }
    }

    // ════════════════════════════════════════════════════════════════
    // Internal: ERC-4626 primitives
    // ════════════════════════════════════════════════════════════════

    /// @dev Returns DECIMALS_OFFSET for the virtual-share inflation defence.
    function _decimalsOffset() internal pure virtual returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** uint256(_decimalsOffset()), totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** uint256(_decimalsOffset()), rounding);
    }

    /// @dev CEI: effects (_mint) before interactions (safeTransferFrom).
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual {
        _mint(receiver, shares);
        _getVaultStorage().asset.safeTransferFrom(caller, address(this), assets);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev CEI: effects (_burn) before interactions (safeTransfer).
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        virtual
    {
        if (caller != owner_) {
            _spendAllowance(owner_, caller, shares);
        }
        _burn(owner_, shares);
        _getVaultStorage().asset.safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, owner_, assets, shares);
    }

    // ════════════════════════════════════════════════════════════════
    // Internal: helpers
    // ════════════════════════════════════════════════════════════════

    function _tryGetAssetDecimals(IERC20Metadata token_) private view returns (uint8) {
        try token_.decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    // ════════════════════════════════════════════════════════════════
    // Yul Math Engine
    // ════════════════════════════════════════════════════════════════
    //
    // These functions are a direct, gas-optimised counterpart to the
    // Solidity _convertToShares / _convertToAssets paths above and are
    // exposed as public preview*Yul() functions for benchmarking.
    //
    // ALGORITHM — two-phase mulDiv
    // ─────────────────────────────────────────────────────────────────
    // Both Floor and Ceil share the same 512-bit multiply foundation
    // (identical to OZ Math.mulDiv / mul512):
    //
    //   [hi, lo] = x * y           — lo via MUL, hi via CRT with MULMOD
    //
    //   Phase 1 — fast path (hi == 0, i.e. x*y < 2^256):
    //     Floor: result = lo / d                                  (DIV, 5 gas)
    //     Ceil:  result = lo / d + (lo % d != 0)          (DIV+MOD, 10 gas)
    //                                                    ↑ MOD = 5 gas
    //   Phase 2 — slow path (hi > 0, exact 512-bit division):
    //     Subtract mulmod remainder, factor twos, Newton-Raphson
    //     inversion — identical to OZ, same gas cost as baseline.
    //
    // KEY OPTIMISATION vs OZ mulDiv(…, Ceil):
    // ─────────────────────────────────────────────────────────────────
    // OZ computes Ceil as: mulDiv(x,y,d) + (mulmod(x,y,d) > 0 ? 1 : 0)
    // This calls MULMOD *twice* — once inside mul512 (with not(0)) and
    // once explicitly with d.  MULMOD costs 8 gas.
    //
    // In the fast path _yulMulDivCeil uses MOD(lo, d) instead of a
    // second MULMOD(x, y, d).  Since lo = x*y exactly (no overflow),
    // MOD(lo, d) == MULMOD(x, y, d).  MOD costs 5 gas → saves 3 gas
    // per Ceil conversion (previewMint, previewWithdraw).
    //
    // Additionally, the two dedicated functions (_yulMulDivFloor /
    // _yulMulDivCeil) avoid the Math.Rounding enum branch that the
    // combined Solidity path evaluates on every call.
    // ════════════════════════════════════════════════════════════════

    /// @dev Yul-optimised floor(x * y / d).
    ///      Reverts on zero denominator or result overflow (same as OZ).
    function _yulMulDivFloor(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        assembly ("memory-safe") {
            // ── Guard ──────────────────────────────────────────────────
            if iszero(d) { revert(0, 0) }

            // ── 512-bit product [hi, lo] = x * y ──────────────────────
            // CRT decomposition identical to OZ mul512:
            //   lo = x*y mod 2^256          (EVM MUL opcode)
            //   mm = x*y mod (2^256 - 1)    (EVM MULMOD with modulus = not(0))
            //   hi = high 256 bits, derived via hi = mm - lo - borrow
            let lo := mul(x, y)
            let mm := mulmod(x, y, not(0))
            let hi := sub(sub(mm, lo), lt(mm, lo))

            // ── Two-phase switch ───────────────────────────────────────
            // `leave` is only valid inside a named Yul function; using
            // switch/case avoids restructuring into a nested function.
            switch iszero(hi)
            case 1 {
                // Fast path: product fits in 256 bits — plain DIV.
                result := div(lo, d)
            }
            default {
                // ── Overflow guard (result > 2^256 would corrupt) ──────
                if iszero(lt(hi, d)) { revert(0, 0) }

                // ── Exact remainder r = (x*y) mod d ───────────────────
                let r := mulmod(x, y, d)

                // ── Subtract r from [hi, lo] with carry ───────────────
                hi := sub(hi, gt(r, lo))
                lo := sub(lo, r)

                // ── Factor all powers-of-2 out of d ───────────────────
                // twos = d & -d  isolates the lowest set bit of d
                let twos := and(d, sub(0, d))
                d := div(d, twos) // d is now odd
                lo := div(lo, twos) // right-shift lo

                // Merge high bits via 2^256/twos.
                // sub(0,twos)/twos = 2^256/twos - 1; add 1 gives 2^256/twos
                // (wraps to 0 when twos=1, which is harmless).
                twos := add(div(sub(0, twos), twos), 1)
                lo := or(lo, mul(hi, twos))

                // ── Modular inverse of d (now odd) mod 2^256 ──────────
                // Seed: (3*d) XOR 2  ->  d*inv = 1 (mod 2^4)
                let inv := xor(mul(3, d), 2)
                // Newton-Raphson: each step doubles accurate bits
                // 4 -> 8 -> 16 -> 32 -> 64 -> 128 -> 256
                inv := mul(inv, sub(2, mul(d, inv))) // mod 2^8
                inv := mul(inv, sub(2, mul(d, inv))) // mod 2^16
                inv := mul(inv, sub(2, mul(d, inv))) // mod 2^32
                inv := mul(inv, sub(2, mul(d, inv))) // mod 2^64
                inv := mul(inv, sub(2, mul(d, inv))) // mod 2^128
                inv := mul(inv, sub(2, mul(d, inv))) // mod 2^256

                result := mul(lo, inv)
            }
        }
    }

    /// @dev Yul-optimised ceil(x * y / d).
    ///      Fast-path savings: uses MOD (5 gas) instead of a second
    ///      MULMOD (8 gas) to detect whether rounding-up is needed.
    function _yulMulDivCeil(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        assembly ("memory-safe") {
            if iszero(d) { revert(0, 0) }

            let lo := mul(x, y)
            let mm := mulmod(x, y, not(0))
            let hi := sub(sub(mm, lo), lt(mm, lo))

            switch iszero(hi)
            case 1 {
                // ── Fast path ──────────────────────────────────────────
                // No overflow: lo = x*y exactly.
                // Ceil = lo/d + (lo mod d != 0 ? 1 : 0)
                // Key: MOD opcode (5 gas) replaces a second MULMOD (8 gas),
                // saving 3 gas per Ceil conversion vs the OZ baseline.
                let q := div(lo, d)
                result := add(q, gt(mod(lo, d), 0))
            }
            default {
                // ── Overflow guard ─────────────────────────────────────
                if iszero(lt(hi, d)) { revert(0, 0) }

                // ── Remainder for ceiling adjustment ───────────────────
                let r := mulmod(x, y, d)
                let addOne := gt(r, 0)

                // ── Subtract r from [hi, lo] ───────────────────────────
                hi := sub(hi, gt(r, lo))
                lo := sub(lo, r)

                // ── Factor + Newton-Raphson (same as Floor slow path) ──
                let twos := and(d, sub(0, d))
                d := div(d, twos)
                lo := div(lo, twos)
                twos := add(div(sub(0, twos), twos), 1)
                lo := or(lo, mul(hi, twos))

                let inv := xor(mul(3, d), 2)
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))

                result := add(mul(lo, inv), addOne)
            }
        }
    }

    // ─── Internal view wrappers ──────────────────────────────────────

    /// @dev Yul-backed _convertToShares: picks Floor or Ceil branch
    ///      without the Math.Rounding enum overhead of the Solidity path.
    function _convertToSharesYul(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        uint256 supply = totalSupply() + 10 ** uint256(_decimalsOffset());
        uint256 assets_ = totalAssets() + 1;
        if (rounding == Math.Rounding.Ceil) {
            return _yulMulDivCeil(assets, supply, assets_);
        }
        return _yulMulDivFloor(assets, supply, assets_);
    }

    /// @dev Yul-backed _convertToAssets: picks Floor or Ceil branch.
    function _convertToAssetsYul(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        uint256 assets_ = totalAssets() + 1;
        uint256 supply = totalSupply() + 10 ** uint256(_decimalsOffset());
        if (rounding == Math.Rounding.Ceil) {
            return _yulMulDivCeil(shares, assets_, supply);
        }
        return _yulMulDivFloor(shares, assets_, supply);
    }

    // ─── Public Yul preview functions (for benchmarking) ────────────

    /// @notice Yul counterpart to previewDeposit (Floor rounding).
    function previewDepositYul(uint256 assets) public view returns (uint256) {
        return _convertToSharesYul(assets, Math.Rounding.Floor);
    }

    /// @notice Yul counterpart to previewMint (Ceil rounding).
    ///         Saves 3 gas vs Solidity path by using MOD instead of MULMOD.
    function previewMintYul(uint256 shares) public view returns (uint256) {
        return _convertToAssetsYul(shares, Math.Rounding.Ceil);
    }

    /// @notice Yul counterpart to previewWithdraw (Ceil rounding).
    function previewWithdrawYul(uint256 assets) public view returns (uint256) {
        return _convertToSharesYul(assets, Math.Rounding.Ceil);
    }

    /// @notice Yul counterpart to previewRedeem (Floor rounding).
    function previewRedeemYul(uint256 shares) public view returns (uint256) {
        return _convertToAssetsYul(shares, Math.Rounding.Floor);
    }

    // ─── Public pure helpers for isolated math benchmarking ─────────
    //     These take all inputs directly (no storage reads) so gas
    //     measurements isolate the arithmetic cost alone.

    /// @notice Solidity mulDiv — baseline for the gas report.
    function mathSolidity(uint256 x, uint256 y, uint256 d, bool ceil) public pure returns (uint256) {
        return ceil ? x.mulDiv(y, d, Math.Rounding.Ceil) : x.mulDiv(y, d, Math.Rounding.Floor);
    }

    /// @notice Yul mulDiv — optimised path for the gas report.
    function mathYul(uint256 x, uint256 y, uint256 d, bool ceil) public pure returns (uint256) {
        return ceil ? _yulMulDivCeil(x, y, d) : _yulMulDivFloor(x, y, d);
    }
}
