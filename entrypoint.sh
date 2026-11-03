#!/bin/sh
# Entrypoint for the Cloady sing-box + cf-probe container (POSIX sh).
#
# v3: volume-persisted, auto-generated sing-box config.
#
# Persistent state lives in /data (compose volume appdata:/data):
#   /data/sing-box.json   sing-box config (generated once, reused after)
#   /data/cert.pem        TUIC TLS certificate (generated once, reused)
#   /data/key.pem         TUIC TLS key (generated once, reused)
#   /data/config.conf     probe config (from PROBE_CONFIG env, or reused)
#   /data/node-links.txt  generated node links + params (also printed)
#
# sing-box config resolution (first match wins):
#   1. /data/sing-box.json exists -> use it (stable across restarts).
#   2. SING_BOX_CONFIG (or SING_BOX_CONFIG_B64) set -> save it to
#      /data/sing-box.json and use it.
#   3. Otherwise -> generate fresh credentials (VLESS UUID, TUIC UUID +
#      password, WS path), save the config, use it.
# Probe resolution:
#   1. PROBE_CONFIG (or PROBE_CONFIG_B64) set -> save /data/config.conf.
#   2. /data/config.conf exists -> reuse it.
#   3. Otherwise -> probe disabled: sing-box runs alone, warning logged.
#      (Probe credentials cannot be generated: they must match the monitor
#      backend registration, so they still arrive via PROBE_CONFIG once.)
#
# Node links + params are printed to stdout on every start, so they are
# recoverable from the panel logs at any time. They are also saved to
# /data/node-links.txt. The container does not know its public hostname,
# so links use ${APP_HOST:-HOST} as a placeholder:
#   - VLESS link: replace HOST with the panel https domain.
#   - TUIC link: replace HOST with the panel IPv6 address in brackets,
#     e.g. [2604:...]:50000 (UDP has no public IPv4; a bare domain may
#     resolve to IPv4 first and fail). Set APP_HOST to print complete
#     links directly.
# sing-box 1.14.4 note: the VLESS WebSocket transport type is "ws",
# NOT "websocket" (check rejects "websocket" with "unknown transport
# type"). Generated configs use "ws".
#
# Security: links/params printed to logs are visible to whoever can open
# the panel logs (the workspace owner, same audience as the env panel).
# The probe config (SECRET) is NEVER printed.
set -eu

mkdir -p /data

# ---- TUIC TLS identity (generated once, reused from volume) ----
if [ ! -f /data/cert.pem ] || [ ! -f /data/key.pem ]; then
  if [ -n "${TUIC_CERT_B64:-}" ] && [ -n "${TUIC_KEY_B64:-}" ]; then
    printf '%s' "$TUIC_CERT_B64" | base64 -d > /data/cert.pem
    printf '%s' "$TUIC_KEY_B64" | base64 -d > /data/key.pem
  else
    openssl req -x509 -newkey rsa:2048 \
      -keyout /data/key.pem \
      -out /data/cert.pem \
      -days 3650 -nodes -subj "/CN=localhost" >/dev/null 2>&1
  fi
  chmod 600 /data/key.pem
  echo "[entrypoint] TUIC TLS identity generated and saved to volume" >&2
fi

# ---- sing-box config resolution ----
if [ -f /data/sing-box.json ]; then
  echo "[entrypoint] using saved sing-box config from volume" >&2
elif [ -n "${SING_BOX_CONFIG_B64:-}" ]; then
  printf '%s' "$SING_BOX_CONFIG_B64" | base64 -d > /data/sing-box.json
  echo "[entrypoint] sing-box config saved from SING_BOX_CONFIG_B64" >&2
elif [ -n "${SING_BOX_CONFIG:-}" ]; then
  { printf '%s' "$SING_BOX_CONFIG"; echo; } > /data/sing-box.json
  echo "[entrypoint] sing-box config saved from SING_BOX_CONFIG" >&2
