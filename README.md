# cloady-sing-box (DRAFT — not pushed, not built)

Single-container image for Cloady that runs **sing-box** (proxy node) and
**cf-probe** (CF Server Monitor agent) together, built only by GitHub
Actions and deployed to Cloady pinned by commit SHA.

Status of this draft: local files only. No repository has been created,
nothing has been pushed, and no image has been built anywhere.

## What is in this repo

| File | Purpose |
| --- | --- |
| `Dockerfile` | Builds the image: alpine base, pinned sing-box release binary, cf-probe binary copied from the upstream agent image, entrypoint. |
| `entrypoint.sh` | Container start: renders configs from environment variables, validates with `sing-box check`, starts both processes, supervises them. |
| `compose.yml` | What Cloady reads: one service, two ports, resource limits. This file is the Cloady source definition. |
| `.github/workflows/docker-publish.yml` | GitHub Actions build -> GHCR, SHA tag only. |
| `.dockerignore` | Keeps the build context small. |

## How it works

```
Cloady ingress (TLS termination)
  └─ https hostname (primary endpoint, first port)
       └─ VLESS + WebSocket ──> sing-box (plain WS inside the container)
IPv6 address shown on the Cloady app page (raw UDP endpoint, second port)
  └─ TUIC (QUIC + TLS) ───────> sing-box
sing-box ──direct──> internet
cf-probe ──POST / WSS──> monitor Worker (server already created in admin)
```

Ports (do not reorder in `compose.yml`):

| # | compose entry | Cloady meaning | sing-box inbound |
| --- | --- | --- | --- |
| 1 | `8080:8080` | First entry, HTTP primary endpoint, published as the app's https hostname | VLESS + WebSocket, no TLS in-container (ingress terminates TLS) |
| 2 | `50000:50000/udp` | Raw UDP endpoint, no public IPv4, connect via the IPv6 address on the app page | TUIC, TLS with h3 ALPN, BBR congestion control |

## Deploy steps (in order)

1. **Delete the hello test app first (already decided; verify the
   workspace is empty before creating the new app).** Deletion is
   permanent, but hello held no data. An empty workspace is what makes
   the new app fit the free allowance on its own.
2. **Create the GitHub repo** `revoke0699/cloady-sing-box`.
   Recommended: private repo (this repo contains no secrets either way).
   See "Write access" below before pushing anything.
3. **Push these draft files to `main`.** The workflow runs automatically
   (it triggers on `Dockerfile`, `entrypoint.sh` and the workflow file).
   Do NOT push from a local Docker build; the workflow is the only build.
4. **Wait for the Actions run to succeed.** Copy the full SHA tag from
   the run (form `sha-<full commit SHA>`). Verify the pushed image
   digest matches the run log.
5. **Point `compose.yml` at that tag.** Replace `sha-PLACEHOLDER` with
   the full SHA tag and push only `compose.yml`. This push does NOT
   rebuild the image (workflow path filter excludes `compose.yml`).
6. **Create the Cloady app** from the GitHub repo: name `sing-box`,
   region Japan (JPN1), environment Production. Cloady reads
   `compose.yml` from the repo root.
7. **Set panel Environment variables** (App Settings -> Environment,
   mark secrets as secret). See the table below. Variables take effect
   on the next deploy, so set them before the first deploy, or Redeploy
   after changing them.
8. **Verify on the app page:** the primary https endpoint exists, the
   UDP endpoint shows an IPv6 address, and the container logs show
   `sing-box check` passing, sing-box starting, and the probe connecting
   (WSS connected, or POST fallback). Then check the monitor: the
   `cloady-sing-box` server must flip from offline to online.
9. **Test from a client:** VLESS + WebSocket via the https hostname,
   and TUIC via the IPv6 address + UDP port. If either fails, check the
   "Unconfirmed items" section before changing config blindly.

## Environment variables (names only — set values in the Cloady panel)

Secrets are NEVER written in this repo, in the image, or in chat logs.
Set them in Cloady App Settings -> Environment (secret values are
encrypted and hidden after saving).

| Variable | Required | Default | Notes |
| --- | --- | --- | --- |
| `VLESS_UUID` | Yes | — | UUID for the VLESS + WebSocket user. |
| `WS_PATH` | Yes | — | WebSocket path for the VLESS inbound. |
| `WS_PORT` | No | `8080` | Must match the first compose port's container port. |
| `TUIC_UUID` | Yes | — | UUID for the TUIC user (may reuse the VLESS UUID, kept separate here). |
| `TUIC_PASSWORD` | Yes | — | Password for the TUIC user. |
| `TUIC_PORT` | No | `50000` | Must match the second compose port's container port. |
| `SERVER_ID` | Yes | — | Probe server ID from the monitor admin (already created). |
| `SECRET` | Yes | — | Probe reporting secret (matches the Worker secret). |
| `WORKER_URL` | Yes | — | Probe reporting URL, ending in `/update`. |
| `LOG_LEVEL` | No | `warn` | sing-box log level (`warn` keeps logs small). |
| `COLLECT_INTERVAL` | No | `0` | Probe sampling interval; `0` disables extra sampling. |
| `REPORT_INTERVAL` | No | `60` | Probe reporting interval in seconds. |
| `CONNECTION_MODE` | No | `auto` | Probe connection mode (`auto` prefers WSS, falls back to POST). |
| `PING_MODE` | No | `tcp` | Probe ping mode (`tcp` needs no extra capability; `icmp` needs NET_RAW). |
| `TUIC_CERT_B64` | No | — | Optional stable TUIC certificate (base64 PEM). If unset, a self-signed certificate is generated on every start. |
| `TUIC_KEY_B64` | No | — | Optional stable TUIC key (base64 PEM), paired with the above. |

