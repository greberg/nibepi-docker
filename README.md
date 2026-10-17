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
[nibepi-backend](https://github.com/greberg/nibepi-backend). The only
inbound port is TCP 8080, a read-only status page for the LAN (plus UDP 9999
with a NibeGW gateway).

> **History.** Until October 2026 this repository built a Node-RED image
> (`ghcr.io/greberg/nibepi-nodered`) with dashboard and controllers. That
> version is preserved as the `nodered-final` tag in this and the other
> NibePi repositories, and its last images stay on GHCR. See
> [Going back to Node-RED](#going-back-to-node-red).

## Install on a Raspberry Pi

A 64-bit Raspberry Pi OS with Docker and the compose plugin
(`curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker $USER`,
then log in again), and an MQTT broker (usually the Mosquitto add-on on the
Home Assistant machine, see [below](#connecting-to-home-assistants-mosquitto)).

[`docker-compose.yml`](docker-compose.yml) is the whole configuration:
the image, the serial port and all gateway settings in its `environment:`
section. Copy it to the Pi, fill in the MQTT settings, pull and start:

```sh
mkdir -p ~/nibepi/config && cd ~/nibepi
sudo chown 1000:1000 config          # the gateway runs as uid 1000
curl -fsSLO https://raw.githubusercontent.com/greberg/nibepi-docker/improvements/docker-compose.yml
chmod 600 docker-compose.yml         # it will hold the MQTT password
nano docker-compose.yml              # NIBEPI_MQTT_HOST, _USER, _PASS
docker compose pull
docker compose up -d
docker ps                            # STATUS turns healthy within ~5 minutes
```

Then open the status page at `http://<pi>:8080/` (see [Status page](#status-page)).

| file | holds |
|---|---|
| `~/nibepi/docker-compose.yml` | image tag, serial port, MQTT and other gateway settings. Yours: keep it on the Pi, don't commit a filled-in copy. |
| `~/nibepi/config/` | `/etc/nibepi` in the container: `config.json` (+ `.bak`), lease baselines |

The serial port defaults to `/dev/serial0` (the stable alias for the GPIO
UART), mapped to `/dev/ttyAMA0` in the container. The RS485 HAT needs
`enable_uart=1` (and `dtoverlay=disable-bt` on a Pi 3/4) in
`/boot/firmware/config.txt`. For a NibeGW gateway instead: set
`NIBEPI_CONNECTION: 'nibegw'` and `NIBEPI_NIBEGW_HOST`, remove `devices:` and
`group_add:`, and uncomment the `9999/udp` line under `ports:`.

### The installer

`pi/install.sh` does the same in one command, plus the checks (Docker, the
UART), the migration from Node-RED and a health wait:

```sh
curl -fsSL https://raw.githubusercontent.com/greberg/nibepi-docker/improvements/pi/install.sh \
  | NIBEPI_MQTT_HOST=192.168.1.10 NIBEPI_MQTT_USER=nibepi NIBEPI_MQTT_PASS=secret bash
```

It writes `~/nibepi/docker-compose.yml` (mode 600) from this repo's file
with the MQTT settings filled in, sets up `~/nibepi/config`, pulls, starts
`nibepi-gateway` and waits for it to report healthy. Without
`NIBEPI_MQTT_HOST` it only writes the compose file and stops, so you can fill
it in and re-run. An existing `docker-compose.yml` is never changed: the
installer saves the current template as `docker-compose.yml.example` and
shows what changed in it since the last run, for you to merge.
`NIBEPI_MQTT_DISCOVERY`, `NIBEPI_UI_PORT`, `NIBEPI_UI_USER` and
`NIBEPI_UI_PASS` can be passed like the MQTT settings. A compose file written before the status page existed
needs the `ports:` entry `"8080:8080"` merged in from the example to reach
it.

An install by the previous version of the installer (`.env` plus a generated
`compose.yml`) is converted: the `.env` settings go into the new
`docker-compose.yml`, the old files to `~/nibepi/env-backup/`.

### Coming from the Node-RED installer

If the old installer's `nibepi` container is running, the installer migrates
it:

1. It checks everything first (Docker, serial port, MQTT settings) and stops
   with the Node-RED container still running if anything is missing.
2. It pulls the gateway image.
3. It copies the Node-RED `config.json` (from the container's `/etc/nibepi`
   mount, normally `~/nibepi/etc/nibepi`) to `~/nibepi/config/`, unless a
   gateway config is already there. The original is not touched.
4. It moves the old `~/nibepi/.env` (with the Node-RED credential secret) and
   `compose.yml` to `~/nibepi/nodered-backup/` (a `compose.yml` would take
   precedence over `docker-compose.yml`).
5. It stops and removes the `nibepi` container and starts `nibepi-gateway`.

`~/nibepi/data`, `~/nibepi/etc` and `~/nibepi/tmp` and the old image are left
as they were. A `nibepi` container that the old installer didn't start in
`~/nibepi` is only replaced with `REPLACE=1`.

By hand, the same is (the old installer used `~/nibepi` too, and its
`compose.yml` there would take precedence over `docker-compose.yml`):

```sh
docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/nibepi"}}{{.Source}}{{end}}{{end}}' nibepi
                                       # where its config.json is, normally ~/nibepi/etc/nibepi
cd ~/nibepi
mkdir -p nodered-backup && mv .env compose.yml nodered-backup/
curl -fsSLO https://raw.githubusercontent.com/greberg/nibepi-docker/improvements/docker-compose.yml
chmod 600 docker-compose.yml && nano docker-compose.yml   # MQTT settings
docker compose pull
docker stop nibepi && docker rm nibepi # its data folders and image stay
mkdir -p config && sudo cp -p etc/nibepi/config.json config/   # the folder from inspect
sudo chown -R 1000:1000 config
docker compose up -d
```

## Upgrade and rollback

```sh
cd ~/nibepi && docker compose pull && docker compose up -d
```

`up -d` recreates the container only when the image or the compose file
changed. Re-running the installer does the same, and first tags the running
image `ghcr.io/greberg/nibepi-gateway:previous` (only if it was healthy, so a
re-run after a bad upgrade keeps the good one); afterwards it waits for the
health check and says how to go back. The NibePi workspace's
`scripts/deploy.sh` does the same for a compose file in any directory.

To roll back or pin a version, change `image:` in `docker-compose.yml` and
run `docker compose pull && docker compose up -d` (no pull for `:previous`,
it only exists on the Pi):

```yaml
    image: ghcr.io/greberg/nibepi-gateway:previous     # the image before (installer/deploy.sh)
    image: ghcr.io/greberg/nibepi-gateway:20261010     # a dated build
    image: ghcr.io/greberg/nibepi-gateway:sha-1a2b3c4  # a build of this repo's commit
```

There is no automatic rollback: unhealthy means no data from the pump, which
is as likely wiring or UART config as the image.

### Going back to Node-RED

After a migration, the installer prints this; the paths are the defaults:

```sh
cd ~/nibepi && docker compose down                     # stop the gateway
mv docker-compose.yml docker-compose.yml.gateway
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
set in `docker-compose.yml`'s `environment:` section. They override
`config.json` without being written to it; an empty value counts as unset.

| variable | meaning |
|---|---|
| `NIBEPI_MQTT_HOST`, `NIBEPI_MQTT_PORT` | broker, port default 1883; without a host MQTT is off |
| `NIBEPI_MQTT_USER`, `NIBEPI_MQTT_PASS` | broker login |
| `NIBEPI_MQTT_TOPIC` | topic prefix, default `nibe/modbus/` |
| `NIBEPI_MQTT_DISCOVERY` | `true` also announces every polled register and the Bus errors sensor to Home Assistant as MQTT sensors on a "Nibe <model>" device; `false` (default) removes them. The NibePi integration does not need it |
| `NIBEPI_CONNECTION` | `serial` or `nibegw` |
| `NIBEPI_SERIAL_PORT` | `/dev/ttyAMA0`, where `devices:` maps the host's port |
| `NIBEPI_NIBEGW_HOST`, `NIBEPI_NIBEGW_PORT` | NibeGW gateway |
| `NIBEPI_RAW_SET` | what plain `<reg>/set` may write: `all`, `none` or a comma list of registers; `none` once the HA component is in use |
| `NIBEPI_LOG_LEVEL` | `error`, `warn`, `info` (default), `debug` or `trace` (every raw bus frame); logs go to stdout |
| `TZ` | time zone for the log, e.g. `Europe/Stockholm` |
| `NIBEPI_CONFIG_DIR` | `/etc/nibepi` in the image |
| `NIBEPI_HEALTH_FILE` | `/dev/shm/nibepi-health.json` in the image |
| `NIBEPI_UI_PORT` | status page port inside the container, `8080` in the image; empty turns it off |
| `NIBEPI_UI_USER`, `NIBEPI_UI_PASS` | optional HTTP Basic auth for the status page: both or neither |
| `NIBEPI_BUILD` | set by the image build (`<date>-<backend commit>`, e.g. `20261017-87eb233`); shown on the status page, in `gateway/state` and in Home Assistant. Leave it alone |

Values are single-quoted in the file; inside the quotes write `'` as `''`
and `$` as `$$` (compose would substitute a single `$`):
`NIBEPI_MQTT_PASS: 'it''s$$ecret'` is `it's$ecret`. After editing:
`cd ~/nibepi && docker compose up -d`.

The container runs as `node` (uid 1000), so the config folder must be
writable by uid 1000 (`sudo chown -R 1000:1000 config`; the installer does
this). For the serial port it is in `dialout` (gid 20 in the image); the
device keeps the host's group, so the compose file adds `dialout` with
`group_add`. If the host's dialout gid isn't 20
(`getent group dialout | cut -d: -f3`), put that number there instead.

Health: the gateway rewrites `/dev/shm/nibepi-health.json` every minute.
The container is unhealthy when that file is missing or older than 3
minutes, or the pump hasn't answered for 10 minutes (`docker ps` shows it).

## Status page

The gateway serves a read-only status page at `http://<pi>:8080/`. It shows
the following and refreshes itself every 5 seconds:

- the connection to the pump and to MQTT
- the age of the last data from the pump
- bus health over the last hour
- the virtual RMU40 room units (emulated or read-only, the last poll and
  the last room temperature written)
- leases, with a countdown to expiry
- key temperatures
- recent warnings and errors

It needs no internet: everything is in one page. `GET /healthz` answers
`200` or `503` by the same rule as the healthcheck (pump data in the last 10
minutes), for an external monitor.

- **Port.** To move it, change the host port on the left of `"8080:8080"`
  in `ports:`. To turn it off, remove that line and set `NIBEPI_UI_PORT: ''`.
- **Access.** Without `NIBEPI_UI_USER`/`NIBEPI_UI_PASS`, anyone on the LAN
  can read it. It changes nothing and never shows the MQTT password, but it
  does show the broker address and user. Keep it on the LAN and don't
  forward it to the internet. Basic auth over plain HTTP is not encrypted;
  for remote access, use a VPN.

## Connecting to Home Assistant's Mosquitto

1. In Home Assistant, install the **Mosquitto broker** add-on and start it.
2. Create a Home Assistant user for the gateway (Settings → People → Users,
   e.g. `nibepi`); the add-on accepts HA users as MQTT logins.
3. Make sure the **MQTT** integration is set up in HA (it is offered once the
   add-on runs).
4. In the gateway's `docker-compose.yml`, set `NIBEPI_MQTT_HOST` to HA's
   address, `NIBEPI_MQTT_USER: 'nibepi'` and `NIBEPI_MQTT_PASS` to its
   password, then `docker compose up -d`.
5. Check: in HA, Settings → Devices & services → MQTT → Configure → Listen to
   topic `nibe/modbus/#`. `nibe/modbus/status` should be `online`.
6. Install the [nibepi-ha](https://github.com/greberg/nibepi-ha) component
   (HACS custom repository) with the same topic prefix.

## Building

Building is separate from running: `docker-compose.yml` has no `build:`
section and only names an image. The published one comes from CI (below).
To build your own, from this repository plus nibepi-backend, checked out as
`nibepi/` next to the Dockerfile (gitignored):

```sh
git clone https://github.com/greberg/nibepi-docker.git
cd nibepi-docker
git clone -b improvements https://github.com/greberg/nibepi-backend.git nibepi
docker build -t ghcr.io/greberg/nibepi-gateway:local .
```

Or point a named build context at a checkout elsewhere:

```sh
docker build --build-context backend=../nibepi-backend -t ghcr.io/greberg/nibepi-gateway:local .
```

Then set `image: ghcr.io/greberg/nibepi-gateway:local` in your
`docker-compose.yml` and `docker compose up -d` (a `pull` would fail for a
tag that only exists locally). The NibePi workspace's `scripts/build.sh`
does this with date/commit tags, `--platform` and `--push`.

## Prebuilt image

`.github/workflows/image.yml` builds for amd64 and arm64 and publishes
`ghcr.io/<owner>/nibepi-gateway` on every push to `improvements`, nightly
(picking up backend changes and base image updates) and on demand, tagged
`latest`, `YYYYMMDD` and `sha-<short>`. A new GHCR package is private; make it
public under the package's settings, or `docker login ghcr.io` on the Pi.
