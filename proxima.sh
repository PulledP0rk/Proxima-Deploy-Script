#!/usr/bin/env bash
set -euo pipefail

# ── Proxima Installer ────────────────────────────────────────────
# Usage: curl -s https://get.dev-proxima.com/ | bash
# Or:    bash proxima.sh

REGISTRY="updates.dev-proxima.com"
INSTALL_DIR="./proxima"
VERSION="0.1.0"
LOGFILE="./proxima-install.log"

# ── Colors & Formatting ─────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'
C_RED='\033[31m'
C_YELLOW='\033[33m'
C_WHITE='\033[97m'

# ── Helper Functions ─────────────────────────────────────────────
log()     { printf "[%s] %s\n" "$(date -u +"%Y-%m-%d %H:%M:%S")" "$1" >> "$LOGFILE"; }
info()    { printf "${C_CYAN}  ▸ ${C_WHITE}%s${C_RESET}\n" "$1"; log "INFO: $1"; }
success() { printf "${C_GREEN}  ✓ ${C_WHITE}%s${C_RESET}\n" "$1"; log "OK:   $1"; }
error()   { printf "${C_RED}  ✗ %s${C_RESET}\n" "$1"; log "ERR:  $1"; }
warn()    { printf "${C_YELLOW}  ! %s${C_RESET}\n" "$1"; log "WARN: $1"; }
debug()   { printf "${C_DIM}    %s${C_RESET}\n" "$1"; log "DBG:  $1"; }
divider() { printf "${C_DIM}  ──────────────────────────────────────────────${C_RESET}\n"; }

# ── Interactive Input ────────────────────────────────────────────
# Prompts read from the controlling terminal, NOT stdin.
#
# The documented usage is `curl -s https://get.dev-proxima.com/ | bash`, which
# hands the SCRIPT itself to bash on stdin. A bare `read` would then consume
# the script's own remaining source as the user's answer — silently eating
# whole functions and leaving every prompted variable filled with shell code.
#
# When there is no controlling terminal (CI, or `bash proxima.sh < answers.txt`)
# fall back to stdin so deliberately non-interactive runs still work.
# NB: test by actually OPENING /dev/tty. A `[ -r /dev/tty ]` check passes even
# with no controlling terminal — the device node exists and is readable, but
# the open then fails with ENXIO ("No such device or address").
if { : < /dev/tty; } 2>/dev/null; then
    INPUT_SRC="/dev/tty"
else
    INPUT_SRC=""
fi

# prompt_read <varname> [silent]
# Reads one line into the named variable. Pass "silent" to suppress echo
# (for secrets). Never aborts on EOF — callers validate the value instead.
prompt_read() {
    local __var="$1"
    local __silent="${2:-}"
    local __value=""

    if [ -n "$INPUT_SRC" ]; then
        if [ "$__silent" = "silent" ]; then
            read -r -s __value < "$INPUT_SRC" || true
        else
            read -r __value < "$INPUT_SRC" || true
        fi
    else
        if [ "$__silent" = "silent" ]; then
            read -r -s __value || true
        else
            read -r __value || true
        fi
    fi

    printf -v "$__var" '%s' "$__value"
}

# ── Banner ───────────────────────────────────────────────────────
show_banner() {
    # Start the log file
    printf "=== Proxima Installer v%s — %s ===\n" "$VERSION" "$(date -u)" > "$LOGFILE"
    log "Platform: $(uname -srm)"
    log "Shell: $BASH_VERSION"
    log "Working directory: $(pwd)"

    clear
    printf "${C_CYAN}${C_BOLD}"
    cat << 'BANNER'

    ╔═══════════════════════════════════════════════════════╗
    ║    _____  _____   ______   _______ __  __             ║
    ║   |  __ \|  __ \ / __ \ \ / /_   _|  \/  |   /\       ║
    ║   | |__) | |__) | |  | \ / /  | | | \  / |  /  \      ║
    ║   |  ___/|  _  /| |  |  / \   | | | |\/| | / /\ \     ║
    ║   | |    | | \ \| |__| / \ \ _| |_| |  | |/ /  \ \    ║
    ║   |_|    |_|  \_\\____/_/ \_\_____|_|  |_/_/    \_\   ║
    ║                                                       ║
    ╚═══════════════════════════════════════════════════════╝
BANNER
    printf "${C_RESET}"
    printf "${C_DIM}           Community Edition Installer v%s${C_RESET}\n\n" "$VERSION"
}

