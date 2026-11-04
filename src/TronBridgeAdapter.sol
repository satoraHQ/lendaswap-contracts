// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "./interfaces/IOFT.sol";

/// @notice Send-only native USDT payouts through the Arbitrum Legacy Mesh.
/// @dev Deployed separately from the standard USDT0 adapter. The source claim,
///      DEX swap and bridge send revert together; destination delivery is async.
contract TronBridgeAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint32 public constant TRON_EID = 30420;
    IERC20 public immutable token;
    IOFT public immutable mesh;
    address public immutable owner;

    error InvalidRoute();
    error InvalidRecipient();
    error InvalidDeployment();
    error InvalidAmount();
    error InsufficientFee();
    error InsufficientDelivery();
    error NotOwner();

    event BridgeInitiated(
        bytes32 indexed guid,
        bytes32 indexed recipient,
        address indexed caller,
        uint256 amountSent,
        uint256 amountReceived,
        uint256 nativeFee
    );

    constructor(address token_, address mesh_, address owner_) {
        if (token_ == address(0) || mesh_ == address(0) || owner_ == address(0)) revert InvalidDeployment();
        if (IOFT(mesh_).token() != token_) revert InvalidDeployment();
        token = IERC20(token_);
        mesh = IOFT(mesh_);
        owner = owner_;
    }

    receive() external payable {}

    /// @param to Tron account bytes, without the off-chain 0x41 prefix, left-padded to bytes32.
    /// @param minAmountLD Least USDT that must arrive on Tron, after the mesh fee. Set per
    ///        swap by the caller (and bound into its signed calls), so a mesh fee change
    ///        needs no redeploy.
    function bridgeBalance(uint32 dstEid, bytes32 to, uint256 minAmountLD) external payable nonReentrant {
        if (dstEid != TRON_EID) revert InvalidRoute();
        if (to == bytes32(0) || uint256(to) >> 160 != 0) revert InvalidRecipient();
        uint256 amount = token.balanceOf(msg.sender);
        if (minAmountLD == 0 || minAmountLD > amount) revert InvalidAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        token.forceApprove(address(mesh), amount);
        SendParam memory param = SendParam(dstEid, to, amount, minAmountLD, "", "", "");
        MessagingFee memory fee = mesh.quoteSend(param, false);
        if (msg.value < fee.nativeFee) revert InsufficientFee();
        (MessagingReceipt memory receipt, OFTReceipt memory delivered) =
            mesh.send{value: fee.nativeFee}(param, fee, address(this));
        if (delivered.amountSentLD != amount || delivered.amountReceivedLD < minAmountLD) {
            revert InsufficientDelivery();
        }
        token.forceApprove(address(mesh), 0);
        emit BridgeInitiated(
            receipt.guid, to, msg.sender, delivered.amountSentLD, delivered.amountReceivedLD, fee.nativeFee
        );
    }

    /// @notice Recover tokens sent to the adapter by mistake. The adapter holds
    ///         no tokens between calls: each bridge call forwards everything it pulls.
    function rescueToken(IERC20 asset, address recipient, uint256 amount) external nonReentrant {
        if (msg.sender != owner) revert NotOwner();
        asset.safeTransfer(recipient, amount);
    }

    /// @notice Withdraw buffered native gas left over after exact-fee sends.
    function withdraw(address payable recipient) external nonReentrant {
        if (msg.sender != owner) revert NotOwner();
        (bool success,) = recipient.call{value: address(this).balance}("");
        require(success, "ETH transfer failed");
    }
}
