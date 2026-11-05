//! E2E for the HTLCNativeCoordinator flows on a **local Anvil**, no network access.
//! The chain's native coin stands in for RBTC; nothing here is Rootstock-specific.
//!
//! 1. `test_lock_then_redeem_via_coordinator` — `executeAndCreate` with no calls locks exactly
//!    `amount`; Bob signs an HTLC-level redeem naming the coordinator as caller; a relayer submits
//!    `redeemAndExecute` and Bob is paid the native coin.
//! 2. `test_lock_then_wrapped_redeem` — same lock; the redeem wraps the coin and sweeps the ERC20
//!    to Bob.
//! 3. `test_lock_then_depositor_refunds` — after the timelock Alice, the HTLC sender, refunds
//!    straight on the HTLC; a stranger cannot.
//!
//! The `sol!` bindings and the signing helper are the pattern the backend reuses.
//!
//! Run:
//!   cargo test --test e2e_native_coordinator -- --nocapture

use alloy::network::EthereumWallet;
use alloy::node_bindings::Anvil;
use alloy::primitives::Address;
use alloy::primitives::Bytes;
use alloy::primitives::FixedBytes;
use alloy::primitives::U256;
use alloy::primitives::keccak256;
use alloy::providers::Provider;
use alloy::providers::ProviderBuilder;
use alloy::signers::Signer;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use alloy::sol_types::SolCall;
use alloy::sol_types::SolValue;
use anyhow::Result;
use sha2::Digest;
use sha2::Sha256;

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    HTLCNative,
    "../out/HTLCNative.sol/HTLCNative.json"
);

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    HTLCNativeCoordinator,
    "../out/HTLCNativeCoordinator.sol/HTLCNativeCoordinator.json"
);

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    MockWRBTC,
    "../out/MockWRBTC.sol/MockWRBTC.json"
);

const AMOUNT: u128 = 1_000_000_000_000_000_000; // 1 RBTC
const TIMELOCK_SECS: u64 = 3600;

struct Harness {
    _anvil: alloy::node_bindings::AnvilInstance,
    raw: alloy::providers::DynProvider,
    alice: PrivateKeySigner,
    bob: PrivateKeySigner,
    relayer: PrivateKeySigner,
    htlc: Address,
    coordinator: Address,
    wrbtc: Address,
    preimage: FixedBytes<32>,
    preimage_hash: FixedBytes<32>,
    timelock: U256,
}

impl Harness {
    async fn spawn() -> Result<Self> {
        let anvil = Anvil::new().try_spawn()?;
        let endpoint = anvil.endpoint_url();

        let deployer: PrivateKeySigner = anvil.keys()[0].clone().into();
        let alice: PrivateKeySigner = anvil.keys()[1].clone().into();
        let bob: PrivateKeySigner = anvil.keys()[2].clone().into();
        let relayer: PrivateKeySigner = anvil.keys()[3].clone().into();

        let deployer_provider = ProviderBuilder::new()
            .wallet(EthereumWallet::from(deployer.clone()))
            .connect_http(endpoint.clone());
        let raw = ProviderBuilder::new()
            .connect_http(endpoint.clone())
            .erased();

        let htlc = HTLCNative::deploy(&deployer_provider, deployer.address()).await?;
        let coordinator =
            HTLCNativeCoordinator::deploy(&deployer_provider, *htlc.address()).await?;
        let wrbtc = MockWRBTC::deploy(&deployer_provider).await?;

        let preimage = FixedBytes::<32>::from(keccak256(b"native e2e preimage").0);
        let preimage_hash = FixedBytes::<32>::from_slice(&Sha256::digest(preimage));
        let now = raw
            .get_block_by_number(alloy::eips::BlockNumberOrTag::Latest)
            .await?
            .expect("latest block")
            .header
            .timestamp;
        let timelock = U256::from(now + TIMELOCK_SECS);

        Ok(Self {
            _anvil: anvil,
            raw,
            alice,
            bob,
            relayer,
            htlc: *htlc.address(),
            coordinator: *coordinator.address(),
            wrbtc: *wrbtc.address(),
            preimage,
            preimage_hash,
            timelock,
        })
    }

