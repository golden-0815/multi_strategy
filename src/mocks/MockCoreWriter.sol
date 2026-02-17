// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockLockupStrategy} from "./MockLockupStrategy.sol";

contract MockCoreWriter {
    using SafeERC20 for IERC20;

    IERC20 public immutable ASSET;

    event CoreWrite(uint8 indexed actionId, bytes data);

    constructor(IERC20 asset_) {
        ASSET = asset_;
    }

    /// @dev For Action ID 2: data = abi.encode(protocol, amount)
    function write(uint8 actionId, bytes calldata data) external {
        emit CoreWrite(actionId, data);
        require(actionId == 2, "unsupported action");

        (address protocol, uint256 amount) = abi.decode(data, (address, uint256));

        // Pull funds from the vault (msg.sender) and route into the lockup protocol.
        ASSET.safeTransferFrom(msg.sender, address(this), amount);
        ASSET.safeIncreaseAllowance(protocol, amount);

        // Deposit into the lockup protocol (HLP-like mock) by the vault i.e. msg.sender.
        MockLockupStrategy(protocol).depositFor(msg.sender, amount);
    }
}

