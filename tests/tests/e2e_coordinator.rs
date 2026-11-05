//! E2E tests for the 3 core HTLCCoordinator flows using **local Anvil + mock
//! contracts** (MockUSDC, MockWBTC, MockDEX). No network access required.
//!
//! Tests 1 and 2 overlap with `e2e_swap_then_lock_then_redeem` (which uses a
//! real Polygon fork + Uniswap V3). They are kept here so the full coordinator
//! lifecycle can be validated locally without RPC credentials.
//! Test 3 (the refund path) is unique to this file.
//!
//! 1. `test_lock_and_execute`    — `executeAndCreateWithPermit2`: swap USDC→WBTC via DEX, lock WBTC
//!    in HTLC
//! 2. `test_claim`               — Bob redeems the HTLC with the preimage
//! 3. `test_depositor_refunds`   — after the timelock Alice, the HTLC sender, refunds straight on
//!    the HTLC; a stranger cannot
//!
//! Run:
//!   cargo test --test e2e_coordinator -- --nocapture

use alloy::network::EthereumWallet;
use alloy::node_bindings::Anvil;
use alloy::primitives::Address;
use alloy::primitives::Bytes;
use alloy::primitives::FixedBytes;
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
// Contract bindings
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

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    MockUSDC,
    "../out/HTLCCoordinatorSwapAndLock.t.sol/MockUSDC.json"
);

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    MockWBTC,
    "../out/HTLCCoordinatorSwapAndLock.t.sol/MockWBTC.json"
);

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    MockDEX,
    "../out/HTLCCoordinatorSwapAndLock.t.sol/MockDEX.json"
);

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

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const USDC_AMOUNT: u128 = 60_000_000_000; // 60,000 USDC (6 decimals)
const EXPECTED_WBTC: u128 = 100_000_000; // 1 WBTC (8 decimals)

const TOKEN_PERMISSIONS_TYPEHASH: &str = "TokenPermissions(address token,uint256 amount)";
const PERMIT2_WITNESS_TYPEHASH_STUB: &str = "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