    fn provider_for(&self, signer: &PrivateKeySigner) -> impl Provider + Clone {
        ProviderBuilder::new()
            .wallet(EthereumWallet::from(signer.clone()))
            .connect_http(self._anvil.endpoint_url())
    }

    /// Alice locks exactly AMOUNT for Bob through the coordinator with no calls.
    async fn lock(&self) -> Result<()> {
        let coordinator =
            HTLCNativeCoordinator::new(self.coordinator, self.provider_for(&self.alice));
        let receipt = coordinator
            .executeAndCreate(
                vec![],
                self.preimage_hash,
                U256::from(AMOUNT),
                self.bob.address(),
                self.timelock,
            )
            .value(U256::from(AMOUNT))
            .send()
            .await?
            .get_receipt()
            .await?;
        assert!(receipt.status(), "executeAndCreate reverted");

        let htlc = HTLCNative::new(self.htlc, self.raw.clone());
        let active = htlc
            .isActive(
                self.preimage_hash,
                U256::from(AMOUNT),
                Address::ZERO,
                self.alice.address(),
                self.bob.address(),
                self.timelock,
            )
            .call()
            .await?;
        assert!(active, "swap should be active after the lock");
        assert_eq!(self.raw.get_balance(self.htlc).await?, U256::from(AMOUNT));
        Ok(())
    }

    /// Bob's HTLC-level redeem signature: sender = Alice, caller = coordinator, plus the sweep
    /// terms.
    async fn sign_redeem(
        &self,
        destination: Address,
        sweep_token: Address,
        min_amount_out: U256,
        calls: &[CallExecutor::Call],
    ) -> Result<(u8, FixedBytes<32>, FixedBytes<32>)> {
        let htlc = HTLCNative::new(self.htlc, self.raw.clone());
        let domain_separator = htlc.DOMAIN_SEPARATOR().call().await?;
        let typehash = htlc.TYPEHASH_REDEEM().call().await?;
        let calls_hash = keccak256(calls.abi_encode());

        let struct_hash = keccak256(
            (
                typehash,
                self.preimage,
                U256::from(AMOUNT),
                self.alice.address(),
                self.timelock,
                self.coordinator,
                destination,
                sweep_token,
                min_amount_out,
                calls_hash,
            )
                .abi_encode(),
        );
        let digest = keccak256(
            [
                b"\x19\x01".as_slice(),
                domain_separator.as_slice(),
                struct_hash.as_slice(),
            ]
            .concat(),
        );
        let sig = self.bob.sign_hash(&digest).await?;
        Ok((
            27 + u8::from(sig.v()),
            FixedBytes::from(sig.r().to_be_bytes::<32>()),
            FixedBytes::from(sig.s().to_be_bytes::<32>()),
        ))
    }

    async fn warp_past_timelock(&self) -> Result<()> {
        let ts: u64 = self.timelock.to::<u64>() + 1;
        self.raw
            .raw_request::<_, serde_json::Value>("evm_setNextBlockTimestamp".into(), vec![ts])
            .await?;
        self.raw
            .raw_request::<_, serde_json::Value>("evm_mine".into(), Vec::<u64>::new())
            .await?;
        Ok(())
    }
}

