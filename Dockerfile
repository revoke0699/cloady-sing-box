# syntax=docker/dockerfile:1
# Cloady sing-box + cf-probe single-container image.
#
# Design (see README.md for the full picture):
#   - One container runs TWO processes: sing-box (proxy) and cf-probe (monitor agent).
#   - sing-box is pinned to a stable release tarball, downloaded at build time.
#   - cf-probe is copied from the upstream agent image. The binary path
#     /app/cf-probe is confirmed from the upstream cfsm-agent Dockerfile
#     (alpine:3.21 base, COPY dist/cf-probe-${TARGETOS}-${TARGETARCH}
#     to /app/cf-probe, ENTRYPOINT /entrypoint.sh).
#   - No secret, UUID or password is baked into this image. All credentials
#     arrive at runtime as container environment variables (Cloady panel
#     Environment) and are only rendered into /etc/sing-box/config.json
#     and /data/config.conf by entrypoint.sh at container start.
#
# TODO after the first successful build: pin the agent stage below to the
# digest printed in the build log (replace the moving `latest` tag).

ARG SING_BOX_VERSION=1.14.4

FROM ghcr.io/huilang-me/cfsm-agent:latest AS agent

FROM alpine:3.21

ARG SING_BOX_VERSION
ARG TARGETARCH

RUN apk add --no-cache ca-certificates openssl jq curl

# cf-probe binary, copied from the upstream agent image (path verified upstream).
COPY --from=agent /app/cf-probe /usr/local/bin/cf-probe

# sing-box binary, pinned stable release.
# Asset pattern verified from multiple independent sources:
#   sing-box-<version>-linux-<arch>.tar.gz
#   containing sing-box-<version>-linux-<arch>/sing-box
# Supported build platforms (see workflow): linux/amd64, linux/arm64.
RUN set -eux; \
  case "$TARGETARCH" in \
    amd64|arm64) SB_ARCH="$TARGETARCH" ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  curl -fsSL -o /tmp/sing-box.tar.gz \
    "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${SB_ARCH}.tar.gz"; \
  tar -xzf /tmp/sing-box.tar.gz -C /tmp; \
  cp "/tmp/sing-box-${SING_BOX_VERSION}-linux-${SB_ARCH}/sing-box" /usr/local/bin/sing-box; \
  chmod 755 /usr/local/bin/sing-box /usr/local/bin/cf-probe; \
  rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${SING_BOX_VERSION}-linux-${SB_ARCH}"; \
  sing-box version

COPY entrypoint.sh /entrypoint.sh

RUN chmod 755 /entrypoint.sh \
  && mkdir -p /etc/sing-box /data

# Declared endpoints (also declared in compose.yml, which is what Cloady reads).
# First port: HTTP primary endpoint (VLESS + WebSocket).
# Second port: raw UDP endpoint (TUIC).
EXPOSE 8080
EXPOSE 50000/udp

ENTRYPOINT ["/entrypoint.sh"]
