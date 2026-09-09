#!/usr/bin/env bash
#
# Remove what install.sh set up: units are stopped and disabled, mounts are
# unmounted, symlinks go away.  Your configuration and your synced files are
# left alone - this removes the machinery, never the data.
#
set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cloud-sync"

say() { printf '%s\n' "$*"; }
ok()  { printf '  ok    %s\n' "$*"; }

say "Stopping units"
shopt -s nullglob
for env_file in "$CONF_DIR"/mounts/*.env; do
    instance="$(basename "$env_file" .env)"
    systemctl --user disable --now "rclone-mount@${instance}.service" 2>/dev/null || true
    ok "rclone-mount@${instance}.service"
done
shopt -u nullglob

for unit in cloud-sync.service cloud-sync-periodic.timer rclone-token-refresh.timer; do
    systemctl --user disable --now "$unit" 2>/dev/null || true
    ok "$unit"
done

say
say "Removing links"
rm -f "$BIN_DIR/cloud-sync"
for unit in cloud-sync.service cloud-sync-periodic.service cloud-sync-periodic.timer \
            rclone-token-refresh.service rclone-token-refresh.timer rclone-mount@.service; do
    rm -f "$UNIT_DIR/$unit"
done
systemctl --user daemon-reload
systemctl --user reset-failed 2>/dev/null || true
ok "symlinks and units removed"

say
say "Left in place on purpose:"
say "  $CONF_DIR                       your configuration"
say "  ~/.cache/rclone/bisync          bisync baselines"
say "  ~/.local/state/cloud-sync       last-run state"
say "  ~/.local/share/rclone/*.log     logs"
say "  your synced directories and mountpoints"
say
say "Check nothing is left mounted:  mount | grep fuse.rclone"
