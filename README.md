# Lendaswap Atomic Swap Smart Contracts

Smart contracts for atomic swaps between Bitcoin (via Lightning, Arkade, or on-chain) and EVM tokens using Hash Time
Locked Contracts (HTLCs). Deployed on Polygon, Ethereum, and Arbitrum.

## Features

- **HTLC-based Atomic Swaps**: Trustless swaps using hash locks and timelocks
- **Multi-chain**: Deployed on Polygon, Ethereum, and Arbitrum
- **DEX Integration**: Arbitrary call execution for on-chain token swaps (e.g., Uniswap V3)
- **Gasless Transactions**: EIP-712 signature-based redeem/refund (no gas needed for the claimer)
- **Permit2 Support**: Gasless token approvals via Uniswap Permit2
- **Security**: OpenZeppelin SafeERC20, transient-storage reentrancy guard (EIP-1153)

## Contracts

### HTLCErc20

**Purpose**: Lock and release ERC20 tokens in a hash time-locked swap.

Minimal storage design — only a single `bool` per swap. All parameters are verified via hash on redeem/refund.

1. **Create**: Lock ERC20 tokens with a preimage hash and timelock
2. **Redeem**: Claim address reveals preimage to unlock tokens (supports EIP-712 signatures)
3. **Refund**: Sender reclaims tokens after timelock expiry (supports EIP-712 signatures)

### HTLCCoordinator

**Purpose**: Compose arbitrary calls (e.g., DEX swaps) with HTLC create/redeem/refund in a single transaction.

Three primary flows:

1. **executeAndCreate**: Run arbitrary calls (e.g., swap USDC to WBTC via Uniswap), then lock the resulting tokens in an
   HTLC. Uses Permit2 for gasless token approvals.
2. **redeemAndExecute**: Redeem tokens from an HTLC via EIP-712 signature, run arbitrary calls (e.g., swap WBTC to
   USDC), then sweep the result to the caller.
3. **refundTo**: Refund an expired HTLC straight to the original depositor.

### HTLCNative on Rootstock

New RBTC swaps use `HTLCNative` directly. A source wallet funds `create` and
retains the refund right. For an RBTC payout, the swap's derived claim key signs
`redeemBySig`, and the payout wallet submits it and pays gas. The deployed HTLC
pays `msg.sender`, so the SDK requires the submitting wallet to match the payout
address. No coordinator or backend claim relay is involved.

When RIF Relay is configured, the recipient signs a claim through their smart
wallet and the relay fee comes out of the claimed RBTC. Without RIF Relay, users
need RBTC for claim gas. Quotes include the server's funding gas, without the
former server-relayed client claim allowance. The existing HTLC deployment can
be reused; `DeployHTLCNative.s.sol` deploys only the HTLC. Configure
`native_htlc_contract` and `native_htlc_version` without a coordinator.

Native coordinator code and refund helpers remain for already-funded legacy
swaps. Their pinned on-chain sender continues to determine how they settle.
Ethereum, Arbitrum, and Polygon retain their existing coordinator and gasless flows.

### Key Parameters

- `preimageHash`: SHA-256 hash of the secret (compatible with Bitcoin HTLC scripts)
- `timelock`: Unix timestamp after which refund is possible
- `token`: ERC20 token address to lock
- `claimAddress`: Address authorized to redeem (prevents front-running)
- `refundAddress`: Address that can reclaim after timelock

## USDT payouts to Tron

Bitcoin, Lightning and Arkade can pay out native TRC-20 USDT through the
Arbitrum Legacy Mesh pool. Tron is a destination only. The HTLC and DEX leg
remain on Arbitrum; no Tron wallet key or Tron HTLC is required.

This route uses `TronBridgeAdapter`, separately from `USDT0BridgeAdapter`:

- Source token: Arbitrum USDT0, `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9`.
- Mesh pool: `0x77652D5aba086137b595875263FC200182919B92`.
- Tron endpoint: `30420`; destination token: `TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`.
- Token fee: 3 bps today, set by `contracts.arbitrum.tron_bridge.mesh_fee_bps`.
  Quotes gross up target-pinned requests and deduct the fee from source-pinned
  requests. Each claim passes the least amount that must arrive on Tron (the
  DEX slippage floor less the mesh fee) to `bridgeBalance`, bound into the signed
  calls; the adapter and the mesh revert below it. A changed mesh fee needs a
  config update only, no redeploy.
- Native messaging fees are quoted live, converted to sats, and charged with
  network fees. Tron has no hardcoded fee fallback. Buffered claim funding
  left in the adapter is withdrawable by its owner, as are tokens sent to it
  by mistake (`rescueToken`).