else
  VUUID=$(cat /proc/sys/kernel/random/uuid)
  TUUID=$(cat /proc/sys/kernel/random/uuid)
  TPASS=$(openssl rand -hex 16)
  WSUFFIX=$(openssl rand -hex 8)
  cat > /data/sing-box.json <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "::",
      "listen_port": 8080,
      "users": [{ "uuid": "$VUUID" }],
      "transport": { "type": "ws", "path": "/ws-$WSUFFIX" }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": 50000,
      "users": [{ "uuid": "$TUUID", "password": "$TPASS" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/data/cert.pem",
        "key_path": "/data/key.pem"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct" }
}
EOF
  echo "[entrypoint] sing-box config auto-generated and saved to volume" >&2
fi

# ---- Validate before starting anything ----
# A corrupt saved config fails here on purpose: silently regenerating
# over it would orphan the node links the user already has.
sing-box check -c /data/sing-box.json

# ---- Node links + params (printed every start, saved to volume) ----
APP_HOST="${APP_HOST:-HOST}"
VLESS_UUID=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // empty' /data/sing-box.json)
WS_PATH=$(jq -r '.inbounds[] | select(.type=="vless") | .transport.path // empty' /data/sing-box.json)
TUIC_UUID=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].uuid // empty' /data/sing-box.json)
TUIC_PASSWORD=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].password // empty' /data/sing-box.json)
if [ -n "$VLESS_UUID" ] && [ -n "$WS_PATH" ] && [ -n "$TUIC_UUID" ] && [ -n "$TUIC_PASSWORD" ]; then
  WS_PATH_ENC="%2F${WS_PATH#/}"
  {
    echo "[node] VLESS link (replace HOST with the panel https domain):"
    echo "[node] vless://$VLESS_UUID@$APP_HOST:443?encryption=none&security=tls&sni=$APP_HOST&type=ws&path=$WS_PATH_ENC#web-01-vless"
    echo "[node] TUIC link (replace HOST with the panel IPv6 address in brackets, e.g. [2604:...]):"
    echo "[node] tuic://$TUIC_UUID:$TUIC_PASSWORD@$APP_HOST:50000?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#web-01-tuic"
    echo "[node] params: vless_uuid=$VLESS_UUID ws_path=$WS_PATH tuic_uuid=$TUIC_UUID tuic_password=$TUIC_PASSWORD"
    echo "[node] ports: VLESS+WS 443 via panel domain (TLS terminated by ingress); TUIC UDP 50000 via panel IPv6 address"
  } | tee /data/node-links.txt
else
  echo "[entrypoint] warning: could not extract node params from config, links skipped" >&2
fi

# ---- Probe resolution (optional) ----
PROBE_ENABLED=0
if [ -n "${PROBE_CONFIG_B64:-}" ]; then
  printf '%s' "$PROBE_CONFIG_B64" | base64 -d > /data/config.conf
  PROBE_ENABLED=1
  echo "[entrypoint] probe config saved from PROBE_CONFIG_B64" >&2
elif [ -n "${PROBE_CONFIG:-}" ]; then
  { printf '%s' "$PROBE_CONFIG"; echo; } > /data/config.conf
  PROBE_ENABLED=1
  echo "[entrypoint] probe config saved from PROBE_CONFIG" >&2
elif [ -f /data/config.conf ]; then
  PROBE_ENABLED=1
  echo "[entrypoint] using saved probe config from volume" >&2
else
  echo "[entrypoint] warning: no probe config (PROBE_CONFIG unset, none saved); running sing-box alone" >&2
fi

# ---- Start and supervise ----
sing-box run -c /data/sing-box.json &
SB_PID=$!

if [ "$PROBE_ENABLED" = "1" ]; then
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
else
  trap 'kill $SB_PID 2>/dev/null || true' TERM INT
  wait "$SB_PID" 2>/dev/null; SB_RC=$?
  echo "[entrypoint] sing-box exit=$SB_RC (probe disabled)" >&2
fi
exit 1
