#!/bin/sh
# Entrypoint for the Cloady sing-box + cf-probe container (POSIX sh).
#
# Two-variable configuration (v2). The container no longer renders its
# configs from individual fields; it takes two ready-made configs:
#
#   SING_BOX_CONFIG   Full sing-box config.json content (JSON, multi-line).
#   PROBE_CONFIG      Full cf-probe config.conf content (KEY="value" lines,
#                     upstream container format; AUTO_UPDATE should be 0).
#
# Each also accepts a base64 form (SING_BOX_CONFIG_B64 / PROBE_CONFIG_B64)
# as a fallback, in case a panel mangles multi-line values. The base64
# form wins when both are set. The old seven variables (VLESS_UUID,
# WS_PATH, TUIC_UUID, TUIC_PASSWORD, SERVER_ID, SECRET, WORKER_URL) are
# ignored by this version, so leaving them in the panel is harmless.
#
# What it does, in order:
#   1. Fails fast if either required config variable is missing or empty.
#   2. Builds the TUIC TLS identity: uses caller-provided base64 PEM files
#      when TUIC_CERT_B64/TUIC_KEY_B64 are set, otherwise generates an
#      ephemeral self-signed certificate (regenerated on every start).
#      With an ephemeral certificate the TUIC client must allow insecure
#      connections; see README.md.
#   3. Writes /etc/sing-box/config.json from SING_BOX_CONFIG
#      (or its base64 form) and runs `sing-box check`, failing fast on an
#      invalid config. The config must listen on the ports the platform
#      declares (8080 for VLESS+WS, 50000/udp for TUIC) and reference
#      /etc/sing-box/cert.pem and /etc/sing-box/key.pem for TUIC TLS.
#   4. Writes /data/config.conf from PROBE_CONFIG (or its base64 form)
#      and starts both processes:
#        sing-box run -c /etc/sing-box/config.json   (background)
#        cf-probe run -config /data/config.conf     (supervised)
#   5. Supervises both: if either exits, stops the other and exits non-zero
#      so the platform restarts the container.
#
# No secret, UUID or password is written into the image or this repo.
# Everything sensitive arrives as a container environment variable and is
# only written into /etc/sing-box/config.json and /data/config.conf at
# runtime. Values inside PROBE_CONFIG containing a double quote, backslash
# or newline will break the probe config format (upstream format has no
# escaping); keep SECRET and password values free of those characters.
set -eu

# ---- 1. Required configs (fail fast) ----
if [ -z "${SING_BOX_CONFIG:-}" ] && [ -z "${SING_BOX_CONFIG_B64:-}" ]; then
  echo "[entrypoint] missing required environment variable: SING_BOX_CONFIG" >&2
  exit 1
fi
if [ -z "${PROBE_CONFIG:-}" ] && [ -z "${PROBE_CONFIG_B64:-}" ]; then
  echo "[entrypoint] missing required environment variable: PROBE_CONFIG" >&2
  exit 1
fi

mkdir -p /etc/sing-box /data

# ---- 2. TUIC TLS identity ----
if [ -n "${TUIC_CERT_B64:-}" ] && [ -n "${TUIC_KEY_B64:-}" ]; then
  printf '%s' "$TUIC_CERT_B64" | base64 -d > /etc/sing-box/cert.pem
  printf '%s' "$TUIC_KEY_B64" | base64 -d > /etc/sing-box/key.pem
else
  openssl req -x509 -newkey rsa:2048 \
    -keyout /etc/sing-box/key.pem \
    -out /etc/sing-box/cert.pem \
    -days 3650 -nodes -subj "/CN=localhost" >/dev/null 2>&1
fi
chmod 600 /etc/sing-box/key.pem

# ---- 3. sing-box config (verbatim, or base64 fallback) ----
if [ -n "${SING_BOX_CONFIG_B64:-}" ]; then
  printf '%s' "$SING_BOX_CONFIG_B64" | base64 -d > /etc/sing-box/config.json
else
  { printf '%s' "$SING_BOX_CONFIG"; echo; } > /etc/sing-box/config.json
fi

# ---- 4. Validate before starting anything ----
sing-box check -c /etc/sing-box/config.json

# ---- 5. Probe config (verbatim, or base64 fallback) ----
if [ -n "${PROBE_CONFIG_B64:-}" ]; then
  printf '%s' "$PROBE_CONFIG_B64" | base64 -d > /data/config.conf
else
  { printf '%s' "$PROBE_CONFIG"; echo; } > /data/config.conf
fi

# ---- 6. Start both processes and supervise them ----
sing-box run -c /etc/sing-box/config.json &
SB_PID=$!

cf-probe run -config /data/config.conf &
PROBE_PID=$!

trap 'kill $SB_PID $PROBE_PID 2>/dev/null || true' TERM INT

while kill -0 "$SB_PID" 2>/dev/null && kill -0 "$PROBE_PID" 2>/dev/null; do
  sleep 5
done

kill "$SB_PID" "$PROBE_PID" 2>/dev/null || true
wait "$SB_PID" 2>/dev/null; SB_RC=$?
wait "$PROBE_PID" 2>/dev/null; PROBE_RC=$?
echo "[entrypoint] sing-box exit=$SB_RC cf-probe exit=$PROBE_RC" >&2
exit 1
