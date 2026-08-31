#!/usr/bin/env bash
# ── Proxima — rack console setup ────────────────────────────────────
#
# Turns an attached monitor into a permanent, unattended display of the
# Proxima backend TUI: autologin on a dedicated tty at boot, the TUI
# rendered full screen, and the screen never blanking.
#
# Escaping out is preserved: Ctrl+Alt+F2 (through F6) give ordinary
# login prompts on the other virtual terminals, so the console is a
# display, not a lockout.
#
# Idempotent — safe to re-run. Every step checks before it changes.
#
# Usage:  sudo ./setup-rack-console.sh [--user NAME] [--tty N]
#                                      [--container NAME] [--no-video]
#
# ── Design notes ────────────────────────────────────────────────────
#
# * The console user has a LOCKED password, not an empty one. Autologin
#   never consults it, so the practical effect is the "no password"
#   login that was asked for -- but an empty password would also let
#   anyone log in as that user from any other tty or over SSH. Locked
#   gives the convenience without the second door.
#
# * The user is NOT added to the `docker` group. Membership of that
#   group is root-equivalent (it can bind-mount the host filesystem into
#   a container), and this account logs in automatically with no
#   credential, so it would hand root to anyone who walks up to the
#   rack. Instead a single root-owned helper is allowed through sudo,
#   which can attach the TUI and nothing else.
#
# * The console loop is self-healing, because quitting the TUI with `q`
#   STOPS THE BACKEND CONTAINER: docker-supervisor.sh is PID 1 and ends
#   with `wait "$TUI_PID"`, so the TUI exiting takes the container with
#   it. Docker's `restart: unless-stopped` brings it back; this script
#   waits for that and re-attaches, so a stray keypress costs a short
#   outage instead of a dark screen until someone notices.
set -euo pipefail

TUI_USER=proxima-tui
TUI_TTY=1
CONTAINER=proxima-backend
DO_VIDEO=1

while [ $# -gt 0 ]; do
    case "$1" in
        --user)      TUI_USER="$2"; shift 2 ;;
        --tty)       TUI_TTY="$2"; shift 2 ;;
        --container) CONTAINER="$2"; shift 2 ;;
        --no-video)  DO_VIDEO=0; shift ;;
        -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

