#!/usr/bin/env bash
# TezSentinel Node Bootstrap
# https://github.com/TezSolutions/tez-sentinel-bootstrap
# Safe to pipe via: curl -fsSL <url> | bash

set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET}  $*"; }
err()  { echo -e "${RED}✗${RESET}  $*" >&2; }

# ─── Error trap ───────────────────────────────────────────────────────────────
trap 'err "Bootstrap failed at line ${LINENO}. See output above for details."; exit 1' ERR

# ─── Helpers ──────────────────────────────────────────────────────────────────
# Always read from /dev/tty so curl | bash piping works
prompt() {
    local __var="$1"
    local __msg="$2"
    local __default="${3:-}"
    local __reply

    if [[ -n "$__default" ]]; then
        printf "%b" "${CYAN}${__msg}${RESET} [${BOLD}${__default}${RESET}]: " > /dev/tty
    else
        printf "%b" "${CYAN}${__msg}${RESET}: " > /dev/tty
    fi

    IFS= read -r __reply < /dev/tty
    if [[ -z "$__reply" && -n "$__default" ]]; then
        __reply="$__default"
    fi
    printf -v "$__var" '%s' "$__reply"
}

prompt_enter() {
    printf "%b" "${CYAN}$*${RESET}" > /dev/tty
    IFS= read -r _ < /dev/tty
}

# ─── 1. Banner ────────────────────────────────────────────────────────────────
echo -e "
${BOLD}${CYAN}════════════════════════════════════════════════════════════
  Tez Sentinel — Node Bootstrap
  https://github.com/TezSolutions/tez-sentinel-bootstrap
════════════════════════════════════════════════════════════${RESET}
"

# ─── 2. Prerequisites ─────────────────────────────────────────────────────────
echo -e "${BOLD}[Step 1/8] Checking prerequisites...${RESET}"

if [[ $EUID -ne 0 ]]; then
    # Check if we can sudo
    if ! sudo -n true 2>/dev/null; then
        warn "This script needs sudo privileges to install packages."
        warn "You may be prompted for your password."
    fi
    SUDO="sudo"
else
    SUDO=""
fi

PACKAGES_NEEDED=()
for pkg in git curl docker.io; do
    if ! dpkg -s "$pkg" &>/dev/null 2>&1; then
        PACKAGES_NEEDED+=("$pkg")
    fi
done

# docker-compose-plugin check (package name may vary)
if ! dpkg -s docker-compose-plugin &>/dev/null 2>&1; then
    PACKAGES_NEEDED+=("docker-compose-plugin")
fi

