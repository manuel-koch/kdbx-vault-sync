# kdbx-vault-sync

Sync KeePassXC vault files (`*.kdbx`, `*.keyx`) between multiple macOS hosts and
any rclone remote — without ever risking password loss.

## Use-case

You keep KeePassXC vaults on several Macs (e.g. work and private) and want them
in sync through a remote storage of your choice. Plain bidirectional sync tools
pick a "newer" winner when both sides changed — on a password database that
silently loses entries. `kdbx-vault-sync` never auto-overwrites on divergence:
conflicts are detected, both versions backed up, and *you* merge in KeePassXC
(which understands the format).

Key properties:

- **Per-file one-way transfer** (`rclone copyto`) — only top-level `*.kdbx` /
  `*.keyx` files travel; state, backups, logs and the launcher app never do.
- **Backup before every overwrite** — locally and on the remote (per-host dir),
  so any mistake is reversible.
- **Persistent macOS alerts** for conflicts and failures — re-arm every 4 h
  until resolved, but never spam (a healthy run is silent).
- **New files propagate**: a vault file pushed by another host is adopted
  automatically on the next run.
- **Deletions never propagate silently**: removing a file from syncing is an
  explicit `remove FILE` command; accidental deletions raise an alert.

## Workflow

### One-time setup per machine

```zsh
# 1. Define an rclone remote for your storage (once per machine) — any
#    rclone-supported remote works, e.g.:
rclone config create <remote-name> sftp host <host.example.com> user <username>

# 2. Place the script in the vault directory (same dir as the kdbx files).
#    Multiple vaults are supported: symlink the same script into each vault
#    dir; each gets its own state, backups, .app and launchd job.
ln -s /path/to/kdbx-vault-sync.sh ~/Documents/Vaults/kdbx-vault-sync.sh

# 3. Create the mandatory per-vault config (no fallback — the script refuses
#    to run without it):
echo 'REMOTE_ALIAS="my-remote:"' > ~/Documents/Vaults/.kdbx-vault-sync.conf

# 4. Make sure local and remote hold the SAME content before init — if they
#    diverged, reconcile by hand first (open both in KeePassXC and merge).
```

### Start syncing

```zsh
cd ~/Documents/Vaults

./kdbx-vault-sync.sh init          # record baseline (transfers nothing)
./kdbx-vault-sync.sh               # a few manual runs to sanity-check
./kdbx-vault-sync.sh status        # inspect LOCAL/REMOTE change state

./kdbx-vault-sync.sh init-app        # build the launchd .app (needs Xcode CLT)
./kdbx-vault-sync.sh init-background # register launchd job (runs every 60s)
```

### Day to day

The launchd job syncs every 60 seconds; you normally do nothing. When a
conflict occurs (both a local and a remote change since the last sync), the
script stops touching that file: your local vault stays as-is, the remote
version is backed up, and a `CONFLICT_<file>.txt` marker next to the vault
explains the situation and names the backup paths.

To resolve:

1. Open the local vault in KeePassXC.
2. **Database → Merge from database…** and select the backed-up remote copy
   (its path is in the `CONFLICT_<file>.txt` marker). Review the merged
   result and save.
3. `./kdbx-vault-sync.sh resolve <file>` — pushes the merged file to the
   remote, updates the baseline, and clears the conflict marker.

### Removing a file from sync

```zsh
./kdbx-vault-sync.sh remove <file>   # backs up local+remote, deletes remote,
                                     # drops state entry. Local file is NOT deleted.
```

## Commands

| Command | Description |
|---|---|
| `init` | Create `.kdbx-vault-sync.conf` interactively (if missing); add **new** vault files without touching existing baselines. |
| `init full` | Re-record **all** baselines — only after manual reconciliation. |
| `status` | Show LOCAL/REMOTE change state of every vault file. |
| *(no args)* | One sync run (push/pull/conflict detection) — what launchd executes every 60 s. |
| `resolve FILE` | After a conflict and manual KeePassXC merge: push the merged file, adopt as new baseline. |
| `remove FILE` | Stop syncing FILE: backs up both copies, deletes the remote file, drops the state entry. Local file is NOT deleted. |
| `init-app` | Build the launchd `.app` launcher (macOS requires a signed binary). |
| `init-background` | Register the launchd job (60 s interval). |

## Managing the launchd job

Each vault directory gets its own launchd job. The `<hash>` in the service
label is the MD5 of `<vault-dir>/kdbx-vault-sync.sh` (the path as invoked,
symlink **not** resolved), making the label unique per vault directory.
Compute it and find your jobs:

```zsh
# Compute the label for the current vault directory:
HASH=$(echo "$PWD/kdbx-vault-sync.sh" | md5 -q)
LABEL="com.user.kdbx-vault-sync.${HASH}"

# list all vault-sync jobs
launchctl list | grep kdbx-vault-sync           

# inspect the vault-sync job
launchctl print     "gui/$(id -u)/${LABEL}"     

# stop the sync job, but keep it
launchctl bootout   "gui/$(id -u)/${LABEL}"     

# resume a stopped sync job
launchctl load -w   ~/Library/LaunchAgents/${LABEL}.plist

# stop a sync job permanently and remove it
launchctl bootout   "gui/$(id -u)/${LABEL}" \
  && rm ~/Library/LaunchAgents/${LABEL}.plist
```

## Why a dedicated .app launcher?

macOS places two obstacles in front of running a shell script on a schedule:

1. **launchd wants a signed binary in an .app bundle.** Modern macOS only
   starts *signed executables* for LaunchAgents — a bare `zsh script.sh` in a
   plist is refused. `kdbx-vault-sync.sh init-app` therefore compiles a
   ~10-line C launcher into `kdbx-vault-sync.app`, ad-hoc codesigns it
   (`codesign --sign -`), and `kdbx-vault-sync.sh init-background` points
   the launchd job at that binary.
2. **TCC protects your Documents folder.** The vault directory (typically
   `~/Documents/Vaults`) sits behind macOS's privacy protection (TCC). A plain
   launchd-started shell has no permission to read it and cannot grant itself
   that permission. A proper `.app`, by contrast, can be granted
   *Files and Folders → Documents* access: the first scheduled run pops the
   standard macOS consent dialog once; after you approve, every subsequent
   run inherits that permission.

The launcher itself does almost nothing: it redirects stdout/stderr into the
sync log and `exec`s `/bin/zsh <script>`. It exists purely to satisfy the two
macOS requirements above — all sync logic stays in the plain shell script.

## Requirements

- macOS with `zsh` (default shell)
- [rclone](https://rclone.org/) with a configured remote (any rclone-supported backend)
- Xcode Command Line Tools (`kdbx-vault-sync.sh init-app` compiles a small C launcher)
- [KeePassXC](https://keepassxc.org/) for merging conflicts
