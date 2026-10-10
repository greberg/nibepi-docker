#!/usr/bin/env bash
# One-command NibePi install/upgrade on a Raspberry Pi (64-bit OS), using the
# prebuilt image from GHCR - nothing is built on the Pi.
#
#   curl -fsSL https://raw.githubusercontent.com/greberg/nibepi-docker/improvements/pi/install.sh | bash
#
# Re-running it upgrades: pulls the newest image and recreates the container.
# Data is never overwritten. Settings (override with environment variables):
#   NIBEPI_ROOT    where data lives               default ~/nibepi
#   NIBEPI_IMAGE   image to run                   default ghcr.io/greberg/nibepi-nodered:latest
#   NIBEPI_SERIAL  RS485 serial device, or "none" for a NibeGW gateway
#                                                 default /dev/ttyAMA0 if present, else none
#   FLOW_REPO      flows to start from            default https://github.com/greberg/nibepi-flow.git
#   FLOW_BRANCH    branch of FLOW_REPO            default improvements
#   REPLACE=1      remove an existing "nibepi" container started some other way
#
# Everything runs from main(), called on the last line, so a download cut off
# halfway through (curl | bash) is a syntax error that runs nothing rather
# than half an install.
set -euo pipefail

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

main() {
NIBEPI_ROOT="${NIBEPI_ROOT:-$HOME/nibepi}"
NIBEPI_IMAGE="${NIBEPI_IMAGE:-ghcr.io/greberg/nibepi-nodered:latest}"
FLOW_REPO="${FLOW_REPO:-https://github.com/greberg/nibepi-flow.git}"
FLOW_BRANCH="${FLOW_BRANCH:-improvements}"
if [ -z "${NIBEPI_SERIAL:-}" ]; then
  if [ -e /dev/ttyAMA0 ]; then NIBEPI_SERIAL=/dev/ttyAMA0; else NIBEPI_SERIAL=none; fi
fi

# --- prerequisites ---------------------------------------------------------
command -v docker >/dev/null || die "Docker is not installed. Install it with:
  curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker \$USER
then log out and in again, and re-run this installer."
docker compose version >/dev/null 2>&1 || die "The docker compose plugin is missing (sudo apt install docker-compose-plugin)."
docker info >/dev/null 2>&1 || die "Can't talk to Docker. Is your user in the docker group? (sudo usermod -aG docker \$USER, then log in again)"
command -v git >/dev/null || die "git is missing (sudo apt install -y git)."
case "$(uname -m)" in
  aarch64|x86_64) ;;
  *) die "The prebuilt image is for 64-bit systems (arm64/amd64); this is $(uname -m). Use a 64-bit Raspberry Pi OS, or build locally." ;;
esac

# --- an existing container from another setup ------------------------------
existing_project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' nibepi 2>/dev/null || true)"
if docker inspect nibepi >/dev/null 2>&1 && [ "$existing_project" != "$NIBEPI_ROOT" ]; then
  if [ "${REPLACE:-}" = "1" ]; then
    say "Removing the existing nibepi container (data in bind mounts is kept)"
    docker rm -f nibepi >/dev/null
  else
    die "A container named nibepi already exists (from ${existing_project:-docker run}).
Its data folders are not touched by removing it. Re-run with REPLACE=1 to replace it,
and point NIBEPI_ROOT at its data folder if that isn't $NIBEPI_ROOT."
  fi
fi

# --- data folders ------------------------------------------------------------
say "Data in $NIBEPI_ROOT"
mkdir -p "$NIBEPI_ROOT/etc/nibepi" "$NIBEPI_ROOT/tmp" "$NIBEPI_ROOT/data"
if [ ! -d "$NIBEPI_ROOT/data/nibepi-flow" ]; then
  say "Fetching flows from $FLOW_REPO ($FLOW_BRANCH)"
  git clone --quiet -b "$FLOW_BRANCH" "$FLOW_REPO" "$NIBEPI_ROOT/data/nibepi-flow"
else
  echo "    flows already present, left as they are"