Value constraints: `SECRET` and passwords must not contain a double
quote, backslash or newline (the probe config format has no escaping).
UUIDs are hex plus hyphens and are safe.

TUIC TLS identity trade-off: with no caller-provided certificate, the
container generates an ephemeral self-signed certificate on every start,
so the TUIC client must allow insecure connections. For a stable
identity, provide `TUIC_CERT_B64`/`TUIC_KEY_B64` and configure the client
accordingly.

## Capacity (free tier)

Declared limits in `compose.yml` (0.50 vCPU / 512M) are summed per
workspace by Cloady. With hello deleted the workspace is empty, so this
app fits the free allowance on its own. If creation ever reports
`payment_required`, lower the declared limits or scale the app to 0.5x
in the panel before retrying; do not add a card to force it through.

## Rollback

- Keep the previous working SHA tag. To roll back, point `compose.yml`
  at the previous `sha-<...>` tag and push only `compose.yml`, then
  Redeploy in Cloady.
- Never roll back by re-tagging or re-pushing `latest`.
- The hello test app cannot be rolled back after deletion (it held no
  data, so nothing is lost).

## Write access (must be resolved before any push)

Read access is proven (GitHub connector connected as `revoke0699`),
but write access is NOT proven, and read success is not write proof.
Before pushing, the repo owner must do ALL of these:

1. Create `revoke0699/cloady-sing-box` on GitHub (it does not exist yet
   by repository search).
2. If Muse is to push via the GitHub connector: select the new repo in
   the GitHub App installation, then verify reachability with a read;
   each write call still asks for fresh approval at push time.
3. If pushing via git SSH with the existing sandbox deploy key: add
   that key's public part to the NEW repo as a Deploy key WITH
   "Allow write access" checked. A read-only deploy key fails pushes
   with "Permission denied to deploy key" (seen before on another repo).
4. Repo Settings -> Actions -> General -> Workflow permissions: set to
   Read and write (the workflow also declares `contents: read` and
   `packages: write`; a read-only repo cap would still block the GHCR
   push).
5. GHCR package visibility: after the first build, check the package
   page. If Cloady cannot pull it, set the package to public (the image
   contains no secrets, so this is safe) or confirm Cloady supports
   private-registry authentication first.

## Unconfirmed items (verify at first deploy, do not assume)

1. **Cloady Japan container architecture (amd64 vs arm64).** The
   workflow builds both, so either works; the actual runtime arch is
   only known after the first deploy (app page / container terminal).
2. **Compose HTTP-vs-UDP classification.** Cloady docs say the primary
   endpoint is the first HTTP endpoint, and panel findings say the first
   entry is HTTP and `/udp` marks raw UDP. Standard Compose treats an
   un-suffixed port as TCP, so the HTTP classification is Cloady-layer
   behaviour. Verify on the app page: one https endpoint plus one UDP
   endpoint with an IPv6 address. If misclassified, adjust the compose
   ports (long syntax / order) and redeploy.
3. **WebSocket passthrough through Cloady ingress.** The WS upgrade and
   long-lived WS connection through the https ingress are unconfirmed
   until a real VLESS + WebSocket handshake succeeds.
4. **Panel variables reaching compose services.** Docs say panel
   Environment holds the variables services see; this draft assumes
   direct injection with no `environment:` block in compose. If the
   entry script reports missing variables on first deploy, add an
   explicit pass-through `environment:` block and redeploy.
5. **Compose limits key.** This draft uses standard
   `deploy.resources.limits`. Verify the app Resources page shows the
   declared values after the first deploy; if it shows defaults instead,
   switch to the key Cloady actually reads.
6. **GHCR private-package pull.** Unknown whether Cloady supports
   private-registry authentication. Default to a public package (no
   secrets inside) unless private pull is confirmed.
7. **Probe + sing-box supervision.** The combined start/supervise logic
   in `entrypoint.sh` is new code (probe part follows the upstream
   container pattern: env -> `/data/config.conf`, `run -config`).
   Verify via container logs on first deploy.
8. **Upstream agent image tag.** The Dockerfile copies cf-probe from
   `ghcr.io/huilang-me/cfsm-agent:latest` (moving tag). After the first
   successful build, pin it to the digest from the build log.
9. **No persistent volume.** Probe traffic state is not persisted
   (config regenerates from env on every start). Server-side monitor
   history is unaffected; only per-container traffic counters reset.

## Security rules for this repo

- No secret, UUID, password, token or private key in any file, commit
  or image layer. Ever. Values live only in Cloady panel Environment.
- Node credentials are told to the user once, in chat, at delivery time
  — never written to memory, files or this repo.
- Deploy only full-SHA tags. Never `latest`, never a moving tag.
- Builds happen only in GitHub Actions. Never build locally or in a
  sandbox as a shortcut.
