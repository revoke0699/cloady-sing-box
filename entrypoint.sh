#!/bin/sh
# Entrypoint for the Cloady sing-box + cf-probe container (POSIX sh).
#
# What it does, in order:
#   1. Fails fast if any required environment variable is missing or empty.
#   2. Builds the TUIC TLS identity: uses caller-provided base64 PEM files
#      when TUIC_CERT_B64/TUIC_KEY_B64 are set, otherwise generates an
#      ephemeral self-signed certificate (regenerated on every start).
#      With an ephemeral certificate the TUIC client must allow insecure
#      connections; see README.md.
#   3. Renders /etc/sing-box/config.json from environment variables with jq
#      (jq quoting makes arbitrary UUID/password values JSON-safe).
#   4. Runs `sing-box check` and fails fast on an invalid config.
#   5. Writes /data/config.conf in the upstream cf-probe container format
#      (KEY="value" lines; AUTO_UPDATE forced to 0, matching upstream
#      container behaviour) and starts both processes:
#        sing-box run -c /etc/sing-box/config.json   (background)
#        cf-probe run -config /data/config.conf     (supervised)
#   6. Supervises both: if either exits, stops the other and exits non-zero
#      so the platform restarts the container.
#
# No secret, UUID or password is written into the image or this repo.
# Everything sensitive arrives as a container environment variable and is
# only rendered into /etc/sing-box/config.json and /data/config.conf at
# runtime. Values containing a double quote, backslash or newline will
# break the probe config format (upstream format has no escaping); keep
# SECRET and password values free of those characters.
set -eu

# ---- 1. Required variables (fail fast) ----
for var in VLESS_UUID WS_PATH TUIC_UUID TUIC_PASSWORD SERVER_ID SECRET WORKER_URL; do
  eval "value=\${$var:-}"
  if [ -z "$value" ]; then
    echo "[entrypoint] missing required environment variable: $var" >&2
    exit 1
  fi
done

# ---- Defaults for optional variables ----
WS_PORT="${WS_PORT:-8080}"
TUIC_PORT="${TUIC_PORT:-50000}"
LOG_LEVEL="${LOG_LEVEL:-warn}"
COLLECT_INTERVAL="${COLLECT_INTERVAL:-0}"
REPORT_INTERVAL="${REPORT_INTERVAL:-60}"
CONNECTION_MODE="${CONNECTION_MODE:-auto}"
PING_MODE="${PING_MODE:-tcp}"

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

# ---- 3. Render sing-box config (jq guarantees valid JSON) ----
# VLESS + WebSocket has NO TLS block here on purpose: Cloady ingress
# terminates TLS for the https hostname and forwards plain WebSocket to
# the container. TUIC always has TLS (QUIC requires it) with h3 ALPN.
jq -n \
  --arg ws_port "$WS_PORT" \
  --arg tuic_port "$TUIC_PORT" \
  --arg vless_uuid "$VLESS_UUID" \
  --arg ws_path "$WS_PATH" \
  --arg tuic_uuid "$TUIC_UUID" \
  --arg tuic_password "$TUIC_PASSWORD" \
  --arg log_level "$LOG_LEVEL" \
  '{
    log: { level: $log_level },
    inbounds: [
      {
        type: "vless",
        tag: "vless-ws",
        listen: "::",
        listen_port: ($ws_port | tonumber),
        users: [{ uuid: $vless_uuid }],
        transport: { type: "websocket", path: $ws_path }
      },
      {
        type: "tuic",
        tag: "tuic-in",
        listen: "::",
        listen_port: ($tuic_port | tonumber),
        users: [{ uuid: $tuic_uuid, password: $tuic_password }],
        congestion_control: "bbr",
        tls: {
          enabled: true,
          alpn: ["h3"],
          certificate_path: "/etc/sing-box/cert.pem",
          key_path: "/etc/sing-box/key.pem"
        }
      }
    ],
    outbounds: [{ type: "direct", tag: "direct" }],
    route: { final: "direct" }
  }' > /etc/sing-box/config.json

# ---- 4. Validate before starting anything ----
sing-box check -c /etc/sing-box/config.json

# ---- 5. Probe config (upstream container format) ----
{
  printf 'SERVER_ID="%s"\n' "$SERVER_ID"
  printf 'SECRET="%s"\n' "$SECRET"
  printf 'WORKER_URL="%s"\n' "$WORKER_URL"
  printf 'COLLECT_INTERVAL="%s"\n' "$COLLECT_INTERVAL"
  printf 'REPORT_INTERVAL="%s"\n' "$REPORT_INTERVAL"
  printf 'CONNECTION_MODE="%s"\n' "$CONNECTION_MODE"
  printf 'PING_MODE="%s"\n' "$PING_MODE"
  printf 'AUTO_UPDATE="0"\n'
} > /data/config.conf

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