# ── Detect Existing Installation ─────────────────────────────────
detect_existing() {
    local found=0
    local containers=("proxima-frontend" "proxima-backend" "proxima-db" "proxima-sidecar")

    # Check if docker is available before scanning
    if ! command -v docker &>/dev/null; then
        return
    fi

    for name in "${containers[@]}"; do
        local status
        status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)
        if [ -n "$status" ]; then
            if [ "$found" -eq 0 ]; then
                divider
                printf "${C_BOLD}${C_YELLOW}  Existing Proxima Installation Detected${C_RESET}\n\n"
                printf "${C_WHITE}  %-22s %-10s %s${C_RESET}\n" "CONTAINER" "STATUS" "COMPOSE FILE"
                printf "${C_DIM}  %-22s %-10s %s${C_RESET}\n" "─────────────────────" "─────────" "────────────────────────────"
                found=1
            fi
            # Get the compose file path from labels
            local compose_dir
            compose_dir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name" 2>/dev/null || true)
            local compose_file="${compose_dir:--}/docker-compose.yml"

            local status_color="$C_GREEN"
            if [ "$status" != "running" ]; then
                status_color="$C_RED"
            fi

            printf "  ${C_WHITE}%-22s${C_RESET} ${status_color}%-10s${C_RESET} ${C_DIM}%s${C_RESET}\n" "$name" "$status" "$compose_file"
        fi
    done

    if [ "$found" -eq 1 ]; then
        echo
        warn "An existing installation was found."
        printf "${C_DIM}  Continuing will create a new installation in %s${C_RESET}\n" "$INSTALL_DIR"
        printf "${C_DIM}  The existing containers above will NOT be affected.${C_RESET}\n"
        echo
        printf "${C_YELLOW}  Continue with new installation? [y/N]: ${C_RESET}"
        prompt_read CONTINUE
        if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
            info "Installation cancelled."
            exit 0
        fi
        echo
    fi
}

# ── Package Manager Helper ──────────────────────────────────────
# Installs packages with whichever package manager the distro provides.
# Best-effort: callers verify the resulting binary rather than the exit code.
#
# Every command reads from /dev/null. Package managers happily consume stdin,
# and under `curl … | bash` this script's stdin IS its own source — a child
# that reads it swallows the rest of the installer. It would also eat answers
# the user has already typed ahead of a slow install.
pkg_install() {
    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq < /dev/null >> "$LOGFILE" 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" < /dev/null >> "$LOGFILE" 2>&1 || true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "$@" < /dev/null >> "$LOGFILE" 2>&1 || true
    elif command -v yum &>/dev/null; then
        yum install -y -q "$@" < /dev/null >> "$LOGFILE" 2>&1 || true
    elif command -v zypper &>/dev/null; then
        zypper --non-interactive install "$@" < /dev/null >> "$LOGFILE" 2>&1 || true
    fi
}

# ── Docker Installation ─────────────────────────────────────────
# A fresh container or VM has no Docker, so install it rather than sending
# the user away. Uses Docker's official convenience script, which sets up the
# right repo + signing keys and installs docker-ce together with the Compose
# V2 plugin on Debian, Ubuntu, Fedora, CentOS, RHEL and SLES.
install_docker() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Docker is not installed, and this installer is not running as root."
        printf "${C_DIM}    Re-run as root (or install Docker yourself first):${C_RESET}\n"
        printf "${C_DIM}      https://docs.docker.com/engine/install/${C_RESET}\n"
        exit 1
    fi

    info "Docker not found — installing Docker Engine..."
    log "Installing Docker via get.docker.com"

    # Minimal container images often ship without curl or CA certificates.
    if ! command -v curl &>/dev/null; then
        debug "Installing curl..."
        pkg_install curl ca-certificates
    fi
    if ! command -v curl &>/dev/null; then
        error "curl is required to install Docker, and it could not be installed."
        printf "${C_DIM}    Install curl manually, then re-run this installer.${C_RESET}\n"
        exit 1
    fi

    debug "Downloading Docker install script..."
    if ! curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>> "$LOGFILE"; then
        error "Could not download the Docker install script from get.docker.com."
        printf "${C_DIM}    Check network access and DNS, then re-run.${C_RESET}\n"
        exit 1
    fi

    debug "Running Docker install (this takes a minute)..."
    # </dev/null for the same reason as pkg_install — get-docker.sh and the
    # dpkg/rpm work it drives must not read this script's stdin.
    if ! sh /tmp/get-docker.sh < /dev/null >> "$LOGFILE" 2>&1; then
        rm -f /tmp/get-docker.sh
        error "Docker installation failed. See $LOGFILE for details."
        exit 1
    fi
    rm -f /tmp/get-docker.sh

    # Packages usually start the daemon; make it explicit and persistent.
    if command -v systemctl &>/dev/null; then
        systemctl enable docker < /dev/null >> "$LOGFILE" 2>&1 || true
        systemctl start  docker < /dev/null >> "$LOGFILE" 2>&1 || true
    fi

    if ! docker info &>/dev/null; then
        error "Docker installed, but the daemon is not responding."
        # Much the most common cause on Proxmox: the container was created
        # without nesting, which Docker requires and which can only be set
        # from the host.
        if grep -qaF 'container=lxc' /proc/1/environ 2>/dev/null || [ -f /run/systemd/container ]; then
            echo
            warn "This looks like an LXC container."
            printf "${C_DIM}    Docker requires nesting. On the Proxmox host run:${C_RESET}\n"
            printf "${C_DIM}      pct set <vmid> --features nesting=1${C_RESET}\n"
            printf "${C_DIM}    then restart the container and re-run this installer.${C_RESET}\n"
        fi
        printf "${C_DIM}    Daemon logs: journalctl -u docker --no-pager -n 50${C_RESET}\n"
        exit 1
    fi

    success "Docker installed"
    log "Docker installed successfully"
}

