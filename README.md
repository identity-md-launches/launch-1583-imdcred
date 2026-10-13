# IMDCred (IMDCRED)

The project token of **imdcred**, a Proof-of-Work NFT game on Robinhood Chain with 4,444 collectible
NFTs: mine, mint and stake NFTs, share in project revenue, and redeem eligible NFTs against the floor
reserve. Powered by IMD, with project-token buybacks and burns.

- Website: https://imdcred.fun
- X (Twitter): https://x.com/Imdcred

This repository delivers the token for an IMD **custom token launch**. The game contracts (mining,
minting, staking, revenue share, floor reserve, buyback) are not part of this deliverable; see
"Scope" below.

## Token

| Parameter        | Value                                                       |
| ---------------- | ----------------------------------------------------------- |
| Solidity name    | `IMDCred` (`src/IMDCred.sol`)                               |
| `name()`         | `IMDCred`                                                   |
| `symbol()`       | `IMDCRED`                                                   |
| `decimals()`     | 18                                                          |
| Total supply     | 1,000,000,000 IMDCRED = `1000000000000000000000000000` minor units |
| Constructor args | none                                                        |
| Minting          | once, in the constructor, the whole supply to `msg.sender`  |
| Standard         | ERC-20 (OpenZeppelin v5.4.0) + EIP-2612 `permit`            |
| Extras           | `burn(uint256)` on the caller's own balance                 |
| Owner / admin    | none                                                        |

### Behaviour

- **Fixed supply.** `TOTAL_SUPPLY` is minted once to the deployer. There is no `mint`, no minter role,
  no owner and no upgrade path: nothing can ever increase `totalSupply()`.
- **Plain transfers.** No tax, no reflections, no blocklist, no pause, no exemptions. Every
  `transfer` / `transferFrom` moves exactly the amount requested, so each launch flow (factory to
  MerkleDistributor, distributor to claimant, factory to PoolManager, trader to and from the
  PoolManager) arrives whole.
- **Burns.** Any holder may call `burn(amount)` to destroy tokens from their own balance; this is the
  mechanism for the project's buyback-and-burn programme (the buying contract or wallet burns what it
  bought). There is deliberately no `burnFrom`: nobody can burn another holder's balance, with or
  without an allowance.
- **Permit.** EIP-2612 `permit` lets holders approve spenders by signature (gasless approvals for the
  game contracts). Domain name `IMDCred`, version `1`.
- **No ether.** The token has no `receive`/`fallback`; sending ETH to it reverts.
- **Bytecode.** No `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`; no external library calls (all
  OpenZeppelin helpers are internal and inlined).

## Launch on Robinhood Chain

These values are set by the launch and are reproduced here for the record. The manifest
(`launch.json`) is written by the manifest step after this work is accepted; it is not part of this
tree.

| Item                      | Value                                                                    |
| ------------------------- | ------------------------------------------------------------------------ |
| Chain                     | Robinhood Chain, chain id 4663                                           |
| Deployer                  | IMD ProjectFactory (`launchCustom`), via CREATE2 from the attested code   |
| Token constructor args    | `[]`                                                                     |
| Token `totalSupply`       | `1000000000000000000000000000`                                           |
| Paired currency           | IMD, `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` (18 decimals)         |
| Pool fee                  | 12500 (1.25%)                                                            |
| Pool tick spacing         | 60                                                                       |
| Pool initial price (prov.)| `79228162514264337593543950336`                                          |
| Economics                 | `{"poolBps":9000,"initialMarketCapWei":"500000000000000000000"}`         |
| Application contracts     | none (`contracts: []`)                                                   |

Supply split performed by the factory, by construction:

- 10% to the launch's MerkleDistributor (the swarm's share; not settable here).
- 90% (`poolBps` = 9000) seeds the single-sided Uniswap v4 pool against IMD, opened at a 500 IMD
  market cap for the whole supply.
- The remainder of the requester's share (here 0%, since poolBps covers all of it) goes to
  `economics.remainderTo`.

The token's constructor mints everything to `msg.sender`, which is the factory. No contract in this
tree is allocated, reserved or sent any of the supply at launch.

### After launch

There is nothing to configure. The token has no owner, no setters and no external dependencies.

### Deploying elsewhere (local fork / testnet only)

