# Findings: packaging Caravan as an Umbrel community app

Notes from building, shipping, and debugging this store end-to-end against a
live umbrelOS device (June 2026). Everything below was verified empirically;
no wallet-identifying data appears in this document.

## Architecture that worked

```
GitHub (or any git host reachable over HTTP/S)
├── caravan fork, branch `umbrel`
│     apps/coordinator/Dockerfile.umbrel   ← official multi-stage build,
│                                            final stage swapped for nginx +
│                                            a /bitcoind reverse proxy
│     apps/coordinator/umbrel/40-bitcoind-proxy.sh
└── umbrel-community-app-store
      umbrel-app-store.yml                 ← id: caravan-store
      caravan-store-caravan/
        umbrel-app.yml                     ← port 4242, dependencies: [bitcoin]
        docker-compose.yml                 ← build context = git URL #umbrel
```

- **No Docker registry anywhere.** The compose file's `build.context` is a git
  URL; umbrelOS builds the image on-device at install/update time. This avoids
  the insecure-registry problem entirely (a plain-HTTP registry would require
  editing the Umbrel's Docker daemon config over SSH and restarting Docker —
  i.e., restarting every app).
- Build contexts work over plain `http://` (a LAN Gitea) and `https://`
  (GitHub) alike. umbreld streams the BuildKit output into its journal, which
  is the only build log you get without SSH.
- First build on-device: ~10 min on mid-range x86 (the turborepo build is the
  heavy part; the official Dockerfile sets a very large `NODE_OPTIONS`
  heap). Rebuilds hit Docker layer cache: dependency layers survive unless
  package manifests change.

## Umbrel community app store mechanics

- `umbrel-app-store.yml`: `id` must be lowercase a–z and dashes only. Every
  app directory and app `id` must be **prefixed with the store id**
  (`caravan-store-caravan`).
- `umbrel-app.yml` `port:` is the public host port; the compose `app_proxy`
  service's `APP_PORT` is the *container* port, and `APP_HOST` must be the
  compose container name: `<app-id>_<service>_1`.
- `dependencies: [bitcoin]` makes Umbrel require the Bitcoin app and injects
  these env vars into the compose context: `APP_BITCOIN_NODE_IP` (10.21.21.8),
  `APP_BITCOIN_RPC_PORT` (8332), `APP_BITCOIN_RPC_USER`, `APP_BITCOIN_RPC_PASS`,
  `APP_BITCOIN_NETWORK`.
- `PROXY_AUTH_ADD: "false"` on `app_proxy` disables the Umbrel session-auth
  wall (the Gitea app does the same). Without it, every request to the app
  port redirects to the dashboard login.
- Apps from community stores update when the manifest `version` changes;
  applying an update re-runs the compose lifecycle and (for build-context
  services) rebuilds the image.
- `docker compose pull` skips services that have `build:` and no `image:` —
  installs don't fail on the missing registry image.

## The nginx proxy (and the bug that bit us)

The container generates its nginx config at startup
(`/docker-entrypoint.d/40-bitcoind-proxy.sh`) because the Bitcoin credentials
arrive as env vars and nginx's envsubst templating can't base64-encode:

- Serves the Caravan SPA at `/` (hash routing → no try_files gymnastics
  needed, though the fallback is included).
- Proxies `location = /bitcoind` **and** `location /bitcoind/` to
  `http://$APP_BITCOIN_NODE_IP:$APP_BITCOIN_RPC_PORT/`, injecting
  `Authorization: Basic <node creds>` server-side. Same-origin from the
  browser's perspective → bitcoind's total lack of CORS support becomes
  irrelevant.
- Wallet paths map naturally: `/bitcoind/wallet/<name>` → `/wallet/<name>`.

**Bug worth remembering:** the first version redirected `/bitcoind` →
`/bitcoind/` with `return 308`. nginx builds absolute redirect Locations from
`$host`, which **strips the port** — browsers got bounced from
`umbrel.local:4242` to `umbrel.local:80` (the Umbrel dashboard) and the
request died cross-origin. Caravan posts to the no-slash form, so "Test
Connection" failed while direct slashed requests worked. Fix: never redirect
between the two forms; proxy both directly (plus `absolute_redirect off` as
belt-and-braces). If you must redirect in a port-mapped container, use
`$http_host`, not `$host`.

## Caravan quirks

All observed on coordinator v1.19.1, confirmed by instrumenting the app in a
browser (request/console capture) and by direct RPC probes through the proxy.

