// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {ERC4626} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {Owned} from "../lib/solmate/src/auth/Owned.sol";
import {ReentrancyGuard} from "../lib/solmate/src/utils/ReentrancyGuard.sol";

interface ILockupStrategy {
    function deposit(uint256 assets) external returns (uint256 shares);
    function totalAssetsOf(address owner) external view returns (uint256 assets);
    function requestWithdraw(uint256 assets) external returns (uint256 requestId);
    function claim(uint256 requestId) external returns (uint256 assetsClaimed);
    function isRequestClaimable(uint256 requestId) external view returns (bool);
}

interface ICoreWriter {
    /// @notice Generic write entrypoint (mocked). For HLP deposits, use actionId=2 and data=abi.encode(protocol, amount).
    function write(uint8 actionId, bytes calldata data) external;
}

contract MultiStrategyVault is ERC4626, Owned, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bool public paused;
    uint16 public maxAllocPerProtocol;
    uint16 public immutable MAX_BPS;
    /// @notice Mock HyperCore CoreWriter used for depositing into HLP-like strategies (Action ID = 2).
    address public coreWriter;
    uint256 private constant SHARE_PRICE_SCALE = 1e27;

    struct PendingWithdrawal {
        bool claimed;
        address protocol; // lockup protocol address
        uint256 amount;
        uint256 requestId;
    }

    mapping(address => PendingWithdrawal[]) public pending;

    // Multi-protocol routing
    struct Allocation {
        bool isInstantOrLockup;
        address protocol;
        uint256 targetBps; // 5000 = 50%
        uint8 actionId; // 0 = direct deposit, 2 = HyperCore(HLP) deposit via CoreWriter
    }

    Allocation[] public allocations;

    event Invested(address indexed protocol, uint256 assets);
    event WithdrawalQueued(address indexed user, address indexed protocol, uint256 amount, uint256 requestId);
    event PendingClaimed(address indexed user, uint256 idx, uint256 amount);
    event RebalancePulled(address indexed protocol, uint256 assets);
    event RebalancePushed(address indexed protocol, uint256 assets);
    /// @dev sharePriceScaled = totalAssets * 1e27 / totalSupply (0 if totalSupply==0).
    event VaultCheckpoint(uint256 totalAssets, uint256 totalSupply, uint256 sharePriceScaled);

    error AlreadyClaimed();
    error BadActionId();
    error BadCoreWriter();
    error BadIdx();
    error BadProtocol();
    error CapExceeded();
    error CapPerProtocolExceeded();
    error CoreWriterNotSet();
    error InstantActionId();
    error InsufficientLockupLiquidity();
    error MaxTargetBpsReached();
    error NeedAllocations();
    error NeedAtleastTwoAllocations();
    error NotClaimable();
    error NothingClaimed();
    error ShortClaim();
    error ZeroBps();

    constructor(IERC20 asset_, uint16 maxBps, uint16 maxAllocPerProtocol_)
        ERC20("MultiStrategy Vault Share", "msVLT")
        ERC4626(asset_)
        Owned(msg.sender)
    {
        MAX_BPS = maxBps;
        maxAllocPerProtocol = maxAllocPerProtocol_;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN
    //////////////////////////////////////////////////////////////*/

    function setAllocations(Allocation[] calldata allocations_) external onlyOwner {
        uint16 len = uint16(allocations_.length);
        require(len >= 2, NeedAllocations());

        uint16 maxBps = MAX_BPS;
        delete allocations;

        uint16 _maxAllocPerProtocol = maxAllocPerProtocol;

        uint256 sum;
        for (uint256 i = 0; i < len; ++i) {
            Allocation memory a = allocations_[i];
            require(a.protocol != address(0), BadProtocol());
            require(a.targetBps > 0, ZeroBps());
            require(a.targetBps <= _maxAllocPerProtocol, CapExceeded());

            require(a.actionId == 0 || a.actionId == 2, BadActionId());

            // INSTANT (ERC4626) allocations must be direct deposits.
            if (a.isInstantOrLockup) {
                require(a.actionId == 0, InstantActionId());
            } else {
                // HyperCore(HLP) deposits must use actionId=2 and require coreWriter to be configured.
                if (a.actionId == 2) {
                    require(coreWriter != address(0), CoreWriterNotSet());
                }
            }

            sum += a.targetBps;
            if ((sum >= maxBps) && (i != len - 1)) {
                revert MaxTargetBpsReached();
            }

            allocations.push(a);
        }

        require(sum == maxBps, "sum != 100%");
    }

    function setCoreWriter(address coreWriter_) external onlyOwner {
        require(coreWriter_ != address(0), BadCoreWriter());
        coreWriter = coreWriter_;
    }

    function setMaxAllocPerProtocol(uint16 maxAllocPerProtocol_) external onlyOwner {
        require(maxAllocPerProtocol_ <= 5000, CapPerProtocolExceeded());
        maxAllocPerProtocol = maxAllocPerProtocol_;
    }

    modifier whenNotPaused() {
        _whenNotPaused();
        _;
    }

    function _whenNotPaused() private view {
        require(!paused);
    }

    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    /// @notice Manager-triggered rebalance toward target allocations.
    ///         - If an INSTANT (ERC4626) strategy is overweight, pull excess back to idle.
    ///         - Then invest idle into underweight strategies (instant first, then lockup).
    ///         - LOCKUP strategies are never forced to withdraw (only topped up).
    function rebalance() external onlyOwner whenNotPaused nonReentrant {
        Allocation[] memory al = allocations;
        uint256 len = al.length;
        require(len >= 2, NeedAtleastTwoAllocations());

        uint256 tot = totalAssets();
        if (tot == 0) return;

        uint16 maxBps = MAX_BPS;

        // -----------------------------
        // 1) Pull from overweight INSTANT strategies
        // -----------------------------
        for (uint256 i = 0; i < len; ++i) {
            Allocation memory a = al[i];
            if (!a.isInstantOrLockup) continue; // only instant can be reduced immediately

            address p = a.protocol;

            uint256 pShares = IERC20(p).balanceOf(address(this));
            if (pShares == 0) continue;

            uint256 nav = IERC4626(p).convertToAssets(pShares);
            if (nav == 0) continue;

            uint256 target = (tot * a.targetBps) / maxBps;
            if (nav <= target) continue;

            uint256 excess = nav - target;

            // Redeem shares pro-rata for the excess assets.
            // sharesToRedeem = pShares * excess / nav
            uint256 sharesToRedeem = (pShares * excess) / nav;
            if (sharesToRedeem == 0) continue;

            uint256 got = IERC4626(p).redeem(sharesToRedeem, address(this), address(this));
            if (got == 0) continue;

            emit RebalancePulled(p, got);
        }

        // -----------------------------
        // 2) Push idle into underweight strategies
        // -----------------------------
        IERC20 token = IERC20(asset());
        uint256 idle = token.balanceOf(address(this));
        if (idle == 0) return;

        // (a) Top up underweight INSTANT strategies first
        for (uint256 i = 0; i < len && idle > 0; ++i) {
            Allocation memory a = al[i];
            if (!a.isInstantOrLockup) continue;

            address p = a.protocol;

            uint256 pShares = IERC20(p).balanceOf(address(this));
            uint256 nav = pShares == 0 ? 0 : IERC4626(p).convertToAssets(pShares);

            uint256 target = (tot * a.targetBps) / maxBps;
            if (nav >= target) continue;

            uint256 deficit = target - nav;
            uint256 amount = deficit > idle ? idle : deficit;
            if (amount == 0) continue;

            token.safeIncreaseAllowance(p, amount);
            IERC4626(p).deposit(amount, address(this));
            idle -= amount;

            emit RebalancePushed(p, amount);
        }

        // Refresh idle before lockup pushes
        idle = token.balanceOf(address(this));
        if (idle == 0) return;

        // (b) Then top up underweight LOCKUP strategies with remaining idle
        for (uint256 i = 0; i < len && idle > 0; ++i) {
            Allocation memory a = al[i];
            if (a.isInstantOrLockup) continue;

            address p = a.protocol;

            uint256 nav = ILockupStrategy(p).totalAssetsOf(address(this));
            uint256 target = (tot * a.targetBps) / maxBps;
            if (nav >= target) continue;

            uint256 deficit = target - nav;
            uint256 amount = deficit > idle ? idle : deficit;
            if (amount == 0) continue;

            if (a.actionId == 2) {
                address cw = coreWriter;
                require(cw != address(0), CoreWriterNotSet());
                token.safeIncreaseAllowance(cw, amount);
                ICoreWriter(cw).write(2, abi.encode(p, amount));
            } else {
                token.safeIncreaseAllowance(p, amount);
                ILockupStrategy(p).deposit(amount);
            }
            idle -= amount;

            emit RebalancePushed(p, amount);
        }
        _checkpoint();
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the total asset value of the vault.
    /// @dev This includes:
    ///      1) Idle assets held directly by the vault.
    ///      2) Assets deposited into INSTANT strategies (ERC4626-compatible),
    ///         valued via `convertToAssets` on the strategy shares owned by this vault.
    ///      3) Assets deposited into LOCKUP strategies, valued via
    ///         `totalAssetsOf(address(this))` i.e. owned by this vault.
    ///
    ///      Pending withdrawals from lockup strategies that are not yet claimed
    ///      are still counted as part of totalAssets, ensuring share pricing
    ///      remains consistent and ERC4626-compliant.
    ///
    ///      This function is used for:
    ///      - ERC4626 share price calculations
    ///      - Rebalance targeting
    ///      - Off-chain APY/APR estimation via VaultCheckpoint events
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 nav;

        Allocation[] memory a = allocations;
        uint16 len = uint16(a.length);

        for (uint256 i = 0; i < len; ++i) {
            address addr = a[i].protocol;

            if (a[i].isInstantOrLockup) {
                uint256 shares = IERC20(addr).balanceOf(address(this));
                nav += IERC4626(addr).convertToAssets(shares);
            } else {
                nav += ILockupStrategy(addr).totalAssetsOf(address(this));
            }
        }

        return idle + nav;
    }

    /// @notice Deposit `assets` of the underlying token into the vault and mint shares to `receiver`.
    /// @dev ERC4626 flow:
    ///      - Transfers `assets` from the caller into this vault
    ///      - Mints vault shares to `receiver` per the current share price
    ///
    ///      After minting, the vault automatically invests any idle balance according to the
    ///      current `allocations` via `_investIdle()`.
    ///
    ///      Reverts while paused. Protected by `nonReentrant` to prevent reentrancy through
    ///      token callbacks or underlying strategy interactions.
    ///
    /// @param assets   Amount of underlying token (USDC here) to deposit.
    /// @param receiver Address that receives the newly minted vault shares.
    /// @return shares  Amount of vault shares minted to `receiver`.
    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        shares = super.deposit(assets, receiver);
        _investIdle();
        _checkpoint();
    }

    /// @notice Withdraw `assets` of the underlying token to `receiver` by burning shares from `owner`.
    /// @dev ERC4626-compatible withdrawal with multi-strategy liquidity handling:
    ///      1) Burns the required shares up-front (computed via `previewWithdraw`) to preserve accounting.
    ///      2) Pays immediately from idle assets held in the vault.
    ///      3) If needed, redeems from INSTANT strategies (ERC4626) in allocation order and forwards
    ///         redeemed assets to `receiver`.
    ///      4) If still short, queues withdrawals from LOCKUP strategies by calling `requestWithdraw`.
    ///         These queued amounts are tracked under `pending[receiver]` and must be claimed later
    ///         via `claimPending(idx)` once the lockup request becomes claimable.
    ///
    ///      Important:
    ///      - The ERC4626 `Withdraw` event is emitted for the full `assets` requested, even if some
    ///        portion is queued and paid later, so off-chain accounting matches user intent.
    ///      - Any excess assets received from strategy redemptions are retained as idle in the vault.
    ///
    ///      Reverts while paused. Protected by `nonReentrant` to prevent reentrancy through token
    ///      callbacks or underlying strategy interactions.
    ///
    /// @param assets   Amount of underlying token to withdraw.
    /// @param receiver Address receiving the underlying token now and/or later via pending claims.
    /// @param owner_    Address whose vault shares will be burned.
    /// @return shares  Amount of vault shares burned from `owner`.
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        require(receiver != address(0), "bad receiver");
        require(owner_ != address(0), "bad owner");

        // ERC4626: compute shares to burn for the requested assets
        shares = previewWithdraw(assets);

        // Spend allowance if caller != owner
        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }

        // Burn shares up-front to keep accounting honest even if part is queued.
        _burn(owner_, shares);

        IERC20 token = IERC20(asset());
        uint256 remaining = assets;

        // ------------------------------------------------------------
        // 1) Pay from idle assets first
        // ------------------------------------------------------------
        remaining = _payFromIdle(receiver, remaining, token);

        // ------------------------------------------------------------
        // 2) Pay from INSTANT (ERC4626) protocols
        //    - Loop allocations in order; for each instant protocol,
        //      redeem only what we need (pro-rata by NAV).
        // ------------------------------------------------------------
        Allocation[] memory al = allocations;
        remaining = _payFromInstant(receiver, remaining, token, al);

        // ------------------------------------------------------------
        // 3) Queue remainder from LOCKUP protocols
        //    - Request withdrawals across lockups in order
        // ------------------------------------------------------------
        _payFromLockedup(receiver, remaining, al);

        // Standard ERC4626 event for the requested assets (not just immediate payout)
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        _checkpoint();
    }

    /*//////////////////////////////////////////////////////////////
                        PENDING CLAIMS
    //////////////////////////////////////////////////////////////*/

    function pendingCount(address user) external view returns (uint256) {
        return pending[user].length;
    }

    /// @notice Claim a previously queued lockup withdrawal.
    /// @dev Pending withdrawals are keyed by the receiver address used in `withdraw()`.
    ///      This function pays the originally-queued `amount` to the caller; any extra
    ///      claimed (e.g., yield) stays in the vault as idle.
    function claimPending(uint256 idx) external whenNotPaused nonReentrant {
        require(idx < pending[msg.sender].length, BadIdx());

        PendingWithdrawal storage p = pending[msg.sender][idx];
        require(!p.claimed, AlreadyClaimed());

        // Ensure request is claimable in the underlying lockup protocol
        require(ILockupStrategy(p.protocol).isRequestClaimable(p.requestId), NotClaimable());

        // Claim from the lockup protocol to this vault
        uint256 got = ILockupStrategy(p.protocol).claim(p.requestId);
        require(got > 0, NothingClaimed());
        require(got >= p.amount, ShortClaim());

        // Mark claimed before transferring out
        p.claimed = true;

        IERC20(asset()).safeTransfer(msg.sender, p.amount);

        emit PendingClaimed(msg.sender, idx, p.amount);
        _checkpoint();
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Emits a vault-level checkpoint used for off-chain APY/APR calculation.
    function _checkpoint() internal {
        uint256 assets = totalAssets();
        uint256 supply = totalSupply();
        uint256 priceScaled = supply == 0 ? 0 : (assets * SHARE_PRICE_SCALE) / supply;
        emit VaultCheckpoint(assets, supply, priceScaled);
    }

    /// @notice Invest idle amount into protocols based on their type & weight.
    function _investIdle() private {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle == 0) return;

        Allocation[] memory al = allocations;
        uint256 len = allocations.length;
        if (len == 0) return;

        uint16 maxBps = MAX_BPS;

        uint256 distributed;
        for (uint256 i = 0; i < len; ++i) {
            Allocation memory a = al[i];

            // Allocate pro-rata; send any rounding remainder to the last protocol.
            uint256 amount;
            if (i == len - 1) {
                amount = idle - distributed;
            } else {
                amount = (idle * a.targetBps) / maxBps;
                distributed += amount;
            }

            if (amount == 0) continue;

            IERC20(asset()).safeIncreaseAllowance(a.protocol, amount);

            if (a.isInstantOrLockup) {
                // ERC4626-style (instant) strategy
                IERC20(asset()).safeIncreaseAllowance(a.protocol, amount);
                IERC4626(a.protocol).deposit(amount, address(this));
            } else {
                // LOCKUP strategy
                if (a.actionId == 2) {
                    address cw = coreWriter;
                    require(cw != address(0), CoreWriterNotSet());
                    IERC20(asset()).safeIncreaseAllowance(cw, amount);
                    ICoreWriter(cw).write(2, abi.encode(a.protocol, amount));
                } else {
                    IERC20(asset()).safeIncreaseAllowance(a.protocol, amount);
                    ILockupStrategy(a.protocol).deposit(amount);
                }
            }

            emit Invested(a.protocol, amount);
        }
    }

    function _payFromIdle(address receiver, uint256 remaining_, IERC20 token) private returns (uint256 remaining) {
        remaining = remaining_;
        uint256 idle = token.balanceOf(address(this));
        if (idle > 0) {
            uint256 fromIdle = idle >= remaining ? remaining : idle;
            if (fromIdle > 0) {
                token.safeTransfer(receiver, fromIdle);
                remaining -= fromIdle;
            }
        }
    }

    function _payFromInstant(address receiver, uint256 remaining_, IERC20 token, Allocation[] memory al)
        private
        returns (uint256 remaining)
    {
        remaining = remaining_;
        if (remaining > 0) {
            uint256 len = al.length;

            for (uint256 i = 0; i < len && remaining > 0; ++i) {
                Allocation memory a = al[i];
                if (!a.isInstantOrLockup) continue; // skip lockups

                address p = a.protocol;

                // Vault holds ERC4626 "shares" of protocol p
                uint256 pShares = IERC20(p).balanceOf(address(this));
                if (pShares == 0) continue;

                uint256 nav = IERC4626(p).convertToAssets(pShares);
                if (nav == 0) continue;

                uint256 want = remaining > nav ? nav : remaining;

                // sharesToRedeem = pShares * want / nav  (pro-rata)
                uint256 sharesToRedeem = (pShares * want) / nav;
                if (sharesToRedeem == 0) continue;

                // redeem to this vault, then forward to receiver
                uint256 got = IERC4626(p).redeem(sharesToRedeem, address(this), address(this));
                if (got == 0) continue;

                // Don't accidentally overpay; keep extra in vault if got > remaining
                uint256 pay = got > remaining ? remaining : got;
                token.safeTransfer(receiver, pay);
                remaining -= pay;
            }
        }
    }

    function _payFromLockedup(address receiver, uint256 remaining, Allocation[] memory al) private {
        if (remaining > 0) {
            uint256 len2 = al.length;

            for (uint256 i = 0; i < len2 && remaining > 0; ++i) {
                Allocation memory a = al[i];
                if (a.isInstantOrLockup) continue; // skip instants

                address p = a.protocol;

                // NAV of this vault in the lockup protocol
                uint256 navB = ILockupStrategy(p).totalAssetsOf(address(this));
                if (navB == 0) continue;

                uint256 reqAmount = remaining > navB ? navB : remaining;

                // Request withdrawal in the lockup protocol
                uint256 requestId = ILockupStrategy(p).requestWithdraw(reqAmount);

                // Track pending by RECEIVER (who will claim later)
                pending[receiver]
                .push(PendingWithdrawal({protocol: p, amount: reqAmount, requestId: requestId, claimed: false}));

                emit WithdrawalQueued(receiver, p, reqAmount, requestId);

                remaining -= reqAmount;
            }

            // If we still couldn't cover (shouldn't happen if totalAssets logic is right),
            // revert to avoid silently burning shares without a way to repay.
            require(remaining == 0, "insufficient lockup liquidity");
        }
    }
}
