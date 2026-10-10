#!/usr/bin/env bash
# One-command NibePi gateway install/upgrade on a Raspberry Pi (64-bit OS),
# using the prebuilt image from GHCR - nothing is built on the Pi.
#
#   curl -fsSL https://raw.githubusercontent.com/greberg/nibepi-docker/improvements/pi/install.sh \
#     | NIBEPI_MQTT_HOST=192.168.1.10 NIBEPI_MQTT_USER=nibepi NIBEPI_MQTT_PASS=secret bash
#
# It sets up the same thing as doing it by hand: this repo's
# docker-compose.yml as $NIBEPI_ROOT/docker-compose.yml, with all settings in
# its environment: section, and config/ next to it. Then docker compose pull
# and up -d, and it waits for the container to report healthy.
#
# The first run fills the MQTT settings below into the new compose file
# (mode 600). Without NIBEPI_MQTT_HOST it only writes the file and stops, so
# you can fill it in and re-run. An existing docker-compose.yml is never
# changed: edit it yourself. Each run saves the current template as
# docker-compose.yml.example and shows what changed in it since the last run.
#
# Re-running upgrades: it pulls the image your compose file names and
# recreates the container. The image that was running is kept as
# ghcr.io/greberg/nibepi-gateway:previous (only if it was healthy); to roll
# back, set image: to that tag in the compose file and docker compose up -d.
#
# Coming from the Node-RED installer (container "nibepi", data in
# ~/nibepi/{data,etc,tmp}): its config.json is copied to ~/nibepi/config, its
# .env and compose.yml are moved to ~/nibepi/nodered-backup, and the
# container is stopped and removed. Its data folders and image are left
# alone; the installer prints how to go back. An install by the previous
# version of this installer (.env + generated compose.yml) is converted: its
# .env settings go into docker-compose.yml, the old files to
# ~/nibepi/env-backup.
#
# Settings (environment variables):
#   NIBEPI_ROOT    where the gateway's files live      default ~/nibepi
#   NIBEPI_SERIAL  RS485 serial device on the host for a new compose file,
#                  or "none" for NibeGW (then edit the file and re-run)
#                                                       default /dev/serial0
#   REPLACE=1      remove a "nibepi" or "nibepi-gateway" container started
#                  some other way (not in NIBEPI_ROOT)
# Gateway settings, only used when a new docker-compose.yml is written:
#   NIBEPI_MQTT_HOST NIBEPI_MQTT_PORT NIBEPI_MQTT_USER NIBEPI_MQTT_PASS
#   NIBEPI_MQTT_TOPIC NIBEPI_CONNECTION (serial|nibegw) NIBEPI_NIBEGW_HOST
#   NIBEPI_NIBEGW_PORT NIBEPI_RAW_SET (all|none|list) NIBEPI_LOG_LEVEL TZ
#
# Everything runs from main(), called on the last line, so a download cut off
# halfway through (curl | bash) is a syntax error that runs nothing rather
# than half an install.
set -euo pipefail

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

RAW_URL=https://raw.githubusercontent.com/greberg/nibepi-docker/improvements
INSTALL_URL=$RAW_URL/pi/install.sh
TEMPLATE_URL=$RAW_URL/docker-compose.yml
NODERED_INSTALL_URL=https://raw.githubusercontent.com/greberg/nibepi-docker/nodered-final/pi/install.sh
NAME=nibepi-gateway
OLD_NAME=nibepi   # the Node-RED installer's container
SETTING_KEYS=(NIBEPI_MQTT_HOST NIBEPI_MQTT_PORT NIBEPI_MQTT_USER NIBEPI_MQTT_PASS
  NIBEPI_MQTT_TOPIC NIBEPI_CONNECTION NIBEPI_NIBEGW_HOST NIBEPI_NIBEGW_PORT
  NIBEPI_RAW_SET NIBEPI_LOG_LEVEL TZ)

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
  echo "  To go back, set the image in $compose_file to"
  if docker image inspect "$previous_image" >/dev/null 2>&1 && [ "$image" != "$previous_image" ]; then
    echo "    image: $previous_image     # the image that ran before"
    echo "  or a dated build ($image_repo:YYYYMMDD, see the package's tags on GitHub),"
  else
    echo "    image: $image_repo:YYYYMMDD   # a dated build, see the package's tags on GitHub"
  fi
  echo "  then: cd $NIBEPI_ROOT && docker compose pull && docker compose up -d"
  echo "  (no pull for :previous, it only exists on this machine)."
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
    echo "    mv docker-compose.yml docker-compose.yml.gateway"
    echo "    cp -p $backup/.env $backup/compose.yml $NIBEPI_ROOT/"
    echo "    docker compose up -d"
    echo "  or, after the same down + mv + cp (the restored .env keeps the Node-RED"
    echo "  credential secret), re-run the last Node-RED installer:"
    echo "    curl -fsSL $NODERED_INSTALL_URL | NIBEPI_ROOT=$NIBEPI_ROOT bash"
  else
    echo "  then start $old_image again the way it was started before"
    echo "  (${old_project:-docker run}; compose files there are unchanged)."
  fi
}