fi
# The container runs as node-red (uid 1000); if it can't write here, Node-RED
# and the nibepi core fail in ways that are hard to trace back to this.
owned=("$NIBEPI_ROOT/etc/nibepi" "$NIBEPI_ROOT/tmp" "$NIBEPI_ROOT/data/nibepi-flow")
chown_cmd=(sudo chown); if [ "$(id -u)" -eq 0 ]; then chown_cmd=(chown); fi
"${chown_cmd[@]}" -R 1000:1000 "${owned[@]}" \
  || die "Couldn't hand ${owned[*]} to uid 1000 (node-red in the container). Fix it with:
  sudo chown -R 1000:1000 ${owned[*]}
and re-run this installer."

# --- .env ---------------------------------------------------------------------
env_file="$NIBEPI_ROOT/.env"
touch "$env_file"; chmod 600 "$env_file"
set_env() { grep -q "^$1=" "$env_file" && sed -i "s|^$1=.*|$1=$2|" "$env_file" || echo "$1=$2" >> "$env_file"; }
set_env NIBEPI_IMAGE "$NIBEPI_IMAGE"
set_env TZ "${TZ:-$(cat /etc/timezone 2>/dev/null || echo Europe/Stockholm)}"
if ! grep -q '^NODE_RED_CREDENTIAL_SECRET=.' "$env_file"; then
  set_env NODE_RED_CREDENTIAL_SECRET "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  echo "    generated a Node-RED credential secret in $env_file - back it up"
fi

# --- compose file ---------------------------------------------------------------
serial_block=""
if [ "$NIBEPI_SERIAL" != "none" ]; then
  [ -e "$NIBEPI_SERIAL" ] || die "$NIBEPI_SERIAL does not exist. Enable the serial port (raspi-config -> Interface -> Serial: login shell no, hardware yes), or set NIBEPI_SERIAL=none for a NibeGW gateway."
  dialout_gid="$(getent group dialout | cut -d: -f3)"
  serial_block="    devices:
      - $NIBEPI_SERIAL:$NIBEPI_SERIAL
    group_add:
      - \"${dialout_gid:-20}\""
fi
say "Writing $NIBEPI_ROOT/compose.yml (serial: $NIBEPI_SERIAL)"
cat > "$NIBEPI_ROOT/compose.yml" <<YML
# Written by pi/install.sh - re-running the installer regenerates it.
services:
  nibepi:
    image: \${NIBEPI_IMAGE}
    container_name: nibepi
    restart: unless-stopped
    stdin_open: true
    tty: true
    environment:
      - TZ=\${TZ}
      - NODE_RED_CREDENTIAL_SECRET=\${NODE_RED_CREDENTIAL_SECRET}
    volumes:
      - ./data/nibepi-flow:/data
      - ./etc/nibepi:/etc/nibepi
      - ./tmp:/tmp
    ports:
      - "1880:1880"
      - "9999:9999/udp"
$serial_block
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YML

# --- start ------------------------------------------------------------------------
cd "$NIBEPI_ROOT"
say "Pulling $NIBEPI_IMAGE"
docker compose pull --quiet
say "Starting"
docker compose up -d --force-recreate

# --- credentialSecret in settings.js (Node-RED creates the file on first start) ----
settings="$NIBEPI_ROOT/data/nibepi-flow/settings.js"
for _ in $(seq 1 30); do [ -f "$settings" ] && break; sleep 2; done
if [ -f "$settings" ] && ! grep -q 'credentialSecret: *process.env.NODE_RED_CREDENTIAL_SECRET' "$settings"; then
  say "Letting settings.js read the credential secret from the environment"
  sudo cp "$settings" "$settings.bak" 2>/dev/null || cp "$settings" "$settings.bak"
  if grep -qE '^\s*//\s*credentialSecret:' "$settings"; then
    sudo sed -i -E 's|^(\s*)//\s*credentialSecret:.*|\1credentialSecret: process.env.NODE_RED_CREDENTIAL_SECRET,|' "$settings"
  else
    sudo sed -i -E 's|^(module.exports\s*=\s*\{)|\1\n    credentialSecret: process.env.NODE_RED_CREDENTIAL_SECRET,|' "$settings"
  fi
  docker compose restart >/dev/null
fi

docker image prune -f >/dev/null 2>&1 || true
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
say "NibePi is running: http://${ip:-<pi-address>}:1880  (dashboard: /ui)"
echo "    logs:    cd $NIBEPI_ROOT && docker compose logs -f"
echo "    upgrade: re-run this installer"
}

main "$@"