Verify addresses against the [deployment registry](https://docs.usdt0.to/api/deployments)
and read the [Legacy Mesh integration guidance](https://docs.usdt0.to/technical-documentation/developer/).
Mesh upgrades can migrate pool addresses. Before enabling this route, simulate
the deployment script against the intended Arbitrum RPC, deploy it, and set
`contracts.arbitrum.tron_bridge.adapter` in the daemon config to the resulting
address. Restart the daemon after changing it. Without it, Tron is disabled.
Before first use the daemon checks that the address holds code with
`TRON_EID() == 30420`, `mesh()` = the mesh pool and `token()` = Arbitrum USDT0;
any mismatch keeps Tron disabled and logs an error.

Opt-in source-side integration test, using only a local fork:

```bash
TRON_BRIDGE_FORK_RPC=https://arb1.arbitrum.io/rpc \
  forge test --match-contract TronBridgeForkTest -vv
```

The TypeScript SDK accepts `Asset.USDT_TRON` with a checksummed `T…` recipient:

```ts
await client.createSwap({
  source: Asset.BTC_LIGHTNING,
  target: Asset.USDT_TRON,
  sourceAmount: 100_000,
  targetAddress: recipientTronAddress,
});
```

Raw API clients select Arbitrum USDT0 and `bridge_target_chain: "Tron"` when
creating the swap. `target_address` must be a valid Tron Base58Check address;
`claiming_address` remains the EVM claim key. Pass the Tron address as
`bridge_recipient` to both redeem-calldata and gasless-claim endpoints; their
`destination` stays an EVM address. The signature's calls hash commits to the
actual Tron recipient. The SDK pins it for auto-claim and restores it from
server metadata after recovery.

An EVM claim, DEX swap and source bridge send execute in one transaction.
Tron delivery is asynchronous and depends on the mesh's destination liquidity
and messaging infrastructure. The source receipt is **not** proof of payout.
`BridgeInitiated` records the message GUID; the UI tracks the matching Tron
message through LayerZero Scan and links to Tronscan. On delays or tracking
errors, retain the original source tx/GUID and resume tracking it. Do not send
a replacement payout merely because tracking timed out. Destination execution
recovery follows LayerZero/USDT0 procedures; there is no automatic reverse
bridge or Tron-side refund implemented here.

Before production rollout, verify a small real transfer through destination
delivery and the recovery procedure. The fork test verifies the source send
only and never broadcasts a live transaction.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Polygon RPC URL
- Private key for deployment

## Setup

1. Navigate to the contracts directory:

```bash
cd contracts
```

2. Install dependencies:

```bash
forge install
```

3. Copy `.env.example` to `.env` and configure:

```bash
cp ../.env.example .env
```

Required environment variables:

```bash
RPC_URL=your_polygon_rpc_url
PRIVATE_KEY=your_private_key_for_deployment
```

## Testing

Run all tests:

```bash
forge test
```

## Gasless Execution

Both contracts support **EIP-712 signature-based** gasless execution. Users sign a typed message off-chain, and a
relayer submits the transaction and pays gas.

### How It Works

```
User signs EIP-712 msg → Submit to Relayer → Relayer executes & pays gas → User receives tokens
      (off-chain, free)                            (on-chain)                (no gas needed!)
```

- **HTLCErc20**: Redeem and refund both accept EIP-712 signatures, allowing a third party to submit on behalf of the
  user.
- **HTLCCoordinator**: Uses Permit2 for gasless token approvals on `executeAndCreate`.

### Testing Gasless Execution

```bash
cd contracts
forge build
cd tests
cargo test --test e2e_permit2_swap_lock_then_claim -- --nocapture
```

See [`tests/tests/e2e_permit2_swap_lock_then_claim.rs`](tests/tests/e2e_permit2_swap_lock_then_claim.rs) for implementation details.

## Security Considerations

1. **Secret Management**: Use cryptographically secure random generation. Hash with SHA-256 (same as Bitcoin).
2. **Timelock Values**: Coordinate with Bitcoin-side timelock (should be longer on Bitcoin). Typical: 1-24 hours.
3. **Slippage Protection**: Set proper `minAmountOut` when using the coordinator with DEX calls.
4. **Front-running**: `claimAddress` is part of the swap key — only that address can redeem.

## Contract Addresses

Current deployment: **HTLCErc20 v6** (terminal swap state in storage, full
typed errors; EIP-712 domain version `"6"`) with **HTLCCoordinator v4** (domain
version `"4"`, `CallFailed(index)` and friends). Deployed via CREATE2, so the
addresses are identical on every chain. Note: `refundBySig` is stubbed
(`Unimplemented()`) pending the dual-sig refund redesign — collaborative
refunds are unavailable on this deployment until it lands; timeout refunds
work.

### Polygon (Chain ID: 137)

- HTLCErc20 (v6): [`0xf12A26a6CEfc1F5a0772fAf09F94c5e5662a3948`](https://polygonscan.com/address/0xf12A26a6CEfc1F5a0772fAf09F94c5e5662a3948)
- HTLCCoordinator: [`0xdb76F29f1d04D1202f56a34549869b070DFcBfF0`](https://polygonscan.com/address/0xdb76F29f1d04D1202f56a34549869b070DFcBfF0)

Tokens:

- WBTC: `0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6`

### Ethereum (Chain ID: 1)

- HTLCErc20 (v6): [`0xf12A26a6CEfc1F5a0772fAf09F94c5e5662a3948`](https://etherscan.io/address/0xf12A26a6CEfc1F5a0772fAf09F94c5e5662a3948)
- HTLCCoordinator: [`0xdb76F29f1d04D1202f56a34549869b070DFcBfF0`](https://etherscan.io/address/0xdb76F29f1d04D1202f56a34549869b070DFcBfF0)

Tokens:

- tBTC: `0x18084fba666a33d37592fa2633fd49a74dd93a88`

### Arbitrum (Chain ID: 42161)

- HTLCErc20 (v6): [`0xf12A26a6CEfc1F5a0772fAf09F94c5e5662a3948`](https://arbiscan.io/address/0xf12A26a6CEfc1F5a0772fAf09F94c5e5662a3948)
- HTLCCoordinator: [`0xdb76F29f1d04D1202f56a34549869b070DFcBfF0`](https://arbiscan.io/address/0xdb76F29f1d04D1202f56a34549869b070DFcBfF0)
- TronBridgeAdapter: [`0x5f6050f1a45566c802d58dA1c1124Df48bBbC444`](https://arbiscan.io/address/0x5f6050f1a45566c802d58dA1c1124Df48bBbC444)

Tokens:

- tBTC: `0x6c84a8f1c29108F47a79964b5Fe888D4f4D0dE40`

### Rootstock (Chain ID: 30)

The lock asset is RBTC itself, so the pair is **HTLCNative v1** +
**HTLCNativeCoordinator v1**, deployed with `script/deploy-rootstock.sh`
(CREATE2, salt `0x…03`, legacy transactions, Blockscout verification).
Addresses are lowercase: Rootstock tooling uses EIP-1191 checksums.

- HTLCNative: [`0x18123a31261a76c74c82ed2f8346002caa78ab39`](https://rootstock.blockscout.com/address/0x18123a31261a76c74c82ed2f8346002caa78ab39)
- HTLCNativeCoordinator: [`0x447a4cd711ce66d25c7008d26d5f09ca7d621f48`](https://rootstock.blockscout.com/address/0x447a4cd711ce66d25c7008d26d5f09ca7d621f48)

### Rootstock Testnet (Chain ID: 31)

Same salt, owner and bytecode as mainnet, so the same addresses (deployed
2026-09-24, verified on [rootstock-testnet.blockscout.com](https://rootstock-testnet.blockscout.com)).
Served by the mutinynet daemon under `network.rootstock_chain_id: 31`.

- HTLCNative: [`0x18123a31261a76c74c82ed2f8346002caa78ab39`](https://rootstock-testnet.blockscout.com/address/0x18123a31261a76c74c82ed2f8346002caa78ab39)
- HTLCNativeCoordinator: [`0x447a4cd711ce66d25c7008d26d5f09ca7d621f48`](https://rootstock-testnet.blockscout.com/address/0x447a4cd711ce66d25c7008d26d5f09ca7d621f48)

Testnet RBTC: https://faucet.rootstock.io. A fresh account sending two
transactions back to back trips RSKj's per-account tx-pool quota ("account
exceeds quota"); the deploy script sends them one at a time and is safe to rerun.

### Legacy deployments

Still live — in-flight swaps created on them settle against their stored
address and version. Do not remove until no unresolved swaps reference them.

- All chains (v5, 2026-08-14, never served production): HTLCErc20 `0x16f898C8E56daE38f782302e35f3eF3E51524fF6`, HTLCCoordinator `0xD26eF0b3AC359B02b0ED6276e82CF9Ad4718aE05`
- All chains (v5, 2026-08-13, never served production): HTLCErc20 `0x1feB479a912bd706bE6d22979Ba5C9ca0e9FDB49`, HTLCCoordinator `0x3cf9385c8D3dC7D9f199f4C9814eC0aCff6c8E7d`
- All chains (v4, EIP-712 domain version `"4"`): HTLCErc20 `0x5cedE56704374c6Aa37592af9d8818f7abb5147F`, HTLCCoordinator `0xe2E043B72161Ed562b6235D7654E2449871fC58F`
- Polygon + Ethereum (older): HTLCErc20 `0xc23a186aedf24537ec82318da9891c02d544bffa`, HTLCCoordinator `0x628729f060d01001efcfb6077dfe072821346485`
- Arbitrum (older): HTLCErc20 `0x13572c930A5Bbb3d0d46d567D71a9Ad962f85D18`, HTLCCoordinator `0x5B7cDa892cF870156bcb9a710249830Fa1Fc67Be`

## License

MIT
