//! E2E test: Swap → Lock → Redeem (Polygon fork + real Uniswap V3)
//!
//! Tests `executeAndCreate` + direct `redeem` against a **Polygon fork** with
//! real on-chain liquidity (Uniswap V3 USDC/WBTC pool).
//!
//! Flow: Alice swaps USDC→WBTC via `coordinator.executeAndCreate`, which locks
//! the resulting WBTC in an HTLC. Bob then redeems by revealing the preimage.
//!
//! The same flow is also covered locally (with mock contracts) in
//! `e2e_coordinator::test_lock_and_execute` + `test_claim`.
//!
//! Requires `POLYGON_RPC_URL` env var and network access.
//! Run:
//!   POLYGON_RPC_URL="..." cargo test --test e2e_swap_then_lock_then_redeem -- --ignored
//! --nocapture

use alloy::network::EthereumWallet;
use alloy::node_bindings::Anvil;
use alloy::primitives::Address;
use alloy::primitives::Bytes;
use alloy::primitives::FixedBytes;
use alloy::primitives::U160;
use alloy::primitives::U256;
use alloy::primitives::address;
use alloy::primitives::keccak256;
use alloy::providers::Provider;
use alloy::providers::ProviderBuilder;
use alloy::providers::WalletProvider;
use alloy::signers::Signer;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use alloy::sol_types::SolCall;
use alloy::sol_types::SolValue;
use anyhow::Result;
use sha2::Digest;
use sha2::Sha256;

// ---------------------------------------------------------------------------
// Contract bindings from forge build artifacts
// ---------------------------------------------------------------------------

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    HTLCErc20,
    "../out/HTLCErc20.sol/HTLCErc20.json"
);

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    HTLCCoordinator,
    "../out/HTLCCoordinator.sol/HTLCCoordinator.json"
);

// ---------------------------------------------------------------------------
// Inline ABI fragments for on-chain contracts (IERC20, Uniswap V3 Router)
// ---------------------------------------------------------------------------

sol! {
    #[sol(rpc)]
    interface IERC20 {
        function balanceOf(address account) external view returns (uint256);
        function approve(address spender, uint256 amount) external returns (bool);
        function transfer(address to, uint256 amount) external returns (bool);
    }
}

sol! {
    #[sol(rpc)]
    interface IPermit2 {
        function DOMAIN_SEPARATOR() external view returns (bytes32);
    }
}

sol! {
    #[sol(rpc)]
    interface ISwapRouter {
        struct ExactInputSingleParams {
            address tokenIn;
            address tokenOut;
            uint24 fee;
            address recipient;
            uint256 deadline;
            uint256 amountIn;
            uint256 amountOutMinimum;
            uint160 sqrtPriceLimitX96;
        }

        function exactInputSingle(ExactInputSingleParams calldata params)
            external
            payable
            returns (uint256 amountOut);
    }
}

// ---------------------------------------------------------------------------
// Polygon mainnet constants
// ---------------------------------------------------------------------------

