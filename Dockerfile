# Node-RED 5.0.7 on Node 24 — the combination the dependency audit was run against.
# serialport 13 ships prebuilt binaries for Node >=20, so no build toolchain is
# needed at image build time (serialport 9 had prebuilds only up to Node 16,
# which is what pinned this image to the -14 tag).
FROM nodered/node-red:5.0.7-24

# Tells the nibepi core it is running in a container: config writes go
# straight to disk instead of bracketing themselves with sudo mount
# remount,rw to reach a read-only SD card. Bare-Pi installs leave this unset.
ENV NIBEPI_DOCKER=1

COPY nibepi /usr/src/nibepi
COPY node-red-contrib-nibepi /usr/src/node-red-contrib-nibepi

USER root
RUN chown -R node-red /usr/src/nibepi /usr/src/node-red-contrib-nibepi
USER node-red

RUN cd /usr/src/node-red-contrib-nibepi && \
    npm install ../nibepi --omit=dev && \
    cd /usr/src/node-red && \
    npm install ../node-red-contrib-nibepi --omit=dev

# Pinned to what node-red-contrib-nibepi's package.json resolves to (~3.6.6,
# ~0.3.6), so a rebuild can't pick up a different dashboard by surprise.
# FROM above is pinned by tag, not digest; the nightly CI build is what
# picks up the base image's security updates.
RUN npm install node-red-dashboard@3.6.6 --omit=dev && \
    npm install node-red-node-ui-list@0.3.6 --omit=dev

# Healthy = the nibepi config node is alive (it rewrites the file every
# minute) and the pump has answered in the last 10 minutes. Replaces the
# base image's check, which only asks whether the editor answers HTTP.
# Docker doesn't restart an unhealthy container on its own; this makes the
# state visible in docker ps and to pi/install.sh / scripts/deploy.sh.
HEALTHCHECK --interval=60s --timeout=10s --start-period=5m --retries=3 \
  CMD node -e 'const f="/dev/shm/nibepi-health.json"; let h; \
    try { h = JSON.parse(require("fs").readFileSync(f, "utf8")); } \
    catch (e) { console.log("unhealthy: " + f + " missing or unreadable"); process.exit(1); } \
    const now = Date.now(); \
    if (!(now - h.ts < 180e3)) { console.log("unhealthy: health file stale (core " + h.core + ")"); process.exit(1); } \
    if (!h.lastData || !(now - h.lastData < 600e3)) { console.log("unhealthy: no data from the pump for 10 min (core " + h.core + ")"); process.exit(1); } \
    console.log("ok: core " + h.core);'