# ── Prerequisite Checks ─────────────────────────────────────────
check_prerequisites() {
    info "Checking prerequisites..."
    echo

    # Install Docker if it is missing, rather than failing the run.
    if ! command -v docker &>/dev/null; then
        install_docker
    fi

    # An existing Docker install predating Compose V2 (or a partial install)
    # can leave the plugin missing — pull just that piece in.
    if command -v docker &>/dev/null && ! docker compose version &>/dev/null; then
        info "Docker Compose V2 plugin not found — installing..."
        pkg_install docker-compose-plugin
    fi

    local missing=0

    if command -v docker &>/dev/null; then
        success "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)"
    else
        error "Docker is not installed"
        missing=1
    fi

    if docker compose version &>/dev/null; then
        success "Docker Compose $(docker compose version --short 2>/dev/null || echo 'available')"
    else
        error "Docker Compose is not installed (requires Docker Compose V2)"
        missing=1
    fi

    echo
    if [ "$missing" -eq 1 ]; then
        error "Missing prerequisites that could not be installed automatically."
        printf "${C_DIM}    https://docs.docker.com/get-docker/${C_RESET}\n"
        printf "${C_DIM}    See %s for details.${C_RESET}\n" "$LOGFILE"
        exit 1
    fi
}

# ── Credential Prompt ────────────────────────────────────────────
prompt_credentials() {
    divider
    printf "${C_BOLD}${C_WHITE}  Registry Authentication${C_RESET}\n"
    printf "${C_DIM}  Enter your Proxima community credentials${C_RESET}\n\n"

    printf "${C_YELLOW}  Username: ${C_RESET}"
    prompt_read REGISTRY_USER
    printf "${C_YELLOW}  License Key: ${C_RESET}"
    prompt_read REGISTRY_PASS silent
    echo

    if [ -z "$REGISTRY_USER" ] || [ -z "$REGISTRY_PASS" ]; then
        echo
        error "Username and license key are required."
        exit 1
    fi

    echo
    info "Authenticating with registry..."
    log "Docker login to $REGISTRY as $REGISTRY_USER"

    if echo "$REGISTRY_PASS" | docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin &>/dev/null; then
        success "Authentication successful"
    else
        echo
        error "Authentication failed. Please check your credentials."
        log "Docker login command failed (exit $?)"
        exit 1
    fi
    echo
}

# ── Component Selection ──────────────────────────────────────────
select_components() {
    divider
    printf "${C_BOLD}${C_WHITE}  Component Selection${C_RESET}\n\n"
    printf "${C_WHITE}  ┌─────────────────────────────────────────────┐${C_RESET}\n"
    printf "${C_WHITE}  │                                             │${C_RESET}\n"
    printf "${C_WHITE}  │  ${C_CYAN}[1]${C_WHITE}  Frontend Only                       │${C_RESET}\n"
    printf "${C_DIM}  │       NGINX + SPA web interface             │${C_RESET}\n"
    printf "${C_DIM}  │       Connects to a remote backend API      │${C_RESET}\n"
    printf "${C_WHITE}  │                                             │${C_RESET}\n"
    printf "${C_WHITE}  │  ${C_CYAN}[2]${C_WHITE}  Backend Only                        │${C_RESET}\n"
    printf "${C_DIM}  │       API + Database + Sidecar               │${C_RESET}\n"
    printf "${C_DIM}  │       API exposed on :8443                   │${C_RESET}\n"
    printf "${C_WHITE}  │                                             │${C_RESET}\n"
    printf "${C_WHITE}  │  ${C_CYAN}[3]${C_WHITE}  Full Stack ${C_GREEN}(Recommended)${C_WHITE}            │${C_RESET}\n"
    printf "${C_DIM}  │       Frontend + Backend + Database         │${C_RESET}\n"
    printf "${C_DIM}  │       Web UI :8086 — API :8443              │${C_RESET}\n"
    printf "${C_WHITE}  │                                             │${C_RESET}\n"
    printf "${C_WHITE}  └─────────────────────────────────────────────┘${C_RESET}\n"
    echo

    printf "${C_YELLOW}  Select [1/2/3]: ${C_RESET}"
    prompt_read SELECTION

    case "$SELECTION" in
        1) COMPONENT="frontend" ;;
        2) COMPONENT="backend" ;;
        3) COMPONENT="both" ;;
        *)
            error "Invalid selection."
            exit 1
            ;;
    esac

    echo
    success "Selected: $COMPONENT"
    log "Component selection: $COMPONENT"
    echo
}

