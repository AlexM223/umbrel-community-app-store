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
   *Fixed in this fork (1.19.3):* on Umbrel, imported configs are auto-filled
   with a complete private client — `walletName` defaults to `caravan-main` —
   so the empty-walletName dead end can't be reached from the normal flow.
2. **Importing a wallet config resets the client.** A config file with
   `"client": null` silently switches the app back to the default public-API
   client with an empty base URL. Embed the full client object (type, url,
   username, walletName) in configs you intend to re-import. Passwords are
   never stored in configs; with this proxy any non-empty password works.
   *Fixed in this fork (1.19.3):* `"client": null` now triggers the
   zero-config defaults instead (private client, same-origin `/bitcoind`
   proxy URL, dummy credentials — the proxy injects the real ones
   server-side). localhost URLs in imported configs are rewritten to the
   proxy; deliberate non-localhost URLs are honored. A related bug where an
   imported config could keep the *previous* client's wallet name is fixed
   too.
3. **"invalid response from <url>" is a catch-all.** Observed causes, in
   decreasing frequency: (a) addresses not yet imported into the node wallet —
   the HTTP responses are actually `200` with valid `getaddressinfo` JSON;
   (b) bitcoind JSON-RPC errors like `-18` (wallet not loaded / wrong
   walletName) and `-19` (root-path call with multiple wallets loaded), whose
   messages Caravan swallows; (c) any non-JSON reply. The console floods with
   one error per polled address. The crucial wrinkle: bitcoind reuses error
   code **`-4`** for *both* "address not in wallet" *and* "wallet is
   currently rescanning" — the only way to tell them apart is to check
   `getwalletinfo.scanning` **before** interpreting a `-4`. That ambiguity
   was the root cause of the rescan crash (quirk 5).
4. **Wallet RPCs are routed correctly.** When `walletName` is set, all wallet
   calls go to `/wallet/<name>` (verified: 80+ consecutive requests). Multiple
   loaded wallets on the node are fine *as long as* every Caravan wallet
   config names its wallet.
5. **Rescan blocks the wallet and crashes the UI.** While bitcoind rescans,
   every wallet RPC fails and Caravan eventually hits a minified React crash
   (#168); clicks stop working. The scan itself is unaffected. Recover with a
   full page reload after the scan completes.
   *Fixed in this fork (1.19.3):* all wallet-RPC consumers are gated on a
   single `scanStatus` state, and the ambiguous `-4` error (quirk 3) is only
   interpreted after checking `getwalletinfo.scanning`. During a scan the UI
   shows a progress bar (2 s `getwalletinfo` poll), disables Refresh/Import,
   and pops a snackbar on completion — no crash, no console flood, and
   reloading mid-scan resumes the progress display.
6. **Persistence is session-scoped.** Caravan persists the wallet config in
   `sessionStorage` under the key `caravan_config` (localStorage stays
   empty), so a same-tab reload restores it; only new tabs, windows, or
   browser sessions start empty and need the config re-imported. Plan your
   debugging around the tab boundary.
7. **Watch-only prerequisite.** Caravan expects a wallet to exist on the node:
   `createwallet` with `disable_private_keys: true, blank: true,
   load_on_startup: true`, then Caravan's **Import Addresses** writes the
   wallet's descriptors (`importdescriptors`, ~1000-entry keypool, receive +
   change) into it. Without a rescan, descriptors import with a current
   timestamp — balances stay 0 until you rescan.
   *Fixed in this fork (1.19.3):* the node wallet is created/loaded
   automatically with exactly those flags (plus descriptors) for whatever
   `walletName` the config specifies, descriptors import right after wallet
   confirm, and a first-time rescan starts automatically whenever the node
   wallet has no history (`txcount` 0).
