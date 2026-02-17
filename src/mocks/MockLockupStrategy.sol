// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Lockup strategy mock implementing the interface your vault expects.
contract MockLockupStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable ASSET;
    uint256 public immutable LOCKUP_DELAY;

    struct Req {
        bool claimed;
        address owner;
        uint256 amount;
        uint256 unlockTime;
    }

    uint256 public nextId = 1;
    mapping(uint256 => Req) public reqs;
    mapping(address => uint256) public balanceOfOwner; // assets deposited (net of successful claims)

    constructor(IERC20 asset_, uint256 lockupDelay_) {
        ASSET = asset_;
        LOCKUP_DELAY = lockupDelay_;
    }

    /// NOTE: Not used anywhere after adding `depositFor` fn.
    function deposit(uint256 assets) external returns (uint256 shares) {
        return _depositFor(msg.sender, assets);
    }

    function depositFor(address owner, uint256 assets) external returns (uint256 shares) {
        return _depositFor(owner, assets);
    }

    function _depositFor(address owner, uint256 assets) private returns (uint256 shares) {
        require(owner != address(0), "bad owner");
        require(assets > 0, "zero");

        // Pull funds from whoever is calling (CoreWriter in the actionId=2 path)
        ASSET.safeTransferFrom(msg.sender, address(this), assets);

        // Credit the vault (owner) as the position owner
        balanceOfOwner[owner] += assets;

        return assets; // 1:1 shares
    }

    function totalAssetsOf(address owner) external view returns (uint256 assets) {
        return balanceOfOwner[owner];
    }

    function requestWithdraw(uint256 assets) external returns (uint256 requestId) {
        require(assets > 0, "zero");
        require(balanceOfOwner[msg.sender] >= assets, "insufficient");
        // Reserve it (deduct immediately) so NAV drops right away
        balanceOfOwner[msg.sender] -= assets;

        requestId = nextId++;
        reqs[requestId] =
            Req({owner: msg.sender, amount: assets, unlockTime: block.timestamp + LOCKUP_DELAY, claimed: false});
    }

    function isRequestClaimable(uint256 requestId) external view returns (bool) {
        Req memory r = reqs[requestId];
        if (r.owner == address(0)) return false;
        if (r.claimed) return false;
        return block.timestamp >= r.unlockTime;
    }

    function claim(uint256 requestId) external returns (uint256 assetsClaimed) {
        Req storage r = reqs[requestId];
        require(r.owner != address(0), "bad id");
        require(!r.claimed, "claimed");
        require(block.timestamp >= r.unlockTime, "not unlocked");

        r.claimed = true;
        assetsClaimed = r.amount;

        ASSET.safeTransfer(r.owner, assetsClaimed);
    }
}
