# Security Policy

Charity Billionaire is a non-custodial smart-contract system. We take security
seriously and welcome responsible disclosure.

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities. Instead, email
**goldenhomeprojectllc@gmail.com** with:

- A description of the issue and its impact
- Steps to reproduce (or a proof-of-concept)
- The affected contract address / file and, if possible, a suggested fix

We aim to acknowledge reports within a few business days. Please give us a
reasonable window to investigate and remediate before any public disclosure.

## Scope

In scope:
- The smart contracts in `src/` (the vault, the VRF adapter, the owner lock, the
  automation target, and the schedule library).
- The deployed, verified contracts on the network listed in the README.

Out of scope:
- Testing against live contracts in a way that puts **other users' funds** at
  risk. Use a local fork or testnet.
- Issues in third-party dependencies (Aave, Chainlink, OpenZeppelin) — report
  those upstream.
- The front-end's reliance on public RPC availability.

## Please do not

- Attempt to access funds that are not yours.
- Run denial-of-service attacks against the contracts or infrastructure.
- Publicly disclose an unfixed vulnerability.

## Audits

Live on Base mainnet. The contracts are verified on Basescan and have had multiple
in-depth security reviews, with every finding from those reviews fixed. Verified source
for every deployed contract is linked in the README, so anyone can review exactly what is
running. Smart-contract risk applies.