/// USDC (native, 6 decimals) on Polygon
const USDC: Address = address!("3c499c542cEF5E3811e1192ce70d8cC03d5c3359");
/// WBTC (8 decimals) on Polygon
const WBTC: Address = address!("1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6");
/// Uniswap V3 SwapRouter on Polygon
const UNISWAP_ROUTER: Address = address!("E592427A0AEce92De3Edee1F18E0157C05861564");
/// 0.05% fee tier
const POOL_FEE: u32 = 500;
/// 100 USDC (6 decimals)
const USDC_TEST_AMOUNT: u128 = 100_000_000; // 100e6
/// Fork block — chosen so the whale has sufficient balance
const FORK_BLOCK: u64 = 82_488_076;
/// Known USDC whale on Polygon
const USDC_WHALE: Address = address!("0x852f57dd17edbb0bedae8c55dd4b20feb3133089");
/// Canonical Permit2 address (deployed on Polygon mainnet)
const PERMIT2_ADDRESS: Address = address!("000000000022D473030F116dDEE9F6B43aC78BA3");
const TOKEN_PERMISSIONS_TYPEHASH: &str = "TokenPermissions(address token,uint256 amount)";
const PERMIT2_WITNESS_TYPEHASH_STUB: &str = "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore] // requires POLYGON_RPC_URL and network access
async fn test_e2e_swap_then_lock_then_redeem() -> Result<()> {
    // -----------------------------------------------------------------------
    // 0. Setup: fork Polygon at pinned block
    // -----------------------------------------------------------------------
    let rpc_url =
        std::env::var("POLYGON_RPC_URL").expect("Set POLYGON_RPC_URL to a Polygon RPC endpoint");

    println!("\n=== E2E: Swap → Lock → Redeem (Polygon Fork) ===\n");
    println!("Forking Polygon at block {FORK_BLOCK} ...");

    let anvil = Anvil::new()
        .fork(&rpc_url)
        .fork_block_number(FORK_BLOCK)
        .try_spawn()?;

    let endpoint = anvil.endpoint_url();

    // Alice (uses a wallet-backed provider for sending txs)
    let alice_key: PrivateKeySigner = anvil.keys()[0].clone().into();
    let alice_address = alice_key.address();
    let alice_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(alice_key.clone()))
        .connect_http(endpoint.clone());

    // Bob (claims the HTLC by revealing the preimage)
    let bob_key: PrivateKeySigner = anvil.keys()[1].clone().into();
    let bob_address = bob_key.address();
    let bob_wallet = EthereumWallet::from(bob_key);
    let bob_provider = ProviderBuilder::new()
        .wallet(bob_wallet)
        .connect_http(endpoint.clone());

    // Hub — independent deployer of the contracts
    let hub_key: PrivateKeySigner = anvil.keys()[2].clone().into();
    let hub_address = hub_key.address();
    let hub_wallet = EthereumWallet::from(hub_key);
    let hub_provider = ProviderBuilder::new()
        .wallet(hub_wallet)
        .connect_http(endpoint.clone());

    // Non-wallet provider for raw RPC calls (impersonation)
    let raw_provider = ProviderBuilder::new().connect_http(endpoint.clone());

    println!("  Alice: {alice_address}");
    println!("  Bob:   {bob_address}");
    println!("  Hub:   {hub_address}");

    // -----------------------------------------------------------------------
    // 1. Deploy HTLCErc20 + HTLCCoordinator
    // -----------------------------------------------------------------------
    println!("\n1. Deploying contracts ...");

    let htlc = HTLCErc20::deploy(&hub_provider, hub_provider.default_signer_address()).await?;
    let htlc_address = *htlc.address();
    println!("   HTLCErc20 at {htlc_address} (deployed by hub)");

    let coordinator = HTLCCoordinator::deploy(&hub_provider, htlc_address, PERMIT2_ADDRESS).await?;
    let coordinator_address = *coordinator.address();
    println!("   HTLCCoordinator at {coordinator_address} (deployed by hub)");

    // -----------------------------------------------------------------------
    // 2. Impersonate USDC whale → fund Alice with USDC
    // -----------------------------------------------------------------------
    println!("\n2. Funding Alice with USDC from whale ...");

    let usdc_on_raw = IERC20::new(USDC, &raw_provider);

    // Check whale balance first
    let whale_balance = usdc_on_raw.balanceOf(USDC_WHALE).call().await?;
    println!("   Whale USDC balance: {whale_balance}");
    assert!(
        whale_balance >= U256::from(USDC_TEST_AMOUNT),
        "Whale has insufficient USDC at block {FORK_BLOCK}"
    );

    // Impersonate
    raw_provider
        .raw_request::<_, ()>(
            "anvil_impersonateAccount".into(),
            &[format!("{USDC_WHALE:?}")],
        )
        .await?;

    // Transfer USDC from whale to Alice
    let usdc_on_whale = IERC20::new(USDC, &raw_provider);
    let _tx = usdc_on_whale
        .transfer(alice_address, U256::from(USDC_TEST_AMOUNT))
        .from(USDC_WHALE)
        .send()
        .await?
        .get_receipt()
        .await?;

    // Stop impersonating
    raw_provider
        .raw_request::<_, ()>(
            "anvil_stopImpersonatingAccount".into(),
            &[format!("{USDC_WHALE:?}")],
        )
        .await?;

    let alice_usdc_before = IERC20::new(USDC, &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    println!("   Alice USDC balance: {alice_usdc_before}");
    assert_eq!(alice_usdc_before, U256::from(USDC_TEST_AMOUNT));

    // -----------------------------------------------------------------------
    // 3. Alice approves USDC to Permit2
    // -----------------------------------------------------------------------
    println!("\n3. Alice approving USDC to Permit2 ...");

    let usdc_as_alice = IERC20::new(USDC, &alice_provider);
    usdc_as_alice
        .approve(PERMIT2_ADDRESS, U256::MAX)
        .send()
        .await?
        .get_receipt()
        .await?;
    println!("   Approved USDC to Permit2");

    // -----------------------------------------------------------------------
    // 4. Build Call[] structs for executeAndCreateWithPermit2
    // -----------------------------------------------------------------------
    println!("\n4. Building calls for executeAndCreateWithPermit2 ...");

    let block = alice_provider.get_block_number().await?;
    let block_ts = raw_provider
        .get_block_by_number(block.into())
        .await?
        .expect("block exists")
        .header
        .timestamp;
    let deadline = U256::from(block_ts + 600); // 10 minutes

    // Preimage / hash
    let preimage = FixedBytes::<32>::from([0xABu8; 32]);
    let preimage_hash = FixedBytes::<32>::from_slice(&Sha256::digest(preimage.as_slice()));

    // Timelock — far in the future relative to the fork block
    let timelock = U256::from(block_ts + 3600); // 1 hour from current block

    // Call 0: USDC.approve(uniswapRouter, amount)
    let call0_data = IERC20::approveCall {
        spender: UNISWAP_ROUTER,
        amount: U256::from(USDC_TEST_AMOUNT),
    }
    .abi_encode();

    // Call 1: router.exactInputSingle(...)
    let swap_params = ISwapRouter::ExactInputSingleParams {
        tokenIn: USDC,
        tokenOut: WBTC,
        fee: POOL_FEE.try_into().unwrap(),
        recipient: coordinator_address,
        deadline,
        amountIn: U256::from(USDC_TEST_AMOUNT),
        amountOutMinimum: U256::ZERO, // no slippage protection for test
        sqrtPriceLimitX96: U160::ZERO,
    };
    let call1_data = ISwapRouter::exactInputSingleCall {
        params: swap_params,
    }
    .abi_encode();

    let calls = vec![
        HTLCCoordinator::Call {
            target: USDC,
            value: U256::ZERO,
            callData: Bytes::from(call0_data),
        },
        HTLCCoordinator::Call {
            target: UNISWAP_ROUTER,
            value: U256::ZERO,
            callData: Bytes::from(call1_data),
        },
    ];

    println!("   2 calls prepared (approve, exactInputSingle)");

    // -----------------------------------------------------------------------
    // 5. Build Permit2 signature and call executeAndCreateWithPermit2
    // -----------------------------------------------------------------------
    println!("\n5. Calling coordinator.executeAndCreateWithPermit2 ...");

    let calls_hash = keccak256(calls.abi_encode());

    let coordinator_instance = HTLCCoordinator::new(coordinator_address, &raw_provider);
    let coordinator_typehash = coordinator_instance
        .TYPEHASH_EXECUTE_AND_CREATE()
        .call()
        .await?;

    let witness = keccak256(
        (
            coordinator_typehash,
            preimage_hash,
            WBTC,
            bob_address,
            alice_address, // refundAddress = the depositor, who is the HTLC sender
            timelock,
            calls_hash,
        )
            .abi_encode(),
    );

    let permit = ISignatureTransfer::PermitTransferFrom {
        permitted: ISignatureTransfer::TokenPermissions {
            token: USDC,
            amount: U256::from(USDC_TEST_AMOUNT),
        },
        nonce: U256::ZERO,
        deadline: timelock + U256::from(3600),
    };

    let typehash = keccak256(
        format!(
            "{}{}",
            PERMIT2_WITNESS_TYPEHASH_STUB,
            coordinator_instance
                .TYPESTRING_EXECUTE_AND_CREATE()
                .call()
                .await?
        )
        .as_bytes(),
    );

    let token_permissions_hash = keccak256(
        (
            keccak256(TOKEN_PERMISSIONS_TYPEHASH.as_bytes()),
            permit.permitted.token,
            permit.permitted.amount,
        )
            .abi_encode(),
    );

    let struct_hash = keccak256(
        (
            typehash,
            token_permissions_hash,
            coordinator_address,
            permit.nonce,
            permit.deadline,
            witness,
        )
            .abi_encode(),
    );

    let domain_separator = IPermit2::new(PERMIT2_ADDRESS, &raw_provider)
        .DOMAIN_SEPARATOR()
        .call()
        .await?;

    let digest = keccak256(
        [
            b"\x19\x01",
            domain_separator.as_slice(),
            struct_hash.as_slice(),
        ]
        .concat(),
    );

    let sig = alice_key.sign_hash(&digest).await?;
    let signature = Bytes::from(sig.as_bytes().to_vec());

    let coordinator_as_alice = HTLCCoordinator::new(coordinator_address, &alice_provider);
    let receipt = coordinator_as_alice
        .executeAndCreateWithPermit2(
            calls,
            preimage_hash,
            WBTC,
            bob_address,
            timelock,
            alice_address,
            permit,
            signature,
        )
        .send()
        .await?
        .get_receipt()
        .await?;

    println!(
        "   tx: {:?}  status: {:?}",
        receipt.transaction_hash,
        receipt.status()
    );
    assert!(
        receipt.status(),
        "executeAndCreateWithPermit2 tx should succeed"
    );

    // -----------------------------------------------------------------------
    // 6. Assertions
    // -----------------------------------------------------------------------
    println!("\n6. Verifying ...");

    // a) WBTC locked in HTLC
    let wbtc_in_htlc = IERC20::new(WBTC, &alice_provider)
        .balanceOf(htlc_address)
        .call()
        .await?;
    println!("   WBTC locked in HTLC: {wbtc_in_htlc}");
    assert!(wbtc_in_htlc > U256::ZERO, "HTLC should hold WBTC");

    // b) isActive — sender is the coordinator, not Alice
    let htlc_reader = HTLCErc20::new(htlc_address, &alice_provider);
    let is_active = htlc_reader
        .isActive(
            preimage_hash,
            wbtc_in_htlc,
            WBTC,
            alice_address, // sender = the depositor
            bob_address,
            timelock,
        )
        .call()
        .await?;
    println!("   isActive (sender=coordinator): {is_active}");
    assert!(is_active, "HTLC swap should be active");

    // c) Alice USDC decreased
    let alice_usdc_after = IERC20::new(USDC, &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    println!("   Alice USDC after: {alice_usdc_after}");
    assert_eq!(
        alice_usdc_after,
        U256::ZERO,
        "Alice should have spent all her USDC"
    );

    // -----------------------------------------------------------------------
    // 7. Bob claims the HTLC by revealing the preimage
    // -----------------------------------------------------------------------
    println!("\n7. Bob claiming HTLC with preimage ...");

    let bob_wbtc_before = IERC20::new(WBTC, &bob_provider)
        .balanceOf(bob_address)
        .call()
        .await?;

    let htlc_as_bob = HTLCErc20::new(htlc_address, &bob_provider);
    // Direct redeem: msg.sender is used as claimAddress (bob = msg.sender = claimAddress)
    let redeem_receipt = htlc_as_bob
        .redeem(
            preimage,
            wbtc_in_htlc,
            WBTC,
            alice_address, // sender = the depositor
            timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;

    println!(
        "   tx: {:?}  status: {:?}",
        redeem_receipt.transaction_hash,
        redeem_receipt.status()
    );
    assert!(redeem_receipt.status(), "redeem tx should succeed");

    // -----------------------------------------------------------------------
    // 8. Post-claim assertions
    // -----------------------------------------------------------------------
    println!("\n8. Verifying post-claim state ...");

    // a) Bob received the WBTC
    let bob_wbtc_after = IERC20::new(WBTC, &bob_provider)
        .balanceOf(bob_address)
        .call()
        .await?;
    println!("   Bob WBTC: {bob_wbtc_before} -> {bob_wbtc_after}");
    assert_eq!(
        bob_wbtc_after,
        bob_wbtc_before + wbtc_in_htlc,
        "Bob should have received the locked WBTC"
    );

    // b) HTLC no longer holds WBTC
    let htlc_wbtc_after = IERC20::new(WBTC, &alice_provider)
        .balanceOf(htlc_address)
        .call()
        .await?;
    println!("   HTLC WBTC balance: {htlc_wbtc_after}");
    assert_eq!(htlc_wbtc_after, U256::ZERO, "HTLC should be empty");

    // c) Swap is no longer active
    let still_active = htlc_reader
        .isActive(
            preimage_hash,
            wbtc_in_htlc,
            WBTC,
            alice_address,
            bob_address,
            timelock,
        )
        .call()
        .await?;
    println!("   isActive after redeem: {still_active}");
    assert!(!still_active, "HTLC swap should no longer be active");

    println!("\n=== Test passed — {wbtc_in_htlc} WBTC swapped and claimed by Bob ===\n");

    Ok(())
}