8. **Rescans are fast with block filters.** With `blockfilterindex=1`
   (Umbrel's Bitcoin app default), a genesis-to-tip descriptor rescan finished
   in **minutes** on a fully-synced mainnet node — bitcoind uses BIP158
   filters to skip irrelevant blocks. Without the index, budget hours.

## Operational runbook

- **Install**: add store → install → watch dashboard (build streams to the
  umbreld journal). App at `http://umbrel.local:4242`.
- **Connect**: zero-config since 1.19.3 — import a wallet config, click
  Confirm (README "Connecting Caravan to your node"). The manual
  private-client setup lives in the README's "Advanced" section.
- **Update loop**: push fork/store changes → bump manifest version → apply
  update in the dashboard.
- **Diagnose without SSH**: the proxy is your RPC window —
  `curl -X POST http://umbrel.local:4242/bitcoind/ -d '{"jsonrpc":"1.0","id":"x","method":"getblockchaininfo","params":[]}'`
  (root path) and `/bitcoind/wallet/<name>` (wallet path, e.g.
  `getwalletinfo` shows `scanning` progress during a rescan).
  *Since 1.19.7 the app sits behind the Umbrel auth wall, so bare `curl`
  gets redirected to the dashboard login — run the same RPC as a `fetch()`
  from the browser devtools console on the Caravan page instead (the README's
  Advanced section has a copy-paste snippet).*
- **UI dead during rescan**: upstream v1.19.1 behavior (quirk 5; the 1.19.3
  fork shows a progress bar instead). On the old build, wait for
  `"scanning": false`, then reload — a same-tab reload restores the config
  (quirk 6).

## Zero-config mode (1.19.3)

The 1.19.3 fork makes the Umbrel build self-configuring. The moving parts:

- **Runtime config file.** A second entrypoint script
  (`41-umbrel-config.sh`, alongside the proxy generator) writes
  `/umbrel-config.json` at container start:

  ```json
  {"umbrel": true, "bitcoindPath": "/bitcoind", "network": "<chain>"}
  ```

  `network` comes from `BITCOIND_NETWORK` (Umbrel's `APP_BITCOIN_NETWORK`,
  passed through by the compose file; the container defaults to mainnet if
  unset). nginx serves the file with `Cache-Control: no-store`, so a cached
  copy can never pin a stale node config.
- **404 = stock Caravan.** The SPA fetches `/umbrel-config.json` once at
  boot; if it isn't there (any non-Umbrel deployment), the app behaves
  exactly like upstream Caravan. The same image is therefore safe anywhere.
- **Initial-state seeding.** The fetched config seeds Caravan's *initial*
  client state rather than patching it afterwards, so even Clear Wallet /
  reset flows land back on the configured private client instead of the
  public-API default.
- **The auto pipeline.** On wallet confirm: *ensure node wallet*
  (`listwallets` → `loadwallet` → `createwallet` blank / watch-only /
  descriptors / `load_on_startup`, for whatever `walletName` the config
  names, default `caravan-main`) → *probe* the wallet's history → *import
  descriptors* → *conditional rescan* (only when `getwalletinfo.txcount` is
  0, i.e. a first-time wallet) → *poll* `getwalletinfo` every 2 s to drive
  the progress bar, with Refresh/Import disabled and a snackbar on
  completion. Reloading mid-scan re-detects the running scan and resumes the
  progress UI.
- **Scan gating.** Every wallet-RPC consumer hangs off one shared
  `scanStatus` state, and bitcoind's overloaded `-4` error (quirk 3) is only
  interpreted after checking `getwalletinfo.scanning`. That single choke
  point is what eliminated both the per-address "invalid response" flood and
  the React #168 crash.

## Shipped in 1.19.3

The packaging revision previously listed here as roadmap shipped in the
1.19.3 fork (built on-device from
`https://github.com/AlexM223/caravan.git#umbrel`): zero-config node
connection (quirks 1, 2 and 7 automated away), automatic descriptor import
and first-time rescan with a progress UI, rescan-safe wallet RPCs (no more
"invalid response" flood or React crash — quirks 3/5), and a fix for imported
configs keeping a stale client's wallet name. The fork commits, in order:
error-surfacing foundation; node-wallet management in the clients package
(`listwallets`/`createwallet`/`loadwallet` + scan status); Umbrel runtime
config; zero-config client defaults; auto-import + auto-rescan.

Opt-in config persistence beyond sessionStorage was considered and not done.
Upstreaming the fixes to caravan-bitcoin/caravan remains on the table.

## Per-config node wallets (1.19.5) — a lesson

1.19.3 deliberately shared one node wallet (`caravan-main`) across all
configs "to keep state down." Real usage proved that wrong within hours:
**Bitcoin Core has no descriptor-removal RPC**, so descriptors from every
imported config accumulate in the shared wallet forever — importing wallet B
after wallet A makes B's session report A's addresses and balances too
(looks alarmingly like leaked key data; it's actually persisted watch-only
state in the node's `wallets/caravan-main/wallet.dat`, surviving app
reinstalls).

1.19.5 therefore derives a wallet per config —
`caravan-<FNV-1a-64 hex of (network, addressType, quorum, sorted xpubs)>` —
so the same config always reuses its wallet (one rescan, ever) and different
configs can never see each other. An explicit `client.walletName` is honored
verbatim. (FNV-1a instead of SHA-256 for a hard-won reason: `crypto.subtle`
only exists in secure contexts, and the Umbrel app serves over plain http on
the LAN — the first 1.19.5 build silently broke every import because the
digest call threw. It's a naming scheme, not a security boundary.) Node side effects (create/load/
import) also moved strictly to the Confirm click: connection tests are
reachability-only (`estimatesmartfee`), and `ensureNodeWallet` throws if it
runs before a name is set. The confirm screen displays the derived name in
an editable field.

Cleanup from the shared-wallet era is manual and deliberate (the app must
never destroy node wallets): `unloadwallet "caravan-main"` via RPC, and
optionally delete its directory from the Bitcoin app's data on disk.

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
- (The above covers 1.19.2; verification of the 1.19.3 zero-config release is
  described in the repo README and the manifest release notes.)
