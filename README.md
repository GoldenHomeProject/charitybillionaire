# Charity Billionaire

**Give to charity. Win the prize. Keep your money.**

A no-lose, prize-linked charitable draw built on Base. Depositors pool refundable
USDC; the pool earns interest in Aave; once a week that **interest** (never anyone's
principal) is split **90% to one randomly selected depositor, 5% to a vetted charity,
and 5% to sustain the platform**. Your deposit is always yours and withdrawable at any
time. Inspired by on-chain prize-savings designs such as PoolTogether.

> **This is software, not an offer.** See the [Disclaimer](#disclaimer) below.

## Why it's designed the way it is

- **Refundable deposits** — you can withdraw your full principal at any time, so no
  "consideration" is paid. Only forgone *interest* ever funds the prize or the charity.
- **Non-custodial** — there is no function by which any operator can move depositor
  principal. The contracts only ever distribute *yield*, and only the excess of the
  Aave balance over tracked principal is ever touchable.
- **Equal odds per $1** — entries track dollars, not wallets, so splitting a deposit
  across wallets confers no advantage (Sybil-resistant).
- **Provably fair draw** — randomness comes from Chainlink VRF; the weekly trigger comes
  from Chainlink Automation; the 90/5/5 split is hard-coded; the address excluded from
  winning (the operator) is immutable; and no human can influence the outcome. The VRF
  adapter's ownership is locked so the coordinator can never be repointed.
- **Transparent** — every deposit, withdrawal, and prize/charity distribution is an
  on-chain event, surfaced on the site's public record.

## Architecture

`Base · USDC · Aave v3 (yield) · Chainlink VRF (randomness) · Chainlink Automation (weekly trigger)`

| Contract | Role |
| --- | --- |
| `src/CharityPrizeVault.sol` | The vault: deposits/withdrawals, yield accounting, O(log n) winner selection, 90/5/5 payout. |
| `src/ChainlinkVRFProvider.sol` | VRF v2.5 adapter that feeds verified randomness to the vault. |
| `src/VRFProviderOwner.sol` | Immutable lock that owns the adapter so no human can repoint the VRF coordinator. |
| `src/DrawUpkeep.sol` | Chainlink Automation target that fires the weekly draw at exactly Thursday 21:00 ET and self-heals a stuck request. |
| `src/EasternTime.sol` | Pure, DST-aware date math for the Thursday-21:00-ET schedule. |

## Deployed contracts

Currently **testnet only (Base Sepolia, chainId 84532)**. Every contract's source is
verified on the block explorer — read exactly what is running:

| Contract | Address |
| --- | --- |
| Vault | `0xE977CBBfcC5DAD30F16AA299cEE910e8eFE6cC24` |
| VRF adapter | `0x986b70d7Cfde426A1ceE324FceBA39E8eea0CC29` |
| VRF owner-lock | `0x364cfa16D929d397704449225c3BBeE01DE847F7` |
| Automation target | `0xEa377A351BA87DD08BD5EB3B3C67A6D1Ec98DA0F` |

Explorer: https://sepolia.basescan.org · Mainnet deployment is gated on a professional
audit and legal review (see below) and is **not** live.

## Build & test

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge build
forge test     # full suite
```

Deployment is driven by the scripts in `script/` (e.g. `DeployAll.s.sol`), which read
all addresses and parameters from a local `.env` (not committed). The signer's key is
supplied via an encrypted keystore at deploy time and never lives in the repo.

## Front-end

`web/` is a static site (no build step). It reads live figures straight from the
contract over a public RPC, lets a connected wallet deposit/withdraw, and renders the
on-chain record of past drawings. Wallets are discovered via EIP-6963 (MetaMask,
Coinbase Wallet, Rabby, …), with optional WalletConnect for mobile (set `wcProjectId`
in `web/app.js`).

## Security

See [SECURITY.md](SECURITY.md) for responsible disclosure. This code has had internal
review; a professional third-party audit is planned before any mainnet launch.
**Treat all current deployments as experimental.**

## Disclaimer

This repository is provided for transparency and is licensed under the
[MIT License](LICENSE) **without warranty of any kind**. Nothing here is, or should be
construed as, legal, financial, tax, or investment advice, an offer or solicitation, or
a guarantee of any outcome. The software is experimental. You are solely responsible for
complying with the laws of your own jurisdiction; the project may be unavailable where
restricted. Interacting with smart contracts carries risk, including the risk of loss
due to bugs or misuse. Do your own research and consult your own qualified advisors.
