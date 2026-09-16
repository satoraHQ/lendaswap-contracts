# Security Policy

`lendaswap-contracts` is the on-chain HTLC + coordinator for LendaSwap
atomic swaps (Bitcoin / Lightning / Arkade ↔ EVM tokens). The contracts
are deployed on Ethereum, Polygon, and Arbitrum.

## Reporting a vulnerability

**Please do not open a public issue for an actively exploitable
funds-loss bug on a live deployment.** Email first so we can pause or
patch before the details are public.

Report privately to:

- [hello@satora.io](mailto:hello@satora.io) with the subject
  `[lendaswap-contracts security]`

If the issue is already public (for example a source-review finding
with no live leftover-balance to steal), a GitHub issue on this
repository is acceptable.

Please include:

- Impact (funds loss, shared-pool theft, signature bypass, frozen HTLC)
- Affected contract (`HTLCCoordinator` / `HTLCErc20`) and commit or
  deployed address
- Chain (Ethereum / Polygon / Arbitrum)
- Reproduction steps or a Foundry / Anvil PoC
- Suggested fix (optional)

### Response

- Acknowledge within **3 business days**
- Initial severity assessment within **7 business days**
- We will coordinate a fix and a disclosure date with you

## Scope

**In scope:** anything that can steal, freeze, or mis-attribute tokens
held by `HTLCCoordinator` or `HTLCErc20` — including leftover-balance
accounting, Permit2 / EIP-712 auth, sweep / refund paths, and
allowlisted arbitrary calls.

**Out of scope:** issues that require a compromised deployer key or
 Pallet/owner compromise; third-party DEX / Permit2 bugs with no
demonstrated impact on these contracts; test-only helpers.

## Supported versions

Security fixes land on `main` and are redeployed (CREATE2 addresses
are documented in the README). Older deployments are best-effort —
treat a new coordinator deployment as the supported version.