const PERMIT2_ADDRESS: Address = address!("000000000022D473030F116dDEE9F6B43aC78BA3");
const PERMIT2_RUNTIME_CODE: &str = "0x6040608081526004908136101561001557600080fd5b600090813560e01c80630d58b1db1461126c578063137c29fe146110755780632a2d80d114610db75780632b67b57014610bde57806330f28b7a14610ade5780633644e51514610a9d57806336c7851614610a285780633ff9dcb1146109a85780634fe02b441461093f57806365d9723c146107ac57806387517c451461067a578063927da105146105c3578063cc53287f146104a3578063edd9444b1461033a5763fe8ec1a7146100c657600080fd5b346103365760c07ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126103365767ffffffffffffffff833581811161033257610114903690860161164b565b60243582811161032e5761012b903690870161161a565b6101336114e6565b9160843585811161032a5761014b9036908a016115c1565b98909560a43590811161032657610164913691016115c1565b969095815190610173826113ff565b606b82527f5065726d697442617463685769746e6573735472616e7366657246726f6d285460208301527f6f6b656e5065726d697373696f6e735b5d207065726d69747465642c61646472838301527f657373207370656e6465722c75696e74323536206e6f6e63652c75696e74323560608301527f3620646561646c696e652c000000000000000000000000000000000000000000608083015282519a8b9181610222602085018096611f93565b918237018a8152039961025b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe09b8c8101835282611437565b5190209085515161026b81611ebb565b908a5b8181106102f95750506102f6999a6102ed9183516102a081610294602082018095611f66565b03848101835282611437565b519020602089810151858b015195519182019687526040820192909252336060820152608081019190915260a081019390935260643560c08401528260e081015b03908101835282611437565b51902093611cf7565b80f35b8061031161030b610321938c5161175e565b51612054565b61031b828661175e565b52611f0a565b61026e565b8880fd5b8780fd5b8480fd5b8380fd5b5080fd5b5091346103365760807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126103365767ffffffffffffffff9080358281116103325761038b903690830161164b565b60243583811161032e576103a2903690840161161a565b9390926103ad6114e6565b9160643590811161049f576103c4913691016115c1565b949093835151976103d489611ebb565b98885b81811061047d5750506102f697988151610425816103f9602082018095611f66565b037fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe08101835282611437565b5190206020860151828701519083519260208401947ffcf35f5ac6a2c28868dc44c302166470266239195f02b0ee408334829333b7668652840152336060840152608083015260a082015260a081526102ed8161141b565b808b61031b8261049461030b61049a968d5161175e565b9261175e565b6103d7565b8680fd5b5082346105bf57602090817ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126103325780359067ffffffffffffffff821161032e576104f49136910161161a565b929091845b848110610504578580f35b8061051a610515600193888861196c565b61197c565b61052f84610529848a8a61196c565b0161197c565b3389528385528589209173ffffffffffffffffffffffffffffffffffffffff80911692838b528652868a20911690818a5285528589207fffffffffffffffffffffffffffffffff000000000000000000000000000000008154169055855191825284820152\
7f89b1add15eff56b3dfe299ad94e01f2b52fbcb80ae1a3baea6ae8c04cb2b98a4853392a2016104f9565b8280fd5b50346103365760607ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261033657610676816105ff6114a0565b936106086114c3565b6106106114e6565b73ffffffffffffffffffffffffffffffffffffffff968716835260016020908152848420928816845291825283832090871683528152919020549251938316845260a083901c65ffffffffffff169084015260d09190911c604083015281906060820190565b0390f35b50346103365760807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc360112610336576106b26114a0565b906106bb6114c3565b916106c46114e6565b65ffffffffffff926064358481169081810361032a5779ffffffffffff0000000000000000000000000000000000000000947fda9fa7c1b00402c17d0161b249b1ab8bbec047c5a52207b9c112deffd817036b94338a5260016020527fffffffffffff0000000000000000000000000000000000000000000000000000858b209873ffffffffffffffffffffffffffffffffffffffff809416998a8d5260205283878d209b169a8b8d52602052868c209486156000146107a457504216925b8454921697889360a01b16911617179055815193845260208401523392a480f35b905092610783565b5082346105bf5760607ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126105bf576107e56114a0565b906107ee6114c3565b9265ffffffffffff604435818116939084810361032a57338852602091600183528489209673ffffffffffffffffffffffffffffffffffffffff80911697888b528452858a20981697888a5283528489205460d01c93848711156109175761ffff9085840316116108f05750907f55eb90d810e1700b35a8e7e25395ff7f2b2259abd7415ca2284dfb1c246418f393929133895260018252838920878a528252838920888a5282528389209079ffffffffffffffffffffffffffffffffffffffffffffffffffff\
7fffffffffffff000000000000000000000000000000000000000000000000000083549260d01b16911617905582519485528401523392a480f35b84517f24d35a26000000000000000000000000000000000000000000000000000000008152fd5b5084517f756688fe000000000000000000000000000000000000000000000000000000008152fd5b503461033657807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc360112610336578060209273ffffffffffffffffffffffffffffffffffffffff61098f6114a0565b1681528084528181206024358252845220549051908152f35b5082346105bf57817ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126105bf577f3704902f963766a4e561bbaab6e6cdc1b1dd12f6e9e99648da8843b3f46b918d90359160243533855284602052818520848652602052818520818154179055815193845260208401523392a280f35b8234610a9a5760807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc360112610a9a57610a606114a0565b610a686114c3565b610a706114e6565b6064359173ffffffffffffffffffffffffffffffffffffffff8316830361032e576102f6936117a1565b80fd5b503461033657817ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261033657602090610ad7611b1e565b9051908152f35b508290346105bf576101007ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126105bf57610b1a3661152a565b90807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7c36011261033257610b4c611478565b9160e43567ffffffffffffffff8111610bda576102f694610b6f913691016115c1565b939092610b7c8351612054565b6020840151828501519083519260208401947f939c21a48a8dbe3a9a2404a1d46691e4d39f6583d6ec6b35714604c986d801068652840152336060840152608083015260a082015260a08152610bd18161141b565b51902091611c25565b8580fd5b509134610336576101007ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261033657610c186114a0565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffdc360160c08112610332576080855191610c51836113e3565b1261033257845190610c6282611398565b73ffffffffffffffffffffffffffffffffffffffff91602435838116810361049f578152604435838116810361049f57602082015265ffffffffffff606435818116810361032a5788830152608435908116810361049f576060820152815260a435938285168503610bda576020820194855260c4359087830182815260e43567ffffffffffffffff811161032657610cfe90369084016115c1565b929093804211610d88575050918591610d786102f6999a610d7e95610d238851611fbe565b90898c511690519083519260208401947ff3841cd1ff0085026a6327b620b67997ce40f282c88a8e905a7a5626e310f3d086528401526060830152608082015260808152610d70816113ff565b519020611bd9565b916120c7565b519251169161199d565b602492508a51917fcd21db4f000000000000000000000000000000000000000000000000000000008352820152fd5b5091346103365760607ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc93818536011261033257610df36114a0565b9260249081359267ffffffffffffffff9788851161032a578590853603011261049f578051978589018981108282111761104a578252848301358181116103265785019036602383011215610326578382013591610e50836115ef565b90610e5d85519283611437565b838252602093878584019160071b83010191368311611046578801905b828210610fe9575050508a526044610e93868801611509565b96838c01978852013594838b0191868352604435908111610fe557610ebb90369087016115c1565b959096804211610fba575050508998995151610ed681611ebb565b908b5b818110610f9757505092889492610d7892610f6497958351610f02816103f98682018095611f66565b5190209073ffffffffffffffffffffffffffffffffffffffff9a8b8b51169151928551948501957faf1b0d30d2cab0380e68f0689007e3254993c596f2fdd0aaa7f4d04f794408638752850152830152608082015260808152610d70816113ff565b51169082515192845b848110610f78578580f35b80610f918585610f8b600195875161175e565b5161199d565b01610f6d565b80610311610fac8e9f9e93610fb2945161175e565b51611fbe565b9b9a9b610ed9565b8551917fcd21db4f000000000000000000000000000000000000000000000000000000008352820152fd5b8a80fd5b6080823603126110465785608091885161100281611398565b61100b85611509565b8152611018838601611509565b838201526110278a8601611607565b8a8201528d611037818701611607565b90820152815201910190610e7a565b8c80fd5b84896041867f4e487b7100000000000000000000000000000000000000000000000000000000835252fd5b5082346105bf576101407ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126105bf576110b03661152a565b91807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7c360112610332576110e2611478565b67ffffffffffffffff93906101043585811161049f5761110590369086016115c1565b90936101243596871161032a57611125610bd1966102f6983691016115c1565b969095825190611134826113ff565b606482527f5065726d69745769746e6573735472616e7366657246726f6d28546f6b656e5060208301527f65726d697373696f6e73207065726d69747465642c6164647265737320737065848301527f6e6465722c75696e74323536206e6f6e63652c75696e7432353620646561646c60608301527f696e652c0000000000000000000000000000000000000000000000000000000060808301528351948591816111e3602085018096611f93565b918237018b8152039361121c7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe095868101835282611437565b5190209261122a8651612054565b6020878101518589015195519182019687526040820192909252336060820152608081019190915260a081019390935260e43560c08401528260e081016102e1565b5082346105bf576020807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261033257813567ffffffffffffffff92838211610bda5736602383011215610bda5781013592831161032e576024906007368386831b8401011161049f57865b8581106112e5578780f35b80821b83019060807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffdc83360301126103265761139288876001946060835161132c81611398565b611368608461133c8d8601611509565b9485845261134c60448201611509565b809785015261135d60648201611509565b809885015201611509565b918291015273ffffffffffffffffffffffffffffffffffffffff80808093169516931691166117a1565b016112da565b6080810190811067ffffffffffffffff8211176113b457604052565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b6060810190811067ffffffffffffffff8211176113b457604052565b60a0810190811067ffffffffffffffff8211176113b457604052565b60c0810190811067ffffffffffffffff8211176113b457604052565b90601f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0910116810190811067ffffffffffffffff8211176113b457604052565b60c4359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b600080fd5b6004359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b6024359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b6044359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc01906080821261149b576040805190611563826113e3565b8082941261149b57805181810181811067ffffffffffffffff8211176113b457825260043573ffffffffffffffffffffffffffffffffffffffff8116810361149b578152602435602082015282526044356020830152606435910152565b9181601f8401121561149b5782359167ffffffffffffffff831161149b576020838186019501011161149b57565b67ffffffffffffffff81116113b45760051b60200190565b359065ffffffffffff8216820361149b57565b9181601f8401121561149b5782359167ffffffffffffffff831161149b576020808501948460061b01011161149b57565b91909160608184031261149b576040805191611666836113e3565b8294813567ffffffffffffffff9081811161149b57830182601f8201121561149b578035611693816115ef565b926116a087519485611437565b818452602094858086019360061b8501019381851161149b579086899897969594939201925b8484106116e3575050505050855280820135908501520135910152565b90919293949596978483031261149b578851908982019082821085831117611730578a928992845261171487611509565b81528287013583820152815201930191908897969594936116c6565b602460007f4e487b710000000000000000000000000000000000000000000000000000000081526041600452fd5b80518210156117725760209160051b010190565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052603260045260246000fd5b92919273ffffffffffffffffffffffffffffffffffffffff604060008284168152600160205282828220961695868252602052818120338252602052209485549565ffffffffffff8760a01c16804211611884575082871696838803611812575b5050611810955016926118b5565b565b878484161160001461184f57602488604051907ff96fb0710000000000000000000000000000000000000000000000000000000082526004820152fd5b7fffffffffffffffffffffffff000000000000000000000000000000000000000084846118109a031691161790553880611802565b602490604051907fd81b2f2e0000000000000000000000000000000000000000000000000000000082526004820152fd5b9060006064926020958295604051947f23b872dd0000000000000000000000000000000000000000000000000000000086526004860152602485015260448401525af13d15601f3d116001600051141617161561190e57565b60646040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601460248201527f5452414e534645525f46524f4d5f4641494c45440000000000000000000000006044820152fd5b91908110156117725760061b0190565b3573ffffffffffffffffffffffffffffffffffffffff8116810361149b5790565b9065ffffffffffff908160608401511673ffffffffffffffffffffffffffffffffffffffff908185511694826020820151169280866040809401511695169560009187835260016020528383208984526020528383209916988983526020528282209184835460d01c03611af5579185611ace94927fc6a377bfc4eb120024a8ac08eef205be16b817020812c73223e81d1bdb9708ec98979694508715600014611ad35779ffffffffffff00000000000000000000000000000000000000009042165b60a01b167fffffffffffff00000000000000000000000000000000000000000000000000006001860160d01b1617179055519384938491604091949373ffffffffffffffffffffffffffffffffffffffff606085019616845265ffffffffffff809216602085015216910152565b0390a4565b5079ffffffffffff000000000000000000000000000000000000000087611a60565b600484517f756688fe000000000000000000000000000000000000000000000000000000008152fd5b467f0000000000000000000000000000000000000000000000000000000000007a6903611b69577fd5a17abc3865df5c1400c0299bd4ce2eefc8114aec5f9d3dded1745783e57b9890565b60405160208101907f8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a86682527f9ac997416e8ff9d2ff6bebeb7149f65cdae5e32e2b90440b566bb3044041d36a604082015246606082015230608082015260808152611bd3816113ff565b51902090565b611be1611b1e565b906040519060208201927f190100000000000000000000000000000000000000000000000000000000000084526022830152604282015260428152611bd381611398565b9192909360a435936040840151804211611cc65750602084510151808611611c955750918591610d78611c6594611c60602088015186611e47565b611bd9565b73ffffffffffffffffffffffffffffffffffffffff809151511692608435918216820361149b57611810936118b5565b602490604051907f3728b83d0000000000000000000000000000000000000000000000000000000082526004820152fd5b602490604051907fcd21db4f0000000000000000000000000000000000000000000000000000000082526004820152fd5b959093958051519560409283830151804211611e175750848803611dee57611d2e918691610d7860209b611c608d88015186611e47565b60005b868110611d42575050505050505050565b611d4d81835161175e565b5188611d5a83878a61196c565b01359089810151808311611dbe575091818888886001968596611d84575b50505050505001611d31565b611db395611dad9273ffffffffffffffffffffffffffffffffffffffff6105159351169561196c565b916118b5565b803888888883611d78565b6024908651907f3728b83d0000000000000000000000000000000000000000000000000000000082526004820152fd5b600484517fff633a38000000000000000000000000000000000000000000000000000000008152fd5b6024908551907fcd21db4f0000000000000000000000000000000000000000000000000000000082526004820152fd5b9073ffffffffffffffffffffffffffffffffffffffff600160ff83161b9216600052600060205260406000209060081c6000526020526040600020818154188091551615611e9157565b60046040517f756688fe000000000000000000000000000000000000000000000000000000008152fd5b90611ec5826115ef565b611ed26040519182611437565b8281527fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0611f0082946115ef565b0190602036910137565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff8114611f375760010190565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b805160208092019160005b828110611f7f575050505090565b835185529381019392810192600101611f71565b9081519160005b838110611fab575050016000815290565b8060208092840101518185015201611f9a565b60405160208101917f65626cad6cb96493bf6f5ebea28756c966f023ab9e8a83a7101849d5573b3678835273ffffffffffffffffffffffffffffffffffffffff8082511660408401526020820151166060830152606065ffffffffffff9182604082015116608085015201511660a082015260a0815260c0810181811067ffffffffffffffff8211176113b45760405251902090565b6040516020808201927f618358ac3db8dc274f0cd8829da7e234bd48cd73c4a740aede1adec9846d06a1845273ffffffffffffffffffffffffffffffffffffffff81511660408401520151606082015260608152611bd381611398565b919082604091031261149b576020823592013590565b6000843b61222e5750604182036121ac576120e4828201826120b1565b939092604010156117725760209360009360ff6040608095013560f81c5b60405194855216868401526040830152606082015282805260015afa156121a05773ffffffffffffffffffffffffffffffffffffffff806000511691821561217657160361214c57565b60046040517f815e1d64000000000000000000000000000000000000000000000000000000008152fd5b60046040517f8baa579f000000000000000000000000000000000000000000000000000000008152fd5b6040513d6000823e3d90fd5b60408203612204576121c0918101906120b1565b91601b7f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff84169360ff1c019060ff8211611f375760209360009360ff608094612102565b60046040517f4be6321b000000000000000000000000000000000000000000000000000000008152fd5b929391601f928173ffffffffffffffffffffffffffffffffffffffff60646020957fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0604051988997889687947f1626ba7e000000000000000000000000000000000000000000000000000000009e8f8752600487015260406024870152816044870152868601378b85828601015201168101030192165afa9081156123a857829161232a575b507fffffffff000000000000000000000000000000000000000000000000000000009150160361230057565b60046040517fb0669cbc000000000000000000000000000000000000000000000000000000008152fd5b90506020813d82116123a0575b8161234460209383611437565b810103126103365751907fffffffff0000000000000000000000000000000000000000000000000000000082168203610a9a57507fffffffff0000000000000000000000000000000000000000000000000000000090386122d4565b3d9150612337565b6040513d84823e3d90fdfea164736f6c6343000811000a";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build the forward calls for executeAndCreateWithPermit2:
///   1. approve(dex, USDC)
///   2. dex.swap(USDC → WBTC)
fn build_forward_calls(usdc: Address, wbtc: Address, dex: Address) -> Vec<HTLCCoordinator::Call> {
    vec![
        HTLCCoordinator::Call {
            target: usdc,
            value: U256::ZERO,
            callData: Bytes::from(
                IERC20::approveCall {
                    spender: dex,
                    amount: U256::from(USDC_AMOUNT),
                }
                .abi_encode(),
            ),
        },
        HTLCCoordinator::Call {
            target: dex,
            value: U256::ZERO,
            callData: Bytes::from(
                MockDEX::swapCall {
                    tokenIn: usdc,
                    tokenOut: wbtc,
                    amountIn: U256::from(USDC_AMOUNT),
                    minAmountOut: U256::from(EXPECTED_WBTC),
                }
                .abi_encode(),
            ),
        },
    ]
}

