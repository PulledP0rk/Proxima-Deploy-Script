# Proxima Deploy Script

One-command installer for [Proxima](https://dev-proxima.com) — Community Edition.

`proxima.sh` provisions a complete Proxima deployment on a fresh Linux host: it
installs Docker if it is missing, pulls the container images from the Proxima
registry, generates a `docker-compose.yml` and `.env`, and brings the stack up.

On a clean container or VM the only thing you need is this script.

---

## Quick start

Run as **root** on a fresh Debian/Ubuntu container or VM:

```bash
curl -fsSL https://raw.githubusercontent.com/PulledP0rk/Proxima-Deploy-Script/main/proxima.sh | bash
```

Not running as root? Use `sudo bash`:

```bash
curl -fsSL https://raw.githubusercontent.com/PulledP0rk/Proxima-Deploy-Script/main/proxima.sh | sudo bash
```

Prefer to read it before running it (recommended for any `curl | bash`):

```bash
curl -fsSL -o proxima.sh https://raw.githubusercontent.com/PulledP0rk/Proxima-Deploy-Script/main/proxima.sh
less proxima.sh
bash proxima.sh
```

The installer will ask for:

1. **Registry credentials** — your Proxima community username and license key.
2. **Component selection** — Full Stack, Backend only, or Frontend only.
3. **Backend API port** — defaults to `8443`.

---

## Requirements

| | |
|---|---|
| **Privileges** | root (the installer manages packages and Docker) |
| **OS** | 64-bit Linux with systemd — Debian, Ubuntu, Fedora, CentOS, RHEL, SLES |
| **Docker** | installed automatically if missing |
| **Network** | outbound HTTPS to `get.docker.com`, your distro's package mirrors, and `updates.dev-proxima.com` |
| **Disk** | ~4 GB for images and the database |
| **Memory** | 4 GB minimum, 8 GB recommended for the full stack |
| **Credentials** | a Proxima community username + license key |

### Running inside an LXC container — nesting is required

Docker cannot start inside an LXC container unless **nesting** is enabled. This
is a property of the container and **can only be set from the Proxmox host** —
the installer cannot set it for you. It will detect the situation and tell you,
but you will need to fix it outside the container and re-run.

On the Proxmox host:

```bash
pct set <vmid> --features nesting=1
pct reboot <vmid>
```

Or in the Proxmox web UI: **Container → Options → Features → Nesting**.

You can also set it when creating the container:

```bash
pct create <vmid> local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname proxima \
  --cores 4 --memory 8192 --swap 2048 \
  --rootfs local-lvm:32 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --features nesting=1 \
  --unprivileged 1 \
  --start 1
```

> **Note:** `nesting=1` is all Docker needs here. Other feature flags such as
> `keyctl=1` are restricted to `root@pam` and cannot be set with an API token,
> but they are not required for this deployment.

Running on a normal VM or bare metal? Nothing extra to do.

---

## Install modes

| Mode | What it deploys | Use when |
|---|---|---|
| **1 — Frontend only** | NGINX + web UI, proxying to a remote backend | The API already runs on another host |
| **2 — Backend only** | API + PostgreSQL + update sidecar | Headless API node, UI served elsewhere |
| **3 — Full Stack** *(recommended)* | Everything on one host | Single-box install |

---

## After installation

The web UI is served over **HTTPS**:

```
https://<host-ip>:8086
```

The certificate is **self-signed**, so your browser will show a warning on the
first visit — that is expected. Use the machine's IP or FQDN rather than
`localhost` if you are connecting from another computer.

### Ports

| Port | Service | Notes |
|---|---|---|
| `8086` | Web UI (HTTPS) | The browser talks only to this port |
| `8443` | Backend API (HTTP) | Published for direct API access and debugging |

The browser reaches the API **same-origin** through `https://<host>:8086/api` —
NGINX proxies it to the backend internally. Port `8443` is exposed for direct
API use; it is not required for the UI to work.

### Files the installer creates

Everything lands in `./proxima` relative to where you ran the script:

| File | Purpose |
|---|---|
| `proxima/docker-compose.yml` | Generated stack definition |
| `proxima/.env` | Ports, database credentials, registry credentials |
| `proxima/frontend-upstream.sh` | Points the web UI's `/api` proxy at your backend |
| `proxima-install.log` | Full installation log — check here first when something fails |

`.env` contains your registry password and a generated PostgreSQL password.
Keep it private and do not commit it anywhere.

---

## Managing the deployment

```bash
cd proxima

docker compose ps            # status
docker compose logs -f       # follow all logs
docker compose logs backend  # one service
docker compose restart       # restart everything
docker compose down          # stop (data is preserved)
docker compose up -d         # start again
```

### Updating

The `sidecar` container checks the registry hourly and pulls new images on your
chosen release channel. To change the cadence or channel, edit `proxima/.env`:

```ini
UPDATE_CHANNEL=stable          # stable | beta
CHECK_INTERVAL_MINUTES=60      # 0 disables automatic checks
```

then `docker compose up -d` to apply.

To update by hand:

```bash
cd proxima
docker compose pull
docker compose up -d
```

### Uninstalling

```bash
cd proxima
docker compose down          # keep volumes (database, keys, settings)
docker compose down -v       # DELETE all data — database, JWT keys, uploads
```

> `down -v` also destroys the JWT signing keys, which invalidates every issued
> session token. That is fine for a teardown, but do not run it expecting a
> clean restart with your data intact.

---

## Troubleshooting

**Docker installs, then the daemon will not start**

Almost always nesting inside an LXC. See
[the nesting section](#running-inside-an-lxc-container--nesting-is-required).
Check the daemon directly with:

```bash
systemctl status docker
journalctl -u docker --no-pager -n 50
```

**Browser warns the certificate is not trusted**

Expected — the UI ships with a self-signed certificate. Accept the warning, or
put your own reverse proxy with a real certificate in front of port `8086`.

**`https://<host>:8086` refuses to connect**

Confirm the stack is up (`docker compose ps`) and that nothing is filtering the
port. Note the UI is **HTTPS**, not HTTP — `http://<host>:8086` will not work.

**Authentication failed during install**

The username and license key are checked against `updates.dev-proxima.com` with
`docker login`. Confirm the credentials and that the host can reach the
registry:

```bash
getent hosts updates.dev-proxima.com
```

**Login returns an error / the UI cannot reach the API**

Check the backend and the API path through the UI:

```bash
docker logs proxima-backend --tail 50
curl -sk https://<host-ip>:8086/api/health
```

A healthy response is `{"status":"ok","ready":true,...}`.

**Anything else**

`proxima-install.log` records every step, the generated compose file, and the
full output of the image pull and startup.

---

## What gets deployed

Full Stack mode brings up:

| Container | Image | Role |
|---|---|---|
| `proxima-frontend` | `proxima-frontend/app` | Web UI over HTTPS, proxies `/api` to the backend |
| `proxima-backend` | `proxima-backend/app` | API server |
| `proxima-db` | `postgres:18-alpine` | PostgreSQL database |
| `proxima-sidecar` | `proxima-sidecar/app` | Watches the registry and applies updates |
| `proxima-jwt-key-init` | `alpine/openssl` | One-shot: generates the RS256 token-signing keypair, then exits |

`proxima-jwt-key-init` is expected to show as **Exited (0)** — it runs once at
install and on each `up` to make sure the signing keys exist. The keys live in a
Docker volume so sessions survive restarts.

---

## License

Proxima Community Edition. Use of the container images requires valid community
credentials.
