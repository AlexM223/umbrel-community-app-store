# Caravan Store

A self-hosted [Umbrel community app store](https://github.com/getumbrel/umbrel-community-app-store)
that packages [Caravan](https://github.com/caravan-bitcoin/caravan) - the
stateless Bitcoin multisig coordinator - as an Umbrel app wired to your own
Bitcoin node.

## Add this store to your Umbrel

Umbrel home -> App Store -> three-dots menu -> Community App Stores -> paste:

```
http://umbrel.local:8085/caravan-store/umbrel-community-app-store.git
```

## Apps in this store

- **Caravan** (`caravan-store-caravan`) - stateless multisig coordinator on
  port `4242`. Depends on the official **Bitcoin** app (Umbrel installs it
  first and injects its RPC credentials).

## How the build works

This app is not pulled from a public Docker registry. The `web` service in
`caravan-store-caravan/docker-compose.yml` uses a **git build context** on the
same Gitea instance:

```
http://umbrel.local:8085/caravan-store/caravan.git#umbrel
```

At install time the Umbrel clones the `umbrel` branch of the Gitea-hosted
Caravan fork and builds `apps/coordinator/Dockerfile.umbrel` on-device. The
resulting container serves the Caravan UI on port 80 (exposed via the app
proxy at 4242) and reverse-proxies `/bitcoind/` to the Umbrel Bitcoin node,
injecting the real RPC credentials server-side.

## Dev loop

1. Edit the Caravan fork locally, commit, and push to the Gitea `umbrel`
   branch.
2. If store files changed (`umbrel-app.yml`, `docker-compose.yml`), push this
   repo to Gitea too.
3. On the Umbrel, uninstall and reinstall the Caravan app. Reinstalling
   re-clones the build context and rebuilds the image, picking up both kinds
   of changes.
