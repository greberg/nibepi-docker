# nibepi-docker

Container packaging for the NibePi gateway: a small service on a Raspberry Pi
that talks to a Nibe F-series heat pump over RS485 (or a NibeGW gateway) and
connects out to an MQTT broker. Control logic — price, indoor temperature,
weather, hot water — runs in the Home Assistant component
[nibepi-ha](https://github.com/greberg/nibepi-ha) on another machine and
writes registers through *leases* that the gateway falls back from by itself.

```
F1255 ──RS485── Pi: nibepi-gateway ──MQTT──> broker (HA's Mosquitto) <── HA: nibepi
```

The image runs `node gateway.js` from
[nibepi-backend](https://github.com/greberg/nibepi-backend). It publishes no
ports and needs nothing inbound (except UDP 9999 with a NibeGW gateway).

> **History.** Until October 2026 this repository built a Node-RED image
> (`ghcr.io/greberg/nibepi-nodered`) with dashboard and controllers. That
> version is preserved as the `nodered-final` tag in this and the other
> NibePi repositories, and its last images stay on GHCR. See
> [Going back to Node-RED](#going-back-to-node-red).

## Install on a Raspberry Pi

A 64-bit Raspberry Pi OS with Docker and the compose plugin
(`curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker $USER`,
then log in again). The first run needs the MQTT broker:

```sh
curl -fsSL https://raw.githubusercontent.com/greberg/nibepi-docker/improvements/pi/install.sh \
  | NIBEPI_MQTT_HOST=192.168.1.10 NIBEPI_MQTT_USER=nibepi NIBEPI_MQTT_PASS=secret bash
```

It pulls the prebuilt image (nothing is built on the Pi), passes the RS485
serial port through, writes `~/nibepi/.env` (mode 600) and
`~/nibepi/compose.yml`, starts the `nibepi-gateway` container and waits for it
to report healthy.

| file | holds |
|---|---|
| `~/nibepi/.env` | MQTT and other gateway settings, `NIBEPI_TAG`, `TZ`. Kept on re-runs. |
| `~/nibepi/compose.yml` | written by the installer on every run |
| `~/nibepi/config/` | `/etc/nibepi` in the container: `config.json` (+ `.bak`), lease baselines |

The serial port defaults to `/dev/serial0` (the stable alias for the GPIO
UART), mapped to `/dev/ttyAMA0` in the container. The RS485 HAT needs
`enable_uart=1` (and `dtoverlay=disable-bt` on a Pi 3/4) in
`/boot/firmware/config.txt`; the installer checks and warns but doesn't edit
it. For a NibeGW gateway instead:

```sh
curl -fsSL .../pi/install.sh | NIBEPI_SERIAL=none NIBEPI_CONNECTION=nibegw \
  NIBEPI_NIBEGW_HOST=192.168.1.20 NIBEPI_MQTT_HOST=192.168.1.10 bash
```

### Coming from the Node-RED installer

If the old installer's `nibepi` container is running, the installer migrates
it:

1. It checks everything first (Docker, serial port, MQTT settings) and stops
   with the Node-RED container still running if anything is missing.
2. It copies the Node-RED `config.json` (from the container's `/etc/nibepi`
   mount, normally `~/nibepi/etc/nibepi`) to `~/nibepi/config/`, unless a
   gateway config is already there. The original is not touched.
3. It saves the old `~/nibepi/.env` (with the Node-RED credential secret) and
   `compose.yml` in `~/nibepi/nodered-backup/`, and writes new ones.
4. It pulls the gateway image, then stops and removes the `nibepi` container
   and starts `nibepi-gateway`.

`~/nibepi/data`, `~/nibepi/etc` and `~/nibepi/tmp` and the old image are left
as they were. A `nibepi` container that the old installer didn't start in
`~/nibepi` is only replaced with `REPLACE=1`.

## Upgrade and rollback

Re-run the installer (without the MQTT variables; `.env` is kept). Variables
you do pass, such as `NIBEPI_MQTT_PASS`, update their line in `.env`.

Before pulling, the running image is tagged
`ghcr.io/greberg/nibepi-gateway:previous` (only if it was healthy, so a re-run
after a bad upgrade keeps the good one). If the new container doesn't turn
healthy, the installer shows the health output, the last log lines and the
command to go back:

```sh
curl -fsSL .../pi/install.sh | NIBEPI_TAG=previous bash      # the image before
curl -fsSL .../pi/install.sh | NIBEPI_TAG=20261010 bash      # a dated build
curl -fsSL .../pi/install.sh | NIBEPI_TAG=sha-1a2b3c4 bash   # a build of this repo's commit
```

Re-running without `NIBEPI_TAG` goes back to `:latest`. There is no automatic
rollback: unhealthy means no data from the pump, which is as likely wiring or
UART config as the image.

### Going back to Node-RED

After a migration, the installer prints this; the paths are the defaults:

```sh
cd ~/nibepi && docker compose down                     # stop the gateway
cp -p nodered-backup/.env nodered-backup/compose.yml .
docker compose up -d                                   # the old nibepi container
```

The restored `compose.yml` uses `ghcr.io/greberg/nibepi-nodered:latest`, the
last Node-RED build. Instead of `docker compose up -d` you can re-run the last
Node-RED installer, after restoring `.env` so it keeps the credential secret:

```sh
curl -fsSL https://raw.githubusercontent.com/greberg/nibepi-docker/nodered-final/pi/install.sh | bash
```

Don't run both: they share the serial port and the MQTT topics.

## Configuration

The gateway reads `/etc/nibepi/config.json` and these environment variables,
which the compose files take from `.env`:

| variable | meaning |
|---|---|
| `NIBEPI_MQTT_HOST`, `NIBEPI_MQTT_PORT` | broker, port default 1883 |
| `NIBEPI_MQTT_USER`, `NIBEPI_MQTT_PASS` | broker login |
| `NIBEPI_MQTT_TOPIC` | topic prefix, default `nibe/modbus/` |
| `NIBEPI_CONNECTION` | `serial` or `nibegw` |
| `NIBEPI_SERIAL_PORT` | set to `/dev/ttyAMA0` by the compose files |
| `NIBEPI_NIBEGW_HOST`, `NIBEPI_NIBEGW_PORT` | NibeGW gateway |
| `NIBEPI_RAW_SET` | what plain `<reg>/set` may write: `all`, `none` or a comma list of registers; `none` once the HA component is in use |
| `NIBEPI_LOG_LEVEL` | `error`, `warn`, `info` (default), `debug` or `trace` (every raw bus frame); logs go to stdout |
| `NIBEPI_CONFIG_DIR` | `/etc/nibepi` in the image |
| `NIBEPI_HEALTH_FILE` | `/dev/shm/nibepi-health.json` in the image |

Values in `.env` are best single-quoted (`NIBEPI_MQTT_PASS='p&ss'`); compose
reads them literally. After editing `.env`: `cd ~/nibepi && docker compose up -d`.

The container runs as `node` (uid 1000), so the config folder must be
writable by uid 1000 (`sudo chown -R 1000:1000 config`; the installer does
this). For the serial port it is in `dialout` (gid 20 in the image); the
device keeps the host's group, so the compose files add the host's dialout
gid with `group_add` (`getent group dialout | cut -d: -f3`, 20 on Raspberry
Pi OS).

Health: the gateway rewrites `/dev/shm/nibepi-health.json` every minute.
The container is unhealthy when that file is missing or older than 3
minutes, or the pump hasn't answered for 10 minutes (`docker ps` shows it).

## Connecting to Home Assistant's Mosquitto

1. In Home Assistant, install the **Mosquitto broker** add-on and start it.
2. Create a Home Assistant user for the gateway (Settings → People → Users,
   e.g. `nibepi`); the add-on accepts HA users as MQTT logins.
3. Make sure the **MQTT** integration is set up in HA (it is offered once the
   add-on runs).
4. Install the gateway with `NIBEPI_MQTT_HOST=<HA's address>`,
   `NIBEPI_MQTT_USER=nibepi`, `NIBEPI_MQTT_PASS=<its password>`.
5. Check: in HA, Settings → Devices & services → MQTT → Configure → Listen to
   topic `nibe/modbus/#`. `nibe/modbus/status` should be `online`.
6. Install the [nibepi-ha](https://github.com/greberg/nibepi-ha) component
   (HACS custom repository) with the same topic prefix.

## Building

The image is built from this repository plus nibepi-backend, checked out as
`nibepi/` next to the Dockerfile (gitignored):

```sh
git clone https://github.com/greberg/nibepi-docker.git
cd nibepi-docker
git clone -b improvements https://github.com/greberg/nibepi-backend.git nibepi
docker build -t nibepi-gateway .
```

Or point a named build context at a checkout elsewhere:

```sh
docker build --build-context backend=../nibepi-backend -t nibepi-gateway .
```

The included `docker-compose.yml` runs the published image with settings from
a `.env` next to it; create `config/` owned by uid 1000 first
(`mkdir config && sudo chown 1000:1000 config`).

## Prebuilt image

`.github/workflows/image.yml` builds for amd64 and arm64 and publishes
`ghcr.io/<owner>/nibepi-gateway` on every push to `improvements`, nightly
(picking up backend changes and base image updates) and on demand, tagged
`latest`, `YYYYMMDD` and `sha-<short>`. A new GHCR package is private; make it
public under the package's settings, or `docker login ghcr.io` on the Pi.
