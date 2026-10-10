# NibePi gateway: nibepi-backend's gateway.js on Node 24, without Node-RED.
# It talks to the pump (RS485 serial or NibeGW) and connects out to an MQTT
# broker; control logic lives in the Home Assistant component (nibepi-ha).
# The Node-RED image this replaced is the nodered-final tag of this repo.

# The backend source: by default the nibepi/ checkout of nibepi-backend next
# to this file (CI and the workspace's scripts/build.sh put it there). A
# named build context called "backend" replaces this stage, so a checkout
# elsewhere works without copying it in:
#   docker build --build-context backend=../nibepi-backend .
FROM scratch AS backend
COPY nibepi/ /

# serialport ships prebuilt binaries for linux arm64/amd64 (glibc); the
# toolchain is only there for when no prebuild matches, and stays in this
# stage.
FROM node:24-bookworm-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=backend / /app/
# A named context brings whatever is in the checkout, node_modules built on
# another OS included; drop it and everything that isn't the runtime.
RUN rm -rf node_modules .git .github test test.js example*.js \
 && if [ -f package-lock.json ]; then npm ci --omit=dev --no-audit --no-fund; \
    else npm install --omit=dev --no-audit --no-fund; fi \
 && npm cache clean --force

FROM node:24-bookworm-slim

LABEL org.opencontainers.image.title="nibepi-gateway" \
      org.opencontainers.image.description="NibePi gateway for Nibe heat pumps: RS485/NibeGW to MQTT, with register leases for Home Assistant" \
      org.opencontainers.image.source="https://github.com/greberg/nibepi-docker" \
      org.opencontainers.image.url="https://github.com/greberg/nibepi-docker" \
      org.opencontainers.image.licenses="MIT"

ENV NODE_ENV=production \
    NIBEPI_CONFIG_DIR=/etc/nibepi \
    NIBEPI_HEALTH_FILE=/dev/shm/nibepi-health.json

# The node user (uid 1000) gets dialout (gid 20 on Debian) for the serial
# port. The device node keeps the host's gid, so compose also adds the host's
# dialout group with group_add when that isn't 20.
RUN usermod -aG dialout node \
 && mkdir -p /etc/nibepi \
 && chown node:node /etc/nibepi

# Owned by root: the gateway can't modify its own code.
COPY --from=build /app /app
WORKDIR /app
USER node

# config.json (atomic writes, .bak) and the persisted lease baselines.
VOLUME /etc/nibepi

# Healthy = the gateway is alive (it rewrites the health file every minute)
# and the pump has answered in the last 10 minutes. Docker doesn't restart an
# unhealthy container on its own; this makes the state visible in docker ps
# and to pi/install.sh / scripts/deploy.sh.
HEALTHCHECK --interval=60s --timeout=10s --start-period=5m --retries=3 \
  CMD node -e 'const f=process.env.NIBEPI_HEALTH_FILE||"/dev/shm/nibepi-health.json"; let h; \
    try { h = JSON.parse(require("fs").readFileSync(f, "utf8")); } \
    catch (e) { console.log("unhealthy: " + f + " missing or unreadable"); process.exit(1); } \
    const now = Date.now(); \
    if (!(now - h.ts < 180e3)) { console.log("unhealthy: health file stale (core " + h.core + ")"); process.exit(1); } \
    if (!h.lastData || !(now - h.lastData < 600e3)) { console.log("unhealthy: no data from the pump for 10 min (core " + h.core + ")"); process.exit(1); } \
    console.log("ok: core " + h.core);'

# gateway.js handles SIGTERM itself: stops the core and MQTT cleanly (leases
# are not released; the grace lease covers the restart).
STOPSIGNAL SIGTERM
CMD ["node", "gateway.js"]
