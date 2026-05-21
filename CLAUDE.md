# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Shell scripts for interacting with the Pearl blockchain wallet and automating trades on Pearl OTC (`https://api.pearl-otc.com`). Dependencies: `bash`, `curl`, `python3` (stdlib only), `notify-send` (optional, for desktop alerts).

## Wallet Binaries (pearl-wallet-v1.0.0)

Three Go binaries extracted from the release:

- **`pearld`** — full node daemon; syncs the blockchain, exposes RPC on port 44107
- **`oyster`** — wallet daemon; connects to `pearld`, exposes its own RPC on port 44207
- **`prlctl`** — CLI that talks to either daemon:
  - `./prlctl -u <user> -P <pass> <command>` → talks to pearld
  - `./prlctl --wallet -u <user> -P <pass> -c ~/.oyster/rpc.cert <command>` → talks to oyster

Daemon configs are read from `~/.pearld/pearld.conf` and `~/.oyster/oyster.conf` on startup. Both daemons auto-generate TLS certs (`rpc.cert` / `rpc.key`) in their respective data dirs on first run. oyster's cert is separate from pearld's — `prlctl --wallet` needs `-c ~/.oyster/rpc.cert`.

## `prl` — Wallet Wrapper Script

Handles daemon lifecycle, credential plumbing, and wallet unlock automatically.

**First-time setup:**
```bash
./prl setup        # configure RPC creds; writes ~/.pearl_wallet.conf + daemon configs
./prl start-node   # start pearld (wait for it to be ready)
./prl create       # interactive wallet creation (prompts for passphrase + seed)
./prl start        # start oyster wallet daemon
```

**Daily use:**
```bash
./prl balance
./prl receive                        # get a new address
./prl send <address> <amount>        # auto-unlocks wallet, sends PRL
./prl txs [n]                        # last N transactions (default 10)
./prl tx <txid>
./prl sync                           # sync progress
./prl stop
```

**Credentials** are stored in `~/.pearl_wallet.conf` (mode 600). If `WALLET_PASS` is set there, `send` auto-unlocks; otherwise it prompts. The RPC credentials are mirrored into the daemon config files.

**Escape hatch** — run any `prlctl` command directly:
```bash
./prl cmd wallet <rpc-command> [args...]   # any wallet server command
./prl cmd node   <rpc-command> [args...]   # any chain server command
```

## OTC Scripts

**`pearl_otc.sh`** — Interactive bid sniper. Prompts for trade parameters, polls `GET /offers?side=BUY_PRL` every 15 seconds, and auto-executes the highest qualifying bid via `POST /trades`. Persists token and addresses to `~/.pearl_otc.conf` (mode 600).

**`watch_offer.sh`** — One-off watcher hardcoded to a specific offer/blocking-trade pair. Edit `OFFER_ID`, `BLOCKING_TRADE`, and `TOKEN` inline before running.

## API Pattern (OTC scripts)

All requests set `User-Agent` to a Chrome string (required). Authenticated endpoints use `Authorization: Bearer <token>`. JSON is parsed and built with inline `python3 -c` snippets.