1. **`walletName` is mandatory for a private node.** With an empty
   `client.walletName`, Caravan's client wrapper throws
   `Wallet name is required for calling wallet specific methods` *client-side*
   (no request is sent), while the UI shows only "Unable to import, check your
   settings and try again". The Test Connection button still succeeds (it
   only does non-wallet RPC), which makes this maddening to diagnose.
2. **Importing a wallet config resets the client.** A config file with
   `"client": null` silently switches the app back to the default public-API
   client with an empty base URL. Embed the full client object (type, url,
   username, walletName) in configs you intend to re-import. Passwords are
   never stored in configs; with this proxy any non-empty password works.
3. **"invalid response from <url>" is a catch-all.** Observed causes, in
   decreasing frequency: (a) addresses not yet imported into the node wallet —
   the HTTP responses are actually `200` with valid `getaddressinfo` JSON;
   (b) bitcoind JSON-RPC errors like `-18` (wallet not loaded / wrong
   walletName) and `-19` (root-path call with multiple wallets loaded), whose
   messages Caravan swallows; (c) any non-JSON reply. The console floods with
   one error per polled address.
4. **Wallet RPCs are routed correctly.** When `walletName` is set, all wallet
   calls go to `/wallet/<name>` (verified: 80+ consecutive requests). Multiple
   loaded wallets on the node are fine *as long as* every Caravan wallet
   config names its wallet.
5. **Rescan blocks the wallet and crashes the UI.** While bitcoind rescans,
   every wallet RPC fails and Caravan eventually hits a minified React crash
   (#168); clicks stop working. The scan itself is unaffected. Recover with a
   full page reload after the scan completes.
6. **No persistence.** Caravan keeps wallet state in memory only (its
   localStorage is empty) — every page reload requires re-importing the wallet
   config. Plan your debugging around that.
7. **Watch-only prerequisite.** Caravan expects a wallet to exist on the node:
   `createwallet` with `disable_private_keys: true, blank: true,
   load_on_startup: true`, then Caravan's **Import Addresses** writes the
   wallet's descriptors (`importdescriptors`, ~1000-entry keypool, receive +
   change) into it. Without a rescan, descriptors import with a current
   timestamp — balances stay 0 until you rescan.
8. **Rescans are fast with block filters.** With `blockfilterindex=1`
   (Umbrel's Bitcoin app default), a genesis-to-tip descriptor rescan finished
   in **minutes** on a fully-synced mainnet node — bitcoind uses BIP158
   filters to skip irrelevant blocks. Without the index, budget hours.

## Operational runbook

- **Install**: add store → install → watch dashboard (build streams to the
  umbreld journal). App at `http://umbrel.local:4242`.
- **Connect**: README "Connecting Caravan to your node" — private client,
  proxy URL, any creds, named watch-only wallet.
- **Update loop**: push fork/store changes → bump manifest version → apply
  update in the dashboard.
- **Diagnose without SSH**: the proxy is your RPC window —
  `curl -X POST http://umbrel.local:4242/bitcoind/ -d '{"jsonrpc":"1.0","id":"x","method":"getblockchaininfo","params":[]}'`
  (root path) and `/bitcoind/wallet/<name>` (wallet path, e.g.
  `getwalletinfo` shows `scanning` progress during a rescan).
- **UI dead during rescan**: expected (quirk 5). Wait for
  `"scanning": false`, then hard-reload and re-import the config (quirk 6).

## Known issues / roadmap

Planned packaging revision (error-UX fixes in the fork, shipping as 1.19.3):
replace the per-address "invalid response" flood with a single "addresses not
yet imported" hint; validate `walletName` inline in the client form; surface
bitcoind's JSON-RPC error codes/messages; survive the rescanning state without
a React crash. Candidates for upstreaming to caravan-bitcoin/caravan.

## Verification performed

- Dockerfile built three ways: local path context (twice) and from the git
  URL context exactly as the Umbrel consumes it; image ~98MB.
- Static UI: 200 + correct index; proxy: `getblockchaininfo` returns live
  chain data through injected credentials, both `/bitcoind` and `/bitcoind/`.
- In-app: client "Connection Success!", wallet config import, descriptor
  import ("Addresses imported.", confirmed via `listdescriptors`), full
  rescan, and a funded multisig wallet rendering its addresses, UTXOs and
  balance — all against the Umbrel's own node, with an in-page guard
  confirming **zero requests left the LAN** during wallet operations.
- The edit→push→update loop exercised with a real bugfix (the 308/port bug
  above): version bump offered in the dashboard, on-device rebuild from the
  git context, fixed behavior live.
