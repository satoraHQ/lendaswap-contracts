// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {HTLCNative, SwapKey} from "../src/HTLCNative.sol";

contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// Drives the HTLC through every entry point with a deliberately small parameter
/// pool (so keys collide, settled keys get re-created, and settlements get tried
/// under terms one parameter away from a real swap) and keeps a ghost model of what
/// each call must have done. Any disagreement with the contract reverts here, and
/// `fail-on-revert` turns that into a failed invariant run.
contract HTLCNativeHandler is CommonBase, StdCheats, StdUtils {
    struct Swap {
        bytes32 preimage;
        uint256 amount;
        address sender;
        address claimAddress;
        uint256 claimPk;
        uint256 timelock;
        SwapKey key;
    }

    HTLCNative public immutable htlc;
    address public immutable treasury;
    uint256 public immutable base;

    address[] actors;
    uint256[] actorPks;
    bytes32[] preimagePool;
    uint256[] timelockPool;

    Swap[] recorded;
    mapping(bytes32 => bool) seen;
    mapping(bytes32 => HTLCNative.SwapState) public ghostState;
    uint256 public ghostActiveSum;
    uint256 public ghostForced;
    uint256 public ghostRecovered;

    uint256 public countCreated;
    uint256 public countRedeemed;
    uint256 public countRefunded;
    uint256 public countCollabRefunded;
    uint256 public countRehashed;
    uint256 public countRejected;

    constructor() {
        htlc = new HTLCNative(address(this));
        treasury = makeAddr("treasury");
        base = block.timestamp;

        for (uint256 i = 0; i < 3; i++) {
            (address a, uint256 pk) = makeAddrAndKey(string(abi.encodePacked("actor", i)));
            actors.push(a);
            actorPks.push(pk);
        }
        preimagePool.push(bytes32(uint256(0xdeadbeef)));
        preimagePool.push(bytes32(uint256(0xcafe)));
        // Staggered so that within one run some swaps expire (and get refunded or
        // rejected for re-creation) while others stay redeemable throughout.
        timelockPool.push(5 minutes);
        timelockPool.push(30 minutes);
        timelockPool.push(2 hours);
    }

    // -- Ghost accessors --

    function swapCount() external view returns (uint256) {
        return recorded.length;
    }

    function swapAt(uint256 i) external view returns (Swap memory) {
        return recorded[i];
    }

    // -- Actions --

    function create(uint256 seed, bool explicitRefund) external {
        Swap memory s = _pick(seed);
        address payer = explicitRefund ? actors[(seed / 27) % 3] : s.sender;
        HTLCNative.SwapState expected = ghostState[SwapKey.unwrap(s.key)];
        uint256 ts = block.timestamp;
        bytes32 preimageHash = sha256(abi.encodePacked(s.preimage));

        vm.deal(payer, s.amount);
        vm.prank(payer);
        bool ok;
        bytes memory data;
        if (explicitRefund) {
            (ok, data) = address(htlc).call{value: s.amount}(
                abi.encodeWithSignature(
                    "create(bytes32,address,address,uint256)", preimageHash, s.sender, s.claimAddress, s.timelock
                )
            );
        } else {
            (ok, data) = address(htlc).call{value: s.amount}(
                abi.encodeWithSignature("create(bytes32,address,uint256)", preimageHash, s.claimAddress, s.timelock)
            );
        }

        if (ok) {
            require(expected == HTLCNative.SwapState.None, "handler: created over an occupied key");
            require(s.timelock > ts, "handler: created with an expired timelock");
            _record(s);
            ghostState[SwapKey.unwrap(s.key)] = HTLCNative.SwapState.Active;
            ghostActiveSum += s.amount;
            countCreated++;
        } else if (s.timelock <= ts) {
            require(bytes4(data) == HTLCNative.TimelockTooSoon.selector, "handler: wrong error for a late timelock");
            countRejected++;
        } else {
            require(expected != HTLCNative.SwapState.None, "handler: create failed on a fresh key");
            require(bytes4(data) == HTLCNative.SwapExists.selector, "handler: wrong error for an occupied key");
            countRejected++;
        }
    }

    function redeem(uint256 idx, bool bySig, uint256 callerSeed) external {
        if (recorded.length == 0) return;
        _redeem(recorded[idx % recorded.length], bySig, callerSeed);
    }

    /// A settlement attempt under terms one parameter away from a recorded swap.
    function redeemAdjacent(uint256 idx, uint8 mutation, bool bySig, uint256 callerSeed) external {
        if (recorded.length == 0) return;
        _redeem(_mutate(recorded[idx % recorded.length], mutation), bySig, callerSeed);
    }

    function refund(uint256 idx, bool toDestination, uint256 destSeed) external {
        if (recorded.length == 0) return;
        _refund(recorded[idx % recorded.length], toDestination, destSeed);
    }

    function refundAdjacent(uint256 idx, uint8 mutation, bool toDestination, uint256 destSeed) external {
        if (recorded.length == 0) return;
        _refund(_mutate(recorded[idx % recorded.length], mutation), toDestination, destSeed);
    }

    /// The sender refunds before the timelock with the claimant's signature.
    function collabRefund(uint256 idx) external {
        if (recorded.length == 0) return;
        _collabRefund(recorded[idx % recorded.length]);
    }

    function collabRefundAdjacent(uint256 idx, uint8 mutation) external {
        if (recorded.length == 0) return;
        _collabRefund(_mutate(recorded[idx % recorded.length], mutation));
    }

    /// The sender moves the lock to pooled new terms with the claimant's signature.
    function rehash(uint256 idx, uint256 newSeed) external {
        if (recorded.length == 0) return;
        _rehash(recorded[idx % recorded.length], newSeed);
    }

    function rehashAdjacent(uint256 idx, uint8 mutation, uint256 newSeed) external {
        if (recorded.length == 0) return;
        _rehash(_mutate(recorded[idx % recorded.length], mutation), newSeed);
    }

    /// Small steps: a run must spend calls both before and after the pooled timelocks
    /// (base + 5 min / 30 min / 2 h) so creates, early refunds and late refunds all get exercised.
    function warp(uint256 delta) external {
        vm.warp(block.timestamp + bound(delta, 0, 10 minutes));
    }

    function forceSend(uint256 amount) external {
        amount = bound(amount, 1, 5 ether);
        vm.deal(address(this), amount);
        new ForceSender{value: amount}(payable(address(htlc)));
        ghostForced += amount;
    }

    function recoverExcess() external {
        uint256 balance = address(htlc).balance;
        uint256 locked = htlc.lockedTotal();
        uint256 before = treasury.balance;

        try htlc.recoverExcess(payable(treasury)) {
            require(balance > locked, "handler: recovered with no excess");
            require(treasury.balance - before == balance - locked, "handler: recovered the wrong amount");
            require(address(htlc).balance == locked, "handler: recovery left the balance off the obligation");
            ghostRecovered += balance - locked;
        } catch (bytes memory data) {
            require(balance <= locked, "handler: recovery failed despite excess");
            require(bytes4(data) == HTLCNative.NoExcess.selector, "handler: wrong recovery error");
        }
    }

    // -- Internals --

    function _redeem(Swap memory s, bool bySig, uint256 callerSeed) internal {
        bytes32 k = SwapKey.unwrap(s.key);
        HTLCNative.SwapState expected = ghostState[k];
        address recipient = bySig ? actors[callerSeed % 3] : s.claimAddress;
        uint256 before = recipient.balance;

        bool ok;
        bytes memory data;
        if (bySig) {
            (uint8 v, bytes32 r, bytes32 s_) = _sign(s, recipient);
            vm.prank(recipient);
            (ok, data) = address(htlc)
                .call(
                    abi.encodeCall(
                        htlc.redeemBySig,
                        (s.preimage, s.amount, s.sender, s.timelock, recipient, address(0), 0, bytes32(0), v, r, s_)
                    )
                );
        } else {
            vm.prank(recipient);
            (ok, data) = address(htlc).call(abi.encodeCall(htlc.redeem, (s.preimage, s.amount, s.sender, s.timelock)));
        }

        if (ok) {
            require(expected == HTLCNative.SwapState.Active, "handler: redeemed a swap that was not Active");
            require(recipient.balance == before + s.amount, "handler: redeem paid the wrong amount");
            ghostState[k] = HTLCNative.SwapState.Redeemed;
            ghostActiveSum -= s.amount;
            countRedeemed++;
        } else {
            require(expected != HTLCNative.SwapState.Active, "handler: redeem failed on an Active swap");
            require(bytes4(data) == HTLCNative.SwapNotActive.selector, "handler: wrong redeem error");
            require(recipient.balance == before, "handler: failed redeem moved value");
            countRejected++;
        }
    }

    function _refund(Swap memory s, bool toDestination, uint256 destSeed) internal {
        bytes32 k = SwapKey.unwrap(s.key);
        HTLCNative.SwapState expected = ghostState[k];
        address recipient = toDestination ? actors[destSeed % 3] : s.sender;
        uint256 before = recipient.balance;
        uint256 ts = block.timestamp;
        bytes32 preimageHash = sha256(abi.encodePacked(s.preimage));

        vm.prank(s.sender);
        bool ok;
        bytes memory data;
        if (toDestination) {
            (ok, data) = address(htlc)
                .call(
                    abi.encodeWithSignature(
                        "refund(bytes32,uint256,address,uint256,address)",
                        preimageHash,
                        s.amount,
                        s.claimAddress,
                        s.timelock,
                        recipient
                    )
                );
        } else {
            (ok, data) = address(htlc)
                .call(
                    abi.encodeWithSignature(
                        "refund(bytes32,uint256,address,uint256)", preimageHash, s.amount, s.claimAddress, s.timelock
                    )
                );
        }

        if (ok) {
            require(expected == HTLCNative.SwapState.Active, "handler: refunded a swap that was not Active");
            require(ts >= s.timelock, "handler: refunded before the timelock");
            require(recipient.balance == before + s.amount, "handler: refund paid the wrong amount");
            ghostState[k] = HTLCNative.SwapState.Refunded;
            ghostActiveSum -= s.amount;
            countRefunded++;
        } else if (ts < s.timelock) {
            require(bytes4(data) == HTLCNative.TimelockNotExpired.selector, "handler: wrong early-refund error");
            countRejected++;
        } else {
            require(expected != HTLCNative.SwapState.Active, "handler: refund failed on an expired Active swap");
            require(bytes4(data) == HTLCNative.SwapNotActive.selector, "handler: wrong refund error");
            require(recipient.balance == before, "handler: failed refund moved value");
            countRejected++;
        }
    }

    function _collabRefund(Swap memory s) internal {
        bytes32 k = SwapKey.unwrap(s.key);
        HTLCNative.SwapState expected = ghostState[k];
        uint256 before = s.sender.balance;
        bytes32 preimageHash = sha256(abi.encodePacked(s.preimage));

        (uint8 v, bytes32 r, bytes32 s_) = _signRefund(s);
        vm.prank(s.sender);
        (bool ok, bytes memory data) =
            address(htlc).call(abi.encodeCall(htlc.refundBySig, (preimageHash, s.amount, s.timelock, v, r, s_)));

        if (ok) {
            require(expected == HTLCNative.SwapState.Active, "handler: collab-refunded a swap that was not Active");
            require(s.sender.balance == before + s.amount, "handler: collab refund paid the wrong amount");
            ghostState[k] = HTLCNative.SwapState.Refunded;
            ghostActiveSum -= s.amount;
            countCollabRefunded++;
        } else {
            require(expected != HTLCNative.SwapState.Active, "handler: collab refund failed on an Active swap");
            require(bytes4(data) == HTLCNative.SwapNotActive.selector, "handler: wrong collab refund error");
            require(s.sender.balance == before, "handler: failed collab refund moved value");
            countRejected++;
        }
    }

    function _rehash(Swap memory s, uint256 newSeed) internal {
        // Memory-to-memory assignment would alias `s`; the new terms need their own struct.
        Swap memory n = _copy(s);
        n.preimage = preimagePool[newSeed % 2];
        n.timelock = base + timelockPool[(newSeed / 2) % 3];
        n.key = _key(n);

        bytes32 k = SwapKey.unwrap(s.key);
        bytes32 nk = SwapKey.unwrap(n.key);
        HTLCNative.SwapState expected = ghostState[k];
        HTLCNative.SwapState expectedNew = ghostState[nk];
        uint256 ts = block.timestamp;
        uint256 lockedBefore = htlc.lockedTotal();
        uint256 balanceBefore = address(htlc).balance;

        (uint8 v, bytes32 r, bytes32 s_) = _signRehash(s, n);
        // The sha256 precompile is a call and would consume the prank if inlined.
        bytes memory callData = abi.encodeCall(
            htlc.rehash,
            (
                sha256(abi.encodePacked(s.preimage)),
                s.amount,
                s.timelock,
                sha256(abi.encodePacked(n.preimage)),
                n.timelock,
                v,
                r,
                s_
            )
        );
        vm.prank(s.sender);
        (bool ok, bytes memory data) = address(htlc).call(callData);

        if (ok) {
            require(expected == HTLCNative.SwapState.Active, "handler: rehashed a swap that was not Active");
            require(expectedNew == HTLCNative.SwapState.None, "handler: rehashed onto an occupied key");
            require(n.timelock > ts, "handler: rehashed to an expired timelock");
            require(n.timelock >= s.timelock, "handler: rehash shortened the timelock");
            require(htlc.lockedTotal() == lockedBefore, "handler: rehash moved the obligation");
            require(address(htlc).balance == balanceBefore, "handler: rehash moved value");
            ghostState[k] = HTLCNative.SwapState.Rehashed;
            ghostState[nk] = HTLCNative.SwapState.Active;
            _record(n);
            countRehashed++;
        } else if (n.timelock <= ts) {
            require(bytes4(data) == HTLCNative.TimelockTooSoon.selector, "handler: wrong error for a late rehash");
            countRejected++;
        } else if (n.timelock < s.timelock) {
            require(
                bytes4(data) == HTLCNative.TimelockShortened.selector, "handler: wrong error for a shortened rehash"
            );
            countRejected++;
        } else if (expected != HTLCNative.SwapState.Active) {
            require(bytes4(data) == HTLCNative.SwapNotActive.selector, "handler: wrong rehash error on the old key");
            countRejected++;
        } else {
            require(expectedNew != HTLCNative.SwapState.None, "handler: rehash failed onto a fresh key");
            require(bytes4(data) == HTLCNative.SwapExists.selector, "handler: wrong rehash error on the new key");
            countRejected++;
        }
    }

    /// Terms from a small pool: 2 preimages x 3 senders x 3 claimants x 2 amounts x 3 timelocks.
    function _pick(uint256 seed) internal view returns (Swap memory s) {
        s.preimage = preimagePool[seed % 2];
        s.sender = actors[(seed / 2) % 3];
        uint256 claimIdx = (seed / 6) % 3;
        s.claimAddress = actors[claimIdx];
        s.claimPk = actorPks[claimIdx];
        s.amount = ((seed / 18) % 2 + 1) * 1 ether;
        s.timelock = base + timelockPool[(seed / 36) % 3];
        s.key = _key(s);
    }

    function _mutate(Swap memory s, uint8 mutation) internal view returns (Swap memory m) {
        m = _copy(s);
        uint8 which = mutation % 5;
        if (which == 0) {
            m.amount = s.amount + 1;
        } else if (which == 1) {
            m.timelock = s.timelock + 1;
        } else if (which == 2) {
            m.sender = actors[(_index(s.sender) + 1) % 3];
        } else if (which == 3) {
            uint256 idx = (_index(s.claimAddress) + 1) % 3;
            m.claimAddress = actors[idx];
            m.claimPk = actorPks[idx];
        } else {
            m.preimage = preimagePool[(uint256(s.preimage) == 0xdeadbeef) ? 1 : 0];
        }
        m.key = _key(m);
    }

    function _copy(Swap memory s) internal pure returns (Swap memory c) {
        c.preimage = s.preimage;
        c.amount = s.amount;
        c.sender = s.sender;
        c.claimAddress = s.claimAddress;
        c.claimPk = s.claimPk;
        c.timelock = s.timelock;
        c.key = s.key;
    }

    function _record(Swap memory s) internal {
        bytes32 k = SwapKey.unwrap(s.key);
        if (seen[k]) return;
        seen[k] = true;
        recorded.push(s);
    }

    function _key(Swap memory s) internal view returns (SwapKey) {
        return htlc.computeKey(
            sha256(abi.encodePacked(s.preimage)), s.amount, address(0), s.sender, s.claimAddress, s.timelock
        );
    }

    function _index(address a) internal view returns (uint256) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (actors[i] == a) return i;
        }
        revert("handler: unknown actor");
    }

    function _signRefund(Swap memory s) internal view returns (uint8 v, bytes32 r, bytes32 s_) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REFUND(), sha256(abi.encodePacked(s.preimage)), s.amount, s.sender, s.timelock
                    )
                )
            )
        );
        (v, r, s_) = vm.sign(s.claimPk, digest);
    }

    function _signRehash(Swap memory s, Swap memory n) internal view returns (uint8 v, bytes32 r, bytes32 s_) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REHASH(),
                        sha256(abi.encodePacked(s.preimage)),
                        s.amount,
                        s.sender,
                        s.timelock,
                        sha256(abi.encodePacked(n.preimage)),
                        n.timelock
                    )
                )
            )
        );
        (v, r, s_) = vm.sign(s.claimPk, digest);
    }

    function _sign(Swap memory s, address caller) internal view returns (uint8 v, bytes32 r, bytes32 s_) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REDEEM(),
                        s.preimage,
                        s.amount,
                        s.sender,
                        s.timelock,
                        caller,
                        caller,
                        address(0),
                        uint256(0),
                        bytes32(0)
                    )
                )
            )
        );
        (v, r, s_) = vm.sign(s.claimPk, digest);
    }
}

