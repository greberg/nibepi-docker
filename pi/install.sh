#!/usr/bin/env bash
# One-command NibePi gateway install/upgrade on a Raspberry Pi (64-bit OS),
# using the prebuilt image from GHCR - nothing is built on the Pi.
#
#   curl -fsSL https://raw.githubusercontent.com/greberg/nibepi-docker/improvements/pi/install.sh \
#     | NIBEPI_MQTT_HOST=192.168.1.10 NIBEPI_MQTT_USER=nibepi NIBEPI_MQTT_PASS=secret bash
#
# The gateway talks to the pump and connects out to an MQTT broker (usually
# the Mosquitto add-on on the Home Assistant machine); control logic lives in
# the Home Assistant component. It publishes no ports.
#
# The first run needs NIBEPI_MQTT_HOST; the MQTT settings go into
# $NIBEPI_ROOT/.env (mode 600), which later runs keep. Re-running upgrades:
# it pulls the newest image and recreates the container. The image that was
# running is kept as ghcr.io/greberg/nibepi-gateway:previous; afterwards the
# installer waits for the container to report healthy and says how to roll
# back if it doesn't.
#
# Coming from the Node-RED installer (container "nibepi", data in
# ~/nibepi/{data,etc,tmp}): its config.json is copied to ~/nibepi/config, its
# .env and compose.yml are saved in ~/nibepi/nodered-backup, and the container
# is stopped and removed. Its data folders and image are left alone; the
# installer prints how to go back.
#
# Settings (environment variables):
#   NIBEPI_ROOT    where the gateway's files live      default ~/nibepi
#   NIBEPI_TAG     image tag: latest, a build date (20261010), sha-<short>
#                  or previous                          default latest
#   NIBEPI_SERIAL  RS485 serial device on the host, or "none" for a NibeGW
#                  gateway; it is /dev/ttyAMA0 inside the container
#                                                       default /dev/serial0 if present, else none
#   REPLACE=1      remove a "nibepi" or "nibepi-gateway" container started
#                  some other way (not by this installer in NIBEPI_ROOT)
# Gateway settings, written to .env when given (required on the first run:
# NIBEPI_MQTT_HOST); a re-run updates only the ones given:
#   NIBEPI_MQTT_HOST NIBEPI_MQTT_PORT NIBEPI_MQTT_USER NIBEPI_MQTT_PASS
#   NIBEPI_MQTT_TOPIC NIBEPI_CONNECTION (serial|nibegw) NIBEPI_NIBEGW_HOST
#   NIBEPI_NIBEGW_PORT NIBEPI_RAW_SET (all|none|list) NIBEPI_LOG_LEVEL
#
# Everything runs from main(), called on the last line, so a download cut off
# halfway through (curl | bash) is a syntax error that runs nothing rather
# than half an install.
set -euo pipefail

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

INSTALL_URL=https://raw.githubusercontent.com/greberg/nibepi-docker/improvements/pi/install.sh
NODERED_INSTALL_URL=https://raw.githubusercontent.com/greberg/nibepi-docker/nodered-final/pi/install.sh
IMAGE_REPO=ghcr.io/greberg/nibepi-gateway
PREVIOUS_IMAGE="$IMAGE_REPO:previous"
NAME=nibepi-gateway
OLD_NAME=nibepi   # the Node-RED installer's container
GATEWAY_KEYS=(NIBEPI_MQTT_HOST NIBEPI_MQTT_PORT NIBEPI_MQTT_USER NIBEPI_MQTT_PASS
  NIBEPI_MQTT_TOPIC NIBEPI_CONNECTION NIBEPI_NIBEGW_HOST NIBEPI_NIBEGW_PORT
  NIBEPI_RAW_SET NIBEPI_LOG_LEVEL)

