// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title IMDCred (IMDCRED)
/// @notice The project token of imdcred, a Proof-of-Work NFT game on Robinhood Chain.
/// @dev A fixed-supply ERC-20 with EIP-2612 permits and holder-initiated burns.
///
/// Supply: 1,000,000,000 IMDCRED (18 decimals), minted once in the constructor to the deployer.
/// On the IMD launch the deployer is the ProjectFactory, which distributes the swarm's share,
/// seeds the Uniswap v4 pool and forwards the remainder to the requester. There is no further
/// minting path of any kind: the supply can only shrink, through `burn`.
///
/// The token has no owner, no pause, no blocklist, no transfer tax and no exemptions. Every
/// transfer moves exactly the amount requested, so launch flows (factory -> distributor -> claimant,
/// factory -> PoolManager, trader <-> PoolManager) all arrive whole.
///
/// Project-token buybacks and burns are performed by whoever holds the bought-back tokens calling
/// `burn` on their own balance. Nobody can burn another holder's balance.
contract IMDCred is ERC20, ERC20Permit {
    /// @notice The whole supply, in minor units (1,000,000,000 * 10^18).
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("IMDCred", "IMDCRED") ERC20Permit("IMDCred") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Destroys `amount` tokens from the caller's own balance, reducing the total supply.
    /// @dev Emits the standard ERC-20 `Transfer(msg.sender, address(0), amount)`.
    /// @param amount The number of tokens (minor units) to burn.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