# ── Backend Address Prompt ───────────────────────────────────────
prompt_backend_address() {
    # Backend-only installs have no frontend to configure
    if [ "$COMPONENT" = "backend" ]; then
        BACKEND_ADDR=""
        BACKEND_PORT="8443"
        log "Backend-only mode — skipping backend address prompt"
        return
    fi

    divider
    printf "${C_BOLD}${C_WHITE}  Backend Connection${C_RESET}\n"

    if [ "$COMPONENT" = "both" ]; then
        printf "${C_DIM}  Both services will run on this host.${C_RESET}\n"
        printf "${C_DIM}  The frontend auto-detects the backend from the browser URL.${C_RESET}\n\n"
        BACKEND_ADDR=""
        printf "${C_YELLOW}  Backend API port [8443]: ${C_RESET}"
        prompt_read BACKEND_PORT
        BACKEND_PORT="${BACKEND_PORT:-8443}"
        echo
        success "Backend API port: $BACKEND_PORT"
        log "Full-stack mode — VITE_API_URL=auto-detect, BACKEND_PORT=$BACKEND_PORT"
    else
        printf "${C_DIM}  Enter the IP address or FQDN of your Proxima backend.${C_RESET}\n"
        printf "${C_DIM}  This must be reachable from end-user browsers.${C_RESET}\n\n"
        printf "${C_YELLOW}  Backend address: ${C_RESET}"
        prompt_read BACKEND_ADDR
        if [ -z "$BACKEND_ADDR" ]; then
            error "Backend address is required for frontend-only installs."
            exit 1
        fi

        printf "${C_YELLOW}  Backend port [8443]: ${C_RESET}"
        prompt_read BACKEND_PORT
        BACKEND_PORT="${BACKEND_PORT:-8443}"

        echo
        success "Backend: $BACKEND_ADDR:$BACKEND_PORT"
        log "Frontend-only mode — BACKEND_ADDR=$BACKEND_ADDR BACKEND_PORT=$BACKEND_PORT"
    fi
    echo
}

# ── Backend Reachability Check ──────────────────────────────────
check_backend_reachable() {
    # Only check for frontend-only installs (backend should already be running)
    if [ "$COMPONENT" != "frontend" ]; then
        return
    fi

    divider
    printf "${C_BOLD}${C_WHITE}  Backend Reachability Check${C_RESET}\n\n"

    local url="http://${BACKEND_ADDR}:${BACKEND_PORT}/api/health"
    info "Testing connection to $url ..."
    log "Reachability check: curl -sf --connect-timeout 5 $url"

    local http_code
    http_code=$(curl -sf --connect-timeout 5 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)

    if [ "$http_code" = "200" ]; then
        success "Backend API is reachable (HTTP $http_code)"
        log "Backend reachable: HTTP $http_code"
    else
        echo
        if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
            error "Cannot reach backend at $url"
            warn "Connection refused or timed out."
            log "Backend unreachable: connection failed"
        else
            error "Backend returned HTTP $http_code at $url"
            log "Backend returned unexpected HTTP $http_code"
        fi
        echo
        printf "${C_DIM}  Possible causes:${C_RESET}\n"
        printf "${C_DIM}    - Backend is not running at $BACKEND_ADDR${C_RESET}\n"
        printf "${C_DIM}    - Port $BACKEND_PORT is blocked by a firewall${C_RESET}\n"
        printf "${C_DIM}    - Wrong address or port${C_RESET}\n"
        echo
        printf "${C_YELLOW}  Install frontend anyway? [y/N]: ${C_RESET}"
        prompt_read CONTINUE
        if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
            info "Installation cancelled."
            exit 0
        fi
        echo
    fi
}

# ── Generate .env ────────────────────────────────────────────────
write_env_file() {
    local pg_pass
    pg_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)

    cat > "$INSTALL_DIR/.env" << ENVEOF
# Proxima — Environment Configuration
# Generated by installer on $(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Port the web UI listens on (frontend)
WEBUI_PORT=8086

# Backend API port
BACKEND_PORT=${BACKEND_PORT:-8443}

# PostgreSQL Database
POSTGRES_USER=proxima
POSTGRES_PASSWORD=${pg_pass}
POSTGRES_DB=proxima_db

# Container Registry (for sidecar auto-updates)
REGISTRY_URL=${REGISTRY}
REGISTRY_USERNAME=${REGISTRY_USER}
REGISTRY_PASSWORD=${REGISTRY_PASS}

# Image names
FRONTEND_IMAGE=proxima-frontend/app
BACKEND_IMAGE=proxima-backend/app

# Release channel: stable | beta
UPDATE_CHANNEL=stable

# How often the sidecar checks for new tags (minutes, 0 to disable)
CHECK_INTERVAL_MINUTES=60

# Version label
PROXIMA_VERSION=${VERSION}
ENVEOF
}

# ── Generate Frontend Upstream Hook ──────────────────────────────
# The stock frontend image ships nginx-standalone.conf, which hardcodes
#
#     set $proxima_backend_upstream "https://backend-nginx:8443";
#
# pointing at the mTLS terminator used by the full Proxima compose. This
# installer's topology has no backend-nginx service, and the backend image
# speaks plain HTTP on 8443, so every /api and /ws request would fail — first
# on DNS ("backend-nginx could not be resolved"), then on the TLS handshake.
#
# This hook drops into /docker-entrypoint.d/, which the official NGINX
# entrypoint runs AFTER proxima-entrypoint.sh has copied the mode config into
# default.conf and BEFORE nginx starts — the one safe place to repoint it.
write_upstream_hook() {
    cat > "$INSTALL_DIR/frontend-upstream.sh" << 'HOOKEOF'
#!/bin/sh
# Repoint the frontend NGINX /api + /ws proxy at this deployment's backend.
# Generated by the Proxima installer — see docker-compose.yml.
set -e

CONF="/etc/nginx/conf.d/default.conf"

[ -n "${PROXIMA_BACKEND_UPSTREAM:-}" ] || exit 0
[ -f "$CONF" ] || exit 0

# Literal substring match (index), not a pattern — the upstream value
# contains '/' and '.' and must never be interpreted.
awk -v up="$PROXIMA_BACKEND_UPSTREAM" '
    index($0, "set $proxima_backend_upstream") {
        print "    set $proxima_backend_upstream \"" up "\";"
        next
    }
    { print }
' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"

echo "  Proxima backend upstream → $PROXIMA_BACKEND_UPSTREAM"
HOOKEOF
    chmod +x "$INSTALL_DIR/frontend-upstream.sh"
}