container_state() {  # running/exited + health: healthy, unhealthy, starting or none
  docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null \
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
  if docker image inspect "$PREVIOUS_IMAGE" >/dev/null 2>&1 && [ "$NIBEPI_TAG" != previous ]; then
    echo "  To go back to the gateway image that ran before this upgrade:"
    echo "    curl -fsSL $INSTALL_URL | NIBEPI_ROOT=$NIBEPI_ROOT NIBEPI_TAG=previous bash"
  else
    echo "  To run a specific dated build instead (see the package's tags on GitHub):"
    echo "    curl -fsSL $INSTALL_URL | NIBEPI_ROOT=$NIBEPI_ROOT NIBEPI_TAG=YYYYMMDD bash"
  fi
  echo "  Re-running the installer without NIBEPI_TAG goes back to :latest."
  echo "  If the pump, the RS485 wiring or the broker is the problem rather than the"
  echo "  image, a rollback won't help - check: cd $NIBEPI_ROOT && docker compose logs --tail 100"
}

# How to get the Node-RED setup back, after a migration in this or an
# earlier run. Its data folders were never touched.
nodered_help() {
  local backup
  backup="$(ls -d "$NIBEPI_ROOT"/nodered-backup* 2>/dev/null | tail -n 1 || true)"
  [ -n "$backup" ] || [ -n "${old_image:-}" ] || return 0
  echo "  To go back to Node-RED (the last Node-RED build stays on GHCR as"
  echo "  ghcr.io/greberg/nibepi-nodered:latest; its data folders are untouched):"
  echo "    cd $NIBEPI_ROOT && docker compose down      # stops the gateway"
  if [ -n "$backup" ]; then
    echo "    cp -p $backup/.env $backup/compose.yml $NIBEPI_ROOT/"
    echo "    docker compose up -d"
    echo "  or, after the same down + cp (the restored .env keeps the Node-RED"
    echo "  credential secret), re-run the last Node-RED installer:"
    echo "    curl -fsSL $NODERED_INSTALL_URL | NIBEPI_ROOT=$NIBEPI_ROOT bash"
  else
    echo "  then start $old_image again the way it was started before"
    echo "  (${old_project:-docker run}; compose files there are unchanged)."
  fi
}

as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

# .env values are written single-quoted, which compose reads literally.
env_set() {  # KEY VALUE
  case "$2" in *"'"*|*$'\n'*) die "$1 can't contain a single quote or a newline (it goes into $env_file)." ;; esac
  local tmp="$env_file.tmp"
  ( umask 077
    { grep -v "^$1=" "$env_file" 2>/dev/null || true; printf "%s='%s'\n" "$1" "$2"; } > "$tmp" )
  chmod 600 "$tmp"; mv "$tmp" "$env_file"
}
env_get() {  # KEY -> value without surrounding quotes, empty if unset
  [ -f "$env_file" ] || return 0
  sed -n "s/^$1=//p" "$env_file" | tail -n 1 | sed -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/'
}

main() {
NIBEPI_ROOT="${NIBEPI_ROOT:-$HOME/nibepi}"
NIBEPI_TAG="${NIBEPI_TAG:-latest}"
env_file="$NIBEPI_ROOT/.env"
config_dir="$NIBEPI_ROOT/config"
# /dev/serial0 is the Pi's stable alias for the GPIO UART. /dev/ttyAMA0 is
# not: on a Pi 3/4 without dtoverlay=disable-bt it is the Bluetooth UART.
serial_guessed=false
if [ -z "${NIBEPI_SERIAL:-}" ]; then
  serial_guessed=true
  if [ -e /dev/serial0 ]; then NIBEPI_SERIAL=/dev/serial0; else NIBEPI_SERIAL=none; fi
fi

# --- prerequisites -------------------------------------------------------------
command -v docker >/dev/null || die "Docker is not installed. Install it with:
  curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker \$USER
then log out and in again, and re-run this installer."
docker compose version >/dev/null 2>&1 || die "The docker compose plugin is missing (sudo apt install docker-compose-plugin)."
docker info >/dev/null 2>&1 || die "Can't talk to Docker. Is your user in the docker group? (sudo usermod -aG docker \$USER, then log in again)"
case "$(uname -m)" in
  aarch64|x86_64) ;;
  *) die "The prebuilt image is for 64-bit systems (arm64/amd64); this is $(uname -m). Use a 64-bit Raspberry Pi OS, or build locally." ;;
esac

