# rclone-cloud-sync

Keep OneDrive, SharePoint or any other [rclone](https://rclone.org) remote
available locally — either fully synced to disk or mounted on demand — with one
status command that tells you the truth about all of it.

> **Platform: Linux.** This is built on systemd user units and FUSE. The two
> ideas behind it port to Windows and macOS without much trouble; see
> [Other platforms](#other-platforms). The code as shipped does not.

```text
$ cloud-sync --status
Configuration  ~/.config/cloud-sync/config.toml
Daemon         ✅ running  PID 614620, up since 2026-09-09 14:33:51 (2h 14min ago)
Connection     🌐 online  (graph.microsoft.com:443)

── 💾 Full sync ───────────────────────────────────────────────

Work OneDrive
  onedrive-work:  →  ~/Documents/Cloud/work/OneDrive
  Baseline       1886 files, written 2026-09-09 16:47:12
  Last run       ✅ OK  2026-09-09 16:47:12  (61s ago)
  Pending local  ✅ nothing waiting
  Next poll      2026-09-09 16:52:12

── 🌐 Network lookup ──────────────────────────────────────────

Team Documents  ✅ OK
  sharepoint-team:  →  ~/Documents/Cloud/work/Team
  Unit           rclone-mount@team-documents.service (active)
```

## Why this exists

Microsoft ships no OneDrive client for Linux. `rclone` does everything needed,
but on its own it leaves you assembling the boring parts yourself: something has
to run it on login, notice when the network is gone, avoid two syncs colliding,
tell you when a mount has silently died, and answer *"is my stuff actually
uploaded?"* without you reading logs.

That assembly is what this repository is.

## The two modes

Each remote is set up in one of two ways, and picking the right one per remote is
the whole point.

|                  | **Full sync**                                 | **Network lookup**                 |
| ---------------- | --------------------------------------------- | ---------------------------------- |
| config block     | `[[pair]]`                                    | `[[mount]]`                        |
| mechanism        | `rclone bisync`                               | `rclone mount` (FUSE)              |
| where files live | on your disk                                  | on the server, cached              |
| works offline    | yes                                           | no                                 |
| disk cost        | the full tree                                 | cache only                         |
| good for         | what you edit daily, what you need on a plane | large shares you occasionally open |

Rule of thumb: if you would be annoyed to find it **missing offline**, make it a
pair. If you would be annoyed to find it **filling your disk**, make it a mount.

Both are watched by the same daemon, reported by the same `--status`, and
notified through the same edge-triggered logic.

## Requirements

- Linux with a **systemd user session**
- **rclone** ≥ 1.60 ([install](https://rclone.org/install/))
- **fuse3** — only if you use `[[mount]]`
- **Python** ≥ 3.11 (for `tomllib`) with the **watchdog** module
  - Arch: `pacman -S python-watchdog`
  - Debian/Ubuntu: `apt install python3-watchdog`
  - otherwise: `pip install --user -r requirements.txt`

`install.sh` checks all of this and stops with a clear message if something is
missing.

## Quick start

### 1. Set up a remote in rclone

This is the only step that needs a browser.

```bash
rclone config
# n) new remote → name it e.g. onedrive-work → storage: onedrive
# Follow the browser login, then confirm the drive
rclone lsd onedrive-work:      # verify it works
```

For SharePoint document libraries, choose the same `onedrive` backend and pick
the site when asked. rclone's
[OneDrive docs](https://rclone.org/onedrive/) cover the tenant-specific cases.

### 2. Install

```bash
git clone https://github.com/<you>/rclone-cloud-sync.git
cd rclone-cloud-sync
./install.sh          # writes a starter config on the first run
```

### 3. Describe what you want

In `~/.config/cloud-sync/config.toml`:

```toml
[[pair]]
name   = "Work OneDrive"
remote = "onedrive-work:"
local  = "~/Documents/Cloud/work/OneDrive"

[[mount]]
name       = "Team Documents"
remote     = "sharepoint-team:"
mountpoint = "~/Documents/Cloud/work/Team"
```

The commented [`config/config.toml.example`](config/config.toml.example)
documents every option.

### 4. Establish the baseline for each pair — once

```bash
cloud-sync --resync
```

`bisync` needs a starting point it can compare future states against. This step
does not re-upload identical files, but it *is* the one destructive-on-conflict
operation, which is why it is never automatic.

### 5. Start everything

```bash
./install.sh          # again: exports mount units, enables and starts them
cloud-sync --status
```

## Commands

```bash
cloud-sync --status              # connection, pairs, mounts, last sync   ← the everyday one
cloud-sync --status --json       # same, machine-readable (exit 0 = healthy)
cloud-sync --list                # what is configured
cloud-sync --diff                # real file-by-file comparison with the cloud
cloud-sync --diff --quick        # compare sizes only, much faster
cloud-sync --once                # one sync run, then exit (what the timer uses)
cloud-sync --resync              # establish a baseline (uninitialized pairs only)
cloud-sync --resync --pair NAME  # …for one pair
cloud-sync --refresh-tokens      # renew every remote's OAuth token
cloud-sync --export-mount-units  # regenerate mount units after a config change
```

`--status` is instant and safe to run in a prompt or a loop: only the
connectivity probe and the mount checks touch anything outside local state.
Colour and emoji switch off automatically when the output is not a terminal, or
when `NO_COLOR` is set.

## How mounts are wired

Mounts do **not** get one unit each. There is a single template unit,
`rclone-mount@.service`, and one instance per mount:

```text
config.toml                     ← you edit only this
    [[mount]] name = "Team Documents"
        │
        │  cloud-sync --export-mount-units
        ▼
~/.config/cloud-sync/mounts/team-documents.env
    REMOTE=sharepoint-team:
    MOUNTPOINT=/home/<user>/Documents/Cloud/work/Team
    MOUNT_OPTS=--vfs-cache-mode writes …
        │
        │  EnvironmentFile=%h/.config/cloud-sync/mounts/%i.env
        ▼
systemctl --user enable --now rclone-mount@team-documents.service
```

The config is the single source of truth; the `.env` files are derived from it
and live outside the repository. If you change the config and forget to
re-export, `--status` says `🔄 SETTINGS OUTDATED` rather than quietly running
stale settings.

After changing a mount:

```bash
cloud-sync --export-mount-units
systemctl --user restart rclone-mount@team-documents.service
```

## Switching a remote between modes

### Network lookup → full sync

```bash
systemctl --user disable --now rclone-mount@team-documents.service
rmdir ~/Documents/Cloud/work/Team        # must be empty
# replace the [[mount]] block with a [[pair]] block
cloud-sync --resync --pair "Team Documents"
systemctl --user restart cloud-sync.service
```

### Full sync → network lookup

```bash
systemctl --user stop cloud-sync.service
# replace [[pair]] with [[mount]], move the local copy out of the way
cloud-sync --export-mount-units
systemctl --user enable --now rclone-mount@team-documents.service
systemctl --user start cloud-sync.service
```

## When uploads get stuck

A `[[mount]]` accepts a write instantly and uploads it afterwards. Until that
upload succeeds, the only copy of the file is the blob in
`~/.cache/rclone/vfs/`. If the upload can never succeed, the mount keeps
looking perfectly healthy while nothing you save actually reaches the cloud.

**SharePoint document libraries do exactly that to Office files.** They rewrite
`.docx`, `.xlsx` and `.pptx` server-side on upload, injecting their own
metadata, so the stored object is a few kilobytes larger than what was sent.
rclone's post-copy size check fails, it calls the transfer corrupt, deletes the
destination copy and retries — forever. Plain files (`.md`, `.pdf`, …) are
unaffected.

### Spotting it

```bash
cloud-sync --status                      # 📤 UPLOADS STUCK, with the file list
systemctl --user show -p StatusText rclone-mount@<instance>.service
# StatusText=…vfs cache: objects 5 (was 5) in use 5, to upload 5, uploading 0…
journalctl --user -u rclone-mount@<instance>.service | grep -i 'corrupted on transfer'
```

`--status` reads the cache metadata only — no network, no FUSE traffic — and
exits non-zero as soon as a file has been waiting longer than `vfs_stuck_after`
(15 min by default). A file that was just saved is *supposed* to be unuploaded
for a moment; that is what the threshold is for.

### The fix

Turn off the two checks SharePoint breaks:

```toml
[[mount]]
name             = "Team Documents"
remote           = "sharepoint-team:"
mountpoint       = "~/Documents/Cloud/work/Team"
# SharePoint rewrites Office files on upload; without these the post-copy
# size and hash checks can never succeed.
extra_mount_opts = ["--ignore-size", "--ignore-checksum"]
```

`extra_mount_opts` is **added** to the built-in defaults; `mount_opts`
**replaces** them. Setting both is a config error.

`--ignore-checksum` is needed alongside `--ignore-size` because SharePoint
recomputes the QuickXorHash over the rewritten file, so the hash mismatches for
the same reason the size does.

### Recovering the files already stuck

Changing the flags does not rescue what is already in the queue: rclone keeps
retrying the *cached* copy, and for some failure modes (`404 itemNotFound —
the upload session was not found`) it never recovers at all. The cached copy is
the newest version of the file, so get it out before touching anything.

```bash
# 1. find them - the paths --status prints are relative to the cache root
cloud-sync --status
CACHE=~/.cache/rclone/vfs/"<remote name>"

# 2. copy them somewhere safe FIRST, while the mount is still up
cp -a "$CACHE/<path>/Report.docx" ~/rescue/

# 3. stop the mount, apply the flags, start it again
systemctl --user stop rclone-mount@<instance>.service
$EDITOR ~/.config/cloud-sync/config.toml     # add extra_mount_opts
cloud-sync --export-mount-units
systemctl --user start rclone-mount@<instance>.service

# 4. write the rescued file back through the mount and confirm it lands
cp ~/rescue/Report.docx ~/Documents/Cloud/work/Team/<path>/
cloud-sync --status                           # ✅ nothing waiting
```

Step 4 is the verification: the entry only goes `"Dirty": false` in
`~/.cache/rclone/vfsMeta/…` once the upload was accepted.

### Orphaned cache roots

Renaming a remote leaves its cache subtree behind under a name nothing points
at any more. Unuploaded files in there are retried by nobody and shown by
nothing — so `--status` scans for them and reports them as `🚨 UNREACHABLE
DATA`:

```bash
cloud-sync --status
cp -a ~/.cache/rclone/vfs/"Team - X"/<path> ~/rescue/   # rescue first
rm -rf ~/.cache/rclone/vfs/"Team - X" ~/.cache/rclone/vfsMeta/"Team - X"
```

Copy anything you still want back in through the current mount afterwards.

## Units

| Unit                         | Role                                                                                         |
| ---------------------------- | -------------------------------------------------------------------------------------------- |
| `cloud-sync.service`         | the daemon: syncs at startup, then inotify + remote polling + mount watching + token refresh |
| `cloud-sync-periodic.timer`  | hourly `--once` fallback, in case a thread inside the daemon dies                            |
| `rclone-token-refresh.timer` | daily token refresh for every remote in the config                                           |
| `rclone-mount@.service`      | template, one instance per `[[mount]]`                                                       |

## Notifications

Edge-triggered, never level-triggered:

- **one** message per state change — a failure repeating every poll stays silent
  after the first
- a persisting problem is re-announced at most once per `notify_repeat` (6 h)
- at most one entry per topic in the notification centre (`notify-send -r`
  replaces rather than stacks)
- while the machine is offline, *one* global message says so, instead of one per
  pair and one per mount

State lives in `$XDG_RUNTIME_DIR/cloud-sync/notify-state.json` and is discarded
at logout, so a fresh session is allowed to warn you once again.

## Troubleshooting

| `--status` says        | Meaning and fix                                                                                                                                             |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `⚠️ Baseline missing`  | never initialized: `cloud-sync --resync`                                                                                                                    |
| `🧹 Lock STALE`        | leftover from a crash; the next run clears it                                                                                                               |
| `🔄 SETTINGS OUTDATED` | config changed without re-export: `cloud-sync --export-mount-units`, then restart the unit                                                                  |
| `🧟 STALE` (mount)     | the mount hangs: `systemctl --user restart rclone-mount@<instance>.service`                                                                                 |
| `🚨 HIDDEN FILES`      | **data at risk**: something wrote into an unmounted mountpoint. Those files vanish from view once it mounts. Move them out, empty the directory, then mount |
| `📤 UPLOADS STUCK`     | **data at risk**: files written to the mount never reached the cloud and exist only in the local cache. See [When uploads get stuck](#when-uploads-get-stuck) |
| `🚨 UNREACHABLE DATA`  | **data at risk**: a cache root left behind by a renamed remote still holds unuploaded files, and no mount will ever retry them. See [Orphaned cache roots](#orphaned-cache-roots) |
| `token expired`        | `rclone config reconnect <remote>:`                                                                                                                         |

Conflicts are resolved with `--conflict-resolve newer`; the losing version is
kept as `file.conflict1` and never deleted.

Logs: `journalctl --user -u cloud-sync -f` or
`~/.local/share/rclone/cloud-sync.log`.

## Files it owns

| Path                                            | Content                                            |
| ----------------------------------------------- | -------------------------------------------------- |
| `~/.config/cloud-sync/config.toml`              | your configuration                                 |
| `~/.config/cloud-sync/mounts/*.env`             | generated, one per mount                           |
| `~/.local/state/cloud-sync/status.json`         | last run per pair, mount states (survives reboots) |
| `$XDG_RUNTIME_DIR/cloud-sync/notify-state.json` | notification state (ephemeral)                     |
| `~/.cache/rclone/bisync/`                       | bisync baselines and locks                         |
| `~/.cache/rclone/vfs/`, `vfsMeta/`              | mount cache: file blobs and their upload state (read by `--status`, never written) |
| `~/.local/share/rclone/cloud-sync.log`          | rotating log, 5 MB × 3                             |

`./uninstall.sh` removes the units and unmounts everything, and touches none of
the above.

## Design notes

The non-obvious decisions, and what forced them.

**One lock per pair, held across the entire run.** rclone writes its own `.lck`
only once bisync is already working. In that window the daemon and the `--once`
timer run both passed the "is it locked?" check and collided — two overlapping
syncs, one dying with an error. `process_lock()` takes an `flock` *before* rclone
starts; the kernel releases it even if the process is killed, so it cannot go
stale the way a PID file can.

**The rclone child is terminated on shutdown.** Otherwise a restart orphans it:
it keeps running, holds the sync lock, and collides with the daemon systemd just
started in its place. Its SIGTERM exit code (143) is deliberately not counted as
a sync failure.

**`--once` fails only on real failures.** A run that was locked out, or skipped
because the machine is offline, exits 0. Treating those as failures left the
timer unit permanently red, which buried the failures that mattered.

**Remote polling is slow on purpose.** A bisync run over a few thousand files
takes seconds to minutes; polling every 30 s meant it essentially never stopped,
for no benefit. Local edits are caught by inotify within a second, so polling
only needs to find changes made *elsewhere*.

**No `network-online.target` dependency.** That target does not exist in the
systemd **user** manager — `systemctl --user list-unit-files
network-online.target` lists nothing. Depending on it silently does nothing while
looking like it waits for the network. Mounts instead fail fast
(`TimeoutStartSec`) and are retried; the daemon probes connectivity itself and
backs off while offline.

**The daemon's identity is not just a PID.** `--status` used to trust the PID
recorded in `status.json`, which fails in both directions: PIDs get reused, so a
stale number can point at an unrelated process, and any hand-started daemon
overwrote the record and made the real one look dead. It now asks systemd first
and verifies the PID against `/proc/<pid>/cmdline`. A second daemon is refused
outright by an flock, since two of them would watch the same directories and
each claim to be *the* daemon.

**A healthy mount is not the same as a mount that uploads.** Every check we
had — mounted, readable, unit active, settings current — passed on a mount that
had not uploaded a single Office file in a week; the files sat in the VFS cache
and `--status` said `✅ OK`. The upload queue is now part of the health check,
read from the cache metadata rather than from rclone: it costs no network, it
works while the remote is unreachable, and it cannot be blocked by the hung
mount it is reporting on. Age is what separates a stuck queue from a file that
is simply still on its way up, hence `vfs_stuck_after`.

**A mount is checked by reading it, not by `ismount()`.** The common failure is
a mount that is still "mounted" but hangs on every I/O. That needs a real read
with a timeout, done in a throwaway thread so a hung FUSE mount cannot block the
daemon.

## Other platforms

The implementation is Linux-only, but it is a thin layer over rclone. Both core
ideas transfer; only the plumbing changes.

What is portable: the `config.toml` model, the two-mode split, `rclone bisync`
and `rclone mount` themselves, and the reasoning in *Design notes*.

What is not: systemd units, `notify-send`, `flock`, inotify via `watchdog`
(actually cross-platform, but tested here on Linux only), and `fusermount`.

### Windows

| Linux piece       | Windows equivalent                                                             |
| ----------------- | ------------------------------------------------------------------------------ |
| systemd user unit | Task Scheduler task *At log on*, or [NSSM](https://nssm.cc) for a real service |
| FUSE              | [WinFsp](https://winfsp.dev) — `rclone mount` maps a remote to a drive letter  |
| `notify-send`     | `New-BurntToastNotification`, or PowerShell toast XML                          |
| `flock`           | `msvcrt.locking`, or a named mutex                                             |
| `journalctl`      | Event Log, or just the rotating log file                                       |

`rclone mount X: --volname Team` giving a real drive letter is arguably nicer
than the Linux mountpoint story. Two viable routes:

1. **WSL2** — run this repository unchanged inside WSL. systemd works in WSL2
   once enabled (`systemd=true` in `/etc/wsl.conf`). Mounts are reachable from
   Windows through `\\wsl$\`. Least work, but the mounts feel like a network
   share to Windows programs.
2. **Native port** — replace the daemon's supervision with a scheduled task and
   the notifications with toasts. The Python is otherwise portable; the pieces
   to swap are isolated in `process_lock()`, `_notify_send()` and the units.

### macOS

Closer to Linux than Windows is:

| Linux piece       | macOS equivalent                                                                        |
| ----------------- | --------------------------------------------------------------------------------------- |
| systemd user unit | `launchd` user agent (`~/Library/LaunchAgents/*.plist`, `RunAtLoad`, `KeepAlive`)       |
| FUSE              | [macFUSE](https://macfuse.github.io), or rclone's NFS mount to avoid a kernel extension |
| `notify-send`     | `osascript -e 'display notification …'`, or `terminal-notifier`                         |
| `flock`           | works as-is (`fcntl.flock` is POSIX)                                                    |
| `journalctl`      | `log show`, or the rotating log file                                                    |

`flock`, `watchdog` and the whole Python layer need no changes. A `launchd`
agent replacing `cloud-sync.service` plus one per mount, and a two-line change in
`_notify_send()`, is close to the whole port.

Ports are welcome — open an issue before starting so the platform-specific parts
can be split out cleanly rather than bolted on.

## License

[MIT](LICENSE)
