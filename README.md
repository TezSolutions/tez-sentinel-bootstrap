# Tez Sentinel — Node Bootstrap
> One-command deployment for new Tez Sentinel nodes

---

## Quick Start

Run the following command on a fresh node to bootstrap the entire Tez Sentinel stack:

```bash
curl -sL https://raw.githubusercontent.com/TezSolutions/tez-sentinel-bootstrap/main/bootstrap.sh | bash
```

> **Note:** Requires `sudo` or a root session on first run — the script installs system packages (git, docker, docker compose) if they are not already present.

---

## What It Does

The bootstrap script handles end-to-end setup so you don't have to stitch things together manually:

1. **Checks and installs prerequisites** — verifies and installs `git`, `docker`, and `docker compose` if missing.
2. **Generates a node-specific SSH deploy key** — creates a fresh ed25519 key pair scoped to this node.
3. **Guides you through adding it to the private TezSentinel repo on GitHub** — prints the public key and pauses with instructions so you can add it before the clone step.
4. **Clones `TezSolutions/TezSentinel` (private)** — pulls the full private stack repo via SSH using the deploy key.
5. **Creates `.env` with configurable defaults** — writes a starter environment file so the stack can come up immediately.
6. **Runs Frigate config reset** — auto-detects the node's Tailscale IP and injects it as the WebRTC `advertised_host`.
7. **Brings up the full Docker Compose stack** — runs `docker compose up -d` and confirms all services are healthy.

---

## Prerequisites

Before running the bootstrap command, make sure the following are in place:

- **OS:** Ubuntu 22.04+ or Debian 12+
- **Internet access** — required to pull packages, Docker images, and the private repo
- **Tailscale installed and connected** — used for WebRTC peer negotiation and secure Tailnet access to services
- **Access to the TezSolutions GitHub org** — you must have permission to add a deploy key to the private `TezSentinel` repository

---

## GitHub Deploy Key

### What is a deploy key?

A **deploy key** is a read-only SSH public key attached to a single GitHub repository. It grants the node just enough access to clone (and pull updates from) `TezSolutions/TezSentinel` — nothing more. Each node gets its own unique key so access can be revoked per-node without affecting others.

### Adding the key

The bootstrap script will print the generated public key and pause, waiting for you to add it to GitHub. Follow these steps:

1. **Copy** the public key printed in the terminal (it starts with `ssh-ed25519 ...`).
2. **Open** the deploy keys settings page for the private repo:
   👉 [https://github.com/TezSolutions/TezSentinel/settings/keys](https://github.com/TezSolutions/TezSentinel/settings/keys)
3. Click **"Add deploy key"** (top-right button).
4. **Title** the key with something identifiable — e.g. `tez-sentinel-node-livingroom` or the hostname.
5. **Paste** the public key into the "Key" field.
6. Leave **"Allow write access"** unchecked — read-only is sufficient.
7. Click **"Add key"** to save.
8. Return to the terminal and press **Enter** to continue the bootstrap.

> 💡 *Screenshot tip:* The deploy keys page lists all active keys with their fingerprints. If you ever need to revoke a node's access, simply delete its key from this list.

---

## After Bootstrap

Once the stack is up, complete these three setup steps:

1. **Edit the Frigate config** — open `frigate/config.yml` and configure your camera RTSP streams, set the `genai` `base_url` for AI detection, and add your notification email address.

2. **Complete Home Assistant onboarding + install HACS integrations** — navigate to `http://<node-ip>:8123`, finish the HA setup wizard, then install the remaining HACS integrations (Frigate, Advanced Camera Card).

3. **Configure the Sentinel Link integration** — the integration is already deployed to `HA/config/custom_components/sentinel_link/` by the bootstrap (step 6 of 8). Inside Home Assistant, just set it up via Settings → Integrations.

---

## Stack Services

| Service | Port | Notes |
|---|---|---|
| Home Assistant | `8123` | Smart home hub |
| Frigate | `5000` | NVR + AI detection |
| Node-RED | `1880` | Automation flows |
| Mosquitto | `1883` | MQTT broker |

All services are accessible over your Tailnet using the node's Tailscale IP (e.g. `http://100.x.x.x:8123`).

---

## Environment Variables

The bootstrap script generates a `.env` file at the root of the cloned repo with the following defaults. Edit this file before (or after) the stack starts to customise your deployment.

| Variable | Default | Description |
|---|---|---|
| `FRIGATE_RTSP_PASSWORD` | `TezCam@1984` | RTSP stream password used by Frigate to authenticate camera feeds |
| `TZ` | `Asia/Kolkata` | Timezone applied to all containers for consistent timestamps and scheduling |

> **Security reminder:** Change `FRIGATE_RTSP_PASSWORD` to a strong, unique value before exposing any camera streams.

---

## Repo Structure

This repository (`TezSolutions/tez-sentinel-bootstrap`) contains **only** the bootstrap script. The full application stack — Docker Compose files, Frigate config, Node-RED flows, and HA configuration — lives in the **private** [`TezSolutions/TezSentinel`](https://github.com/TezSolutions/TezSentinel) repository, which this script clones onto your node.

```
tez-sentinel-bootstrap/
└── bootstrap.sh        # The one-liner entry point
```

---

## License

Copyright © Tez Solutions. All rights reserved.

Unauthorised copying, distribution, or modification of any files in this repository or the private `TezSentinel` stack is strictly prohibited.
