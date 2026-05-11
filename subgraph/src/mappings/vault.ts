import { BigInt, Bytes, Address } from "@graphprotocol/graph-ts";
import {
  VaultDeployed,
  VaultDeployedDeterministic,
} from "../../../generated/VaultFactory/VaultFactory";
import {
  Deposit,
  Withdraw,
  Paused,
  Unpaused,
  PriceFeedAdapterUpdated,
} from "../../../generated/templates/ERC4626VaultV1Template/ERC4626VaultV1";
import { ERC4626VaultV1Template } from "../../../generated/templates";
import { VaultFactory, Vault, VaultDeposit, VaultWithdrawal, ProtocolDayData } from "../../../generated/schema";

// ─────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────

function dayId(timestamp: BigInt): string {
  let dayStart = timestamp.div(BigInt.fromI32(86400)).times(BigInt.fromI32(86400));
  return dayStart.toString();
}

function loadOrCreateDayData(timestamp: BigInt): ProtocolDayData {
  let id = dayId(timestamp);
  let data = ProtocolDayData.load(id);
  if (data == null) {
    data = new ProtocolDayData(id);
    let dayStart = timestamp.div(BigInt.fromI32(86400)).times(BigInt.fromI32(86400));
    data.date                = dayStart;
    data.dailySwapCount      = BigInt.zero();
    data.dailyVolumeToken0   = BigInt.zero();
    data.dailyVolumeToken1   = BigInt.zero();
    data.dailyDepositCount   = BigInt.zero();
    data.dailyWithdrawalCount= BigInt.zero();
    data.dailyProposalCount  = BigInt.zero();
    data.dailyVoteCount      = BigInt.zero();
  }
  return data as ProtocolDayData;
}

function loadOrCreateFactory(address: string): VaultFactory {
  let factory = VaultFactory.load(address);
  if (factory == null) {
    factory = new VaultFactory(address);
    factory.owner          = Bytes.fromHexString("0x0000000000000000000000000000000000000000");
    factory.implementation = Bytes.fromHexString("0x0000000000000000000000000000000000000000");
    factory.vaultCount     = BigInt.zero();
  }
  return factory as VaultFactory;
}

function createVault(
  proxyAddress: string,
  factoryAddress: string,
  lpToken: Address,
  block: BigInt,
  timestamp: BigInt
): void {
  // Start indexing events emitted by the new proxy.
  ERC4626VaultV1Template.create(Address.fromString(proxyAddress));

  let vault = new Vault(proxyAddress);
  vault.factory               = factoryAddress;
  vault.lpToken               = lpToken;
  vault.paused                = false;
  vault.priceFeedAdapter      = null;
  vault.totalAssetsDeposited  = BigInt.zero();
  vault.totalSharesMinted     = BigInt.zero();
  vault.totalAssetsWithdrawn  = BigInt.zero();
  vault.totalSharesBurned     = BigInt.zero();
  vault.depositCount          = BigInt.zero();
  vault.withdrawalCount       = BigInt.zero();
  vault.createdAtBlock        = block;
  vault.createdAtTimestamp    = timestamp;
  vault.save();
}

// ─────────────────────────────────────────────────────────────────
// VaultFactory event handlers
// ─────────────────────────────────────────────────────────────────

export function handleVaultDeployed(event: VaultDeployed): void {
  let factoryAddress = event.address.toHexString();
  let factory = loadOrCreateFactory(factoryAddress);
  factory.implementation = event.params.implementation;
  factory.vaultCount     = factory.vaultCount.plus(BigInt.fromI32(1));
  factory.save();

  createVault(
    event.params.proxy.toHexString(),
    factoryAddress,
    event.params.lpToken,
    event.block.number,
    event.block.timestamp
  );
}

export function handleVaultDeployedDeterministic(event: VaultDeployedDeterministic): void {
  let factoryAddress = event.address.toHexString();
  let factory = loadOrCreateFactory(factoryAddress);
  factory.implementation = event.params.implementation;
  factory.vaultCount     = factory.vaultCount.plus(BigInt.fromI32(1));
  factory.save();

  createVault(
    event.params.proxy.toHexString(),
    factoryAddress,
    event.params.lpToken,
    event.block.number,
    event.block.timestamp
  );
}

// ─────────────────────────────────────────────────────────────────
// ERC4626VaultV1 template event handlers
// (all events are emitted at the proxy address)
// ─────────────────────────────────────────────────────────────────

export function handleDeposit(event: Deposit): void {
  let vaultAddress = event.address.toHexString();
  let vault = Vault.load(vaultAddress);
  if (vault == null) return;

  vault.totalAssetsDeposited = vault.totalAssetsDeposited.plus(event.params.assets);
  vault.totalSharesMinted    = vault.totalSharesMinted.plus(event.params.shares);
  vault.depositCount         = vault.depositCount.plus(BigInt.fromI32(1));
  vault.save();

  let depositId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
  let deposit = new VaultDeposit(depositId);
  deposit.vault            = vaultAddress;
  deposit.sender           = event.params.sender;
  deposit.owner            = event.params.owner;
  deposit.assets           = event.params.assets;
  deposit.shares           = event.params.shares;
  deposit.blockNumber      = event.block.number;
  deposit.timestamp        = event.block.timestamp;
  deposit.transactionHash  = event.transaction.hash;
  deposit.save();

  let day = loadOrCreateDayData(event.block.timestamp);
  day.dailyDepositCount = day.dailyDepositCount.plus(BigInt.fromI32(1));
  day.save();
}

export function handleWithdraw(event: Withdraw): void {
  let vaultAddress = event.address.toHexString();
  let vault = Vault.load(vaultAddress);
  if (vault == null) return;

  vault.totalAssetsWithdrawn = vault.totalAssetsWithdrawn.plus(event.params.assets);
  vault.totalSharesBurned    = vault.totalSharesBurned.plus(event.params.shares);
  vault.withdrawalCount      = vault.withdrawalCount.plus(BigInt.fromI32(1));
  vault.save();

  let withdrawalId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
  let withdrawal = new VaultWithdrawal(withdrawalId);
  withdrawal.vault           = vaultAddress;
  withdrawal.sender          = event.params.sender;
  withdrawal.receiver        = event.params.receiver;
  withdrawal.owner           = event.params.owner;
  withdrawal.assets          = event.params.assets;
  withdrawal.shares          = event.params.shares;
  withdrawal.blockNumber     = event.block.number;
  withdrawal.timestamp       = event.block.timestamp;
  withdrawal.transactionHash = event.transaction.hash;
  withdrawal.save();

  let day = loadOrCreateDayData(event.block.timestamp);
  day.dailyWithdrawalCount = day.dailyWithdrawalCount.plus(BigInt.fromI32(1));
  day.save();
}

export function handlePaused(event: Paused): void {
  let vault = Vault.load(event.address.toHexString());
  if (vault == null) return;
  vault.paused = true;
  vault.save();
}

export function handleUnpaused(event: Unpaused): void {
  let vault = Vault.load(event.address.toHexString());
  if (vault == null) return;
  vault.paused = false;
  vault.save();
}

export function handlePriceFeedAdapterUpdated(event: PriceFeedAdapterUpdated): void {
  let vault = Vault.load(event.address.toHexString());
  if (vault == null) return;
  vault.priceFeedAdapter = event.params.newAdapter;
  vault.save();
}
