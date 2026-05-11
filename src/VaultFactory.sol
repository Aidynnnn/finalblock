// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626VaultV1} from "./ERC4626VaultV1.sol";

/// @title  VaultFactory
/// @notice Deploys ERC1967 UUPS proxies for ERC4626VaultV1 (or any compatible
///         implementation) via two distinct mechanisms:
///
///         ┌────────────────────────────────────────────────────────────┐
///         │  deployVault(...)              — standard CREATE opcode    │
///         │  deployVaultDeterministic(...) — CREATE2 with user salt    │
///         └────────────────────────────────────────────────────────────┘
///
///         The factory is itself owner-controlled so the canonical
///         implementation address can be updated (e.g. to V2) after a
///         governance vote, without re-deploying the factory.
///
/// @dev    All proxies emitted by this factory point to the same
///         `implementation` address; each proxy stores its own independent
///         state in its own storage.
contract VaultFactory {

    // ────────────────────────────────────────────────────────────────
    // Storage
    // ────────────────────────────────────────────────────────────────

    /// @notice The UUPS implementation that newly deployed proxies delegate to.
    address public implementation;

    /// @notice Owner of the factory (may update the implementation).
    address public owner;

    /// @notice Registry of every proxy ever deployed by this factory.
    address[] private _allVaults;

    // ────────────────────────────────────────────────────────────────
    // Errors
    // ────────────────────────────────────────────────────────────────

    error Factory__ZeroAddress();
    error Factory__Unauthorized();
    error Factory__DeploymentFailed();
    error Factory__SaltAlreadyUsed(bytes32 salt);

    // ────────────────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────────────────

    /// @param proxy          Address of the newly created ERC1967Proxy.
    /// @param implementation Implementation the proxy was wired to.
    /// @param lpToken        Vault's underlying LP token.
    /// @param vaultOwner     Initial owner written into the vault's storage.
    event VaultDeployed(
        address indexed proxy,
        address indexed implementation,
        address indexed lpToken,
        address vaultOwner
    );

    /// @param proxy Deterministically deployed proxy address.
    /// @param salt  The user-supplied bytes32 salt.
    event VaultDeployedDeterministic(
        address indexed proxy,
        bytes32 indexed salt,
        address indexed implementation,
        address lpToken,
        address vaultOwner
    );

    event ImplementationUpdated(address indexed oldImpl, address indexed newImpl);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ────────────────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────────────────

    /// @param impl_         The initial ERC4626VaultV1 implementation address.
    /// @param initialOwner  Address that receives factory ownership.
    constructor(address impl_, address initialOwner) {
        if (impl_ == address(0) || initialOwner == address(0)) revert Factory__ZeroAddress();
        implementation = impl_;
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
        emit ImplementationUpdated(address(0), impl_);
    }

    // ────────────────────────────────────────────────────────────────
    // Modifier
    // ────────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert Factory__Unauthorized();
        _;
    }

    // ════════════════════════════════════════════════════════════════
    // Deployment: CREATE  (standard, address is nonce-dependent)
    // ════════════════════════════════════════════════════════════════

    /// @notice Deploy a new vault proxy using the standard CREATE opcode.
    ///         The resulting proxy address depends on this contract's nonce.
    ///
    /// @param lpToken      LP token that serves as the vault's underlying asset.
    /// @param ammAddress   ConstantProductAMM address paired with the LP token.
    /// @param adapter      Chainlink adapter (address(0) = configure later).
    /// @param vaultOwner   Address that becomes the vault's initial owner.
    /// @return proxy       Address of the deployed ERC1967Proxy.
    function deployVault(
        address lpToken,
        address ammAddress,
        address adapter,
        address vaultOwner
    ) external returns (address proxy) {
        if (lpToken    == address(0)) revert Factory__ZeroAddress();
        if (ammAddress == address(0)) revert Factory__ZeroAddress();
        if (vaultOwner == address(0)) revert Factory__ZeroAddress();

        bytes memory initData = _encodeInitCall(lpToken, ammAddress, adapter, vaultOwner);
        address impl = implementation;

        // CREATE: let Solidity pick the address (nonce-based).
        proxy = address(new ERC1967Proxy(impl, initData));

        _allVaults.push(proxy);
        emit VaultDeployed(proxy, impl, lpToken, vaultOwner);
    }

    // ════════════════════════════════════════════════════════════════
    // Deployment: CREATE2  (deterministic, address is salt-dependent)
    // ════════════════════════════════════════════════════════════════

    /// @notice Deploy a new vault proxy using CREATE2 with a user-supplied salt.
    ///         The proxy address is fully deterministic:
    ///             address = keccak256(0xff | factory | salt | keccak256(bytecode))
    ///         and can be predicted off-chain (or via `predictVaultAddress`) before
    ///         the transaction is sent.
    ///
    /// @param salt         Caller-chosen bytes32 salt; must be globally unique
    ///                     within this factory.
    /// @param lpToken      LP token that serves as the vault's underlying asset.
    /// @param ammAddress   ConstantProductAMM address paired with the LP token.
    /// @param adapter      Chainlink adapter (address(0) = configure later).
    /// @param vaultOwner   Address that becomes the vault's initial owner.
    /// @return proxy       Address of the deployed ERC1967Proxy.
    function deployVaultDeterministic(
        bytes32 salt,
        address lpToken,
        address ammAddress,
        address adapter,
        address vaultOwner
    ) external returns (address proxy) {
        if (lpToken    == address(0)) revert Factory__ZeroAddress();
        if (ammAddress == address(0)) revert Factory__ZeroAddress();
        if (vaultOwner == address(0)) revert Factory__ZeroAddress();

        bytes memory initData = _encodeInitCall(lpToken, ammAddress, adapter, vaultOwner);
        bytes memory bytecode = _proxyBytecode(implementation, initData);

        // CREATE2 via inline assembly — Solidity's `new` keyword does not
        // support CREATE2 with a runtime-provided salt.
        assembly {
            proxy := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        if (proxy == address(0)) revert Factory__DeploymentFailed();

        _allVaults.push(proxy);
        emit VaultDeployedDeterministic(proxy, salt, implementation, lpToken, vaultOwner);
    }

    // ════════════════════════════════════════════════════════════════
    // View: Predict CREATE2 Address
    // ════════════════════════════════════════════════════════════════

    /// @notice Off-chain (or on-chain) prediction of the CREATE2 proxy address.
    ///         Call this before `deployVaultDeterministic` to obtain the address
    ///         ahead of time (for pre-approvals, front-end display, etc.).
    ///
    /// @dev    Uses the standard CREATE2 formula:
    ///             address = last 20 bytes of
    ///             keccak256(0xff ++ factory ++ salt ++ keccak256(creationBytecode))
    ///
    /// @param salt       Must match the salt supplied to `deployVaultDeterministic`.
    /// @param lpToken    Must match the lpToken supplied at deployment.
    /// @param ammAddress Must match the ammAddress supplied at deployment.
    /// @param adapter    Must match the adapter supplied at deployment.
    /// @param vaultOwner Must match the vaultOwner supplied at deployment.
    /// @return predicted The address where the proxy will be deployed.
    function predictVaultAddress(
        bytes32 salt,
        address lpToken,
        address ammAddress,
        address adapter,
        address vaultOwner
    ) external view returns (address predicted) {
        bytes memory initData = _encodeInitCall(lpToken, ammAddress, adapter, vaultOwner);
        bytes32 bytecodeHash  = keccak256(_proxyBytecode(implementation, initData));

        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            bytecodeHash
        )))));
    }

    // ════════════════════════════════════════════════════════════════
    // Admin
    // ════════════════════════════════════════════════════════════════

    /// @notice Update the implementation address used for future proxy deployments.
    ///         Existing proxies are unaffected; they must be individually upgraded
    ///         via `ERC4626VaultV1.upgradeToAndCall`.
    function setImplementation(address newImpl) external onlyOwner {
        if (newImpl == address(0)) revert Factory__ZeroAddress();
        address old = implementation;
        implementation = newImpl;
        emit ImplementationUpdated(old, newImpl);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Factory__ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    // ════════════════════════════════════════════════════════════════
    // Views
    // ════════════════════════════════════════════════════════════════

    /// @notice Total number of vaults ever deployed by this factory.
    function allVaultsLength() external view returns (uint256) {
        return _allVaults.length;
    }

    /// @notice Returns the proxy address at `index` in the deployment registry.
    function allVaults(uint256 index) external view returns (address) {
        return _allVaults[index];
    }

    // ════════════════════════════════════════════════════════════════
    // Internal Helpers
    // ════════════════════════════════════════════════════════════════

    /// @dev ABI-encodes the `initialize(...)` call data passed to the proxy.
    function _encodeInitCall(
        address lpToken,
        address ammAddress,
        address adapter,
        address vaultOwner
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ERC4626VaultV1.initialize,
            (lpToken, ammAddress, adapter, vaultOwner)
        );
    }

    /// @dev Returns the full creation bytecode for an ERC1967Proxy instance.
    ///      Equivalent to `new ERC1967Proxy(impl, data)` but returned as bytes
    ///      so it can be hashed or fed to CREATE2.
    function _proxyBytecode(
        address impl,
        bytes memory initData
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(impl, initData)
        );
    }
}
