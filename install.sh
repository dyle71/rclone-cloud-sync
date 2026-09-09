#!/usr/bin/env bash
#
# Install cloud-sync: check the prerequisites, link the script and the systemd
# user units, export the per-mount EnvironmentFiles and enable everything.
#
# Idempotent - safe to re-run after a git pull or a config change.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cloud-sync"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ── Prerequisites ────────────────────────────────────────────────────────────
# Checked up front: failing here with a clear message beats failing later
# inside a systemd unit with a cryptic one.

say "Checking prerequisites"

[[ "$(uname -s)" == "Linux" ]] || die "cloud-sync targets Linux (systemd + FUSE). See the README section 'Other platforms'."

command -v systemctl >/dev/null || die "systemctl not found - this needs systemd."
systemctl --user show-environment >/dev/null 2>&1 || die "no systemd user session (try: loginctl enable-linger ${USER:-$(id -un)})"
ok "systemd user session"

command -v rclone >/dev/null || die "rclone not found - install it from https://rclone.org/install/"
ok "rclone $(rclone version | head -1 | awk '{print $2}')"

command -v fusermount >/dev/null || command -v fusermount3 >/dev/null \
    || warn "fusermount not found - [[mount]] entries will not work (install fuse3)"

PY=$(command -v python3) || die "python3 not found"
"$PY" - <<'PYEOF' || die "python 3.11+ required (tomllib)"
import sys
sys.exit(0 if sys.version_info >= (3, 11) else 1)
PYEOF
ok "python $("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])')"

"$PY" -c 'import watchdog' 2>/dev/null \
    || die "python 'watchdog' module missing - install it (Arch: pacman -S python-watchdog, else: pip install --user watchdog)"
ok "python watchdog"

[[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/rclone/rclone.conf" ]] \
    || warn "no rclone.conf yet - run 'rclone config' to add a remote before starting"

# ── Install ──────────────────────────────────────────────────────────────────

say
say "Installing"
mkdir -p "$BIN_DIR" "$UNIT_DIR" "$CONF_DIR"

ln -sfn "$REPO/bin/cloud-sync" "$BIN_DIR/cloud-sync"
ok "$BIN_DIR/cloud-sync -> $REPO/bin/cloud-sync"

for unit in "$REPO"/systemd/*; do
    ln -sfn "$unit" "$UNIT_DIR/$(basename "$unit")"
done
ok "systemd units in $UNIT_DIR"

if [[ ! -f "$CONF_DIR/config.toml" ]]; then
    cp "$REPO/config/config.toml.example" "$CONF_DIR/config.toml"
    say
    say "A starter config was written to $CONF_DIR/config.toml."
    say "Edit it (remotes, paths), then run this script again."
    systemctl --user daemon-reload
    exit 0
fi
ok "config $CONF_DIR/config.toml (kept)"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH - add it to use 'cloud-sync' directly" ;;
esac

systemctl --user daemon-reload

# ── Mount units ──────────────────────────────────────────────────────────────
# The config is the single source of truth; these files are derived from it.

say
say "Exporting mount units"
"$BIN_DIR/cloud-sync" --export-mount-units

say
say "Enabling units"
systemctl --user enable --now cloud-sync.service >/dev/null
systemctl --user enable --now cloud-sync-periodic.timer >/dev/null
systemctl --user enable --now rclone-token-refresh.timer >/dev/null
ok "cloud-sync.service, periodic timer, token refresh timer"

shopt -s nullglob
for env_file in "$CONF_DIR"/mounts/*.env; do
    instance="$(basename "$env_file" .env)"
    systemctl --user enable --now "rclone-mount@${instance}.service" >/dev/null
    ok "rclone-mount@${instance}.service"
done
shopt -u nullglob

say
say "Done. Check with: cloud-sync --status"