`script/DeployIMDCred.s.sol` exposes `deploy()` (tested directly) and a `run()` wrapper that
broadcasts it. The account that broadcasts receives the whole supply. This script is for review and
local use; the production deployment on Robinhood Chain is done by IMD's deployer through the
factory and must not be run against it.

```sh
forge script script/DeployIMDCred.s.sol --rpc-url <rpc> --broadcast --sender <deployer>
```

## Operational responsibilities

| Party               | Responsibility                                                                    |
| ------------------- | --------------------------------------------------------------------------------- |
| IMD launch          | Deploys the token from the attested bytecode, distributes the swarm share, seeds the pool, forwards the remainder. |
| Requester (project) | Owns the remainder of the 90% (if any); runs buybacks and calls `burn` on bought-back tokens; builds and launches the game contracts as a separate contracts launch. |
| Holders             | Guard their own keys and `permit` signatures. A permit is only as safe as the deadline and spender the holder signs for. |
| Nobody              | There is no admin. No one can mint, pause, freeze, block, seize or upgrade. This is permanent. |

## Assumptions

- The brief's "deployer" is the launch factory, so the whole supply is minted to `msg.sender` of the
  creation. The constructor does not call any other contract and takes no arguments.
- Robinhood Chain runs ArbOS 61 and supports the Cancun opcode set (Uniswap v4 on it requires
  transient storage), so `evm_version = "cancun"` is safe. The token itself uses only ordinary
  opcodes.
- The buyback-and-burn programme described for the project is executed off this contract: whoever
  holds the bought tokens burns them with `burn`. No contract here holds or sells tokens.
- `burnFrom` is intentionally absent (see Behaviour). If a later game contract needs to burn a
  player's tokens, it must first receive them (via `transferFrom` with the player's allowance or
  `permit`) and then burn its own balance.
- Burning reduces `totalSupply()`; anything that reads the supply (e.g. a revenue-share formula)
  must tolerate it shrinking over time.

## Scope

Delivered: the IMDCred token, its tests, the review-only deploy script and this documentation.

Not delivered (out of scope for a custom token launch; order as a contracts launch when ready):
the 4,444-NFT collection, Proof-of-Work mining and minting, NFT staking, revenue sharing, the floor
reserve and redemption, and an on-chain buyback contract. The token is designed to be a plain
dependency of those contracts: fixed supply, no hooks, `permit` for approvals, `burn` for buybacks.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

- Compiler pinned to `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer on (200 runs),
  `bytecode_hash = "none"` (the launch compares bytecode without a metadata hash).
- Dependencies are vendored as ordinary files under `lib/` (no submodules): forge-std v1.9.7 and
  OpenZeppelin Contracts v5.4.0 (contracts directory only). Remappings are in `remappings.txt`.
- Tests read no environment variables and do not depend on the calling address; they run in any
  order and in parallel.

### What the tests cover (`test/IMDCred.t.sol`)

- Metadata, supply constant, whole supply minted to the CREATE2 deployer and to nobody else; a single
  `Transfer(0, deployer, supply)` event; the creation code takes no constructor arguments.
- The launch flows arrive whole: factory to distributor to claimant, factory to pool manager, and a
  trader buying from and selling back into the pool manager, with the supply unchanged.
- ERC-20 success and failure paths: transfer, insufficient balance, zero receiver, approve and
  transferFrom, insufficient and missing allowance (including from the deployer), infinite allowance.
- Burn success, over-burn revert, burn of zero, and a fuzz that burns only ever shrink supply.
- No mint/admin/ownership selector exists and every common privileged selector reverts from both a
  stranger and the deployer, leaving a holder's balance and ability to transfer intact.
- Runtime bytecode contains no DELEGATECALL / CALLCODE / SELFDESTRUCT and is under the EIP-170 limit.
- Permit: success with nonce consumption, replay, expired deadline, wrong signer, tampered value.
- Fuzz: transfers conserve the supply.

## Security notes

- Tests passing do not constitute an audit. The code is a thin composition of audited OpenZeppelin
  v5.4.0 contracts (`ERC20`, `ERC20Permit`) plus a one-line `burn`; the attack surface is that of a
  standard ERC-20.
- No tool beyond `forge build`, `forge test` (with fuzzing) and `forge fmt` was run; Slither/Mythril
  were not available in this environment.
- The token holds no funds and has no privileged roles, so there is no key to secure for it. The
  game contracts that will hold user NFTs and revenue need their own adversarial review before
  release.