as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

# A value from a compose file's environment: (KEY: 'value'), unquoted.
compose_get() {  # FILE KEY
  sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" "$1" | sed -e 's/[[:space:]]*#.*//' \
    -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/' -e "s/''/'/g" | tail -n 1
}
# Sets "      KEY: <old value>" to a single-quoted value, keeping the comment
# after it. In compose ' is written '' inside the quotes, and $ as $$.
compose_set() {  # FILE KEY VALUE
  case "$3" in *$'\n'*) die "$2 can't contain a newline." ;; esac
  KEY="$2" VAL="$3" awk -v q="'" '
    BEGIN { v = ENVIRON["VAL"]; gsub(q, q q, v); gsub(/[$]/, "$$", v) }
    !done && match($0, "^[ ]+" ENVIRON["KEY"] ":[ ]*[^ ]*") {
      print substr($0, 1, index($0, ":")) " " q v q substr($0, RLENGTH + 1); done = 1; next }
    { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
# The old installer's .env values were single-quoted.
env_get() {  # FILE KEY -> value without surrounding quotes, empty if unset
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1 | sed -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/'
}

main() {
NIBEPI_ROOT="${NIBEPI_ROOT:-$HOME/nibepi}"
compose_file="$NIBEPI_ROOT/docker-compose.yml"
config_dir="$NIBEPI_ROOT/config"
env_file="$NIBEPI_ROOT/.env"           # the old installers'
old_compose="$NIBEPI_ROOT/compose.yml" # the old installers'

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
mkdir -p "$NIBEPI_ROOT"
template="$(mktemp)"; new_compose="$compose_file.new"
trap 'rm -f "$template" "$new_compose"' EXIT
curl -fsSL "$TEMPLATE_URL" -o "$template" || die "Couldn't download $TEMPLATE_URL"
grep -q "^  $NAME:" "$template" || die "$TEMPLATE_URL doesn't look like the gateway's compose file."
for f in compose.yaml docker-compose.yaml; do
  [ ! -f "$NIBEPI_ROOT/$f" ] || die "$NIBEPI_ROOT/$f would take precedence over docker-compose.yml; move it away first."
done

# --- what is already there (nothing is changed until all checks pass) ----------
# The previous version of this installer: generated compose.yml + .env.
legacy=false
if grep -qs '^# Written by pi/install.sh' "$old_compose" && grep -qs '^NIBEPI_MQTT_HOST=.' "$env_file"; then
  legacy=true
fi
# The Node-RED installer's .env / compose.yml.
nodered_files=false
if grep -qs '^NODE_RED_CREDENTIAL_SECRET=' "$env_file" || grep -qs '^    container_name: nibepi$' "$old_compose"; then
  nodered_files=true
fi
if [ -f "$old_compose" ] && ! $legacy && ! $nodered_files; then
  die "$old_compose exists and isn't from an installer. docker compose would use it
instead of docker-compose.yml: move it away (or merge it into docker-compose.yml) and re-run."
fi

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

# --- the compose file -----------------------------------------------------------
# An existing one is the user's: only checked. Otherwise the template, filled
# in from the environment, or from the previous installer's .env.
if [ -f "$compose_file" ]; then
  say "Using your $compose_file (not changed)"
  active="$compose_file"; writing=false
else
  # It gets the MQTT password: private from the start (the edits below
  # replace the file).
  old_umask="$(umask)"; umask 077
  cp "$template" "$new_compose"
  for key in "${SETTING_KEYS[@]}"; do
    if [ -n "${!key+x}" ]; then compose_set "$new_compose" "$key" "${!key}"
    elif $legacy && [ -n "$(env_get "$env_file" "$key")" ]; then
      compose_set "$new_compose" "$key" "$(env_get "$env_file" "$key")"
    fi
  done
  [ -n "${TZ:-}" ] || $legacy || [ ! -f /etc/timezone ] || compose_set "$new_compose" TZ "$(cat /etc/timezone)"
  tag="$(env_get "$env_file" NIBEPI_TAG)"
  if $legacy && [ -n "$tag" ] && [ "$tag" != latest ]; then
    sed -i "s|^\(    image: [^:]*\):latest|\1:$tag|" "$new_compose"
  fi
  # /dev/serial0 is the Pi's stable alias for the GPIO UART. /dev/ttyAMA0 is
  # not: on a Pi 3/4 without dtoverlay=disable-bt it is the Bluetooth UART.
  serial="${NIBEPI_SERIAL:-/dev/serial0}"
  if $legacy && [ -z "${NIBEPI_SERIAL:-}" ]; then
    serial="$(sed -n 's|^ *- \(.*\):/dev/ttyAMA0$|\1|p' "$old_compose" | head -n 1)"
    [ -n "$serial" ] || serial=none   # it was set up for NibeGW
  fi
  [ "$serial" = none ] || sed -i "s|^      - /dev/serial0:/dev/ttyAMA0|      - $serial:/dev/ttyAMA0|" "$new_compose"
  dialout_gid="$(getent group dialout | cut -d: -f3 || true)"
  if [ -n "$dialout_gid" ] && [ "$dialout_gid" != 20 ]; then
    sed -i "s|^      - dialout\$|      - \"$dialout_gid\"   # the host's dialout|" "$new_compose"
  fi
  umask "$old_umask"; chmod 600 "$new_compose"
  active="$new_compose"; writing=true
fi

# Stop here when the file still needs editing; nothing else has changed.
host="$(compose_get "$active" NIBEPI_MQTT_HOST)"
if [ -z "$host" ] || { $writing && [ "$serial" = none ]; }; then
  if $writing; then
    mv "$new_compose" "$compose_file"
    cp "$template" "$compose_file.example"
    say "Wrote $compose_file"
  fi
  if [ -z "$host" ]; then
    hint=""
    if [ -n "$old_conf" ] && command -v python3 >/dev/null; then
      old_mqtt="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])).get("mqtt") or {}; print("%s:%s" % (m.get("host",""), m.get("port","")))' \
        "$old_conf/config.json" 2>/dev/null || true)"
      case "$old_mqtt" in ""|:*) ;; *) hint="
