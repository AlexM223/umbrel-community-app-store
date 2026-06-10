# Caravan Store

An [Umbrel community app store](https://github.com/getumbrel/umbrel-community-app-store)
that packages [Caravan](https://github.com/caravan-bitcoin/caravan) — the
stateless Bitcoin multisig coordinator — as an Umbrel app wired to **your own
Bitcoin node**, with no public Docker registry involved: the image is built
on your Umbrel, from source, at install time.

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

## Connecting Caravan to your node

The app's nginx serves the Caravan UI and reverse-proxies `/bitcoind` to your
node's RPC, injecting the node's real credentials **server-side** — you never
have to copy them into a browser.

1. Create a watch-only wallet on your node (one-time, holds no keys). From any
   machine on your LAN:

   ```sh
   curl -X POST http://umbrel.local:4242/bitcoind/ \
     -d '{"jsonrpc":"1.0","id":"1","method":"createwallet","params":{"wallet_name":"caravan-main","disable_private_keys":true,"blank":true,"load_on_startup":true}}'
   ```

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

## How the build works

The `web` service in `caravan-store-caravan/docker-compose.yml` uses a **git
build context**:

```
https://github.com/AlexM223/caravan.git#umbrel
```

At install time the Umbrel clones the `umbrel` branch of the Caravan fork and
builds `apps/coordinator/Dockerfile.umbrel` on-device (the official multi-stage
build plus a small nginx layer for the node proxy). No registry, no insecure
Docker config, no SSH onto the device — git build contexts work out of the box.

## Dev loop

1. Edit the Caravan fork, commit to its `umbrel` branch, push.
2. If store files changed, bump `version:` in `caravan-store-caravan/umbrel-app.yml`
   and push this repo.
3. On the Umbrel: apply the app update (or uninstall → reinstall). Updates
   re-clone the build context and rebuild — cached layers make source-only
   changes quick.

## Security model (read this once)

- The app sits behind Umbrel's `app_proxy` with `PROXY_AUTH_ADD: "false"`
  (like the Gitea app), so `http://umbrel.local:4242` is reachable by anyone
  on your LAN.
- The `/bitcoind` proxy **injects authenticated RPC** — anyone on your LAN can
  query your node through it without credentials. This is the same trust class
  as the node's own LAN-exposed RPC port, but it removes the password gate.
  Don't port-forward 4242, and treat your LAN as the security boundary.
- The watch-only wallet contains public keys only; nothing in this stack can
  spend funds. Spending requires your hardware-wallet signatures, as always
  with Caravan.

## Findings & troubleshooting

Everything learned building and debugging this — Umbrel app-store mechanics,
the nginx proxy design (and the port-dropping 308 bug), Caravan client quirks,
rescan behavior — is written up in [docs/FINDINGS.md](docs/FINDINGS.md).