# ── Generate Frontend-Only Compose ───────────────────────────────
write_compose_frontend() {
    local upstream="http://${BACKEND_ADDR}:${BACKEND_PORT}"

    cat > "$INSTALL_DIR/docker-compose.yml" << COMPEOF
# Proxima — Frontend Only
# Generated by Proxima installer
# Backend API proxied server-side to: ${upstream}

services:
  # ── Frontend SPA (NGINX) ────────────────────────────────────
  frontend:
    image: updates.dev-proxima.com/proxima-frontend/app:latest
    container_name: proxima-frontend
    restart: unless-stopped
    ports:
      # The SPA is served over HTTPS on container port 8086. Container port
      # 80 is a redirect-only server block (301 -> https://\$host), so mapping
      # the host port to :80 would bounce browsers to an unpublished :443.
      - "\${WEBUI_PORT:-8086}:8086"
    environment:
      # Same-origin API: the browser only ever talks to this host over HTTPS
      # and NGINX proxies /api + /ws to the backend server-side. An absolute
      # http:// API URL would be blocked by the browser as mixed content.
      - VITE_API_URL=/api
      - PROXIMA_BACKEND_UPSTREAM=${upstream}
    volumes:
      - ./frontend-upstream.sh:/docker-entrypoint.d/45-proxima-upstream.sh:ro
      - themes-data:/usr/share/nginx/html/themes
      - branding-data:/usr/share/nginx/html/branding
    labels:
      - "proxima.managed=true"
      - "proxima.component=frontend"
      - "proxima.version=\${PROXIMA_VERSION:-0.1.0}"
    networks:
      - proxima-net

  # ── Update Sidecar ─────────────────────────────────────────
  sidecar:
    image: updates.dev-proxima.com/proxima-sidecar/app:latest
    container_name: proxima-sidecar
    restart: unless-stopped
    environment:
      - REGISTRY_URL=\${REGISTRY_URL:-}
      - REGISTRY_USERNAME=\${REGISTRY_USERNAME:-}
      - REGISTRY_PASSWORD=\${REGISTRY_PASSWORD:-}
      - FRONTEND_IMAGE=\${FRONTEND_IMAGE:-proxima-frontend/app}
      - BACKEND_IMAGE=\${BACKEND_IMAGE:-proxima-backend/app}
      - UPDATE_CHANNEL=\${UPDATE_CHANNEL:-stable}
      - CHECK_INTERVAL_MINUTES=\${CHECK_INTERVAL_MINUTES:-60}
      - PROXIMA_VERSION=\${PROXIMA_VERSION:-0.1.0}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - sidecar-state:/data
    networks:
      - proxima-net

networks:
  proxima-net:
    name: proxima-net

volumes:
  sidecar-state:
  themes-data:
  branding-data:
COMPEOF
}

