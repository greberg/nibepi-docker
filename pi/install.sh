#!/usr/bin/env bash
# One-command NibePi install/upgrade on a Raspberry Pi (64-bit OS), using the
# prebuilt image from GHCR - nothing is built on the Pi.
#
#   curl -fsSL https://raw.githubusercontent.com/greberg/nibepi-docker/improvements/pi/install.sh | bash
#
# Re-running it upgrades: pulls the newest image and recreates the container.
# Data is never overwritten. The image that was running is kept as
# ghcr.io/greberg/nibepi-nodered:previous; afterwards the installer waits for
# the container to report healthy and says how to roll back if it doesn't.
# Settings (override with environment variables):
#   NIBEPI_ROOT    where data lives               default ~/nibepi
#   NIBEPI_TAG     image tag: latest, a build date (20261010) or previous
#                                                 default latest
#   NIBEPI_IMAGE   image to run (overrides NIBEPI_TAG)
#                                                 default ghcr.io/greberg/nibepi-nodered:$NIBEPI_TAG
#   NIBEPI_SERIAL  RS485 serial device on the host, or "none" for a NibeGW
#                  gateway; it is /dev/ttyAMA0 inside the container
#                                                 default /dev/serial0 if present, else none
#   FLOW_REPO      flows to start from            default https://github.com/greberg/nibepi-flow.git
#   FLOW_BRANCH    branch of FLOW_REPO            default improvements
#   REPLACE=1      remove an existing "nibepi" container started some other way
#
# Everything runs from main(), called on the last line, so a download cut off
# halfway through (curl | bash) is a syntax error that runs nothing rather
# than half an install.
set -euo pipefail

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

INSTALL_URL=https://raw.githubusercontent.com/greberg/nibepi-docker/improvements/pi/install.sh
IMAGE_REPO=ghcr.io/greberg/nibepi-nodered
PREVIOUS_IMAGE="$IMAGE_REPO:previous"

container_state() {  # running/exited + health: healthy, unhealthy, starting or none
  docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' nibepi 2>/dev/null \
    || echo "missing none"
}

# Waits up to ~6 minutes (the healthcheck's start period is 5) and leaves
# the outcome in $health: healthy, unhealthy, exited, starting (still
# undecided) or none (the image has no healthcheck).
wait_healthy() {
  local state status
  printf '    waiting for the healthcheck'
  for _ in $(seq 1 36); do
    read -r state status <<<"$(container_state)"
    if [ "$state" != running ]; then health=exited; break; fi
    health=$status
    case "$health" in healthy|unhealthy|none) break ;; esac
    printf '.'; sleep 10
  done
  printf ' %s\n' "$health"
}

rollback_help() {
  if docker image inspect "$PREVIOUS_IMAGE" >/dev/null 2>&1 && [ "$NIBEPI_IMAGE" != "$PREVIOUS_IMAGE" ]; then
    echo "  To go back to the image that ran before this upgrade:"
    echo "    curl -fsSL $INSTALL_URL | NIBEPI_ROOT=$NIBEPI_ROOT NIBEPI_TAG=previous bash"
  else
    echo "  To run a specific dated build instead (see the package's tags on GitHub):"
    echo "    curl -fsSL $INSTALL_URL | NIBEPI_ROOT=$NIBEPI_ROOT NIBEPI_TAG=YYYYMMDD bash"
  fi
  echo "  Re-running the installer without NIBEPI_TAG goes back to :latest."
  echo "  If the pump or the RS485 wiring is the problem rather than the image, a"
  echo "  rollback won't help - check: cd $NIBEPI_ROOT && docker compose logs --tail 100"
}

