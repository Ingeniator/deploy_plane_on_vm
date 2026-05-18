# Plane AIO — VM Deploy

Deploys [Plane](https://plane.so) All-In-One community edition to a single VM over SSH using Podman (or Docker) and Compose. All images are pulled from a configurable private registry.

## Architecture

One AIO container runs all Plane services via `supervisord`:

| Process | Role |
|---|---|
| `proxy` | Caddy reverse proxy (port 80/443 inside container) |
| `api` | Django REST API (internal :3004) |
| `worker` | Celery background worker |
| `beat` | Celery beat scheduler |
| `migrator` | DB migrations (runs once on start, exits 0) |
| `space` | Spaces frontend (internal :3002) |
| `live` | Live collaboration server (internal :3005) |

Four infrastructure containers run alongside it:

| Container | Image | Role |
|---|---|---|
| `plane-db` | postgres:15.7-alpine | Primary database |
| `plane-redis` | valkey/valkey:7.2.11-alpine | Cache & task queue |
| `plane-mq` | rabbitmq:3.13.6-management-alpine | Message broker |
| `plane-minio` | minio/minio:latest | S3-compatible object storage |

## Files

```
deploy_plane_on_vm/
  deploy.sh           # main deploy script
  docker-compose.yml  # AIO + infrastructure services
  .env.example        # environment template — setup wizard fills this in
  .env                # live config — created on first run (git-ignored)
  .previous_release   # written before each deploy for rollback
  deploy.log          # append-only deploy log
```

## Prerequisites

**On the VM:**
- CentOS 8+ (or any Linux with systemd)
- `podman` — `dnf install podman`
- `podman-compose` — `pip3 install podman-compose`
- `curl`, `openssl` (usually pre-installed)

**Or with Docker instead of Podman:**
- Docker Engine + `docker compose` plugin

The script auto-detects `podman` first, falls back to `docker`.

## First Deploy

```bash
# 1. Copy files to the VM
scp -r deploy_plane_on_vm/ user@vm:/opt/plane/
ssh user@vm

# 2. Run — interactive setup starts automatically when .env is absent
cd /opt/plane
chmod +x deploy.sh
./deploy.sh
```

The setup wizard prompts for:

```
Persistent data directory [/opt/plane/data]:  ← where all container data is stored on the host
Private registry URL [docker.io]:             ← Enter for Docker Hub, or your private registry
VM IP address [127.0.0.1]:                    ← IP browsers use to reach Plane
PostgreSQL password [Enter to auto-generate]:
RabbitMQ password [Enter to auto-generate]:
MinIO access key [Enter to auto-generate]:
MinIO secret key [Enter to auto-generate]:

Registry username (Enter to skip):            ← credentials for the registry above
Registry password:
```

Passwords left blank are auto-generated via `openssl rand -hex 16`. App secrets (`SECRET_KEY`, `LIVE_SERVER_SECRET_KEY`) are always auto-generated.

After setup the script:
1. Creates all data directories under `DATA_DIR`
2. Pulls infrastructure images (skipped if already present)
3. Pulls the AIO image
4. Starts infrastructure, waits for Postgres to be ready
5. Starts the AIO container
6. Runs a 300 s health check — rolls back automatically on failure

**First boot takes ~2 minutes** — the migrator runs all DB migrations before the API becomes ready.

## Accessing Plane

| URL | What |
|---|---|
| `http://<VM_IP>:<PORT>/` | Main app |
| `http://<VM_IP>:<PORT>/god-mode/` | Admin panel (trailing slash required) |

Default port is `8080` (rootless). Use port `80` if running as root or after lowering `net.ipv4.ip_unprivileged_port_start`.

> Always type the full `http://` scheme in the browser address bar — browsers may silently upgrade to HTTPS otherwise.

## Persistent Storage

All container data is stored under a single `DATA_DIR` on the host (default `/opt/plane/data`):

```
/opt/plane/data/
  pgdata/       ← Postgres WAL + tables
  redis/        ← Valkey snapshots
  rabbitmq/     ← RabbitMQ queues
  minio/        ← uploaded files
  aio/data/     ← AIO runtime data
  aio/logs/     ← supervisord + per-process logs
```

Backup:
```bash
tar czf plane-backup-$(date +%F).tar.gz /opt/plane/data
```

To move data to a larger disk, stop containers, copy the directory, update `DATA_DIR` in `.env`, and redeploy.

## Rootless Mode (Podman / Docker rootless)

The script auto-detects rootless execution and:

- Sets `DOCKER_HOST` to the per-user socket for Docker rootless
- Warns if configured ports are below 1024 with the exact `sysctl` fix
- Warns if `loginctl linger` is not enabled (containers stop on SSH logout)

**Enable linger** so containers survive logout:
```bash
loginctl enable-linger $USER
```

**Use port 80 as a non-root user** (optional):
```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
# persist across reboots:
echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee /etc/sysctl.d/99-unpriv-ports.conf
```

## Updating to a New Release

```bash
APP_RELEASE=v0.28.0 ./deploy.sh
```

The script saves the current release tag, pulls the new image, recreates only `plane-aio` (infra is untouched), and rolls back automatically if the health check fails.

## Manual Rollback

```bash
./deploy.sh --rollback
```

Restores the release recorded in `.previous_release` and verifies with a health check.

## Reconfiguring from Scratch

```bash
rm .env && ./deploy.sh
```

The setup wizard runs again. Existing data in `DATA_DIR` is preserved — only the configuration changes.

## Applying .env Changes Without a Full Redeploy

```bash
# Edit .env, then recreate only the AIO container
podman-compose up -d --force-recreate plane-aio
# or
docker compose up -d --force-recreate plane-aio
```

## Key .env Variables

| Variable | Default | Notes |
|---|---|---|
| `DATA_DIR` | `/opt/plane/data` | Root for all bind-mount volumes |
| `REGISTRY` | `docker.io` | Registry prefix applied to all image pulls |
| `APP_RELEASE` | `stable` | Image tag for `plane-aio-community` |
| `DOMAIN_NAME` / `APP_DOMAIN` | *(VM IP)* | Must match what browsers use to reach Plane |
| `WEB_URL` | `http://<IP>:<PORT>` | Auto-set from IP + port during setup |
| `CORS_ALLOWED_ORIGINS` | `http://<IP>:<PORT>` | Auto-set from IP + port during setup |
| `LISTEN_HTTP_PORT` | `8080` | Host port → container port 80 |
| `LISTEN_HTTPS_PORT` | `8443` | Host port → container port 443 |
| `POSTGRES_PASSWORD` | *(generated)* | Also embedded in `DATABASE_URL` |
| `RABBITMQ_PASSWORD` | *(generated)* | Also embedded in `AMQP_URL` |
| `SECRET_KEY` | *(generated)* | Django secret — do not change after first deploy |

## Troubleshooting

**Nothing responds after deploy:**
```bash
# Check all containers are up and ports are bound
podman-compose ps

# Check AIO startup — migrator takes ~90s on first boot
podman-compose logs plane-aio --tail=50

# Check Caddy proxy
podman exec <plane-aio-container> cat /app/logs/error/proxy.err.log

# Test directly from the VM (bypasses browser HTTPS upgrade)
curl -v http://localhost:8080/
```

**Health check loops forever:**
The health check URL is derived from `LISTEN_HTTP_PORT`. If it loops, the port in `.env` doesn't match what the container is actually bound to. Check with `podman-compose ps` and verify `LISTEN_HTTP_PORT`.

**`/god-mode` shows a React Router error:**
Navigate to `/god-mode/` with a trailing slash. Caddy's `handle_path` strips the prefix before React Router sees the URL — without the trailing slash, `basename="/god-mode/"` can't match.

**Postgres out of disk space:**
```bash
df -h                        # check overall disk
podman system df             # check container storage usage
podman image prune -f        # remove dangling images
```
If `DATA_DIR` is on a small partition, move it to a larger disk and update `DATA_DIR` in `.env`.

**Setup interrupted — `.env` removed on next run:**
Intentional. The EXIT trap checks for `SETUP_COMPLETE=1` and removes the partial file so the next run starts clean.

**Stale lock file:**
```bash
rm /tmp/plane-deploy.lock
```

**Pull fails repeatedly:**
```bash
podman login <registry>
podman pull <registry>/makeplane/plane-aio-community:stable
```