say() { printf '  %s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }

REBOOT_NEEDED=0

# ── 1. Console user ─────────────────────────────────────────────────
hdr "console user"
if id "$TUI_USER" >/dev/null 2>&1; then
    say "user '$TUI_USER' already exists"
else
    useradd --create-home --shell /bin/bash \
            --comment "Proxima rack console" "$TUI_USER"
    say "created user '$TUI_USER'"
fi
# Lock the password: autologin ignores it, every other path refuses it.
passwd --lock "$TUI_USER" >/dev/null
say "password locked (autologin only; no password login anywhere)"

# ── 2. Privileged helper + sudoers ──────────────────────────────────
# The ONLY thing the console account may do as root.
hdr "tui attach helper"
cat > /usr/local/bin/proxima-tui-attach <<EOF
#!/bin/sh
# Wait for the Proxima backend container, then attach its TUI.
# Root-owned and allow-listed in sudoers for the console user; keep it
# to exactly this, since anything more becomes a root escalation from
# an account that logs in with no credential.
set -eu
CONTAINER="\${1:-$CONTAINER}"
while [ "\$(docker inspect -f '{{.State.Running}}' "\$CONTAINER" 2>/dev/null)" != "true" ]; do
    echo "  waiting for \$CONTAINER to start ..."
    sleep 3
done
exec docker exec -it "\$CONTAINER" tui
EOF
chmod 0755 /usr/local/bin/proxima-tui-attach
say "installed /usr/local/bin/proxima-tui-attach"

cat > /etc/sudoers.d/proxima-console <<EOF
# Lets the Proxima rack console attach the backend TUI, and nothing
# else. Deliberately NOT membership of the docker group, which would be
# root-equivalent for an account that logs in automatically.
$TUI_USER ALL=(root) NOPASSWD: /usr/local/bin/proxima-tui-attach
EOF
chmod 0440 /etc/sudoers.d/proxima-console
visudo -cf /etc/sudoers.d/proxima-console >/dev/null
say "sudoers rule installed and validated"

# ── 3. The console loop ─────────────────────────────────────────────
hdr "console loop"
cat > /usr/local/bin/proxima-console <<'EOF'
#!/bin/bash
# Renders the Proxima backend TUI on this terminal, forever.
# Runs as the unprivileged console user.
set -u

# Never blank or power down this screen -- it lives in a rack.
setterm --blank 0 --powerdown 0 2>/dev/null || true

hint() {
    printf '\n\033[1;36m  Proxima rack console\033[0m\n'
    printf '  \033[2mCtrl+Alt+F2\033[0m  log in as another user\n'
    printf '  \033[2mCtrl-\\\033[0m       detach the TUI and return here\n'
    printf '  \033[1;33m  Do NOT quit the TUI with q or Ctrl-C -- that stops Proxima.\033[0m\n\n'
}

while true; do
    hint
    sleep 2
    sudo -n /usr/local/bin/proxima-tui-attach
    rc=$?
    clear
    if [ "$rc" -ne 0 ]; then
        printf '\n\033[1;31m  TUI attach ended (exit %s).\033[0m\n' "$rc"
        printf '  If the container stopped, Docker restarts it automatically.\n'
        printf '  Reattaching shortly ...\n'
        sleep 5
    fi
done
EOF
chmod 0755 /usr/local/bin/proxima-console
say "installed /usr/local/bin/proxima-console"

# Launch it on login, but ONLY on the console tty, so an SSH session or
# another tty as this user still gets an ordinary shell.
PROFILE="/home/$TUI_USER/.bash_profile"
MARKER="# >>> proxima rack console >>>"
if ! grep -qF "$MARKER" "$PROFILE" 2>/dev/null; then
    cat >> "$PROFILE" <<EOF

$MARKER
# Only on the physical console -- never for ssh or another tty.
if [ "\$(tty)" = "/dev/tty$TUI_TTY" ]; then
    exec /usr/local/bin/proxima-console
fi
# <<< proxima rack console <<<
EOF
    chown "$TUI_USER:$TUI_USER" "$PROFILE"
    say "login hook added to $PROFILE"
else
    say "login hook already present"
fi

# ── 4. Autologin on the console tty ─────────────────────────────────
hdr "autologin on tty$TUI_TTY"
DROPIN="/etc/systemd/system/getty@tty$TUI_TTY.service.d"
mkdir -p "$DROPIN"
cat > "$DROPIN/autologin.conf" <<EOF
# Proxima rack console autologin.
#
# NB on DietPi: \`dietpi-autostart\` writes its own drop-in here when set
# to an autologin index. Leave it on "Console: Manual Login" (index 0)
# or the two will fight over this file.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $TUI_USER --noclear %I \$TERM
EOF
say "drop-in written to $DROPIN/autologin.conf"

# ── 5. Never blank the screen ───────────────────────────────────────
hdr "screen blanking"
CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt
if [ -f "$CMDLINE" ]; then
    if grep -q 'consoleblank=' "$CMDLINE"; then
        say "consoleblank already set in $(basename "$CMDLINE")"
    else
        # cmdline.txt MUST stay a single line.
        sed -i '1 s/$/ consoleblank=0/' "$CMDLINE"
        say "added consoleblank=0 (kernel default is 600s)"
        REBOOT_NEEDED=1
    fi
fi

CONFIG=/boot/firmware/config.txt
[ -f "$CONFIG" ] || CONFIG=/boot/config.txt
if [ -f "$CONFIG" ] && grep -q '^hdmi_blanking=1' "$CONFIG"; then
    sed -i 's/^hdmi_blanking=1/hdmi_blanking=0/' "$CONFIG"
    say "hdmi_blanking 1 -> 0 (was letting the display sleep after 10min)"
    REBOOT_NEEDED=1
else
    say "hdmi_blanking already off or unset"
fi

# ── 6. Pin the console video mode ───────────────────────────────────
# Without this the mode depends on what EDID the display happened to
# offer at boot. A rack display is often powered separately from the Pi
# and can be off or asleep at that moment, which silently drops the
# console to a fallback mode -- and moves every panel on a second,
# GPIO-driven display along with it.
if [ "$DO_VIDEO" -eq 1 ] && [ -f "$CMDLINE" ]; then
    hdr "console video mode"
    if grep -q 'video=' "$CMDLINE"; then
        say "video= already pinned: $(grep -o 'video=[^ ]*' "$CMDLINE")"
    else
        CONN=""; MODE=""
        for c in /sys/class/drm/card*-*/; do
            [ "$(cat "$c/status" 2>/dev/null)" = "connected" ] || continue
            CONN="$(basename "$c" | cut -d- -f2-)"
            MODE="$(head -1 "$c/modes" 2>/dev/null)"
            break
        done
        if [ -n "$CONN" ] && [ -n "$MODE" ]; then
            sed -i "1 s/\$/ video=$CONN:${MODE}@60/" "$CMDLINE"
            say "pinned video=$CONN:${MODE}@60 (native mode of the attached display)"
            REBOOT_NEEDED=1
        else
            say "no connected display detected -- skipping (re-run with the monitor on)"
        fi
    fi
fi

# ── 7. Apply ────────────────────────────────────────────────────────
hdr "applying"
systemctl daemon-reload
say "systemd reloaded"
echo
echo "Done. Console user '$TUI_USER' will autologin on tty$TUI_TTY and show the TUI."
echo "  Start it now without rebooting:  systemctl restart getty@tty$TUI_TTY"
if [ "$REBOOT_NEEDED" -eq 1 ]; then
    echo "  A REBOOT is required for the boot-config changes (blanking / video mode)."
fi