main() {
NIBEPI_ROOT="${NIBEPI_ROOT:-$HOME/nibepi}"
NIBEPI_TAG="${NIBEPI_TAG:-latest}"
NIBEPI_IMAGE="${NIBEPI_IMAGE:-$IMAGE_REPO:$NIBEPI_TAG}"
FLOW_REPO="${FLOW_REPO:-https://github.com/greberg/nibepi-flow.git}"
FLOW_BRANCH="${FLOW_BRANCH:-improvements}"
# /dev/serial0 is the Pi's stable alias for the GPIO UART. /dev/ttyAMA0 is
# not: on a Pi 3/4 without dtoverlay=disable-bt it is the Bluetooth UART.
serial_guessed=false
if [ -z "${NIBEPI_SERIAL:-}" ]; then
  serial_guessed=true
  if [ -e /dev/serial0 ]; then NIBEPI_SERIAL=/dev/serial0; else NIBEPI_SERIAL=none; fi
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
replace_existing=false
existing_project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' nibepi 2>/dev/null || true)"
if docker inspect nibepi >/dev/null 2>&1 && [ "$existing_project" != "$NIBEPI_ROOT" ]; then
  if [ "${REPLACE:-}" = "1" ]; then
    replace_existing=true
  else
    die "A container named nibepi already exists (from ${existing_project:-docker run}).
Its data folders are not touched by removing it. Re-run with REPLACE=1 to replace it,
and point NIBEPI_ROOT at its data folder if that isn't $NIBEPI_ROOT."
  fi
fi

# --- keep the running image as :previous, for a rollback ----------------------
# Only a known-good one (healthy, or from before the healthcheck existed):
# re-running after a bad upgrade must not overwrite the good :previous with
# the bad image. Without a :previous yet, any running image beats none.
if [ "$NIBEPI_IMAGE" = "$PREVIOUS_IMAGE" ]; then
  docker image inspect "$PREVIOUS_IMAGE" >/dev/null 2>&1 \
    || die "There is no $PREVIOUS_IMAGE on this machine to roll back to. Pick a dated build with NIBEPI_TAG=YYYYMMDD."
  say "Rolling back to $PREVIOUS_IMAGE"
elif running_image="$(docker inspect -f '{{.Image}}' nibepi 2>/dev/null)"; then
  say "Keeping the current image for a rollback"
  read -r state status <<<"$(container_state)"
  if [ "$state $status" = "running healthy" ] || [ "$state $status" = "running none" ] \
     || ! docker image inspect "$PREVIOUS_IMAGE" >/dev/null 2>&1; then
    docker tag "$running_image" "$PREVIOUS_IMAGE"
    echo "    current image kept as $PREVIOUS_IMAGE"
  else
    echo "    the running container is $state/$status - keeping the existing $PREVIOUS_IMAGE"
  fi
fi
if $replace_existing; then
  say "Removing the existing nibepi container (data in bind mounts is kept)"
  docker rm -f nibepi >/dev/null
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
uart_help="For the RS485 HAT, add to /boot/firmware/config.txt (this installer doesn't edit it):
      enable_uart=1
      dtoverlay=disable-bt    # Pi 3/4: puts the full PL011 UART on the GPIO pins
  then reboot (and on a Pi 3/4: sudo systemctl disable hciuart), and re-run this installer.
  raspi-config -> Interface -> Serial (login shell: no, hardware: yes) sets enable_uart."
serial_block=""
if [ "$NIBEPI_SERIAL" != "none" ]; then
  [ -e "$NIBEPI_SERIAL" ] || die "$NIBEPI_SERIAL does not exist. $uart_help
  Or set NIBEPI_SERIAL=none for a NibeGW gateway."
  if [ "$(readlink -f "$NIBEPI_SERIAL")" = /dev/ttyS0 ]; then
    warn "$NIBEPI_SERIAL is the mini UART (ttyS0), whose baud rate drifts with the CPU clock. $uart_help"
  fi
  dialout_gid="$(getent group dialout | cut -d: -f3)"
  serial_block="    devices:
      - $NIBEPI_SERIAL:/dev/ttyAMA0
    group_add:
      - \"${dialout_gid:-20}\""
elif $serial_guessed; then
  warn "/dev/serial0 is missing, so no serial port is passed through (fine for a NibeGW gateway). $uart_help"
fi
say "Writing $NIBEPI_ROOT/compose.yml (serial: $NIBEPI_SERIAL)"
cat > "$NIBEPI_ROOT/compose.yml" <<YML
# Written by pi/install.sh - re-running the installer regenerates it.
# Kept in step with nibepi-docker's docker-compose.yml.
services:
  nibepi:
    image: \${NIBEPI_IMAGE}
    container_name: nibepi
    restart: unless-stopped
    stdin_open: true
    tty: true
    environment:
      - TZ=\${TZ}
      - NODE_RED_CREDENTIAL_SECRET=\${NODE_RED_CREDENTIAL_SECRET:?set NODE_RED_CREDENTIAL_SECRET in $env_file}
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
if [ "$NIBEPI_IMAGE" != "$PREVIOUS_IMAGE" ]; then  # :previous only exists locally
  say "Pulling $NIBEPI_IMAGE"
  docker compose pull --quiet
fi
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

# Dangling images only; :previous is tagged and stays.
docker image prune -f >/dev/null 2>&1 || true

# --- health -------------------------------------------------------------------------
# No automatic rollback: "unhealthy" means no data from the pump, which is as
# likely the pump, the wiring or the UART config as the new image, and a
# silent rollback would hide that. Say what happened and how to go back.
say "Checking health"
health=starting
wait_healthy
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
url="http://${ip:-<pi-address>}:1880"
case "$health" in
  healthy)
    say "NibePi is running and healthy: $url  (dashboard: /ui)" ;;
  none)
    say "NibePi is running: $url  (dashboard: /ui)"
    echo "    this image has no healthcheck, so its health isn't known" ;;
  starting)
    warn "NibePi is running ($url) but hasn't reported healthy yet - usually no data from the pump so far."
    echo "  Check again in a few minutes:  docker ps   (STATUS shows healthy/unhealthy)"
    echo "  If it turns unhealthy:"
    rollback_help ;;
  *)
    printf 'error: the nibepi container is %s.\n' "$health" >&2
    docker inspect -f '{{if .State.Health}}{{range .State.Health.Log}}    {{.Output}}{{end}}{{end}}' nibepi 2>/dev/null | tail -n 3 || true
    docker compose logs --tail 20 nibepi || true
    rollback_help
    exit 1 ;;
esac
echo "    logs:    cd $NIBEPI_ROOT && docker compose logs -f"
echo "    status:  docker ps --filter name=nibepi"
echo "    upgrade: re-run this installer"
}

main "$@"