# --- what is already there (nothing is changed until all checks pass) ----------
# A gateway container from some other setup.
replace_gateway=false
gw_project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$NAME" 2>/dev/null || true)"
if docker inspect "$NAME" >/dev/null 2>&1 && [ "$gw_project" != "$NIBEPI_ROOT" ]; then
  [ "${REPLACE:-}" = "1" ] || die "A container named $NAME already exists (from ${gw_project:-docker run}).
Re-run with REPLACE=1 to replace it (its config folder is not touched),
and point NIBEPI_ROOT at its folder if that isn't $NIBEPI_ROOT."
  replace_gateway=true
fi

# The Node-RED container. Where its /etc/nibepi is mounted is where its
# config.json is; the old installer used $NIBEPI_ROOT/etc/nibepi.
old_present=false; old_project=""; old_image=""; old_conf=""
if docker inspect "$OLD_NAME" >/dev/null 2>&1; then
  old_present=true
  old_project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$OLD_NAME" 2>/dev/null || true)"
  old_image="$(docker inspect -f '{{.Config.Image}}' "$OLD_NAME")"
  old_conf="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/nibepi"}}{{.Source}}{{end}}{{end}}' "$OLD_NAME")"
  if [ "$old_project" != "$NIBEPI_ROOT" ] && [ "${REPLACE:-}" != "1" ]; then
    die "A Node-RED container named $OLD_NAME exists that this installer didn't start in
$NIBEPI_ROOT (it is from ${old_project:-docker run}, image $old_image).
Re-run with REPLACE=1 to stop and remove it and take over its config.json
(${old_conf:-no /etc/nibepi mount}); its data folders are not touched."
  fi
  [ "$old_project" = "$NIBEPI_ROOT" ] && old_project=""   # the backup below covers it
fi
[ -n "$old_conf" ] || old_conf="$NIBEPI_ROOT/etc/nibepi"
[ -f "$old_conf/config.json" ] || old_conf=""

# Which .env: the gateway's (keep it), the Node-RED installer's (back it up
# and start a new one), or none.
gateway_env=false; nodered_env=false
if [ -f "$env_file" ]; then
  if grep -q '^NIBEPI_MQTT_HOST=.' "$env_file"; then gateway_env=true
  elif grep -q '^NODE_RED_CREDENTIAL_SECRET=' "$env_file"; then nodered_env=true
  fi
fi
if ! $gateway_env && [ -z "${NIBEPI_MQTT_HOST:-}" ]; then
  hint=""
  if [ -n "$old_conf" ] && command -v python3 >/dev/null; then
    old_mqtt="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])).get("mqtt") or {}; print("%s:%s" % (m.get("host",""), m.get("port","")))' \
      "$old_conf/config.json" 2>/dev/null || true)"
    case "$old_mqtt" in ""|:*) ;; *) hint="
The Node-RED config.json used the broker $old_mqtt; if Home Assistant's
Mosquitto is that one, use its address (127.0.0.1 won't reach it from here)." ;; esac
  fi
  die "The gateway needs an MQTT broker (usually the Mosquitto add-on on the Home
Assistant machine) and there is no $env_file with one yet. Run:

  curl -fsSL $INSTALL_URL \\
    | NIBEPI_MQTT_HOST=<broker address> NIBEPI_MQTT_USER=<user> NIBEPI_MQTT_PASS=<password> bash

(NIBEPI_MQTT_PORT defaults to 1883.) The settings are saved in $env_file
(mode 600) and kept on later runs.$hint"
fi

# Serial port: check before anything is stopped.
uart_help="For the RS485 HAT, add to /boot/firmware/config.txt (this installer doesn't edit it):
      enable_uart=1
      dtoverlay=disable-bt    # Pi 3/4: puts the full PL011 UART on the GPIO pins
  then reboot (and on a Pi 3/4: sudo systemctl disable hciuart), and re-run this installer.
  raspi-config -> Interface -> Serial (login shell: no, hardware: yes) sets enable_uart."