# ── Generate Backend-Only Compose ────────────────────────────────
write_compose_backend() {
    cat > "$INSTALL_DIR/docker-compose.yml" << 'COMPEOF'
# Proxima — Backend + Database
# Generated by Proxima installer
# API: http://localhost:8443/api

services:
  # ── PostgreSQL Database ─────────────────────────────────────
  db:
    image: postgres:18-alpine
    container_name: proxima-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-proxima}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-proxima}
      POSTGRES_DB: ${POSTGRES_DB:-proxima_db}
    volumes:
      - db-data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-proxima} -d ${POSTGRES_DB:-proxima_db}"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - proxima-net

  # ── Backend API Server ──────────────────────────────────────
  backend:
    image: updates.dev-proxima.com/proxima-backend/app:latest
    container_name: proxima-backend
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      jwt-key-init:
        condition: service_completed_successfully
    ports:
      - "${BACKEND_PORT:-8443}:8443"
    environment:
      - PD_FRONTEND_ORIGINS=*
      - DB_HOST=db
      - DB_PORT=5432
      - DB_USER=${POSTGRES_USER:-proxima}
      - DB_PASS=${POSTGRES_PASSWORD:-proxima}
      - DB_NAME=${POSTGRES_DB:-proxima_db}
      - SIDECAR_URL=http://sidecar:9009
      - PROXIMA_VERSION=${PROXIMA_VERSION:-0.1.0}
      - FRONTEND_DIST_PATH=/shared-assets
    volumes:
      - backend-secrets:/app/data
      - jwt-keys:/app/keys
      - themes-data:/shared-assets/themes
      - branding-data:/shared-assets/branding
    labels:
      - "proxima.managed=true"
      - "proxima.component=backend"
      - "proxima.version=${PROXIMA_VERSION:-0.1.0}"
    networks:
      - proxima-net
      - proxima-internal

  # ── JWT Signing Keys (one-shot init) ────────────────────────
  # The backend signs access tokens with RS256, reading the key pair from
  # /app/keys (settings.jwt_private_key_path defaults to ./keys/jwt_private.pem
  # and the workdir is /app). The published image ships no keys — they are
  # per-deployment secrets — and nothing generates them at startup, so login
  # authenticates the user and then dies with HTTP 500
  # (FileNotFoundError: './keys/jwt_private.pem') when issuing the token.
  # The keys live in a named volume so sessions survive a restart; rotating
  # them invalidates every issued token. openssl is already in the image, so
  # no network access is needed.
  jwt-key-init:
    image: alpine/openssl:latest
    container_name: proxima-jwt-key-init
    restart: "no"
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        if [ ! -s /keys/jwt_private.pem ] || [ ! -s /keys/jwt_public.pem ]; then
          openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /keys/jwt_private.pem && \
          openssl pkey -in /keys/jwt_private.pem -pubout -out /keys/jwt_public.pem && \
          chmod 600 /keys/jwt_private.pem && \
          chmod 644 /keys/jwt_public.pem && \
          echo "[jwt-key-init] generated RS256 signing keypair"
        else
          echo "[jwt-key-init] JWT keys already present"
        fi
    volumes:
      - jwt-keys:/keys
    networks:
      - proxima-internal

  # ── Update Sidecar ─────────────────────────────────────────
  sidecar:
    image: updates.dev-proxima.com/proxima-sidecar/app:latest
    container_name: proxima-sidecar
    restart: unless-stopped
    environment:
      - REGISTRY_URL=${REGISTRY_URL:-}
      - REGISTRY_USERNAME=${REGISTRY_USERNAME:-}
      - REGISTRY_PASSWORD=${REGISTRY_PASSWORD:-}
      - FRONTEND_IMAGE=${FRONTEND_IMAGE:-proxima-frontend/app}
      - BACKEND_IMAGE=${BACKEND_IMAGE:-proxima-backend/app}
      - UPDATE_CHANNEL=${UPDATE_CHANNEL:-stable}
      - CHECK_INTERVAL_MINUTES=${CHECK_INTERVAL_MINUTES:-60}
      - PROXIMA_VERSION=${PROXIMA_VERSION:-0.1.0}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - sidecar-state:/data
    networks:
      - proxima-internal

networks:
  proxima-net:
    name: proxima-net
  proxima-internal:
    name: proxima-internal
    internal: true

volumes:
  db-data:
  sidecar-state:
  backend-secrets:
  jwt-keys:
  themes-data:
  branding-data:
COMPEOF
}