if [[ ${#PACKAGES_NEEDED[@]} -gt 0 ]]; then
    warn "Missing packages: ${PACKAGES_NEEDED[*]}"
    echo "Installing via apt-get..."
    $SUDO apt-get update -qq
    $SUDO apt-get install -y "${PACKAGES_NEEDED[@]}"
    ok "Packages installed: ${PACKAGES_NEEDED[*]}"
else
    ok "All required packages are already installed."
fi

# Verify docker compose (plugin) is functional
if ! docker compose version &>/dev/null 2>&1; then
    err "docker compose (plugin) is not functional after install."
    err "Try: sudo apt-get install --reinstall docker-compose-plugin"
    exit 1
fi
ok "$(docker compose version)"

# Ensure current user is in docker group (warn only — needs re-login to take effect)
if ! groups | grep -qw docker; then
    warn "Your user is not in the 'docker' group."
    warn "Adding now — you may need to re-login or run 'newgrp docker' for it to take effect."
    $SUDO usermod -aG docker "$USER" || true
fi

# ─── 3. Deploy key setup ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[Step 2/8] Setting up SSH deploy key...${RESET}"

DEPLOY_KEY_PATH="${HOME}/.ssh/tez_sentinel_deploy"
DEPLOY_KEY_PUB="${DEPLOY_KEY_PATH}.pub"

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

if [[ -f "$DEPLOY_KEY_PATH" ]]; then
    warn "Deploy key already exists at ${DEPLOY_KEY_PATH} — reusing it."
else
    ssh-keygen -t ed25519 -C "tez-sentinel-$(hostname)" -f "$DEPLOY_KEY_PATH" -N "" -q
    ok "Ed25519 deploy key generated at ${DEPLOY_KEY_PATH}"
fi

chmod 600 "$DEPLOY_KEY_PATH"
chmod 644 "$DEPLOY_KEY_PUB"

PUB_KEY="$(cat "$DEPLOY_KEY_PUB")"

echo ""
echo -e "${BOLD}${GREEN}══════════════════════════ PUBLIC KEY ══════════════════════════${RESET}"
echo -e "${CYAN}${PUB_KEY}${RESET}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${RESET}"
echo ""

echo -e "${BOLD}Add this deploy key to the TezSentinel GitHub repo:${RESET}
  1. Go to: ${CYAN}https://github.com/TezSolutions/TezSentinel/settings/keys${RESET}
  2. Click ${BOLD}'Add deploy key'${RESET}
  3. Title: ${BOLD}tez-sentinel-$(hostname)${RESET}
  4. Key: (paste the key shown above)
  5. Check ${BOLD}'Allow write access'${RESET}: NO (read-only)
  6. Click ${BOLD}'Add key'${RESET}
"

prompt_enter "Press Enter once you have added the deploy key..."

# Configure SSH to use the deploy key for github.com
SSH_CONFIG="${HOME}/.ssh/config"
if ! grep -qF "tez_sentinel_deploy" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" <<EOF

# TezSentinel deploy key (added by bootstrap)
Host github.com-tezsentinel
    HostName github.com
    User git
    IdentityFile ${DEPLOY_KEY_PATH}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
    chmod 600 "$SSH_CONFIG"
fi

export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY_PATH} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

# Test SSH connection — retry up to 3 times
SSH_OK=false
for attempt in 1 2 3; do
    echo ""
    echo "Testing SSH connection to GitHub (attempt ${attempt}/3)..."
    # ssh -T returns exit code 1 even on success ("Hi user! You've authenticated...")
    SSH_OUTPUT="$(ssh -T -i "${DEPLOY_KEY_PATH}" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        git@github.com 2>&1)" || true

    if echo "$SSH_OUTPUT" | grep -q "successfully authenticated\|You've successfully authenticated\|Hi "; then
        ok "SSH connection to GitHub confirmed."
        SSH_OK=true
        break
    else
        err "SSH test failed (attempt ${attempt}/3)."
        echo -e "  Output: ${RED}${SSH_OUTPUT}${RESET}"
        if [[ $attempt -lt 3 ]]; then
            echo ""
            warn "Possible reasons:"
            warn "  • Deploy key not yet saved on GitHub — double-check step 1-6 above."
            warn "  • Network issue — check your internet connectivity."
            warn "  • Wrong key was pasted — ensure you copied the entire key line."
            echo ""
            prompt_enter "Press Enter to retry SSH test..."
        fi
    fi
done

if [[ "$SSH_OK" != "true" ]]; then
    err "Could not authenticate with GitHub after 3 attempts."
    err "Please verify the deploy key is correctly added, then re-run this script."
    exit 1
fi

# ─── 4. Clone repo ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[Step 3/8] Cloning TezSentinel repository...${RESET}"

REPO_DIR="${HOME}/TezSentinel"
REPO_URL="git@github.com:TezSolutions/TezSentinel.git"

if [[ -d "$REPO_DIR/.git" ]]; then
    warn "Repository already exists at ${REPO_DIR}."
    prompt PULL_CHOICE "Pull latest changes instead of re-cloning? (y/n)" "y"
    if [[ "${PULL_CHOICE,,}" == "y" ]]; then
        echo "Pulling latest..."
        git -C "$REPO_DIR" pull
        ok "Repository updated."
    else
        warn "Skipping clone/pull — using existing directory as-is."
    fi
elif [[ -d "$REPO_DIR" ]]; then
    err "${REPO_DIR} exists but is not a git repository."
    prompt OVERWRITE_CHOICE "Remove and re-clone? (y/n)" "n"
    if [[ "${OVERWRITE_CHOICE,,}" == "y" ]]; then
        rm -rf "$REPO_DIR"
        git clone "$REPO_URL" "$REPO_DIR"
        ok "Repository cloned to ${REPO_DIR}."
    else
        err "Cannot continue — resolve ${REPO_DIR} manually and re-run."
        exit 1
    fi
else
    git clone "$REPO_URL" "$REPO_DIR"
    ok "Repository cloned to ${REPO_DIR}."
fi

# ─── 5. .env setup ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[Step 4/8] Configuring environment (.env)...${RESET}"
echo "Press Enter to accept the default shown in [brackets]."
echo ""

prompt FRIGATE_RTSP_PASSWORD "FRIGATE_RTSP_PASSWORD" "TezCam@1984"
prompt TZ                    "TZ (timezone)"          "Asia/Kolkata"

cat > "${REPO_DIR}/.env" <<EOF
# TezSentinel environment — generated by bootstrap on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
FRIGATE_RTSP_PASSWORD=${FRIGATE_RTSP_PASSWORD}
TZ=${TZ}
EOF

ok ".env written to ${REPO_DIR}/.env"

# ─── 6. Frigate config reset ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[Step 5/8] Resetting Frigate configuration...${RESET}"

cd "$REPO_DIR"

FRIGATE_RESET_SCRIPT="Frigate/scripts/reset-config.sh"
if [[ -f "$FRIGATE_RESET_SCRIPT" ]]; then
    echo "Running: bash ${FRIGATE_RESET_SCRIPT} --apply"
    bash "$FRIGATE_RESET_SCRIPT" --apply
    ok "Frigate config reset complete."
else
    warn "Frigate reset script not found at ${REPO_DIR}/${FRIGATE_RESET_SCRIPT}."
    warn "Skipping Frigate config reset — you can run it manually later."
fi

# ─── 7. Sentinel Link integration ────────────────────────────────────────────
echo ""
echo -e "${BOLD}[Step 6/8] Installing Sentinel Link integration...${RESET}"

SENTINEL_LINK_DIR="${HOME}/sentinel-link"
HA_CC_DIR="${REPO_DIR}/HA/config/custom_components/sentinel_link"

if [[ -d "$SENTINEL_LINK_DIR/.git" ]]; then
    git -C "$SENTINEL_LINK_DIR" pull --ff-only || warn "Could not pull sentinel-link — using existing copy."
else
    git clone git@github.com:TezSolutions/sentinel-link.git "$SENTINEL_LINK_DIR"
    ok "Cloned TezSolutions/sentinel-link."
fi

mkdir -p "$HA_CC_DIR"
rsync -a --exclude='__pycache__' "$SENTINEL_LINK_DIR/custom_components/sentinel_link/" "$HA_CC_DIR/"
LINK_VERSION="$(python3 -c "import json;print(json.load(open('${HA_CC_DIR}/manifest.json'))['version'])" 2>/dev/null || echo unknown)"
ok "Sentinel Link v${LINK_VERSION} deployed to ${HA_CC_DIR}"

# ─── 8. Docker Compose up ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[Step 7/8] Starting TezSentinel stack with Docker Compose...${RESET}"

cd "$REPO_DIR"
docker compose up -d
ok "docker compose up -d complete."

# ─── 8. Confirm HA trusted-proxies trial (HA 2026.9+) ────────────────────────
# HA migrates the YAML http: block (trusted_proxies etc.) into
# .storage/http as a *pending* trial on first boot. The trial must be
# confirmed by a request arriving THROUGH a trusted proxy within 5 minutes
# of boot, otherwise it is recorded error=not_promoted, never applied
# again, and reverse-proxy access (tez-api-server / Caddy / sentinel app)
# dies with "HTTP integration is not set-up for reverse proxies".
# On a fresh node there is no proxied traffic yet, so we promote the
# pending config to stable deterministically instead of hoping.
echo ""
echo -e "${BOLD}[Step 8/8] Confirming HA trusted-proxies config...${RESET}"

HA_URL="http://localhost:8123"
echo "Waiting for Home Assistant to come up..."
HA_UP=false
for attempt in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HA_URL" || true)"
    if [[ "$code" == "200" || "$code" == "401" ]]; then
        HA_UP=true
        break
    fi
    sleep 5
done
if [[ "$HA_UP" != "true" ]]; then
    warn "HA did not respond on ${HA_URL} within 5 minutes — skipping"
    warn "trusted-proxies confirm. Run it manually (see TezSentinel skills)."
else
    docker stop homeassistant >/dev/null
    python3 - <<'PYEOF'
import json, os
p = os.path.expanduser("~/TezSentinel/HA/config/.storage/http")
d = json.load(open(p))
pend = d["data"].get("pending")
if pend:
    pend.pop("error", None)
    pend.pop("error_message", None)
    d["data"]["stable"] = pend
    d["data"]["pending"] = None
    json.dump(d, open(p, "w"))
    print("Promoted pending HTTP config to stable (trusted_proxies active).")
else:
    print("No pending HTTP config — stable already active.")
PYEOF
    docker start homeassistant >/dev/null
    ok "HA restarted with trusted-proxies config confirmed as stable."
fi

# ─── 9. Final summary ─────────────────────────────────────────────────────────
HOST_IP="$(hostname -I | awk '{print $1}')"

echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════
  ✓ TezSentinel stack is up!

  Services:
    Home Assistant : http://${HOST_IP}:8123
    Frigate        : http://${HOST_IP}:5000
    Node-RED       : http://${HOST_IP}:1880

  Next steps:
    1. Edit ~/TezSentinel/Frigate/config/config.yml
       - Add your camera streams under go2rtc.streams
       - Add your cameras: block
       - Set genai.base_url to your Ollama server Tailscale IP
       - Set notifications.email
       Then: docker compose restart frigate

    2. Open Home Assistant and complete onboarding
       Then install remaining HACS integrations:
       - Frigate
       - Advanced Camera Card

    3. Configure Sentinel Link via Settings → Integrations
       (already deployed by bootstrap step 6 — just set it up)
════════════════════════════════════════════════════════════${RESET}
"