if [ "$NIBEPI_SERIAL" != "none" ]; then
  [ -e "$NIBEPI_SERIAL" ] || die "$NIBEPI_SERIAL does not exist. $uart_help
  Or set NIBEPI_SERIAL=none for a NibeGW gateway."
  if [ "$(readlink -f "$NIBEPI_SERIAL")" = /dev/ttyS0 ]; then
    warn "$NIBEPI_SERIAL is the mini UART (ttyS0), whose baud rate drifts with the CPU clock. $uart_help"
  fi
elif $serial_guessed; then
  warn "/dev/serial0 is missing, so no serial port is passed through (fine for a NibeGW gateway). $uart_help"
fi
if [ "$NIBEPI_SERIAL" = none ] && [ -z "${NIBEPI_CONNECTION:-$(env_get NIBEPI_CONNECTION)}" ] \
   && [ ! -f "$config_dir/config.json" ] && [ -z "$old_conf" ]; then
  warn "No serial port and no existing config: for a NibeGW gateway also set
  NIBEPI_CONNECTION=nibegw NIBEPI_NIBEGW_HOST=<its address>"
fi

if [ "$NIBEPI_TAG" = previous ]; then
  docker image inspect "$PREVIOUS_IMAGE" >/dev/null 2>&1 \
    || die "There is no $PREVIOUS_IMAGE on this machine to roll back to. Pick a dated build with NIBEPI_TAG=YYYYMMDD."
fi

# --- keep the running gateway image as :previous, for a rollback ---------------
# Only a known-good one (healthy, or from before the healthcheck existed):
# re-running after a bad upgrade must not overwrite the good :previous with
# the bad image. Without a :previous yet, any running image beats none.
if [ "$NIBEPI_TAG" = previous ]; then
  say "Rolling back to $PREVIOUS_IMAGE"
elif running_image="$(docker inspect -f '{{.Image}}' "$NAME" 2>/dev/null)"; then
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

# --- config ---------------------------------------------------------------------
say "Gateway files in $NIBEPI_ROOT"
mkdir -p "$config_dir"
if [ -f "$config_dir/config.json" ]; then
  echo "    $config_dir/config.json already present, left as it is"
elif [ -n "$old_conf" ]; then
  say "Copying the Node-RED setup's config.json from $old_conf (the original stays)"
  cp -p "$old_conf/config.json" "$config_dir/config.json" 2>/dev/null \
    || as_root cp -p "$old_conf/config.json" "$config_dir/config.json"
else
  echo "    no config.json yet - the gateway starts from its defaults and the settings in .env"
fi
# The container runs as node (uid 1000) and writes config.json atomically,
# so it needs the folder, not just the file.
as_root chown -R 1000:1000 "$config_dir" \
  || die "Couldn't hand $config_dir to uid 1000 (node in the container). Fix it with:
  sudo chown -R 1000:1000 $config_dir
and re-run this installer."

# --- the Node-RED installer's .env and compose.yml ---------------------------------
if $nodered_env || grep -qs '^    container_name: nibepi$' "$NIBEPI_ROOT/compose.yml"; then
  backup="$NIBEPI_ROOT/nodered-backup"
  [ -e "$backup" ] && backup="$backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  for f in .env compose.yml; do
    [ -f "$NIBEPI_ROOT/$f" ] && cp -p "$NIBEPI_ROOT/$f" "$backup/$f"
  done
  chmod 700 "$backup"
  say "Saved the Node-RED .env and compose.yml in $backup"
  if $nodered_env; then rm -f "$env_file"; fi
fi

# --- .env -----------------------------------------------------------------------------
( umask 077; touch "$env_file" ); chmod 600 "$env_file"
for key in "${GATEWAY_KEYS[@]}"; do
  if [ -n "${!key+x}" ]; then
    if $gateway_env && [ "$(env_get "$key")" != "${!key}" ]; then echo "    updating $key in $env_file"; fi
    env_set "$key" "${!key}"
  fi
done
$gateway_env && echo "    the other settings in $env_file are kept"
env_set NIBEPI_TAG "$NIBEPI_TAG"
if [ -n "${TZ:-}" ] || [ -z "$(env_get TZ)" ]; then
  env_set TZ "${TZ:-$(cat /etc/timezone 2>/dev/null || echo Europe/Stockholm)}"
fi

