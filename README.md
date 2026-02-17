# Multi-Strategy ERC-4626 Vault

## Documentation

This is a multi-strategy ERC-4626 vault that aggregates capital across multiple underlying protocols while maintaining accurate share pricing, controlled allocations, and safe withdrawals.

The focus is on demonstrating how a single vault can coordinate funds across heterogeneous yield sources—some ERC-4626–compatible and others custom—while exposing a simple ERC-4626 interface to end users.

### 1. ERC-4626 Vault Core

- Accepts deposits in USDC.
- Mints shares proportional to aggregate vault value.
- Calculates `totalAssets()` by summing value across all underlying positions.
- Ensures ERC-4626–compliant deposit and withdrawal semantics.

### 2. Multi-Protocol Capital Routing

- Supports multiple underlying strategies.
- Each strategy can be ERC-4626–compliant or custom.
- Capital allocation is expressed in basis points like 5000 for 50%, 6000 for 60%, ..
- Allocations are adjustable by an authorized manager.
- Rebalancing logic moves funds to match target weights.

### 3. Allocation Safety Controls

- Maximum allocation caps per protocol.
- Prevents concentration risk i.e. manager can set allocations with each ≤ 50%.
- Enforced at configuration time
- Includes emergency pause capability for risk mitigation

### 4. Withdrawal Handling with Lockups

- Immediate withdrawals when liquidity is available
- Queued withdrawals when underlying protocols enforce lockups
- Per-user pending withdrawal tracking
- Claim-based settlement once liquidity unlocks

### 5. Yield Awareness

- Vault share value reflects underlying protocol performance
- Gains or losses in strategies are transparently reflected in share pricing
- Events can be emitted to support off-chain APY calculations

## Usage

### Build

```shell
forge b
```

### Test

```shell
forge t
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

### Deploy

```shell
forge script script/MultiStrategyVault.s.sol:MultiStategyVaultScript -r <your_rpc_url> --private-key <your_private_key> -vvvv --broadcast
```

Refer the [deployment](./deployment.md) for contract addresses & 2 function calls for initialization. \
And for details, refer [this](./broadcast/MultiStrategyVault.s.sol/11155111/run-latest.json).
