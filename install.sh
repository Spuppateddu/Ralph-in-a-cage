#!/usr/bin/env bash
#
# Host bootstrap for the Ralph runner. Installs the ONLY things the host needs:
# Docker Engine + the Compose plugin, and grants your user access to Docker.
# Everything else (PHP, Node, gh, Claude CLI) lives inside the container.
#
# Safe to re-run: each step is skipped if already satisfied. Debian/Ubuntu only.
#
#   ./install.sh         # run as your normal user; it uses sudo where needed
#
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}!!${NC} $*"; }
err()   { echo -e "${RED}xx${NC} $*" >&2; }

# Use sudo only when not already root.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
# The user that should end up in the docker group (not "root" when via sudo).
TARGET_USER="${SUDO_USER:-$USER}"

# --- Sanity: Debian/Ubuntu --------------------------------------------------
if ! [ -f /etc/os-release ]; then err "Cannot detect OS (no /etc/os-release)."; exit 1; fi
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) : ;;
    *) err "This script supports Debian/Ubuntu only. Detected: ${PRETTY_NAME:-unknown}"; exit 1 ;;
esac
ARCH="$(dpkg --print-architecture)"
# Docker's apt repo is keyed by distro id (ubuntu/debian) + codename.
DOCKER_DISTRO="ubuntu"; [ "${ID:-}" = "debian" ] && DOCKER_DISTRO="debian"
CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
if [ -z "$CODENAME" ]; then err "Cannot determine distro codename."; exit 1; fi
info "Host: ${PRETTY_NAME} (${DOCKER_DISTRO}/${CODENAME}, ${ARCH})"

# --- Docker Engine + Compose plugin -----------------------------------------
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    info "Docker + Compose already installed ($(docker --version))."
else
    info "Installing Docker Engine + Compose plugin..."

    # Drop distro packages that conflict with Docker's official ones.
    $SUDO apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true

    $SUDO apt-get update
    $SUDO apt-get install -y ca-certificates curl

    $SUDO install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        $SUDO curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" \
            -o /etc/apt/keyrings/docker.asc
        $SUDO chmod a+r /etc/apt/keyrings/docker.asc
    fi

    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${CODENAME} stable" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

    $SUDO apt-get update
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    info "Docker installed: $(docker --version)"
fi

# --- Docker group (run without sudo) ----------------------------------------
$SUDO groupadd -f docker
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
    info "User '${TARGET_USER}' already in the docker group."
    DOCKER_GROUP_ADDED=0
else
    $SUDO usermod -aG docker "$TARGET_USER"
    info "Added '${TARGET_USER}' to the docker group."
    DOCKER_GROUP_ADDED=1
fi

# --- .env scaffold ----------------------------------------------------------
cd "$(dirname "$0")"
if [ ! -f .env ]; then
    cp .env.example .env
    info "Created .env from .env.example — edit it before starting."
else
    info ".env already exists (left untouched)."
fi

# --- Next steps -------------------------------------------------------------
echo
info "Host setup complete."
if [ "${DOCKER_GROUP_ADDED}" -eq 1 ]; then
    warn "Log out and back in (or run 'newgrp docker') so docker works without sudo."
fi
cat <<EOF

Next:
  1. Edit ./.env  (PROJECT_API_BASE_URL, PROJECT_SLUG/PROJECT_TOKEN, DEFAULT_AGENT,
     GH_TOKEN)
  2. cp config/repos.list.example config/repos.list  and add your repo SSH URLs
  3. docker compose build
  4. docker compose up -d
  5. docker compose exec -it runner /scripts/setup.sh   # one-time: logins, SSH key, clone
  6. docker compose logs -f runner
EOF