fn compute_calls_hash(calls: &[HTLCCoordinator::Call]) -> FixedBytes<32> {
    keccak256(calls.abi_encode())
}

async fn sign_permit2(
    provider: impl Provider + Clone,
    coordinator_addr: Address,
    depositor_key: &PrivateKeySigner,
    token: Address,
    amount: U256,
    preimage_hash: FixedBytes<32>,
    output_token: Address,
    claim_address: Address,
    timelock: U256,
    calls: &[HTLCCoordinator::Call],
) -> Result<(ISignatureTransfer::PermitTransferFrom, Bytes)> {
    let calls_hash = compute_calls_hash(calls);

    let coordinator = HTLCCoordinator::new(coordinator_addr, provider.clone());
    let coordinator_typehash = coordinator.TYPEHASH_EXECUTE_AND_CREATE().call().await?;

    let witness = keccak256(
        (
            coordinator_typehash,
            preimage_hash,
            output_token,
            claim_address,
            depositor_key.address(), // refundAddress: the depositor is the HTLC sender
            timelock,
            calls_hash,
        )
            .abi_encode(),
    );

    let permit = ISignatureTransfer::PermitTransferFrom {
        permitted: ISignatureTransfer::TokenPermissions { token, amount },
        nonce: U256::ZERO,
        deadline: timelock + U256::from(3600),
    };

    let typehash = keccak256(
        format!(
            "{}{}",
            PERMIT2_WITNESS_TYPEHASH_STUB,
            coordinator.TYPESTRING_EXECUTE_AND_CREATE().call().await?
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
            coordinator_addr,
            permit.nonce,
            permit.deadline,
            witness,
        )
            .abi_encode(),
    );

    let domain_separator = IPermit2::new(PERMIT2_ADDRESS, provider)
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

    let sig = depositor_key.sign_hash(&digest).await?;
    let signature = Bytes::from(sig.as_bytes().to_vec());

    Ok((permit, signature))
}