The Node-RED config.json used the broker $old_mqtt; if Home Assistant's
Mosquitto is that one, use its address (127.0.0.1 won't reach it from here)." ;; esac
    fi
    echo "Fill in the MQTT settings (NIBEPI_MQTT_HOST, _USER, _PASS: usually the Mosquitto
add-on on the Home Assistant machine) in $compose_file, then re-run:
  curl -fsSL $INSTALL_URL | bash$hint"
  else
    echo "For NibeGW, edit $compose_file: set NIBEPI_CONNECTION: 'nibegw' and
NIBEPI_NIBEGW_HOST, remove devices: and group_add:, uncomment ports:. Then re-run:
  curl -fsSL $INSTALL_URL | bash"
  fi
  [ "$NIBEPI_ROOT" = "$HOME/nibepi" ] || echo "(with NIBEPI_ROOT=$NIBEPI_ROOT)"
  if $writing; then exit 0; else exit 1; fi
fi

# Serial port from the compose file: check before anything is stopped.
uart_help="For the RS485 HAT, add to /boot/firmware/config.txt (this installer doesn't edit it):
      enable_uart=1
      dtoverlay=disable-bt    # Pi 3/4: puts the full PL011 UART on the GPIO pins
  then reboot (and on a Pi 3/4: sudo systemctl disable hciuart), and re-run this installer.
  raspi-config -> Interface -> Serial (login shell: no, hardware: yes) sets enable_uart."
device="$(sed -n 's|^ *- ["'"'"']\{0,1\}\([^#"'"'"']*\):/dev/ttyAMA0["'"'"']\{0,1\}[[:space:]]*\(#.*\)\{0,1\}$|\1|p' "$active" | head -n 1)"
if [ -n "$device" ]; then
  [ -e "$device" ] || die "$device (devices: in $active) does not exist. $uart_help"
  if [ "$(readlink -f "$device")" = /dev/ttyS0 ]; then
    warn "$device is the mini UART (ttyS0), whose baud rate drifts with the CPU clock. $uart_help"
  fi
fi

image="$(docker compose -f "$active" --project-directory "$NIBEPI_ROOT" config --images | head -n 1)"
image_repo="$image"; case "${image##*/}" in *:*) image_repo="${image%:*}" ;; esac
previous_image="$image_repo:previous"
if [ "$image" = "$previous_image" ]; then
  docker image inspect "$previous_image" >/dev/null 2>&1 \
    || die "There is no $previous_image on this machine to roll back to. Set a dated build (:YYYYMMDD) in $compose_file."