#[tokio::test]
async fn test_lock_then_redeem_via_coordinator() -> Result<()> {
    let h = Harness::spawn().await?;
    h.lock().await?;

    let bob_before = h.raw.get_balance(h.bob.address()).await?;
    let (v, r, s) = h
        .sign_redeem(h.bob.address(), Address::ZERO, U256::from(AMOUNT), &[])
        .await?;

    let coordinator = HTLCNativeCoordinator::new(h.coordinator, h.provider_for(&h.relayer));
    let receipt = coordinator
        .redeemAndExecute(
            h.preimage,
            U256::from(AMOUNT),
            h.alice.address(),
            h.timelock,
            vec![],
            Address::ZERO,
            U256::from(AMOUNT),
            h.bob.address(),
            v,
            r,
            s,
        )
        .send()
        .await?
        .get_receipt()
        .await?;
    assert!(receipt.status(), "redeemAndExecute reverted");

    let bob_after = h.raw.get_balance(h.bob.address()).await?;
    assert_eq!(
        bob_after - bob_before,
        U256::from(AMOUNT),
        "Bob paid the full amount, relayer paid gas"
    );
    assert_eq!(h.raw.get_balance(h.htlc).await?, U256::ZERO);
    assert_eq!(h.raw.get_balance(h.coordinator).await?, U256::ZERO);

    let htlc = HTLCNative::new(h.htlc, h.raw.clone());
    let key = htlc
        .computeKey(
            h.preimage_hash,
            U256::from(AMOUNT),
            Address::ZERO,
            h.alice.address(),
            h.bob.address(),
            h.timelock,
        )
        .call()
        .await?;
    let state = htlc.swapState(key).call().await?;
    assert_eq!(state.state, 2, "Redeemed");
    assert_eq!(state.preimage, h.preimage, "preimage stored on chain");
    Ok(())
}

#[tokio::test]
async fn test_lock_then_wrapped_redeem() -> Result<()> {
    let h = Harness::spawn().await?;
    h.lock().await?;

    let calls = vec![CallExecutor::Call {
        target: h.wrbtc,
        value: U256::from(AMOUNT),
        callData: Bytes::from(MockWRBTC::depositCall {}.abi_encode()),
    }];
    let (v, r, s) = h
        .sign_redeem(h.bob.address(), h.wrbtc, U256::from(AMOUNT), &calls)
        .await?;

    let coordinator = HTLCNativeCoordinator::new(h.coordinator, h.provider_for(&h.relayer));
    let receipt = coordinator
        .redeemAndExecute(
            h.preimage,
            U256::from(AMOUNT),
            h.alice.address(),
            h.timelock,
            calls,
            h.wrbtc,
            U256::from(AMOUNT),
            h.bob.address(),
            v,
            r,
            s,
        )
        .send()
        .await?
        .get_receipt()
        .await?;
    assert!(receipt.status(), "redeemAndExecute reverted");

    let wrbtc = MockWRBTC::new(h.wrbtc, h.raw.clone());
    assert_eq!(
        wrbtc.balanceOf(h.bob.address()).call().await?,
        U256::from(AMOUNT)
    );
    assert_eq!(h.raw.get_balance(h.coordinator).await?, U256::ZERO);
    Ok(())
}

#[tokio::test]
async fn test_lock_then_depositor_refunds() -> Result<()> {
    let h = Harness::spawn().await?;
    h.lock().await?;

    h.warp_past_timelock().await?;

    // The relayer is not the sender: its refund addresses a key that does not exist.
    let stranger_refund = HTLCNative::new(h.htlc, h.provider_for(&h.relayer))
        .refund_1(
            h.preimage_hash,
            U256::from(AMOUNT),
            h.bob.address(),
            h.timelock,
        )
        .send()
        .await;
    assert!(
        stranger_refund.is_err(),
        "a stranger must not be able to refund"
    );

    let alice_before = h.raw.get_balance(h.alice.address()).await?;
    let receipt = HTLCNative::new(h.htlc, h.provider_for(&h.alice))
        .refund_1(
            h.preimage_hash,
            U256::from(AMOUNT),
            h.bob.address(),
            h.timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;
    assert!(receipt.status(), "refund reverted");

    let alice_after = h.raw.get_balance(h.alice.address()).await?;
    let gas_paid = U256::from(receipt.gas_used) * U256::from(receipt.effective_gas_price);
    assert_eq!(
        alice_after + gas_paid - alice_before,
        U256::from(AMOUNT),
        "Alice is paid back on the HTLC"
    );
    assert_eq!(h.raw.get_balance(h.htlc).await?, U256::ZERO);
    Ok(())
}