# ── Generate Full Stack Compose ──────────────────────────────────
write_compose_both() {
    cat > "$INSTALL_DIR/docker-compose.yml" << 'COMPEOF'
# Proxima — Full Stack
# Generated by Proxima installer
# Web UI:  http://localhost:8086
# API:     http://localhost:8443/api

services:
  # ── PostgreSQL Database ─────────────────────────────────────
  db:
    image: postgres:18-alpine
    container_name: proxima-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-proxima}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-proxima}
      POSTGRES_DB: ${POSTGRES_DB:-proxima_db}
    volumes:
      - db-data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-proxima} -d ${POSTGRES_DB:-proxima_db}"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - proxima-net

  # ── Backend API Server ──────────────────────────────────────
  backend:
    image: updates.dev-proxima.com/proxima-backend/app:latest
    container_name: proxima-backend
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      jwt-key-init:
        condition: service_completed_successfully
    ports:
      - "${BACKEND_PORT:-8443}:8443"
    environment:
      - PD_FRONTEND_ORIGINS=*
      - DB_HOST=db
      - DB_PORT=5432
      - DB_USER=${POSTGRES_USER:-proxima}
      - DB_PASS=${POSTGRES_PASSWORD:-proxima}
      - DB_NAME=${POSTGRES_DB:-proxima_db}
      - SIDECAR_URL=http://sidecar:9009
      - PROXIMA_VERSION=${PROXIMA_VERSION:-0.1.0}
      - FRONTEND_DIST_PATH=/shared-assets
    volumes:
      - backend-secrets:/app/data
      - jwt-keys:/app/keys
      - themes-data:/shared-assets/themes
      - branding-data:/shared-assets/branding
    labels:
      - "proxima.managed=true"
      - "proxima.component=backend"
      - "proxima.version=${PROXIMA_VERSION:-0.1.0}"
    networks:
      - proxima-net
      - proxima-internal

  # ── JWT Signing Keys (one-shot init) ────────────────────────
  # The backend signs access tokens with RS256, reading the key pair from
  # /app/keys (settings.jwt_private_key_path defaults to ./keys/jwt_private.pem
  # and the workdir is /app). The published image ships no keys — they are
  # per-deployment secrets — and nothing generates them at startup, so login
  # authenticates the user and then dies with HTTP 500
  # (FileNotFoundError: './keys/jwt_private.pem') when issuing the token.
  # The keys live in a named volume so sessions survive a restart; rotating
  # them invalidates every issued token. openssl is already in the image, so
  # no network access is needed.
  jwt-key-init:
    image: alpine/openssl:latest
    container_name: proxima-jwt-key-init
    restart: "no"
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        if [ ! -s /keys/jwt_private.pem ] || [ ! -s /keys/jwt_public.pem ]; then
          openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /keys/jwt_private.pem && \
          openssl pkey -in /keys/jwt_private.pem -pubout -out /keys/jwt_public.pem && \
          chmod 600 /keys/jwt_private.pem && \
          chmod 644 /keys/jwt_public.pem && \
          echo "[jwt-key-init] generated RS256 signing keypair"
        else
          echo "[jwt-key-init] JWT keys already present"
        fi
    volumes:
      - jwt-keys:/keys
    networks:
      - proxima-internal

  # ── Frontend SPA (NGINX) ────────────────────────────────────
  frontend:
    image: updates.dev-proxima.com/proxima-frontend/app:latest
    container_name: proxima-frontend
    restart: unless-stopped
    depends_on:
      - backend
    ports:
      # The SPA is served over HTTPS on container port 8086. Container port
      # 80 is a redirect-only server block (301 -> https://$host), so mapping
      # the host port to :80 would bounce browsers to an unpublished :443.
      - "${WEBUI_PORT:-8086}:8086"
    environment:
      # Same-origin API: the browser only ever talks to this host over HTTPS
      # and NGINX proxies /api + /ws to the backend server-side. An absolute
      # http:// API URL would be blocked by the browser as mixed content.
      - VITE_API_URL=/api
      - PROXIMA_BACKEND_UPSTREAM=http://backend:8443
    volumes:
      - ./frontend-upstream.sh:/docker-entrypoint.d/45-proxima-upstream.sh:ro
      - themes-data:/usr/share/nginx/html/themes
      - branding-data:/usr/share/nginx/html/branding
    labels:
      - "proxima.managed=true"
      - "proxima.component=frontend"
      - "proxima.version=${PROXIMA_VERSION:-0.1.0}"
    networks:
      - proxima-net

  # ── Update Sidecar ─────────────────────────────────────────
  sidecar:
    image: updates.dev-proxima.com/proxima-sidecar/app:latest
    container_name: proxima-sidecar
    restart: unless-stopped
    environment:
      - REGISTRY_URL=${REGISTRY_URL:-}
      - REGISTRY_USERNAME=${REGISTRY_USERNAME:-}
      - REGISTRY_PASSWORD=${REGISTRY_PASSWORD:-}
      - FRONTEND_IMAGE=${FRONTEND_IMAGE:-proxima-frontend/app}
      - BACKEND_IMAGE=${BACKEND_IMAGE:-proxima-backend/app}
      - UPDATE_CHANNEL=${UPDATE_CHANNEL:-stable}
      - CHECK_INTERVAL_MINUTES=${CHECK_INTERVAL_MINUTES:-60}
      - PROXIMA_VERSION=${PROXIMA_VERSION:-0.1.0}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - sidecar-state:/data
    networks:
      - proxima-internal

networks:
  proxima-net:
    name: proxima-net
  proxima-internal:
    name: proxima-internal
    internal: true

volumes:
  db-data:
  sidecar-state:
  backend-secrets:
  jwt-keys:
  themes-data:
  branding-data:
COMPEOF
}