/// 1. Lock and execute: swap USDC → WBTC via DEX and lock WBTC in HTLC
#[tokio::test]
async fn test_lock_and_execute() -> Result<()> {
    println!("\n=== test_lock_and_execute ===\n");

    // -- 1. Setup: spawn Anvil and create wallets --
    println!("1. Spawning Anvil and creating wallets ...");
    let anvil = Anvil::new().block_time(1).try_spawn()?;
    let endpoint = anvil.endpoint_url();

    let deployer_key: PrivateKeySigner = anvil.keys()[0].clone().into();
    let alice_key: PrivateKeySigner = anvil.keys()[1].clone().into();
    let bob_key: PrivateKeySigner = anvil.keys()[2].clone().into();
    let alice_address = alice_key.address();
    let bob_address = bob_key.address();

    let deployer_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(deployer_key))
        .connect_http(endpoint.clone());

    let alice_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(alice_key.clone()))
        .connect_http(endpoint.clone());

    let raw_provider = ProviderBuilder::new().connect_http(endpoint.clone());

    println!("   Alice: {alice_address}");
    println!("   Bob:   {bob_address}");

    // -- 2. Deploy contracts (with Permit2) --
    println!("\n2. Deploying contracts ...");
    let htlc = HTLCErc20::deploy(
        &deployer_provider,
        deployer_provider.default_signer_address(),
    )
    .await?;
    raw_provider
        .raw_request::<_, ()>(
            "anvil_setCode".into(),
            &[
                format!("{PERMIT2_ADDRESS:?}"),
                PERMIT2_RUNTIME_CODE.to_string(),
            ],
        )
        .await?;
    let coordinator =
        HTLCCoordinator::deploy(&deployer_provider, *htlc.address(), PERMIT2_ADDRESS).await?;
    let usdc = MockUSDC::deploy(&deployer_provider).await?;
    let wbtc = MockWBTC::deploy(&deployer_provider).await?;
    let dex = MockDEX::deploy(&deployer_provider).await?;
    println!("   HTLCErc20:       {}", htlc.address());
    println!("   HTLCCoordinator: {}", coordinator.address());
    println!("   Permit2:         {PERMIT2_ADDRESS}");
    println!("   MockUSDC:        {}", usdc.address());
    println!("   MockWBTC:        {}", wbtc.address());
    println!("   MockDEX:         {}", dex.address());

    // -- 3. Fund Alice and DEX --
    println!("\n3. Funding Alice with 100k USDC, DEX with 50 WBTC + 500k USDC ...");
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(alice_address, U256::from(100_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*wbtc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(5_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(500_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;

    // Set DEX rates: 60,000 USDC = 1 WBTC
    dex.setRate(
        *usdc.address(),
        *wbtc.address(),
        U256::from(EXPECTED_WBTC),
        U256::from(USDC_AMOUNT),
    )
    .send()
    .await?
    .get_receipt()
    .await?;
    dex.setRate(
        *wbtc.address(),
        *usdc.address(),
        U256::from(USDC_AMOUNT),
        U256::from(EXPECTED_WBTC),
    )
    .send()
    .await?
    .get_receipt()
    .await?;
    println!("   DEX rate: 60,000 USDC = 1 WBTC");

    // -- 4. Prepare preimage and timelock --
    println!("\n4. Preparing preimage and timelock ...");
    let preimage = FixedBytes::<32>::from([0xABu8; 32]);
    let preimage_hash = FixedBytes::<32>::from_slice(&Sha256::digest(preimage.as_slice()));
    let block_num = raw_provider.get_block_number().await?;
    let block = raw_provider
        .get_block_by_number(block_num.into())
        .await?
        .unwrap();
    let timelock = U256::from(block.header.timestamp + 3600);
    println!("   Preimage hash: {preimage_hash}");
    println!("   Timelock:      {timelock} (current + 1h)");

    // -- 5. Alice approves Permit2 to pull USDC --
    println!("\n5. Alice approving USDC to Permit2 ...");
    IERC20::new(*usdc.address(), &alice_provider)
        .approve(PERMIT2_ADDRESS, U256::MAX)
        .send()
        .await?
        .get_receipt()
        .await?;

    // -- 6. Build calls and executeAndCreateWithPermit2 --
    println!("\n6. Calling executeAndCreateWithPermit2 (approve DEX + swap) ...");
    let calls = build_forward_calls(*usdc.address(), *wbtc.address(), *dex.address());

    let (permit, signature) = sign_permit2(
        &raw_provider,
        *coordinator.address(),
        &alice_key,
        *usdc.address(),
        U256::from(USDC_AMOUNT),
        preimage_hash,
        *wbtc.address(),
        bob_address,
        timelock,
        &calls,
    )
    .await?;

    let coordinator_alice = HTLCCoordinator::new(*coordinator.address(), &alice_provider);
    let receipt = coordinator_alice
        .executeAndCreateWithPermit2(
            calls,
            preimage_hash,
            *wbtc.address(),
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
        "executeAndCreateWithPermit2 should succeed"
    );

    // -- 7. Verify --
    println!("\n7. Verifying ...");

    let wbtc_in_htlc = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(*htlc.address())
        .call()
        .await?;
    println!("   WBTC locked in HTLC: {wbtc_in_htlc}");
    assert_eq!(
        wbtc_in_htlc,
        U256::from(EXPECTED_WBTC),
        "HTLC should hold 1 WBTC"
    );

    let htlc_reader = HTLCErc20::new(*htlc.address(), &alice_provider);
    let is_active = htlc_reader
        .isActive(
            preimage_hash,
            U256::from(EXPECTED_WBTC),
            *wbtc.address(),
            alice_address,
            bob_address,
            timelock,
        )
        .call()
        .await?;
    println!("   Swap active: {is_active}");
    assert!(is_active, "swap should be active");

    let alice_usdc = IERC20::new(*usdc.address(), &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    println!("   Alice USDC remaining: {alice_usdc}");
    assert_eq!(
        alice_usdc,
        U256::from(40_000_000_000u128),
        "alice should have 40k USDC left"
    );

    println!("\n=== test_lock_and_execute PASSED ===\n");
    Ok(())
}

/// 2. Claim: after lock and execute, Bob redeems the HTLC with the preimage
#[tokio::test]
async fn test_claim() -> Result<()> {
    println!("\n=== test_claim ===\n");

    // -- 1. Setup --
    println!("1. Spawning Anvil and creating wallets ...");
    let anvil = Anvil::new().block_time(1).try_spawn()?;
    let endpoint = anvil.endpoint_url();

    let deployer_key: PrivateKeySigner = anvil.keys()[0].clone().into();
    let alice_key: PrivateKeySigner = anvil.keys()[1].clone().into();
    let bob_key: PrivateKeySigner = anvil.keys()[2].clone().into();
    let alice_address = alice_key.address();
    let bob_address = bob_key.address();

    let deployer_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(deployer_key))
        .connect_http(endpoint.clone());
    let alice_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(alice_key.clone()))
        .connect_http(endpoint.clone());
    let bob_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(bob_key))
        .connect_http(endpoint.clone());

    let raw_provider = ProviderBuilder::new().connect_http(endpoint.clone());

    println!("   Alice: {alice_address}");
    println!("   Bob:   {bob_address}");

    // -- 2. Deploy contracts (with Permit2) --
    println!("\n2. Deploying contracts ...");
    let htlc = HTLCErc20::deploy(
        &deployer_provider,
        deployer_provider.default_signer_address(),
    )
    .await?;
    raw_provider
        .raw_request::<_, ()>(
            "anvil_setCode".into(),
            &[
                format!("{PERMIT2_ADDRESS:?}"),
                PERMIT2_RUNTIME_CODE.to_string(),
            ],
        )
        .await?;
    let coordinator =
        HTLCCoordinator::deploy(&deployer_provider, *htlc.address(), PERMIT2_ADDRESS).await?;
    let usdc = MockUSDC::deploy(&deployer_provider).await?;
    let wbtc = MockWBTC::deploy(&deployer_provider).await?;
    let dex = MockDEX::deploy(&deployer_provider).await?;
    println!("   HTLCErc20:       {}", htlc.address());
    println!("   HTLCCoordinator: {}", coordinator.address());

    // -- 3. Fund Alice and DEX --
    println!("\n3. Funding Alice with 100k USDC, DEX with 50 WBTC + 500k USDC ...");
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(alice_address, U256::from(100_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*wbtc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(5_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(500_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    dex.setRate(
        *usdc.address(),
        *wbtc.address(),
        U256::from(EXPECTED_WBTC),
        U256::from(USDC_AMOUNT),
    )
    .send()
    .await?
    .get_receipt()
    .await?;

    // -- 4. Alice creates swap via executeAndCreateWithPermit2 --
    println!("\n4. Alice creating swap via executeAndCreateWithPermit2 ...");
    let preimage = FixedBytes::<32>::from([0xABu8; 32]);
    let preimage_hash = FixedBytes::<32>::from_slice(&Sha256::digest(preimage.as_slice()));
    let block_num = raw_provider.get_block_number().await?;
    let block = raw_provider
        .get_block_by_number(block_num.into())
        .await?
        .unwrap();
    let timelock = U256::from(block.header.timestamp + 3600);
    println!("   Preimage hash: {preimage_hash}");
    println!("   Timelock:      {timelock}");

    IERC20::new(*usdc.address(), &alice_provider)
        .approve(PERMIT2_ADDRESS, U256::MAX)
        .send()
        .await?
        .get_receipt()
        .await?;

    let calls = build_forward_calls(*usdc.address(), *wbtc.address(), *dex.address());

    let (permit, signature) = sign_permit2(
        &raw_provider,
        *coordinator.address(),
        &alice_key,
        *usdc.address(),
        U256::from(USDC_AMOUNT),
        preimage_hash,
        *wbtc.address(),
        bob_address,
        timelock,
        &calls,
    )
    .await?;

    let create_receipt = HTLCCoordinator::new(*coordinator.address(), &alice_provider)
        .executeAndCreateWithPermit2(
            calls,
            preimage_hash,
            *wbtc.address(),
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
        create_receipt.transaction_hash,
        create_receipt.status()
    );

    let wbtc_locked = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(*htlc.address())
        .call()
        .await?;
    println!("   WBTC locked in HTLC: {wbtc_locked}");

    // -- 5. Bob redeems with preimage --
    println!("\n5. Bob claiming HTLC with preimage ...");
    let bob_wbtc_before = IERC20::new(*wbtc.address(), &bob_provider)
        .balanceOf(bob_address)
        .call()
        .await?;
    println!("   Bob WBTC before: {bob_wbtc_before}");

    let htlc_bob = HTLCErc20::new(*htlc.address(), &bob_provider);
    let redeem_receipt = htlc_bob
        .redeem(
            preimage,
            U256::from(EXPECTED_WBTC),
            *wbtc.address(),
            alice_address,
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
    assert!(redeem_receipt.status(), "redeem should succeed");

    // -- 6. Verify post-claim state --
    println!("\n6. Verifying post-claim state ...");

    let bob_wbtc_after = IERC20::new(*wbtc.address(), &bob_provider)
        .balanceOf(bob_address)
        .call()
        .await?;
    println!("   Bob WBTC after:  {bob_wbtc_after}");
    assert_eq!(
        bob_wbtc_after - bob_wbtc_before,
        U256::from(EXPECTED_WBTC),
        "Bob should have received 1 WBTC"
    );

    let htlc_balance = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(*htlc.address())
        .call()
        .await?;
    println!("   HTLC WBTC balance: {htlc_balance}");
    assert_eq!(htlc_balance, U256::ZERO, "HTLC should be empty");

    let is_active = HTLCErc20::new(*htlc.address(), &alice_provider)
        .isActive(
            preimage_hash,
            U256::from(EXPECTED_WBTC),
            *wbtc.address(),
            alice_address,
            bob_address,
            timelock,
        )
        .call()
        .await?;
    println!("   Swap active: {is_active}");
    assert!(!is_active, "swap should no longer be active");

    println!("\n=== test_claim PASSED ===\n");
    Ok(())
}

/// 3. Refund the WBTC: after the timelock Alice refunds on the HTLC herself
#[tokio::test]
async fn test_depositor_refunds() -> Result<()> {
    let anvil = Anvil::new().block_time(1).try_spawn()?;
    let endpoint = anvil.endpoint_url();

    let deployer_key: PrivateKeySigner = anvil.keys()[0].clone().into();
    let alice_key: PrivateKeySigner = anvil.keys()[1].clone().into();
    let bob_key: PrivateKeySigner = anvil.keys()[2].clone().into();
    let charlie_key: PrivateKeySigner = anvil.keys()[3].clone().into();
    let alice_address = alice_key.address();
    let bob_address = bob_key.address();

    let deployer_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(deployer_key))
        .connect_http(endpoint.clone());
    let alice_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(alice_key.clone()))
        .connect_http(endpoint.clone());
    let charlie_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(charlie_key))
        .connect_http(endpoint.clone());

    let raw_provider = ProviderBuilder::new().connect_http(endpoint.clone());

    // Deploy (with Permit2)
    let htlc = HTLCErc20::deploy(
        &deployer_provider,
        deployer_provider.default_signer_address(),
    )
    .await?;
    raw_provider
        .raw_request::<_, ()>(
            "anvil_setCode".into(),
            &[
                format!("{PERMIT2_ADDRESS:?}"),
                PERMIT2_RUNTIME_CODE.to_string(),
            ],
        )
        .await?;
    let coordinator =
        HTLCCoordinator::deploy(&deployer_provider, *htlc.address(), PERMIT2_ADDRESS).await?;
    let usdc = MockUSDC::deploy(&deployer_provider).await?;
    let wbtc = MockWBTC::deploy(&deployer_provider).await?;
    let dex = MockDEX::deploy(&deployer_provider).await?;

    // Fund
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(alice_address, U256::from(100_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*wbtc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(5_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(500_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    dex.setRate(
        *usdc.address(),
        *wbtc.address(),
        U256::from(EXPECTED_WBTC),
        U256::from(USDC_AMOUNT),
    )
    .send()
    .await?
    .get_receipt()
    .await?;

    // Create swap via Permit2
    let preimage = FixedBytes::<32>::from([0xABu8; 32]);
    let preimage_hash = FixedBytes::<32>::from_slice(&Sha256::digest(preimage.as_slice()));
    let block_num = raw_provider.get_block_number().await?;
    let block = raw_provider
        .get_block_by_number(block_num.into())
        .await?
        .unwrap();
    let timelock_ts = block.header.timestamp + 3600;
    let timelock = U256::from(timelock_ts);

    IERC20::new(*usdc.address(), &alice_provider)
        .approve(PERMIT2_ADDRESS, U256::MAX)
        .send()
        .await?
        .get_receipt()
        .await?;

    let calls = build_forward_calls(*usdc.address(), *wbtc.address(), *dex.address());

    let (permit, signature) = sign_permit2(
        &raw_provider,
        *coordinator.address(),
        &alice_key,
        *usdc.address(),
        U256::from(USDC_AMOUNT),
        preimage_hash,
        *wbtc.address(),
        bob_address,
        timelock,
        &calls,
    )
    .await?;

    HTLCCoordinator::new(*coordinator.address(), &alice_provider)
        .executeAndCreateWithPermit2(
            calls,
            preimage_hash,
            *wbtc.address(),
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

    // Alice should have 0 WBTC before refund
    let alice_wbtc_before = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    assert_eq!(
        alice_wbtc_before,
        U256::ZERO,
        "alice should have 0 WBTC before refund"
    );

    // Advance time past timelock
    raw_provider
        .raw_request::<_, serde_json::Value>(
            "evm_setNextBlockTimestamp".into(),
            vec![timelock_ts + 1],
        )
        .await?;
    raw_provider
        .raw_request::<_, serde_json::Value>("evm_mine".into(), Vec::<u64>::new())
        .await?;

    // Charlie is not the sender: his refund addresses a key that does not exist
    let charlie_refund = HTLCErc20::new(*htlc.address(), &charlie_provider)
        .refund_0(
            preimage_hash,
            U256::from(EXPECTED_WBTC),
            *wbtc.address(),
            bob_address,
            timelock,
        )
        .send()
        .await;
    assert!(
        charlie_refund.is_err(),
        "a stranger must not be able to refund"
    );

    // Alice is the HTLC sender; she refunds straight on the HTLC
    let receipt = HTLCErc20::new(*htlc.address(), &alice_provider)
        .refund_0(
            preimage_hash,
            U256::from(EXPECTED_WBTC),
            *wbtc.address(),
            bob_address,
            timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;
    assert!(receipt.status(), "refund should succeed");

    // Verify: HTLC empty
    let htlc_balance = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(*htlc.address())
        .call()
        .await?;
    assert_eq!(htlc_balance, U256::ZERO, "HTLC should be empty");

    // Verify: Alice got WBTC directly
    let alice_wbtc_after = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    assert_eq!(
        alice_wbtc_after,
        U256::from(EXPECTED_WBTC),
        "alice should have 1 WBTC"
    );

    // Verify: swap no longer active
    let is_active = HTLCErc20::new(*htlc.address(), &alice_provider)
        .isActive(
            preimage_hash,
            U256::from(EXPECTED_WBTC),
            *wbtc.address(),
            alice_address,
            bob_address,
            timelock,
        )
        .call()
        .await?;
    assert!(!is_active, "swap should no longer be active");

    println!("test_depositor_refunds passed");
    Ok(())
}
