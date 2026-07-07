# Caravan Store

An [Umbrel community app store](https://github.com/getumbrel/umbrel-community-app-store)
with two Bitcoin apps:

- [Caravan](https://github.com/caravan-bitcoin/caravan) — the stateless
  Bitcoin multisig coordinator — as an Umbrel app wired to **your own
  Bitcoin node**, with no public Docker registry involved: the image is
  built on your Umbrel, from source, at install time.
- [Cairn](https://github.com/AlexM223/cairn) — a self-hosted Bitcoin command
  center: watch-only wallet navigator, block explorer, and multisig
  coordinator, installed from a prebuilt multi-arch image.

## Add this store to your Umbrel

Umbrel home → App Store → three-dots menu → **Community App Stores** → paste:

```
https://github.com/AlexM223/umbrel-community-app-store.git
```

Open the new "Caravan Store" and install **Caravan**. Install takes roughly
10–25 minutes the first time (your Umbrel compiles the Caravan monorepo);
updates and reinstalls are much faster thanks to Docker layer caching.

## Apps in this store

- **Caravan** (`caravan-store-caravan`) — stateless multisig coordinator on
  port `4242`. Depends on the official **Bitcoin** app (Umbrel installs it
  first and injects its RPC credentials into the app's environment).
- **Cairn** (`caravan-store-cairn`) — self-hosted Bitcoin command center on
  port `3211`. No dependencies — it defaults to a public Electrum server,
  swappable for your own (e.g. the electrs app) from Admin → Settings.
  First login: `admin@cairn.local` with the password shown on the app's
  install card; change it (and set your real email) from Settings. All app
  state lives in the app's data directory and survives updates/restarts.

## Connecting Caravan to your node

Zero-config as of 1.19.3 — the app wires itself to your Umbrel's Bitcoin node:

1. **Import your wallet config.** Configs without client info — e.g. exports
   from [caravanmultisig.com](https://www.caravanmultisig.com) — are pointed
   at the app's built-in `/bitcoind` proxy automatically, and the proxy
   injects your node's real RPC credentials **server-side**. No URLs,
   usernames, or passwords to enter: a "Connected to your Umbrel node" status
   line replaces the password prompt, and your only action is clicking
   **Confirm**. (Configs that deliberately point at a non-localhost node are
   honored unchanged; localhost URLs are rewritten to the proxy.)

2. **Everything else is automatic.** When you click Confirm, Caravan creates
   and loads a **dedicated** watch-only wallet on your node for this config —
   named `caravan-<hash>`, derived deterministically from the config (or
   whatever `walletName` it specifies; the confirm screen shows the name and
   lets you edit it). It never holds private keys, each wallet config gets
   its own node wallet (no cross-contamination between wallets — Bitcoin
   Core can't remove imported descriptors, so sharing one wallet is a trap),
   and re-importing the same config reuses its wallet without rescanning
   again. Addresses import automatically, and when the node wallet has no
   history yet a first-time blockchain rescan starts on its own with a
   progress bar. The first scan takes minutes on Umbrel's node
   (`blockfilterindex=1` is its default); Refresh/Import stay disabled until
   it finishes, and reloading mid-scan resumes the progress display.

Pointing Caravan at a different node, or debugging? See
[Advanced: manual client configuration](#advanced-manual-client-configuration-non-umbrel-or-troubleshooting)
at the end of this README.

## How the build works

The `web` service in `caravan-store-caravan/docker-compose.yml` uses a **git
build context pinned to a commit** on the Caravan fork's `umbrel` branch:

```
https://github.com/AlexM223/caravan.git#<commit-sha>
```

At install time the Umbrel fetches that exact commit and builds
`apps/coordinator/Dockerfile.umbrel` on-device (the official multi-stage
build plus a small nginx layer for the node proxy). No registry, no insecure
Docker config, no SSH onto the device — git build contexts work out of the
box. Pinning the SHA (rather than the branch name) means each store version
builds exactly the code it claims: a push to the fork can never change what
an install builds until this repo says so.

## Dev loop

1. Edit the Caravan fork, commit to its `umbrel` branch, push.
2. Point the build context at the new commit: update the pinned SHA in
   `caravan-store-caravan/docker-compose.yml`, bump `version:` in
   `caravan-store-caravan/umbrel-app.yml`, and push this repo.
3. On the Umbrel: apply the app update (or uninstall → reinstall). Updates
   fetch the pinned commit and rebuild — cached layers make source-only
   changes quick.

## Security model (read this once)

- The app sits behind Umbrel's `app_proxy` **with the standard Umbrel auth
  wall** (since 1.19.7): `http://umbrel.local:4242` requires a signed-in
  Umbrel dashboard session. Versions up to 1.19.6 disabled the wall, leaving
  the app — and the RPC proxy below — reachable by anyone on the LAN.
- The `/bitcoind` proxy **injects authenticated RPC** server-side, so the
  browser never sees node credentials. Behind the auth wall, only a
  signed-in Umbrel user can query your node through it. Still don't
  port-forward 4242.
- The watch-only wallet contains public keys only; nothing in this stack can
  spend funds. Spending requires your hardware-wallet signatures, as always
  with Caravan.

## Findings & troubleshooting

Everything learned building and debugging this — Umbrel app-store mechanics,
the nginx proxy design (and the port-dropping 308 bug), Caravan client quirks,
rescan behavior — is written up in [docs/FINDINGS.md](docs/FINDINGS.md).

## Advanced: manual client configuration (non-Umbrel or troubleshooting)

The zero-config flow above covers normal use. The manual steps it replaced
are kept here for pointing Caravan at a non-Umbrel node, or for
troubleshooting by hand.

1. Create a watch-only wallet on your node (one-time, holds no keys). Since
   1.19.7 the app sits behind the Umbrel login, so run this from the browser
   devtools console **on the Caravan page itself** (same-origin, carries your
   session):

   ```js
   fetch("/bitcoind/", { method: "POST", body: JSON.stringify({
     jsonrpc: "1.0", id: "1", method: "createwallet",
     params: { wallet_name: "caravan-main", disable_private_keys: true,
               blank: true, load_on_startup: true }
   })}).then(r => r.json()).then(console.log)
   ```

   (On a non-Umbrel deployment without the auth wall, the equivalent
   `curl -X POST http://<host>/bitcoind/ -d '<same JSON>'` still works.)

2. In Caravan (wallet import screen or your wallet-config JSON), set the client to:

   ```json
   "client": {
     "type": "private",
     "url": "http://umbrel.local:4242/bitcoind",
     "username": "anything",
     "walletName": "caravan-main"
   }
   ```

   Username/password can be anything non-empty (the proxy overrides them).
   **`walletName` is required** — without it Caravan refuses every wallet call
   (see [docs/FINDINGS.md](docs/FINDINGS.md#caravan-quirks)).

3. After importing your wallet config: **Import Addresses** (writes your
   descriptors into the watch-only wallet), then toggle **Rescan** on and run
   Import Addresses again to backfill history. On a node with
   `blockfilterindex=1` (Umbrel's default) a full rescan takes minutes, not
   hours. Reload the page when the scan finishes.