# ── Deploy ───────────────────────────────────────────────────────
deploy() {
    divider
    printf "${C_BOLD}${C_WHITE}  Deploying Proxima${C_RESET}\n\n"

    info "Creating install directory: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    # Generate files based on component selection
    info "Generating configuration files..."
    write_env_file
    log "Wrote .env to $INSTALL_DIR/.env"

    case "$COMPONENT" in
        frontend)
            write_compose_frontend
            write_upstream_hook
            log "Wrote frontend-only docker-compose.yml"
            debug "VITE_API_URL=/api (same-origin — NGINX proxies to the backend)"
            debug "PROXIMA_BACKEND_UPSTREAM=http://${BACKEND_ADDR}:${BACKEND_PORT}"
            debug "WEBUI_PORT=${WEBUI_PORT:-8086} (host) → 8086 (container, HTTPS)"
            ;;
        backend)
            write_compose_backend
            log "Wrote backend-only docker-compose.yml"
            debug "BACKEND_PORT=${BACKEND_PORT} (host) → 8443 (container)"
            debug "PD_FRONTEND_ORIGINS=*"
            ;;
        both)
            write_compose_both
            write_upstream_hook
            log "Wrote full-stack docker-compose.yml"
            debug "VITE_API_URL=/api (same-origin — NGINX proxies to the backend)"
            debug "PROXIMA_BACKEND_UPSTREAM=http://backend:8443"
            debug "BACKEND_PORT=${BACKEND_PORT} (host) → 8443 (container)"
            debug "WEBUI_PORT=8086 (host) → 8086 (container, HTTPS)"
            debug "PD_FRONTEND_ORIGINS=* (CORS allows all origins)"
            ;;
    esac
    success "Configuration files written"
    echo

    # Log generated compose file for diagnostics
    log "--- docker-compose.yml ---"
    cat "$INSTALL_DIR/docker-compose.yml" >> "$LOGFILE"
    log "--- end docker-compose.yml ---"

    # Pull images
    info "Pulling container images (this may take a few minutes)..."
    echo
    if (cd "$INSTALL_DIR" && docker compose pull 2>&1 | tee -a "$LOGFILE"); then
        echo
        success "Images pulled successfully"
    else
        echo
        error "Failed to pull images. Check your credentials and network."
        error "See $LOGFILE for details."
        exit 1
    fi
    echo

    # Start services
    info "Starting services..."
    if (cd "$INSTALL_DIR" && docker compose up -d 2>&1 | tee -a "$LOGFILE"); then
        echo
        success "Services started"
    else
        echo
        error "Failed to start services."
        error "See $LOGFILE for details."
        exit 1
    fi

    # Post-deploy: wait for backend health check
    if [ "$COMPONENT" != "frontend" ]; then
        echo
        info "Waiting for backend to become healthy..."
        local retries=0
        local max_retries=30
        local healthy=false
        while [ "$retries" -lt "$max_retries" ]; do
            local state
            state=$(docker inspect --format '{{.State.Health.Status}}' proxima-backend 2>/dev/null || echo "starting")
            if [ "$state" = "healthy" ]; then
                healthy=true
                break
            fi
            # Also check if backend responds on the mapped port
            local http_code
            http_code=$(curl -sf --connect-timeout 2 -o /dev/null -w "%{http_code}" "http://localhost:${BACKEND_PORT}/api/health" 2>/dev/null || true)
            if [ "$http_code" = "200" ]; then
                healthy=true
                break
            fi
            retries=$((retries + 1))
            sleep 2
        done

        if [ "$healthy" = true ]; then
            success "Backend API is healthy on port ${BACKEND_PORT}"
            log "Backend healthy after $((retries * 2))s"
        else
            warn "Backend did not become healthy within 60s"
            warn "Check logs: docker logs proxima-backend"
            log "Backend health check timed out after 60s"
            echo
            info "Container status:"
            (cd "$INSTALL_DIR" && docker compose ps 2>&1 | tee -a "$LOGFILE")
            echo
        fi
    fi
}

# ── Summary ──────────────────────────────────────────────────────
show_summary() {
    echo
    divider
    printf "${C_BOLD}${C_GREEN}"
    cat << 'DONE'

    ┌─────────────────────────────────────────┐
    │                                         │
    │      Installation Complete!              │
    │                                         │
    └─────────────────────────────────────────┘
DONE
    printf "${C_RESET}"

    printf "${C_WHITE}  Access Proxima:${C_RESET}\n"

    case "$COMPONENT" in
        frontend)
            printf "    ${C_CYAN}Web UI:  https://localhost:%s${C_RESET}\n" "${WEBUI_PORT:-8086}"
            printf "    ${C_CYAN}API:     proxied to http://%s:%s/api${C_RESET}\n" "$BACKEND_ADDR" "$BACKEND_PORT"
            echo
            printf "${C_DIM}  The UI is served over HTTPS with a self-signed certificate —${C_RESET}\n"
            printf "${C_DIM}  your browser will warn on first visit.${C_RESET}\n"
            ;;
        backend)
            printf "    ${C_CYAN}API:     http://localhost:%s/api${C_RESET}\n" "$BACKEND_PORT"
            ;;
        both)
            printf "    ${C_CYAN}Web UI:  https://localhost:%s${C_RESET}\n" "${WEBUI_PORT:-8086}"
            printf "    ${C_CYAN}API:     http://localhost:%s/api${C_RESET}\n" "$BACKEND_PORT"
            echo
            printf "${C_DIM}  The UI is served over HTTPS with a self-signed certificate —${C_RESET}\n"
            printf "${C_DIM}  your browser will warn on first visit.${C_RESET}\n"
            printf "${C_DIM}  The browser reaches the API same-origin via /api; the :%s${C_RESET}\n" "$BACKEND_PORT"
            printf "${C_DIM}  mapping is for direct API access.${C_RESET}\n"
            printf "${C_DIM}  Access via IP/FQDN for remote use (not localhost).${C_RESET}\n"
            ;;
    esac

    echo
    local abs_dir
    abs_dir=$(cd "$INSTALL_DIR" && pwd)
    printf "${C_DIM}  Install directory:  %s${C_RESET}\n" "$abs_dir"
    printf "${C_DIM}  Compose file:      %s/docker-compose.yml${C_RESET}\n" "$abs_dir"
    printf "${C_DIM}  Install log:       %s${C_RESET}\n" "$(cd "$(dirname "$LOGFILE")" && pwd)/$(basename "$LOGFILE")"
    printf "${C_DIM}  Manage services:   cd %s && docker compose [up|down|logs]${C_RESET}\n" "$INSTALL_DIR"
    echo
}

# ── Main ─────────────────────────────────────────────────────────
main() {
    show_banner
    detect_existing
    check_prerequisites
    prompt_credentials
    select_components
    prompt_backend_address
    check_backend_reachable
    deploy
    show_summary
}

main