/// @notice Handler-driven invariants: the balance always covers `lockedTotal`,
///         `lockedTotal` is exactly the sum of Active swaps, the state machine only
///         moves forward, and the owner can only ever move what was force-sent in.
contract HTLCNativeInvariantTest is Test {
    HTLCNativeHandler handler;
    HTLCNative htlc;

    function setUp() public {
        handler = new HTLCNativeHandler();
        htlc = handler.htlc();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = HTLCNativeHandler.create.selector;
        selectors[1] = HTLCNativeHandler.redeem.selector;
        selectors[2] = HTLCNativeHandler.redeemAdjacent.selector;
        selectors[3] = HTLCNativeHandler.refund.selector;
        selectors[4] = HTLCNativeHandler.refundAdjacent.selector;
        selectors[5] = HTLCNativeHandler.collabRefund.selector;
        selectors[6] = HTLCNativeHandler.collabRefundAdjacent.selector;
        selectors[7] = HTLCNativeHandler.rehash.selector;
        selectors[8] = HTLCNativeHandler.rehashAdjacent.selector;
        selectors[9] = HTLCNativeHandler.warp.selector;
        selectors[10] = HTLCNativeHandler.forceSend.selector;
        selectors[11] = HTLCNativeHandler.recoverExcess.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// The handler's rehash action must be able to succeed: seed 0 and seed 1 differ in
    /// preimage, so the move lands on a fresh key and the ghost model follows it.
    function test_handler_rehashMovesTheLockToTheNewKey() public {
        handler.create(0, false);
        HTLCNativeHandler.Swap memory old = handler.swapAt(0);
        assertEq(handler.countRehashed(), 0);

        handler.rehash(0, 1);

        assertEq(handler.countRehashed(), 1, "the handler never rehashed");
        assertEq(handler.swapCount(), 2, "the new terms were not recorded");
        HTLCNativeHandler.Swap memory moved = handler.swapAt(1);
        assertTrue(SwapKey.unwrap(moved.key) != SwapKey.unwrap(old.key), "rehash kept the same key");
        (HTLCNative.SwapState oldState,) = htlc.swapState(old.key);
        (HTLCNative.SwapState newState,) = htlc.swapState(moved.key);
        assertEq(uint8(oldState), uint8(HTLCNative.SwapState.Rehashed));
        assertEq(uint8(newState), uint8(HTLCNative.SwapState.Active));
        assertEq(uint8(handler.ghostState(SwapKey.unwrap(old.key))), uint8(HTLCNative.SwapState.Rehashed));
        assertEq(uint8(handler.ghostState(SwapKey.unwrap(moved.key))), uint8(HTLCNative.SwapState.Active));
        assertEq(htlc.lockedTotal(), old.amount);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 256
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balanceCoversLockedTotal() public view {
        assertGe(address(htlc).balance, htlc.lockedTotal(), "balance must cover what active swaps are owed");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 256
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_lockedTotalIsSumOfActiveSwaps() public view {
        uint256 sum;
        uint256 n = handler.swapCount();
        for (uint256 i = 0; i < n; i++) {
            HTLCNativeHandler.Swap memory s = handler.swapAt(i);
            (HTLCNative.SwapState state,) = htlc.swapState(s.key);
            if (state == HTLCNative.SwapState.Active) sum += s.amount;
        }
        assertEq(htlc.lockedTotal(), sum, "lockedTotal must equal the sum over Active swaps");
        assertEq(htlc.lockedTotal(), handler.ghostActiveSum(), "lockedTotal must match the ghost model");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 256
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_stateMachineIsMonotonic() public view {
        uint256 n = handler.swapCount();
        for (uint256 i = 0; i < n; i++) {
            HTLCNativeHandler.Swap memory s = handler.swapAt(i);
            (HTLCNative.SwapState state, bytes32 preimage) = htlc.swapState(s.key);
            // The ghost only ever moves None -> Active -> terminal; the chain must agree.
            assertEq(uint8(state), uint8(handler.ghostState(SwapKey.unwrap(s.key))), "state diverged from the ghost");
            assertTrue(state != HTLCNative.SwapState.None, "a recorded swap was never None again");
            if (state == HTLCNative.SwapState.Rehashed) {
                assertEq(preimage, bytes32(0), "a rehashed key stores no preimage");
            }
            if (state == HTLCNative.SwapState.Redeemed) {
                assertEq(preimage, s.preimage, "a redeemed swap keeps its preimage");
            } else {
                assertEq(preimage, bytes32(0), "only a redeem stores a preimage");
            }
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 256
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ownerOnlyEverMovesForceSentEther() public view {
        assertLe(handler.ghostRecovered(), handler.ghostForced(), "recovery cannot exceed what was force-sent");
        assertEq(
            address(htlc).balance - htlc.lockedTotal(),
            handler.ghostForced() - handler.ghostRecovered(),
            "the surplus is exactly the force-sent ether not yet recovered"
        );
    }
}
