// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "../lib/forge-std/src/Script.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "../src/mocks/MockERC4626Vault.sol";
import {MockLockupStrategy} from "../src/mocks/MockLockupStrategy.sol";
import {MockCoreWriter} from "../src/mocks/MockCoreWriter.sol";
import {MultiStrategyVault} from "../src/MultiStrategyVault.sol";

/*
$ forge script script/MultiStategyVault.s.sol:MultiStategyVaultScript \
--private-keys $ADMIN_SK \
--rpc-url $SEPOLIA_RPC_URL -vvvv --broadcast
 */
contract MultiStategyVaultScript is Script {
    MockUSDC internal usdc;
    MockERC4626Vault internal stratA; // INSTANT (ERC4626)
    MockLockupStrategy internal stratB; // LOCKUP (custom)
    MultiStrategyVault internal vault;
    MockCoreWriter internal coreWriter;

    address public admin;

    function setUp() public {
        uint256 adminSk = vm.envUint("ADMIN_SK");
        admin = vm.addr(adminSk);
    }

    function run() public {
        vm.startBroadcast(admin);

        usdc = new MockUSDC();
        stratA = new MockERC4626Vault(IERC20(usdc));
        stratB = new MockLockupStrategy(IERC20(usdc), 3 days);
        coreWriter = new MockCoreWriter(IERC20(usdc));

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

        vm.stopBroadcast();
    }
}
