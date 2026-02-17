// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice A simple ERC4626 vault backed by MockUSDC.
///         Share price increases if someone mints underlying assets directly to this vault.
contract MockERC4626Vault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock ERC4626 Vault", "m4626") ERC4626(asset_) {}
}