fi

# Template changes since the last run, for the user to merge by hand.
if ! $writing; then
  if [ -f "$compose_file.example" ] && ! cmp -s "$template" "$compose_file.example"; then
    say "The upstream docker-compose.yml has changed since the last run:"
    diff -u -L "last run" -L "now" "$compose_file.example" "$template" | sed 's/^/    /' || true
    echo "    Merge what you want into $compose_file (the new template is $compose_file.example)."
  elif [ ! -f "$compose_file.example" ] && ! diff -q <(grep -v '^ *#' "$template") <(grep -v '^ *#' "$compose_file") >/dev/null; then
    echo "    the current template is in $compose_file.example (compare: diff $compose_file.example $compose_file)"
  fi
  cp "$template" "$compose_file.example"
fi

# --- keep the running gateway image as :previous, for a rollback ---------------
# Only a known-good one (healthy, or from before the healthcheck existed):
# re-running after a bad upgrade must not overwrite the good :previous with
# the bad image. Without a :previous yet, any running image beats none.
if [ "$image" = "$previous_image" ]; then
  say "Rolling back to $previous_image"
elif running_image="$(docker inspect -f '{{.Image}}' "$NAME" 2>/dev/null)"; then
  say "Keeping the current image for a rollback"
  read -r state status <<<"$(container_state)"
  if [ "$state $status" = "running healthy" ] || [ "$state $status" = "running none" ] \
     || ! docker image inspect "$previous_image" >/dev/null 2>&1; then
    docker tag "$running_image" "$previous_image"
    echo "    current image kept as $previous_image"
  else
    echo "    the running container is $state/$status - keeping the existing $previous_image"
  fi
fi

# --- pull first, so a failed pull leaves everything running --------------------
if [ "$image" != "$previous_image" ]; then  # :previous only exists locally
  say "Pulling $image"
  if ! docker compose -f "$active" --project-directory "$NIBEPI_ROOT" pull --quiet; then
    docker image inspect "$image" >/dev/null 2>&1 || die "Couldn't pull $image."
    warn "Couldn't pull $image; using the copy on this machine."
  fi
fi

# --- config ---------------------------------------------------------------------
mkdir -p "$config_dir"
if [ -f "$config_dir/config.json" ]; then
  echo "    $config_dir/config.json already present, left as it is"
elif [ -n "$old_conf" ]; then
  say "Copying the Node-RED setup's config.json from $old_conf (the original stays)"
  cp -p "$old_conf/config.json" "$config_dir/config.json" 2>/dev/null \
    || as_root cp -p "$old_conf/config.json" "$config_dir/config.json"
else
  echo "    no config.json yet - the gateway starts from its defaults and the compose settings"
fi
# The container runs as node (uid 1000) and writes config.json atomically,
# so it needs the folder, not just the file.
as_root chown -R 1000:1000 "$config_dir" \
  || die "Couldn't hand $config_dir to uid 1000 (node in the container). Fix it with:
  sudo chown -R 1000:1000 $config_dir
and re-run this installer."

# --- move the old installers' .env and compose.yml away ---------------------------
# compose.yml would take precedence over docker-compose.yml.
if $nodered_files || $legacy; then
  if $nodered_files; then backup="$NIBEPI_ROOT/nodered-backup"; else backup="$NIBEPI_ROOT/env-backup"; fi
  [ -e "$backup" ] && backup="$backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"; chmod 700 "$backup"
  for f in .env compose.yml; do
    [ -f "$NIBEPI_ROOT/$f" ] && mv "$NIBEPI_ROOT/$f" "$backup/$f"
  done
  say "Moved the old .env and compose.yml to $backup"
fi
if $writing; then
  mv "$new_compose" "$compose_file"
  cp "$template" "$compose_file.example"
  say "Wrote $compose_file (mode 600: it holds the MQTT password)"
fi

# --- stop Node-RED, start the gateway -----------------------------------------------------
cd "$NIBEPI_ROOT"
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
docker compose up -d
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
broker="$host:$(compose_get "$compose_file" NIBEPI_MQTT_PORT)"; broker="${broker%:}"
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
echo "    settings: $compose_file (then: cd $NIBEPI_ROOT && docker compose up -d)"
echo "    upgrade:  cd $NIBEPI_ROOT && docker compose pull && docker compose up -d"
echo "              (or re-run this installer: it also keeps :previous and checks health)"
}

main "$@"
