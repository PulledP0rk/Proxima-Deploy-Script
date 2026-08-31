# Proxima Deploy Script

One-command installer for [Proxima](https://dev-proxima.com) — Community Edition.

`proxima.sh` provisions a complete Proxima deployment on a fresh Linux host: it
installs Docker if it is missing, pulls the container images from the Proxima
registry, generates a `docker-compose.yml` and `.env`, and brings the stack up.

On a clean container or VM the only thing you need is this script.

**Two ways to deploy:**

| | Use when | Start here |
|---|---|---|
| **Installer** (`proxima.sh`) | You have SSH on a fresh Debian/Ubuntu host and want one command to do everything. | [Quick start](#quick-start) |
| **Compose / Portainer** | You manage containers through Portainer, or want to run the stacks by hand. | [Deploying with Compose or Portainer](#deploying-with-compose-or-portainer) |

Both produce the same stack. The compose files are the source of truth — the
installer writes equivalent ones.

---

## Quick start

Run on a fresh Debian/Ubuntu container or VM:

```bash
curl -fsSL https://raw.githubusercontent.com/PulledP0rk/Proxima-Deploy-Script/main/proxima.sh | sudo bash
```

The installer will ask for:

1. **Registry credentials** — your Proxima community username and license key.
2. **Component selection** — Full Stack, Backend only, or Frontend only. **Currently Full Stack is tested working**
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
| **Memory** | 2 GB recommended for the full stack |
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

## Deploying with Compose or Portainer

Two files in this repo, deployed as **two separate stacks**:

| File | Stack | Contains |
|---|---|---|
| `docker-compose.backend.yml` | `proxima-backend` | API, PostgreSQL, Infisical, Valkey, mTLS terminator, RDP gateway, three one-shots |
| `docker-compose.frontend.yml` | `proxima-frontend` | Web UI + public TLS terminator |

They need no files on disk and no bind mounts — everything is in named volumes,
so both paste straight into Portainer ▸ Stacks ▸ Add stack ▸ Web editor.

> These files are **generated** from the composes the Proxima-Backend and
> Proxima-Frontend repos actually run (`scripts/render-deploy-compose.mjs`).
> Don't hand-edit them; edit the source compose and re-render.

Every image is a multi-arch manifest list (amd64 + arm64), so the same file runs
unmodified on a Raspberry Pi or an Ampere host. There are no `platform:` keys and
nothing to delete on ARM.

### Step 1 — log the Docker daemon into the registry

Do this **first**, on the host that owns the Docker socket Portainer is bound to.
The image pull is done by the daemon, which reads `~/.docker/config.json`; it does
*not* see the stack's environment variables.

```bash
docker login updates.dev-proxima.com -u 'robot$name' -p '<token>'
```

The single quotes matter — a Harbor robot name contains a `$`, and unquoted the
shell expands it away and logs you in as `robot`. Without this you get
`pull access denied ... no basic auth credentials`.

### Step 2 — deploy the backend stack

Paste `docker-compose.backend.yml`, then set these environment variables:

| Variable | Required? | Notes |
|---|---|---|
| `POSTGRES_PASSWORD` | **change it** | Default is `proxima` |
| `VALKEY_PASSWORD` | **change it** | Default is `proxima-valkey` |
| `INFISICAL_ENCRYPTION_KEY` | **change it** | `openssl rand -hex 16` |
| `INFISICAL_AUTH_SECRET` | **change it** | `openssl rand -hex 32` |
| `INFISICAL_BOOTSTRAP_EMAIL` | **yes, no default** | Stack won't start without it |
| `INFISICAL_BOOTSTRAP_PASSWORD` | **yes, no default** | Stack won't start without it |
| `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` | for update checks | Update checks + agent pulls, *not* the image pull. **Set both or neither**, and escape a `$` in the username as `$$` — see below |
| `BACKEND_PORT` / `AGENT_PORT` / `INFISICAL_UI_PORT` | optional | Default `8443` / `8444` / `8088` |

There is **no compose profile to set**. Every service starts unconditionally.

> **Harbor robot names contain a `$`, and compose eats it.** Setting
> `REGISTRY_USERNAME=robot$closedbeta` in a `.env` or stack variable resolves to
> plain `robot` — `$closedbeta` is interpolated as an (undefined) variable.
> Write it as `robot$$closedbeta`. Verify what the container actually received,
> because nothing warns you:
>
> ```bash
> docker inspect proxima-backend --format '{{range .Config.Env}}{{println .}}{{end}}' \
>   | grep REGISTRY_USERNAME
> ```
>
> Note this is the *opposite* of the `docker login` rule above, where the name is
> single-quoted so the shell leaves it alone. Same `$`, two different escapes.

Wait for these three one-shots to reach **Exited (0)** — the stack is not ready
until they have:

```
proxima-db-init               creates the `infisical` database
proxima-jwt-key-init          generates the RS256 token-signing keypair
proxima-infisical-bootstrap   provisions the org, project, CA, cert templates
                              and the two Machine Identities
```

`proxima-backend-nginx` will not start until the bootstrap finishes. That is
deliberate — it needs the cert template id the bootstrap writes.

### Step 3 — hand the frontend its Machine Identity

The frontend authenticates to Infisical with its **own** identity, which the
backend's bootstrap generated. Copy it across **before** deploying the frontend
stack. On the backend host:

```bash
docker cp proxima-infisical-bootstrap:/var/lib/proxima/frontend-bundle ./frontend-bundle
cat frontend-bundle/infisical_api_url     # sanity-check it is reachable from the frontend
```

If the frontend runs on a **different machine**, that URL defaults to
`http://infisical:8080` and will not resolve there. Set `INFISICAL_PUBLIC_URL` on
the backend stack to a routable address and redeploy so the bootstrap re-writes
the bundle. (`docker rm proxima-infisical-bootstrap` first to force a re-run.)

Then, on the frontend host — check `docker volume ls` for your stack's prefix:

```bash
docker run --rm \
  -v <stack>_infisical-frontend-secrets:/dst \
  -v "$PWD/frontend-bundle":/src:ro \
  alpine:3.20 sh -c 'cp /src/client_id /src/client_secret /src/cert_template_id \
                        /src/ca_id /src/infisical_api_url /src/config_* /dst/'
```

### Step 4 — deploy the frontend stack

Paste `docker-compose.frontend.yml` and set:

| Variable | Notes |
|---|---|
| `PROXIMA_PUBLIC_HOSTNAME` | Hostname on the self-signed cert; default `localhost` |
| `WEBUI_PORT` | Default `8086` |
| `PROXIMA_BACKEND_UPSTREAM` | **Same host: leave unset.** Different host: the backend's address, e.g. `https://10.0.0.5:8443` |

If the frontend is on a **different host** from the backend, also create the
network the stack expects to join — it stays empty there, but the stack declares
it `external` and will not start without it:

```bash
docker network create proxima-internal
```

Browse to `https://<host>:8086`. The certificate is self-signed until you
configure your own in Settings, so expect a browser warning on first visit.

### Verifying a deployment

```bash
curl -sk https://<host>:8086/api/health          # {"status":"ok","ready":true,...}
docker ps -a --format '{{.Names}}\t{{.Status}}'  # 3 one-shots Exited (0), rest healthy
```

---

## Install modes

| Mode | What it deploys | Use when |
|---|---|---|
| **1 — Frontend only** | NGINX + web UI, proxying to a remote backend | The API already runs on another host |
| **2 — Backend only** | API + PostgreSQL + secret store | Headless API node, UI served elsewhere |
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

### Backend TUI

The backend runs a live terminal UI for status, logs, and database inspection.
Attach to it from the host with:

```bash
docker exec -it proxima-backend tui
```

The `-it` flags are required — it is an interactive terminal application.

> **Detach with `Ctrl-\`.** Do **not** quit with `q` or `Ctrl-C`: the TUI is the
> process the container supervises, so quitting it **stops the container** and
> takes Proxima down with it. `Ctrl-\` leaves it running and returns you to your
> shell.

The TUI is kept alive in a detached pty, so you can attach and detach as often
as you like without disturbing the running service. Plain-text logs stay
available separately via `docker logs proxima-backend`.

If you get `TUI socket not found`, the container has not finished starting —
wait a moment and check `docker logs proxima-backend`.

### Rack console — the TUI on an attached monitor, 24/7

`scripts/setup-rack-console.sh` turns a monitor attached to the host into a
permanent display of the backend TUI: autologin on `tty1` at boot, the TUI full
screen, and a screen that never blanks.

```bash
sudo ./scripts/setup-rack-console.sh
sudo systemctl restart getty@tty1     # start it now, without rebooting
```

Idempotent — safe to re-run. Options: `--user NAME`, `--tty N`,
`--container NAME`, `--no-video`.

**Escaping out.** `Ctrl+Alt+F2` (through `F6`) give ordinary login prompts on the
other virtual terminals. The console is a display, not a lockout. `Ctrl-\`
detaches the TUI and returns to the console loop, which re-attaches.

> **Never quit the TUI with `q` or `Ctrl-C`.** `docker-supervisor.sh` is PID 1
> inside the container and ends with `wait "$TUI_PID"`, so quitting the TUI
> **stops the backend container**. `restart: unless-stopped` brings it back and
> the console loop re-attaches, but it is a real outage. The console prints this
> warning on every attach.

**What it sets up, and why:**

- A dedicated user (default `proxima-tui`) whose password is **locked**, not
  empty. Autologin never consults it, so the effect is the passwordless boot
  login you want — but an empty password would also let anyone log in as that
  account from another tty or over SSH.
- The user is **not** in the `docker` group. That group is root-equivalent, and
  this account logs in automatically with no credential, so membership would
  hand root to anyone standing at the rack. A single root-owned helper
  (`/usr/local/bin/proxima-tui-attach`) is allow-listed through `sudo` instead,
  and it can attach the TUI and nothing else.
- Screen blanking off on both paths — `consoleblank=0` in `cmdline.txt` (the
  kernel default blanks after 600s) and `hdmi_blanking=0` in `config.txt` (which
  otherwise lets the display sleep after 10 minutes).
- The console video mode is **pinned** to the attached display's native mode,
  e.g. `video=HDMI-A-2:1920x1280@60`. Without this the mode depends on whatever
  EDID the display happened to offer at boot — and a rack display is often
  powered separately from the host, so if it is off or asleep at that moment the
  console silently drops to a fallback mode.

The blanking and video changes are boot config, so they need a **reboot**. The
autologin and TUI work immediately after `systemctl restart getty@tty1`.

**On DietPi:** leave `dietpi-autostart` on *Console: Manual Login* (index 0). Set
to an autologin index it writes its own drop-in to
`/etc/systemd/system/getty@tty1.service.d/`, and the two fight over that file.

### Updating

Updates are **notify-only**. The backend lists the semver tags published in the
registry and tells you in the UI when a newer release exists; nothing is pulled
or restarted on your behalf.

There is deliberately no auto-updating container. The old update sidecar mounted
the Docker socket — which is root on the host — alongside the stack that holds
every Proxmox credential, and that is a poor trade for saving one command.

To update, from the directory holding that side's compose file:

```bash
docker compose pull
docker compose up -d
```

Plain `docker compose`, not the `proxima-compose` wrappers — it is already on
`PATH`, and the command is character-for-character identical on Linux, macOS and
Windows, so there is no `.sh`/`.ps1` variant to pick.

**Don't know where it is installed?** Ask the container:

```bash
docker inspect proxima-backend \
  --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'
```

Substitute `proxima-frontend` for the other side — the two stacks are deployed
separately and can live in different places.

> If that prints a path starting with `/data/compose/`, it is **inside the
> Portainer container**, not on the host, and there is no host directory to
> `cd` into. Update that stack from Portainer instead: **Stacks ▸ your stack ▸
> Update the stack**, with *Re-pull image* enabled.

Both stacks can be updated independently; a release usually bumps both.

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

### Compose / Portainer deployments

**Login returns HTTP 500; everything else works**

Backend log shows:

```
File "/app/src/web/api/auth.py", line 91, in login
FileNotFoundError: [Errno 2] No such file or directory: './keys/jwt_private.pem'
```

The RS256 token-signing keypair is missing. It is generated at runtime by the
`proxima-jwt-key-init` one-shot into the `jwt-keys` volume — check that the
service exists in your stack and reached **Exited (0)**. Only login touches these
keys, so health checks stay green and every container reports healthy while this
is broken.

To recover without recreating containers (this also pre-seeds the volume, so the
keys survive the next redeploy and existing sessions stay valid):

```bash
docker volume create proxima-backend_jwt-keys
docker run --rm --entrypoint /bin/sh -v proxima-backend_jwt-keys:/keys alpine/openssl:latest -c \
  'openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /keys/jwt_private.pem &&
   openssl pkey -in /keys/jwt_private.pem -pubout -out /keys/jwt_public.pem &&
   chmod 600 /keys/jwt_private.pem'
```

then redeploy the stack so the backend mounts the volume.

**`proxima-rdp-gateway` restarts forever with exit 133 (ARM hosts)**

```
Process terminated. Couldn't find a valid ICU package installed on the system.
   at Microsoft.PowerShell.ManagedPSEntry.Main(System.String[])
```

The gateway's entrypoint is a PowerShell script and .NET will not start without
ICU. Upstream's amd64 image ships libicu; **the arm64 image ships none**. The
compose sets `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`, upstream's documented
alternative — confirm it is present on the service. Only the entrypoint script is
affected; the gateway itself is Rust.

**`[cert-fetcher] FATAL: INFISICAL_CERT_TEMPLATE_ID not set and ... cert_template_id missing`**

On **backend-nginx**: the `proxima-infisical-bootstrap` one-shot did not run or
did not succeed. Check `docker logs proxima-infisical-bootstrap`. It is
idempotent, so re-running is safe.

On **frontend**: you have not copied the frontend bundle across —
see [Step 3](#step-3--hand-the-frontend-its-machine-identity).

**Server saves and lists fine, but the sidebar resource tree stays empty**

Infisical is unreachable. `secret_resolver.py` has no local fallback (the
Fernet-on-disk path was removed), so storing a Proxmox credential raises
`SecretStoreUnavailable`. Check `proxima-infisical` is healthy and that
`proxima-db-init` created the `infisical` database:

```bash
docker exec proxima-db psql -U proxima -d infisical -c '\dt' | head
```

**PostgreSQL logs `relation "infisical_migrations" does not exist`**

Harmless, first boot only — Infisical probes for its migrations table before
creating it. A long checkpoint right afterwards is the migration write burst.
Confirm it finished with the `\dt` command above (expect hundreds of tables).

**`Task exception was never retrieved` from `docker_registry_service`**

Docker Hub rate-limits unauthenticated pagination per source IP and answers 403.
Benign: the official-images catalog is a cache, the daily loop retries, and only
the Docker image browser's "official" list is affected.

**Updates tab shows no new releases, and "latest" never resolves**

Backend log:

```
WARNING src.services.update_check — Harbor tag listing failed for
proxima-backend/app: Client error '401 Unauthorized' for url
'https://.../v2/proxima-backend/app/tags/list'
```

The update check is authenticating as nobody. Check what the container actually
got — not what you typed into Portainer:

```bash
docker inspect proxima-backend --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E 'REGISTRY_(USERNAME|PASSWORD)='
```

Three ways this ends up wrong, all silent:

1. **Neither is set.** Images still pull fine, because Portainer authenticates
   the *pull* from its own stored registry credentials — the backend never sees
   them. The two are unrelated paths.
2. **Username only.** A username with an empty password is *worse* than none:
   the registry issues a valid token for empty-password basic auth carrying only
   anonymous scope, so you get a bare 401 with no hint credentials were at fault.
   Recent builds log an explicit "credentials are incomplete" warning.
3. **The `$` was interpolated** out of a Harbor robot name — see the note in
   [Step 2](#step-2--deploy-the-backend-stack).

Confirm the credentials themselves are good, independent of Proxima:

```bash
U='robot$yourname'; P='<token>'; REPO=proxima-backend/app
TOK=$(curl -s -u "$U:$P" \
  "https://updates.dev-proxima.com/service/token?service=harbor-registry&scope=repository:$REPO:pull" \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
curl -s -H "Authorization: Bearer $TOK" \
  "https://updates.dev-proxima.com/v2/$REPO/tags/list"
```

A tag list means the robot is fine and the problem is how the variables reached
the container. A 401 means the robot lacks *pull* on that Harbor project —
robot accounts are scoped per project, so each one (`proxima-backend`,
`proxima-frontend`, `proxima-backend-nginx`, `proxima-infisical-bootstrap`,
`proxima-docker-module`, `proxima-flow-agent`) must be granted separately.

**Signing out does not revoke the session; brute-force limits do nothing**

`proxima-valkey` is not running. Both paths fail **open**:
`is_token_blacklisted()` returns `False` and `check_rate_limit()` returns
`(True, max)`, so the login (5/15m), TOTP (3/5m) and password-reset (3/hr) caps
are all inert.

### Installer

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
| `proxima-valkey` | `valkey/valkey:8-alpine` | Token revocation + rate limiting, and Infisical's session cache |
| `proxima-infisical` | `infisical/infisical` | Secret store — holds every Proxmox credential |
| `proxima-jwt-key-init` | `alpine/openssl` | One-shot: generates the RS256 token-signing keypair, then exits |
| `proxima-db-init` | `postgres:18-alpine` | One-shot: creates the `infisical` database, then exits |
| `proxima-infisical-bootstrap` | `proxima-infisical-bootstrap/app` | One-shot: provisions the Machine Identities and PKI, then exits |

`proxima-jwt-key-init` is expected to show as **Exited (0)** — it runs once at
install and on each `up` to make sure the signing keys exist. The keys live in a
Docker volume so sessions survive restarts.

---

## License

Proxima Community Edition. Use of the container images requires valid community
credentials.
