// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "../lib/forge-std/src/Test.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "../src/mocks/MockERC4626Vault.sol";
import {MockLockupStrategy} from "../src/mocks/MockLockupStrategy.sol";
import {MockCoreWriter} from "../src/mocks/MockCoreWriter.sol";
import {MultiStrategyVault} from "../src/MultiStrategyVault.sol";

contract MultiStrategyVaultTest is Test {
    using SafeERC20 for IERC20;

    MockUSDC internal usdc;
    MockERC4626Vault internal stratA; // INSTANT (ERC4626)
    MockLockupStrategy internal stratB; // LOCKUP (custom)
    MultiStrategyVault internal vault;
    MockCoreWriter internal coreWriter;

    address internal manager = address(this);
    address internal alice = address(0xA11CE);

    uint256 internal constant USDC_DEC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        stratA = new MockERC4626Vault(IERC20(usdc));
        stratB = new MockLockupStrategy(IERC20(usdc), 3 days);
        coreWriter = new MockCoreWriter(IERC20(usdc));

        // NOTE: To test 2 protocols with 60/40, had to use 6000 as cap per allocation.
        // MAX_BPS = 10_000
        vault = new MultiStrategyVault(IERC20(usdc), 10_000, 6000);
        vault.setCoreWriter(address(coreWriter));

        // Set allocations:
        // A: 60% INSTANT
        // B: 40% LOCKUP
        MultiStrategyVault.Allocation[] memory al = new MultiStrategyVault.Allocation[](2);
        al[0] = MultiStrategyVault.Allocation({
            protocol: address(stratA), isInstantOrLockup: true, targetBps: 6000, actionId: 0
        });
        al[1] = MultiStrategyVault.Allocation({
            protocol: address(stratB), isInstantOrLockup: false, targetBps: 4000, actionId: 2
        });

        vault.setAllocations(al);

        // Fund Alice
        usdc.mint(alice, 10_000 * USDC_DEC);
    }

    function test_setMaxAllocPerProtocol_revertsForNonAdmin() public {
        // alice is NOT admin
        vm.startPrank(alice);

        // AccessControl revert format (OZ): "AccessControl: account ... is missing role ..."
        // Use a generic expectRevert to avoid brittle string matching
        vm.expectRevert();
        vault.setMaxAllocPerProtocol(5000);

        vm.stopPrank();
    }

    function test_setMaxAllocPerProtocol_revertsIfAbove5000() public {
        // manager/admin is address(this) in your setUp()
        vm.expectRevert(MultiStrategyVault.CapPerProtocolExceeded.selector);
        vault.setMaxAllocPerProtocol(5001);
    }

    function test_setAllocations_revertsWhenSingleProtocolExceedsMaxAlloc() public {
        // 1) Put the vault into "50% cap mode"
        vault.setMaxAllocPerProtocol(5000);

        // 2) Try to set allocations that violate the cap (A=60% > 50%)
        MultiStrategyVault.Allocation[] memory al = new MultiStrategyVault.Allocation[](2);
        al[0] = MultiStrategyVault.Allocation({
            protocol: address(stratA), isInstantOrLockup: true, targetBps: 6000, actionId: 0
        });
        al[1] = MultiStrategyVault.Allocation({
            protocol: address(stratB), isInstantOrLockup: false, targetBps: 4000, actionId: 2
        });

        vm.expectRevert(MultiStrategyVault.CapExceeded.selector);
        vault.setAllocations(al);
    }

    /// Test deposit to vault correctly distributing in 2 protocols.
    /// 1. alice deposit 1000 USDC to Vault
    /// 2. stratA gets 600
    /// 3. stratB gets 400
    /// 4. alice deposit 500 USDC to Vault
    /// 5. stratA has 900
    /// 6. stratB gets 600
    /// 7. total assets of vault is 1500
    /// NOTE: asset:shares ratio is 1:1
    function test_DepositsRouteToStrategies_AndShareMinting() public {
        vm.startPrank(alice);

        // Alice deposit 1000 USDC
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares1 = vault.deposit(1000 * USDC_DEC, alice);
        assertEq(shares1, 1000 * USDC_DEC, "shares should mint 1:1 at start");

        // Strategy routing
        assertEq(usdc.balanceOf(address(stratA)), 600 * USDC_DEC, "A should receive 60%");
        assertEq(usdc.balanceOf(address(stratB)), 400 * USDC_DEC, "B should receive 40%");
        assertEq(usdc.balanceOf(address(vault)), 0, "idle should be ~0");

        // Alice deposit 500 USDC
        uint256 shares2 = vault.deposit(500 * USDC_DEC, alice);
        assertEq(shares2, 500 * USDC_DEC, "shares should mint 1:1 still (no yield yet)");

        // Totals after second deposit
        assertEq(usdc.balanceOf(address(stratA)), 900 * USDC_DEC, "A should total 900");
        assertEq(usdc.balanceOf(address(stratB)), 600 * USDC_DEC, "B should total 600");
        assertEq(vault.totalAssets(), 1500 * USDC_DEC, "totalAssets should aggregate strategies");

        vm.stopPrank();
    }

    /// Test alice redeemable asset increases when stratA yield increases.
    /// NOTE: We mock yield by minting USDC to StratA.
    /// 1. mint 60 USDC to Vault
    /// 2. assert Vault total assets increase: 1000 -> ~ 1060
    /// 3. assert alice's vault balance: 1000
    /// 4. alice redeemable ~ 1060
    /// NAV: Net Asset Value
    function test_YieldOnERC4626Strategy_IncreasesShareValue() public {
        vm.startPrank(alice);

        usdc.approve(address(vault), type(uint256).max);

        // Deposit 1000 USDC => 600 A / 400 B
        vault.deposit(1000 * USDC_DEC, alice);

        // Simulate 10% yield on Strategy A by minting underlying directly to stratA
        // A had 600, yield adds 60 => A becomes 660
        usdc.mint(address(stratA), 60 * USDC_DEC);

        // Vault NAV: A 660 + B 400 ~ 1060
        assertApproxEqAbs(vault.totalAssets(), 1060 * USDC_DEC, 5, "NAV should reflect yield");

        // Alice holds 1000 shares; redeem preview should be ~1060 assets
        uint256 aliceShares = vault.balanceOf(alice);
        assertEq(aliceShares, 1000 * USDC_DEC, "alice shares");
        uint256 previewAssets = vault.previewRedeem(aliceShares);
        assertApproxEqAbs(previewAssets, 1060 * USDC_DEC, 5, "shares should be worth ~ 1060 after yield");

        vm.stopPrank();
    }

    /// Test withdrawing when part of liquidity is locked and remainder is queued.
    ///
    /// Setup:
    /// - Strategy A: INSTANT (ERC4626)
    /// - Strategy B: LOCKUP (custom, 3 days)
    /// - Allocation: 60% A / 40% B
    ///
    /// Flow:
    /// 1. Alice deposits 1000 USDC
    ///    - 600 -> Strategy A
    ///    - 400 -> Strategy B
    ///
    /// 2. Simulate yield on Strategy A
    ///    - +60 USDC minted to A
    ///    - A NAV = 660
    ///    - B NAV = 400
    ///    - Vault totalAssets = 1060
    ///
    /// 3. Alice withdraws 900 USDC
    ///    - Vault has no idle balance
    ///    - Strategy A pays max available liquidity: 660 USDC immediately
    ///    - Remaining 240 USDC is requested from lockup Strategy B
    ///
    /// 4. Verify pending withdrawal
    ///    - One pending entry created for Alice
    ///    - Pending protocol = Strategy B
    ///    - Pending amount ≈ 240 USDC
    ///    - Not claimable before lockup expiry
    ///
    /// 5. Fast-forward past lockup period
    ///    - Pending request becomes claimable
    ///
    /// 6. Alice claims pending withdrawal
    ///    - 240 USDC transferred to Alice
    ///    - Pending entry marked as claimed
    ///
    /// Expectations:
    /// - Immediate withdrawal only uses instant liquidity
    /// - Lockup remainder is queued without reverting
    /// - Claiming works only after lockup expires
    function test_WithdrawQueuesLockupRemainder_ThenClaimPending() public {
        vm.startPrank(alice);

        usdc.approve(address(vault), type(uint256).max);

        // Deposit 1000 USDC => 600 A / 400 B
        vault.deposit(1000 * USDC_DEC, alice);

        // Yield: +10% on A => +60
        usdc.mint(address(stratA), 60 * USDC_DEC);

        // Now:
        // A NAV = 660
        // B NAV = 400 (lockup)
        // total = 1060

        // Alice withdraws 900 USDC
        // - idle: 0
        // - instant A pays up to 660 immediately
        // - remaining 240 is queued from lockup B
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vault.withdraw(900 * USDC_DEC, alice, alice);

        // Immediate payout should be 660 (from A)
        uint256 aliceBalAfterImmediate = usdc.balanceOf(alice);
        assertApproxEqAbs(
            aliceBalAfterImmediate - aliceBalBefore, 660 * USDC_DEC, 5, "immediate payout should match A liquidity"
        );

        // Pending should exist for receiver=alice
        uint256 pc = vault.pendingCount(alice);
        assertEq(pc, 1, "one pending withdrawal expected");

        // Read pending entry via public mapping getter
        (bool claimed, address p, uint256 amount, uint256 requestId) = vault.pending(alice, 0);
        assertEq(p, address(stratB), "pending protocol should be B");
        assertApproxEqAbs(amount, 240 * USDC_DEC, 5, "pending amount should be 240");
        assertEq(claimed, false, "not claimed yet");
        assertGt(requestId, 0, "requestId should be set");

        // Not claimable yet
        assertEq(stratB.isRequestClaimable(requestId), false, "should not be claimable pre-delay");

        // Fast-forward past lockup
        vm.warp(block.timestamp + 3 days + 1);

        assertEq(stratB.isRequestClaimable(requestId), true, "should be claimable now");

        // Claim pending -> should transfer 240 to alice
        uint256 balBeforeClaim = usdc.balanceOf(alice);
        vault.claimPending(0);
        uint256 balAfterClaim = usdc.balanceOf(alice);

        assertApproxEqAbs(balAfterClaim - balBeforeClaim, 240 * USDC_DEC, 5, "claim should pay queued amount");

        // Pending marked claimed
        (bool claimedPost,,,) = vault.pending(alice, 0);
        assertEq(claimedPost, true, "pending should be marked claimed");

        vm.stopPrank();
    }

    /// Test manager-triggered rebalance moving funds from an overweight INSTANT strategy to an underweight LOCKUP strategy.
    /// Setup:
    /// - Strategy A: INSTANT (ERC4626)
    /// - Strategy B: LOCKUP (custom, 3 days)
    /// - Allocation: 60% A / 40% B
    ///
    /// Flow:
    /// 1. Alice deposits 1000 USDC
    ///    - 600 -> Strategy A
    ///    - 400 -> Strategy B
    ///
    /// 2. Simulate excess yield on Strategy A
    ///    - +400 USDC minted to A
    ///    - A becomes 1000, B remains 400
    ///    - Vault totalAssets = 1400
    ///
    /// 3. Compute target balances from allocations
    ///    - Target A = 60% of 1400 = 840
    ///    - Target B = 40% of 1400 = 560
    ///    - A overweight by 160, B underweight by 160
    ///
    /// 4. Manager calls rebalance()
    ///    - Redeem ~160 from A to vault idle
    ///    - Deposit ~160 from idle into B
    ///
    /// - A ends near 840 USDC and B ends near 560 USDC (allowing small rounding tolerance)
    /// - Only the manager triggers rebalance; users are not rebalanced per-withdraw/deposit
    function test_Rebalance_PullsFromOverweightInstant_ThenPushesToUnderweightLockup() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);

        // Deposit 1000 => A 600 / B 400
        vault.deposit(1000 * USDC_DEC, alice);

        // Yield on A: mint +400 to A to make it heavily overweight (A becomes 1000)
        usdc.mint(address(stratA), 400 * USDC_DEC);

        // Now total = A 1000 + B 400 = 1400
        // Targets: A 60% => 840, B 40% => 560
        // A overweight by 160, B under by 160
        vm.stopPrank();

        // Manager calls rebalance (this contract is manager by default)
        vault.rebalance();

        // After rebalance:
        // - It should redeem ~160 from A to idle
        // - Then deposit ~160 into B
        // So B should move from 400 -> ~560
        // A should move from 1000 -> ~840
        // (subject to integer rounding)
        uint256 aAfter = usdc.balanceOf(address(stratA));
        uint256 bAfter = usdc.balanceOf(address(stratB));

        // Allow a tiny rounding tolerance (few units of 1e6)
        assertApproxEqAbs(aAfter, 840 * USDC_DEC, 3 * USDC_DEC, "A rebalanced near target");
        assertApproxEqAbs(bAfter, 560 * USDC_DEC, 3 * USDC_DEC, "B rebalanced near target");
    }
}