# --- compose file ------------------------------------------------------------------------
device_block=""
if [ "$NIBEPI_SERIAL" != "none" ]; then
  dialout_gid="$(getent group dialout | cut -d: -f3 || true)"
  device_block="    devices:
      - $NIBEPI_SERIAL:/dev/ttyAMA0
    group_add:
      - \"${dialout_gid:-20}\"   # the host's dialout, which owns the device"
else
  device_block="    ports:
      - \"9999:9999/udp\"   # NibeGW sends its frames here"
fi
say "Writing $NIBEPI_ROOT/compose.yml (serial: $NIBEPI_SERIAL)"
cat > "$NIBEPI_ROOT/compose.yml" <<YML
# Written by pi/install.sh - re-running the installer regenerates it.
# Kept in step with nibepi-docker's docker-compose.yml. Settings: .env
services:
  $NAME:
    image: $IMAGE_REPO:\${NIBEPI_TAG:-latest}
    container_name: $NAME
    restart: unless-stopped
    init: true
    env_file: .env
    environment:
      NIBEPI_SERIAL_PORT: /dev/ttyAMA0
$device_block
    volumes:
      - ./config:/etc/nibepi
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YML

# --- stop Node-RED, start the gateway -----------------------------------------------------
cd "$NIBEPI_ROOT"
if [ "$NIBEPI_TAG" != previous ]; then  # :previous only exists locally
  say "Pulling $IMAGE_REPO:$NIBEPI_TAG"
  docker compose pull --quiet
fi
# Only now, so a failed check or pull above leaves Node-RED running. Both
# can't have the serial port, and both would answer on the same MQTT topics.
if $old_present; then
  say "Stopping and removing the Node-RED container $OLD_NAME ($old_image)"
  trap 'printf "error: the gateway did not start, and Node-RED is stopped.\n" >&2; nodered_help' ERR
  docker stop -t 30 "$OLD_NAME" >/dev/null
  docker rm "$OLD_NAME" >/dev/null
  echo "    its image and data folders are kept"
fi
if $replace_gateway; then
  say "Removing the existing $NAME container (its config folder is kept)"
  docker rm -f "$NAME" >/dev/null
fi
say "Starting"
docker compose up -d --force-recreate
trap - ERR

# Dangling images only; :previous and the old Node-RED image are tagged and stay.
docker image prune -f >/dev/null 2>&1 || true

# --- health ---------------------------------------------------------------------------------
# No automatic rollback: "unhealthy" means no data from the pump, which is as
# likely the pump, the wiring or the UART config as the new image, and a
# silent rollback would hide that. Say what happened and how to go back.
say "Checking health"
health=starting
wait_healthy
broker="$(env_get NIBEPI_MQTT_HOST):$(env_get NIBEPI_MQTT_PORT)"; broker="${broker%:}"
case "$health" in
  healthy)
    say "The NibePi gateway is running and healthy, publishing to MQTT on $broker" ;;
  none)
    say "The NibePi gateway is running, publishing to MQTT on $broker"
    echo "    this image has no healthcheck, so its health isn't known" ;;
  starting)
    warn "The gateway is running but hasn't reported healthy yet - usually no data from the pump so far."
    echo "  Check again in a few minutes:  docker ps   (STATUS shows healthy/unhealthy)"
    echo "  If it turns unhealthy:"
    rollback_help
    nodered_help ;;
  *)
    printf 'error: the %s container is %s.\n' "$NAME" "$health" >&2
    docker inspect -f '{{if .State.Health}}{{range .State.Health.Log}}    {{.Output}}{{end}}{{end}}' "$NAME" 2>/dev/null | tail -n 3 || true
    docker compose logs --tail 20 "$NAME" || true
    rollback_help
    nodered_help
    exit 1 ;;
esac
if $old_present && [ "$health" != starting ]; then nodered_help; fi
echo "    logs:     cd $NIBEPI_ROOT && docker compose logs -f"
echo "    status:   docker ps --filter name=$NAME"
echo "    settings: $env_file (then: cd $NIBEPI_ROOT && docker compose up -d)"
echo "    upgrade:  re-run this installer"
}

main "$@"
