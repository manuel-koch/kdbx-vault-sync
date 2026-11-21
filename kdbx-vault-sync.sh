#!/bin/zsh
#
# kdbx-vault-sync.sh — safe sync of KeePass vault files (*.kdbx, *.keyx) with a remote
#                      (SFTP) via rclone.
#
# Design (safer than a bidirectional sync that picks "newer wins"):
#   - Only top-level *.kdbx / *.keyx files are synced, file-by-file via
#     `run_rclone copyto` — no recursive directory sync, so logs, scripts, the
#     .app bundle and this state never travel over the wire.
#   - Per file, each run compares the current state against the state recorded
#     at the last successful sync (the "baseline"):
#       * only local changed  -> PUSH:  local -> remote  (remote version backed up first)
#       * only remote changed -> PULL:  remote -> local  (local version backed up first)
#       * BOTH changed        -> NO auto-overwrite. Both versions are backed up,
#                                a CONFLICT_<file>.txt marker is dropped in the
#                                vault dir, and you get a macOS notification.
#                                Resolve by merging in KeePassXC, then run
#                                `./kdbx-vault-sync.sh resolve <file>`.
#     A sync tool never picks a "newer winner" on a kdbx — that is what loses
#     passwords. Merging is done by KeePassXC (it understands the format).
#   - Every push/pull/overwrite is preceded by a dated backup, locally and on
#     the remote (per-host remote backup dir), so any mistake is reversible.
#   - Failures and conflicts raise a PERSISTENT macOS alert dialog that stays
#     on screen until you dismiss it (it cannot time out and vanish like a
#   - Failures and conflicts raise a PERSISTENT macOS alert dialog that stays
#     on screen until you dismiss it (it cannot time out and vanish like a
#     regular notification). A healthy run raises nothing and exits 0; a
#     failing run exits non-zero. Alerts fire once immediately and then re-arm
#     every REMINDER_INTERVAL_SECONDS (default: 4 hours) until the problem is
#     resolved, so dismissing the dialog is never the last you hear about it,
#     while a broken sync running every 60 seconds still does not spam you.
#
# --- Setup (run once per machine) ------------------------------------
#   1. Define an rclone remote for your storage (once per machine), e.g.:
#        rclone config create <remote-name> sftp host <host.example.com> user <username>
#   2. Place this script in the vault directory (same dir as the kdbx files).
#      Multiple vault dirs are supported: symlink the same script into each
#      vault dir; each gets its own state, backups, .app and launchd job.
#   3. Create the MANDATORY per-vault config file next to the script:
#        echo 'REMOTE_ALIAS="my-remote:"' > .kdbx-vault-sync.conf
#      REMOTE_ALIAS names the rclone remote (with optional subpath) this
#      vault syncs to. The script refuses to run without it — no fallback.
#   4. Before init: make sure local and remote hold the SAME (most current)
#      content — if they diverged while no sync was running, reconcile by
#      hand first (open both in KeePassXC and merge), otherwise init will
#      record a diverging baseline.
#   5. ./kdbx-vault-sync.sh init    # record baseline, transfers nothing
#   6. Run ./kdbx-vault-sync.sh a few times by hand BEFORE enabling launchd:
#      - No kdbx changes needed. A run with no changes does nothing and
#        prints "PUSH ok"/"PULL ok" only if something actually transferred;
#        otherwise it stays silent and exits 0.
#      - Optional: modify a kdbx in KeePassXC between two runs to see a PUSH,
#        and touch the remote file (or sync from another host) to see a PULL.
#      - Check ./kdbx-vault-sync.sh status to see LOCAL/REMOTE change state.
#   7. ./kdbx-vault-sync.sh init-app          # build launchd .app (needs Xcode CLT)
#   8. ./kdbx-vault-sync.sh init-background   # register launchd job (every 60s)
#
# --- Managing the launchd job ----------------------------------------
#   Service label:  com.user.kdbx-vault-sync.<md5-of-script-path>
#   Inspect:        launchctl print gui/$(id -u)/com.user.kdbx-vault-sync.<hash>
#   Stop (keep):    launchctl bootout gui/$(id -u)/com.user.kdbx-vault-sync.<hash>
#   Resume:         launchctl load -w ~/Library/LaunchAgents/com.user.kdbx-vault-sync.<hash>.plist
#   Stop (perm.):   ... bootout ... && rm ~/Library/LaunchAgents/com.user.kdbx-vault-sync.<hash>.plist
#
# --- Commands (in workflow order) -------------------------------------
#   ./kdbx-vault-sync.sh init      create .kdbx-vault-sync.conf interactively (if
#                                  missing); add NEW vault files to the state
#                                  without touching existing baselines.
#                                  'init full' re-records ALL baselines (use
#                                  only after manual reconciliation)
#   ./kdbx-vault-sync.sh status    show change state of every vault file
#   ./kdbx-vault-sync.sh           one sync run (push/pull/conflict detection;
#                                  this is what launchd executes every 60s)
#   ./kdbx-vault-sync.sh resolve FILE   after a CONFLICT and manual merge in
#                                  KeePassXC: push the merged file and adopt
#                                  it as the new baseline
#   ./kdbx-vault-sync.sh remove FILE stop syncing FILE: backs up local+remote
#                                  copies, deletes the remote file, drops the
#                                  state entry. Local file is NOT deleted.
#   ./kdbx-vault-sync.sh pause     stop the scheduled sync: the launchd job is
#                                  unloaded (no further runs fire). A run that
#                                  is already in progress is NOT interrupted —
#                                  it finishes on its own. Nothing is deleted;
#                                  a marker file records the paused state.
#   ./kdbx-vault-sync.sh resume    restart the scheduled sync after 'pause':
#                                  removes the paused marker, reloads the
#                                  launchd job, and a sync run fires
#                                  immediately (RunAtLoad), then every 60s.
#   ./kdbx-vault-sync.sh init-app  build the launchd .app launcher
#   ./kdbx-vault-sync.sh init-background register the launchd job (see "Managing
#                                  the launchd job" above to stop/resume)
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------

SCRIPT_DIR=$(realpath "$(dirname "$0")")
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"
VAULT_DIR_ID=$(echo "${SCRIPT_DIR}" | md5 -q | cut -c1-8)   # per-vault unique ID

# Per-vault configuration. The script is meant to be symlinked into each
# vault directory, so a per-vault remote is set via a config file in the
# vault dir: <vault-dir>/.kdbx-vault-sync.conf (sourced as zsh).
#   Example content:
#       REMOTE_ALIAS="my-remote:"
# The config file and REMOTE_ALIAS are MANDATORY — a missing config or unset
# variable aborts the script (no silent fallback to a default remote).
# Exception: `init` interactively creates the config file instead (see
# ensure_config_file_interactive below the commands section).
CONFIG_FILE_PATH="${SCRIPT_DIR}/.kdbx-vault-sync.conf"

# Fail with a clear message if the config is missing or incomplete.
# Used by every command except init (which creates the config itself).
require_valid_config() {
    if [ ! -f "${CONFIG_FILE_PATH}" ]; then
        echo "ERROR: config file not found: ${CONFIG_FILE_PATH}" >&2
        echo "       Run './kdbx-vault-sync.sh init' to create it interactively," >&2
        echo "       or create it manually, e.g.:" >&2
        echo '           echo '"'"'REMOTE_ALIAS="my-remote:"'"'"' > '"${CONFIG_FILE_PATH}" >&2
        exit 1
    fi
    source "${CONFIG_FILE_PATH}"
    if [ -z "${REMOTE_ALIAS}" ]; then
        echo "ERROR: REMOTE_ALIAS is not set in ${CONFIG_FILE_PATH}" >&2
        echo "       Add a line like:  REMOTE_ALIAS=\"my-remote:\"" >&2
        exit 1
    fi
    REMOTE_BACKUP_ROOT="${REMOTE_ALIAS}.kdbx-vault-sync-backups/$(hostname -s)"
}

# The remote is validated lazily (per command), because `init` may create
# the config file first. Non-init commands validate up front.
case "$1" in
    init) ;;
    *) require_valid_config ;;
esac

APP_NAME="VaultSync"
# Bundle ID and launchd label embed the vault dir ID so multiple vault dirs
# (each with its own symlinked copy) get fully independent job identities.
APP_BUNDLE_ID="com.user.kdbx-vault-sync.${VAULT_DIR_ID}"
APP_BUNDLE_PATH="${SCRIPT_DIR}/${APP_NAME}.app"
APP_BINARY_PATH="${APP_BUNDLE_PATH}/Contents/MacOS/${APP_NAME}"
LOG_FILE_PATH="${SCRIPT_PATH}.stdout.log"

LAUNCHD_JOB_SUFFIX=$(echo "${SCRIPT_PATH}" | md5 -q)
LAUNCHD_JOB_NAME="com.user.kdbx-vault-sync.${LAUNCHD_JOB_SUFFIX}"
LAUNCHD_JOB_ID="gui/${UID}/${LAUNCHD_JOB_NAME}"
LAUNCHD_PLIST_PATH="${HOME}/Library/LaunchAgents/${LAUNCHD_JOB_NAME}.plist"

STATE_FILE_PATH="${SCRIPT_DIR}/.kdbx-vault-sync.state"
LOCAL_BACKUP_DIR="${SCRIPT_DIR}/.kdbx-vault-sync-backups"
PAUSED_FLAG_PATH="${SCRIPT_DIR}/.kdbx-vault-sync.paused"

# Re-alert interval for persistent problems (conflicts, failures). An unset
# variable would evaluate as 0 in zsh arithmetic and re-alert on EVERY run,
# so a sane default is mandatory here.
REMINDER_INTERVAL_SECONDS="${REMINDER_INTERVAL_SECONDS:-14400}"   # 4 hours

# ---------------------------------------------------------------- helpers

timestamp() { date +%Y%m%d_%H%M%S; }

log_message() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

show_alert() {
    local alert_title="$1" alert_text="$2"
    # `display dialog` stays on screen until the user dismisses it — unlike
    # `display notification`, which auto-dismisses after a few seconds.
    # The alert intentionally BLOCKS this script run until dismissed; the
    # lock in cmd_run() prevents a second dialog from stacking up meanwhile.
    osascript \
        -e "display dialog \"${alert_text}\" with title \"${alert_title}\" with icon stop buttons {\"OK\"} default button \"OK\"" \
        >/dev/null 2>&1
}

# Show an alert for a problem, at most once per REMINDER_INTERVAL_SECONDS:
# a flag file records when the last alert fired. The first alert fires
# immediately; afterwards the problem reminds you once per interval until
# clear_notification_flag removes the flag (after a successful sync /
# resolution). This way dismissing the dialog is never the last you hear
# about an unresolved conflict or a failing sync.
notify_once() {
    local problem_key="$1" alert_text="$2"
    local notification_flag_file="${SCRIPT_DIR}/.kdbx-vault-sync.notified-${problem_key}"
    local now_seconds flag_seconds

    if [ -e "${notification_flag_file}" ]; then
        now_seconds=$(date +%s)
        flag_seconds=$(stat -f %m "${notification_flag_file}")
        if (( now_seconds - flag_seconds < REMINDER_INTERVAL_SECONDS )); then
            return   # last reminder still fresh — stay quiet
        fi
    fi
    show_alert "Vault Sync" "${alert_text}"
    touch "${notification_flag_file}"
}

clear_notification_flag() {
    # "$1" is the file name; clear ALL alert variants for it (not-in-state,
    # pulled, push-failed, remote-deleted, conflict, ...). Keys are always
    # "<file>-<reason>", so a prefix glob matches every variant at once.
    # null_glob: no matching flags is the normal case, not an error.
    setopt local_options null_glob
    rm -f "${SCRIPT_DIR}/.kdbx-vault-sync.notified-${1}"-*
    rm -f "${SCRIPT_DIR}/.kdbx-vault-sync.notified-${1}"
}

# Print the paths of all syncable vault files in the script directory.
# NOTE: written in bash-compatible style (no zsh glob qualifiers like (N)
# and no ${~pattern} expansion) so syntax highlighters cope with it.
# Excluded: stale conflict copies (*.old.kdbx, *conflict*) and KeeShare
# containers (*.keshare).
list_vault_files() {
    local vault_file_path
    # zsh: unmatched globs must expand to nothing, not abort (bash default).
    setopt local_options null_glob
    for vault_file_path in "${SCRIPT_DIR}"/*.kdbx "${SCRIPT_DIR}"/*.keyx; do
        # no match -> the literal pattern survives the glob; skip it
        [ -e "${vault_file_path}" ] || continue
        case "$(basename "${vault_file_path}")" in
            *.old.kdbx | *conflict* | *.keshare) continue ;;
        esac
        echo "${vault_file_path}"
    done
}

# SHA-256 of a local file; empty string if the file does not exist.
compute_local_hash() {
    if [ -f "$1" ]; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo ""
    fi
}

# Run an rclone command, writing rclone's stderr into the log file (timestamped,
# prefixed "rclone:") so remote/transfer output leaves a trace instead of being
# silently discarded. stdout is passed through unchanged; the return value is
# rclone's exit code. The log lines are written to STDERR, so capturing
# run_rclone's stdout in $(...) never mixes log lines into the captured value.
run_rclone() {
    local rclone_stderr_file rclone_line rclone_rc
    rclone_stderr_file=$(mktemp "${TMPDIR:-/tmp}/kdbx-vault-sync.rclone.XXXXXX")
    if [ -n "${rclone_stderr_file}" ]; then
        rclone "$@" 2>"${rclone_stderr_file}"
        rclone_rc=$?
        while IFS= read -r rclone_line; do
            # Skip the recurring host-key NOTICE — pure noise at a 60s run interval.
            # Silence it permanently by setting known_hosts_file=none on the remote.
            [[ "${rclone_line}" == *"No host key validation is being performed"* ]] && continue
            [ -z "${rclone_line}" ] && continue
            log_message "rclone: ${rclone_line}" >&2
        done < "${rclone_stderr_file}"
        rm -f "${rclone_stderr_file}"
    else
        # No temp file available — let stderr flow into the script's own stderr
        # (which the .app launcher/launchd already route into the log file).
        rclone "$@"
        rclone_rc=$?
    fi
    return "${rclone_rc}"
}

# Print "<size>|<mtime>" for a remote file, "|" if it does not exist, or
# "ERROR" if the remote could not be queried at all. The distinction matters:
# a failed query must NEVER be interpreted as "the file was deleted".
# The whole vault dir is listed instead of the single file, because lsjson on
# a missing FILE exits non-zero just like an unreachable remote does — a
# successful listing that simply lacks the entry is the only reliable
# "file does not exist" answer.
fetch_remote_stat() {
    local vault_file_name="$1" listing_json
    if ! listing_json=$(run_rclone lsjson "${REMOTE_ALIAS}"); then
        echo "ERROR"
        return 0
    fi
    printf '%s' "${listing_json}" | python3 -c '
import json, sys
name = sys.argv[1]
try:
    entries = json.load(sys.stdin)
except Exception:
    entries = []
for entry in entries:
    if not entry.get("IsDir") and entry["Name"] == name:
        print(str(entry["Size"]) + "|" + str(entry["ModTime"]))
        break
else:
    print("|")' "${vault_file_name}"
}

# fetch_remote_stat with retries — used right after a successful transfer,
# when the remote was demonstrably reachable moments ago. Never returns
# "ERROR": if the stat cannot be re-read, it falls back to "|" — that makes
# the next run take the PULL path, which pulls the (identical) content and
# repairs the baseline, instead of leaving a corrupt "ERROR" entry in the
# state file (which would look like "both sides changed" -> false CONFLICT).
refresh_baseline_remote_stat() {
    local remote_stat attempt
    for attempt in 1 2 3; do
        remote_stat=$(fetch_remote_stat "$1")
        [ "${remote_stat}" != "ERROR" ] && break
        [ "${attempt}" -lt 3 ] && sleep 2
    done
    if [ "${remote_stat}" = "ERROR" ]; then
        log_message "WARN: could not re-read the remote stat for $1 after transfer — writing a placeholder baseline; the next run will self-heal it via a content-identical pull" >&2
        remote_stat="|"
    fi
    print -- "${remote_stat}"
}

# Print the raw baseline state entry "<name>|<hash>|<size>|<mtime>", if present.
state_entry_for_file() {
    local vault_file_name="$1"
    grep -m1 "^${vault_file_name}|" "${STATE_FILE_PATH}" 2>/dev/null || true
}

# Remove a file's entry from the state file (used by the `remove` command).
remove_state_entry() {
    local vault_file_name="$1"
    local temp_state_file="${STATE_FILE_PATH}.tmp"
    grep -v "^${vault_file_name}|" "${STATE_FILE_PATH}" 2>/dev/null > "${temp_state_file}" || true
    mv "${temp_state_file}" "${STATE_FILE_PATH}"
}

# Split a state entry into baseline_local_hash and baseline_remote_stat.
# The remote part is normalized so a missing remote file is always "|"
# (a freshly initialized state stores "||", i.e. an empty remote field).
split_state_entry() {
    local state_entry="$1"
    local remainder="${state_entry#*|}"              # <hash>|<size>|<mtime>
    local baseline_local_hash="${remainder%%|*}"
    local baseline_remote_stat="${remainder#*|}"     # <size>|<mtime>
    [ -z "${baseline_remote_stat}" ] && baseline_remote_stat="|"
    print "${baseline_local_hash} ${baseline_remote_stat}"
}

# Rewrite the state entry for one file: $1=name $2=local_hash $3=remote "size|mtime"
write_state_entry() {
    local vault_file_name="$1" local_hash="$2" remote_stat="$3"
    local temp_state_file="${STATE_FILE_PATH}.tmp"
    grep -v "^${vault_file_name}|" "${STATE_FILE_PATH}" 2>/dev/null > "${temp_state_file}" || true
    echo "${vault_file_name}|${local_hash}|${remote_stat}" >> "${temp_state_file}"
    mv "${temp_state_file}" "${STATE_FILE_PATH}"
}

# Conflict markers live next to the vault file: CONFLICT_<name>.txt
conflict_marker_path_for() {
    print "${SCRIPT_DIR}/CONFLICT_$(basename "$1").txt"
}

has_conflict_marker() {
    [ -e "$(conflict_marker_path_for "$1")" ]
}
# ---------------------------------------------------------------- commands

# Interactively create the config file if it does not exist yet.
# Only called from cmd_init — every other command just refuses to run.
ensure_config_file_interactive() {
    if [ -f "${CONFIG_FILE_PATH}" ]; then
        return 0
    fi
    echo "No config file found: ${CONFIG_FILE_PATH}"
    echo "It must define the rclone remote alias this vault syncs to."
    echo "Leave empty to abort."
    printf "rclone remote alias (e.g. my-remote:): "
    read -r entered_remote_alias </dev/tty
    entered_remote_alias="${entered_remote_alias//" "/}"   # strip whitespace
    if [ -z "${entered_remote_alias}" ]; then
        echo "Aborted — no config written."
        exit 1
    fi
    echo "REMOTE_ALIAS=\"${entered_remote_alias}\"" > "${CONFIG_FILE_PATH}"
    echo "Config written: ${CONFIG_FILE_PATH}"
    echo
}

cmd_init() {
    ensure_config_file_interactive
    touch "${STATE_FILE_PATH}"
    local vault_file_path vault_file_name
    local added_count=0 updated_count=0
    while IFS= read -r vault_file_path; do
        vault_file_name=$(basename "${vault_file_path}")
        if [ -n "$(state_entry_for_file "${vault_file_name}")" ]; then
            # Known file: only re-baseline it in full-init mode. In the default
            # (safe) mode its baseline stays untouched — a stale baseline for a
            # file whose remote changed would silently mask a divergence.
            if [ "${INIT_MODE}" = "full" ]; then
                local full_init_remote_stat
                full_init_remote_stat=$(fetch_remote_stat "${vault_file_name}")
                if [ "${full_init_remote_stat}" = "ERROR" ]; then
                    log_message "ERROR: could not query the remote for ${vault_file_name} — baseline NOT re-recorded (re-run 'init full' when the remote is reachable)"
                    continue
                fi
                write_state_entry \
                    "${vault_file_name}" \
                    "$(compute_local_hash "${vault_file_path}")" \
                    "${full_init_remote_stat}"
                log_message "init: ${vault_file_name} baseline re-recorded (full init)"
                updated_count=$((updated_count+1))
            fi
        else
            # Unknown file: record its baseline. If a remote copy exists, the
            # local file becomes the authority (it exists locally; a remote
            # divergence for a never-synced file is resolved by KeePassXC).
            local new_file_remote_stat
            new_file_remote_stat=$(fetch_remote_stat "${vault_file_name}")
            if [ "${new_file_remote_stat}" = "ERROR" ]; then
                log_message "ERROR: could not query the remote for ${vault_file_name} — file NOT added to the state (re-run init when the remote is reachable)"
                continue
            fi
            write_state_entry \
                "${vault_file_name}" \
                "$(compute_local_hash "${vault_file_path}")" \
                "${new_file_remote_stat}"
            log_message "init: ${vault_file_name} baseline recorded (new file)"
            added_count=$((added_count+1))
        fi
    done < <(list_vault_files)
    if [ "${INIT_MODE}" = "full" ]; then
        log_message "full init done: ${updated_count} re-baselined, ${added_count} new. Full init re-records ALL baselines —"
        log_message "if local and remote were diverging, reconcile by hand first (open both in KeePassXC and merge)."
    else
        log_message "init done: ${added_count} new file(s) added, existing baselines untouched."
        log_message "Use 'init full' to re-record baselines for ALL files (after manual reconciliation)."
    fi
}

cmd_status() {
    local vault_file_path vault_file_name
    local current_local_hash current_remote_stat state_entry
    local baseline_local_hash baseline_remote_stat
    local local_state remote_state
    printf "%-40s %-12s %-12s\n" "FILE" "LOCAL" "REMOTE"
    if [ -e "${PAUSED_FLAG_PATH}" ]; then
        print "NOTE: schedule is PAUSED ($(cat "${PAUSED_FLAG_PATH}")) — resume with './kdbx-vault-sync.sh resume'"
        print ""
    fi
    while IFS= read -r vault_file_path; do
        vault_file_name=$(basename "${vault_file_path}")
        current_local_hash=$(compute_local_hash "${vault_file_path}")
        current_remote_stat=$(fetch_remote_stat "${vault_file_name}")
        state_entry=$(state_entry_for_file "${vault_file_name}")
        local_state="unchanged"
        remote_state="unchanged"
        if [ -n "${state_entry}" ]; then
            # state entry format: <name>|<local_hash>|<size>|<mtime>
            local state_remainder="${state_entry#*|}"
            baseline_local_hash="${state_remainder%%|*}"
            baseline_remote_stat="${state_remainder#*|}"
            [ "${current_local_hash}" != "${baseline_local_hash}" ] && local_state="CHANGED"
            if [ "${current_remote_stat}" = "ERROR" ]; then
                remote_state="UNKNOWN"
            elif [ "${current_remote_stat}" != "${baseline_remote_stat}" ]; then
                remote_state="CHANGED"
            fi
        fi
        has_conflict_marker "${vault_file_path}" && local_state="CONFLICT"

        printf "%-40s %-12s %-12s\n" "${vault_file_name}" "${local_state}" "${remote_state}"
    done < <(list_vault_files)
}

# One sync run. Per file: push / pull / conflict — never a silent overwrite.
cmd_run() {
    # Simple in-process lock: the alert dialog below blocks until dismissed,
    # and this run interval is only 60s — so make sure a blocked run cannot
    # overlap with the next launchd run (which would stack up dialogs).
    local lock_file="${SCRIPT_DIR}/.kdbx-vault-sync.lock"
    if ! mkdir "${lock_file}" 2>/dev/null; then
        # A lock without a running kdbx-vault-sync process is stale (left over
        # from a SIGKILLed run — the EXIT trap does not fire on SIGKILL). In
        # that case remove it and retry once; only report "in progress" if a
        # live process actually holds it.
        local lock_pid
        lock_pid=$(pgrep -f "kdbx-vault-sync.sh" | grep -v "^$$\$" | head -1)
        if [ -z "${lock_pid}" ]; then
            log_message "removing stale lock ${lock_file} (no running kdbx-vault-sync process)"
            rmdir "${lock_file}" 2>/dev/null
            if ! mkdir "${lock_file}" 2>/dev/null; then
                log_message "ERROR: could not re-acquire lock ${lock_file} — skipping this run"
                exit 1
            fi
        else
            log_message "another kdbx-vault-sync run is in progress (pid ${lock_pid}) — skipping"
            exit 0
        fi
    fi
    # NOTE: lock_file is expanded NOW (double quotes), not at trap-fire time —
    # a function-local variable would be out of scope when the trap runs.
    trap "rmdir '${lock_file}' 2>/dev/null" EXIT INT TERM

    if [ -e "${PAUSED_FLAG_PATH}" ]; then
        log_message "NOTE: schedule is paused ($(cat "${PAUSED_FLAG_PATH}")) — this is a manual run."
    fi

    if [ ! -s "${STATE_FILE_PATH}" ]; then
        log_message "ERROR: no state file — run './kdbx-vault-sync.sh init' first."
        notify_once "state-missing" "Vault Sync not initialized — run init"
        exit 1
    fi

    local vault_file_path vault_file_name state_entry
    local baseline_local_hash baseline_remote_stat
    local current_local_hash current_remote_stat
    local conflict_marker_path confirm_remote_stat
    local failure_count=0 conflict_count=0 unchanged_count=0 transferred_count=0

    # Orphaned state entries: the state tracks a file that no longer exists
    # locally. Do NOT delete or restore anything automatically — alert instead
    # and let the user decide (re-create the file, or run `remove FILE`).
    local orphan_line orphan_name orphan_remote_stat missing_count=0
    while IFS= read -r orphan_line; do
        orphan_name="${orphan_line%%|*}"
        if [ ! -e "${SCRIPT_DIR}/${orphan_name}" ]; then
            # If the remote cannot be queried, stay silent: the file might
            # only be re-listed once the remote is reachable again.
            orphan_remote_stat=$(fetch_remote_stat "${orphan_name}")
            [ "${orphan_remote_stat}" = "ERROR" ] && continue
            log_message "WARN: ${orphan_name} is tracked but has been deleted locally. The remote copy is kept. Restore the file, or run './kdbx-vault-sync.sh remove ${orphan_name}' to remove it from syncing."
            notify_once "${orphan_name}-locally-deleted" \
                "Vault Sync: ${orphan_name} was deleted locally but is still synced to the remote. Restore the file, or run './kdbx-vault-sync.sh remove ${orphan_name}' to remove it from syncing."
            missing_count=$((missing_count+1))
        fi
    done < "${STATE_FILE_PATH}"

    # Adopt remote-only files: a file that exists on the remote but neither
    # locally nor in the state was created by ANOTHER HOST. Pull it down —
    # this cannot overwrite anything (no local copy exists) — record the
    # baseline from the pulled content, and alert so the arrival is visible.
    local remote_listing remote_entry remote_name remote_listing_json
    remote_listing_json=""
    if ! remote_listing_json=$(run_rclone lsjson "${REMOTE_ALIAS}"); then
        log_message "WARN: could not list the remote — skipping remote-only file adoption this run"
    fi
    remote_listing=$(printf '%s' "${remote_listing_json}" | python3 -c '
import json, sys
try:
    entries = json.load(sys.stdin)
except Exception:
    entries = []
for e in entries:
    if not e.get("IsDir") and (e["Name"].endswith(".kdbx") or e["Name"].endswith(".keyx")):
        print(e["Name"])')
    while IFS= read -r remote_name; do
        [ -z "${remote_name}" ] && continue
        # skip everything this host already knows or has
        if [ -n "$(state_entry_for_file "${remote_name}")" ]; then
            continue   # already tracked
        fi
        if [ -e "${SCRIPT_DIR}/${remote_name}" ]; then
            continue   # exists locally but untracked -> handled by the WARN above
        fi
        log_message "adopting remote-only file ${remote_name} (created on another host) — pulling"
        mkdir -p "${LOCAL_BACKUP_DIR}"
        if run_rclone copyto "${REMOTE_ALIAS}${remote_name}" "${SCRIPT_DIR}/${remote_name}"; then
            write_state_entry \
                "${remote_name}" \
                "$(compute_local_hash "${SCRIPT_DIR}/${remote_name}")" \
                "$(refresh_baseline_remote_stat "${remote_name}")"
            log_message "ADOPTED: ${remote_name} pulled from ${REMOTE_ALIAS} and added to sync"
            notify_once "${remote_name}-adopted" \
                "Vault Sync: new file ${remote_name} arrived from another host and was added to this vault's sync."
            transferred_count=$((transferred_count+1))
        else
            log_message "ERROR: could not pull remote-only file ${remote_name}"
            notify_once "${remote_name}-adopt-failed" \
                "Vault Sync: FAILED to pull new remote file ${remote_name}."
            failure_count=$((failure_count+1))
        fi
    done <<< "${remote_listing}"

    while IFS= read -r vault_file_path; do
        vault_file_name=$(basename "${vault_file_path}")
        state_entry=$(state_entry_for_file "${vault_file_name}")
        if [ -z "${state_entry}" ]; then
            log_message "WARN: ${vault_file_name} not in state file (created after init) — skipping. Re-run init."
            notify_once "${vault_file_name}-not-in-state" \
                "Vault Sync: ${vault_file_name} is not being synced (created after init). Run ./kdbx-vault-sync.sh init to include it."
            continue
        fi
        # state entry format: <name>|<local_hash>|<size>|<mtime>
        local state_remainder="${state_entry#*|}"
        baseline_local_hash="${state_remainder%%|*}"
        baseline_remote_stat="${state_remainder#*|}"
        # empty remote field means "remote file does not exist" -> "|"
        [ -z "${baseline_remote_stat}" ] && baseline_remote_stat="|"

        current_local_hash=$(compute_local_hash "${vault_file_path}")
        current_remote_stat=$(fetch_remote_stat "${vault_file_name}")

        # A failed remote query is NOT "the file was deleted" — treat it like
        # any other transient failure and retry on the next run.
        if [ "${current_remote_stat}" = "ERROR" ]; then
            log_message "ERROR: could not query the remote for ${vault_file_name} — skipping this file this run"
            notify_once "${vault_file_name}-remote-error" \
                "Vault Sync: could not reach the remote to check ${vault_file_name} — will retry"
            failure_count=$((failure_count+1))
            continue
        fi

        if has_conflict_marker "${vault_file_path}"; then
            log_message "CONFLICT unresolved: ${vault_file_name} (merge in KeePassXC, then: ./kdbx-vault-sync.sh resolve ${vault_file_name})"
            conflict_count=$((conflict_count+1))
            continue
        fi

        if [ "${current_local_hash}" = "${baseline_local_hash}" ] && \
           [ "${current_remote_stat}" = "${baseline_remote_stat}" ]; then
            clear_notification_flag "${vault_file_name}"
            log_message "in sync: ${vault_file_name}"
            unchanged_count=$((unchanged_count+1))
            continue   # nothing changed on either side
        fi

        if [ "${current_local_hash}" != "${baseline_local_hash}" ] && \
           [ "${current_remote_stat}" = "${baseline_remote_stat}" ]; then
            # ---- PUSH: only the local copy changed ----
            if [ "${current_remote_stat}" != "|" ]; then
                # Back up the remote version, but only if its content actually
                # differs from what we are about to push (avoid no-op backups).
                local remote_backup_needed=1
                if run_rclone copyto \
                        "${REMOTE_ALIAS}${vault_file_name}" \
                        "${LOCAL_BACKUP_DIR}/.remote-probe_${vault_file_name}"; then
                    if [ "$(compute_local_hash "${LOCAL_BACKUP_DIR}/.remote-probe_${vault_file_name}")" \
                         = "${current_local_hash}" ]; then
                        remote_backup_needed=0   # remote content == local content
                    fi
                    rm -f "${LOCAL_BACKUP_DIR}/.remote-probe_${vault_file_name}"
                fi
                if [ "${remote_backup_needed}" = 1 ]; then
                    if run_rclone copyto \
                            "${REMOTE_ALIAS}${vault_file_name}" \
                            "${REMOTE_BACKUP_ROOT}/$(timestamp)_${vault_file_name}"; then
                        log_message "backed up remote ${vault_file_name}"
                    else
                        log_message "ERROR: could not back up remote ${vault_file_name} — aborting push"
                        failure_count=$((failure_count+1))
                        continue
                    fi
                fi
            fi
            if run_rclone copyto "${vault_file_path}" "${REMOTE_ALIAS}${vault_file_name}"; then
                # Baseline must reflect the NEW remote state after the push.
                write_state_entry \
                    "${vault_file_name}" \
                    "${current_local_hash}" \
                    "$(refresh_baseline_remote_stat "${vault_file_name}")"
                log_message "PUSH ok: ${vault_file_name} -> ${REMOTE_ALIAS}"
                transferred_count=$((transferred_count+1))
                clear_notification_flag "${vault_file_name}"
            else
                log_message "ERROR: push failed for ${vault_file_name}"
                notify_once "${vault_file_name}-push-failed" "Vault Sync: push FAILED for ${vault_file_name}"
                failure_count=$((failure_count+1))
            fi

        elif [ "${current_local_hash}" = "${baseline_local_hash}" ] && \
             [ "${current_remote_stat}" != "${baseline_remote_stat}" ]; then
            # ---- PULL: only the remote copy changed ----
            # Guard: if the remote file NO LONGER EXISTS (stat became "|") and
            # the local copy still matches its baseline, the remote was deleted.
            # Deleting the local vault file automatically would be dangerous —
            if [ "${current_remote_stat}" = "|" ]; then
                # Remote file was deleted; the local copy is the only remaining
                # version, so restore it to the remote (never delete local).
                # A deletion claim this consequential must not rest on a single
                # observation: re-query once, and only act if the file is STILL
                # reported as missing.
                confirm_remote_stat=$(fetch_remote_stat "${vault_file_name}")
                if [ "${confirm_remote_stat}" != "|" ]; then
                    if [ "${confirm_remote_stat}" = "ERROR" ]; then
                        log_message "WARN: remote ${vault_file_name} looked missing, but the re-check failed — skipping this run (no action taken)"
                    else
                        log_message "WARN: remote ${vault_file_name} looked missing, but was visible again on re-check — skipping (transient remote state)"
                    fi
                    continue
                fi
                log_message "remote ${vault_file_name} was deleted (confirmed by re-check) — pushing local copy back (deletion not propagated)"
                notify_once "${vault_file_name}-remote-deleted" \
                    "Vault Sync: ${vault_file_name} was deleted on the remote but still exists locally. The local copy was pushed back to the remote. To remove the file from syncing on ALL hosts, delete it locally and run: ./kdbx-vault-sync.sh remove ${vault_file_name}"
                if run_rclone copyto "${vault_file_path}" "${REMOTE_ALIAS}${vault_file_name}"; then
                    write_state_entry \
                        "${vault_file_name}" \
                        "${current_local_hash}" \
                        "$(refresh_baseline_remote_stat "${vault_file_name}")"
                    transferred_count=$((transferred_count+1))
                    clear_notification_flag "${vault_file_name}"
                else
                    log_message "ERROR: could not re-push ${vault_file_name} after remote deletion"
                    failure_count=$((failure_count+1))
                fi
            else
                # The local version is replaced by the remote one. The user gets
                # a persistent alert (notify_once) so a pull is never silent —
                # in normal use it is another host's save arriving, but if it
                # surprises you (e.g. an old remote version overwriting a local
                # one), you see it immediately. Pre-pull local is backed up.
                local pre_pull_local_hash="${current_local_hash}"
                if [ -n "${current_local_hash}" ]; then
                    mkdir -p "${LOCAL_BACKUP_DIR}"
                    if cp -p "${vault_file_path}" "${LOCAL_BACKUP_DIR}/$(timestamp)_${vault_file_name}"; then
                        log_message "backed up local ${vault_file_name}"
                    fi
                fi
                if run_rclone copyto "${REMOTE_ALIAS}${vault_file_name}" "${vault_file_path}"; then
                    local pulled_local_hash
                    pulled_local_hash=$(compute_local_hash "${vault_file_path}")
                    write_state_entry \
                        "${vault_file_name}" \
                        "${pulled_local_hash}" \
                        "${current_remote_stat}"
                    if [ "${pulled_local_hash}" = "${pre_pull_local_hash}" ]; then
                        # Content was already identical — only size/mtime metadata
                        # differed on the remote. Nothing was really overwritten.
                        log_message "PULL ok (content already identical): ${vault_file_name} — only remote metadata differed, state updated"
                    else
                        log_message "PULL ok: ${REMOTE_ALIAS}${vault_file_name} -> ${vault_file_path}"
                        notify_once "${vault_file_name}-pulled" \
                            "Vault Sync: pulled remote version of ${vault_file_name}. Your previous local copy was backed up in .kdbx-vault-sync-backups/ (use ./kdbx-vault-sync.sh status to verify)."
                    fi
                    transferred_count=$((transferred_count+1))
                    clear_notification_flag "${vault_file_name}"
                else
                    log_message "ERROR: pull failed for ${vault_file_name}"
                    notify_once "${vault_file_name}-pull-failed" "Vault Sync: pull FAILED for ${vault_file_name}"
                    failure_count=$((failure_count+1))
                fi
            fi
        else
            # ---- CONFLICT: both sides changed — do NOT overwrite ----
            conflict_marker_path=$(conflict_marker_path_for "${vault_file_path}")
            mkdir -p "${LOCAL_BACKUP_DIR}"
            [ -n "${current_local_hash}" ] && \
                cp -p "${vault_file_path}" "${LOCAL_BACKUP_DIR}/$(timestamp)_local_${vault_file_name}"
            [ "${current_remote_stat}" != "|" ] && [ "${current_remote_stat}" != "ERROR" ] && \
                run_rclone copyto "${REMOTE_ALIAS}${vault_file_name}" \
                              "${REMOTE_BACKUP_ROOT}/$(timestamp)_remote_${vault_file_name}"
            {
                echo "CONFLICT on ${vault_file_name} detected $(date)"
                echo "Both the local and the remote copy changed since the last sync."
                echo "A file sync tool must not choose a winner for a kdbx — merge by hand:"
                echo "  1. Open the local vault in KeePassXC."
                echo "  2. Use Database > Merge from database and pick the remote backup"
                echo "     copy listed below."
                echo "  3. Save, then run: ./kdbx-vault-sync.sh resolve ${vault_file_name}"
                echo
                echo "Local  backup: ${LOCAL_BACKUP_DIR}/<timestamp>_local_${vault_file_name}"
                echo "Remote backup: ${REMOTE_BACKUP_ROOT}/<timestamp>_remote_${vault_file_name}"
            } > "${conflict_marker_path}"
            log_message "CONFLICT: both sides changed for ${vault_file_name} — no auto-overwrite. See ${conflict_marker_path}"
            notify_once "${vault_file_name}-conflict" "Vault Sync: CONFLICT on ${vault_file_name} — manual merge needed"
            conflict_count=$((conflict_count+1))
        fi
    done < <(list_vault_files)

    if [ ${transferred_count} -eq 0 ] && [ ${conflict_count} -eq 0 ] && [ ${failure_count} -eq 0 ]; then
        log_message "All ${unchanged_count} vault file(s) in sync — nothing to do."
    fi
    [ ${conflict_count} -gt 0 ] && exit 2
    [ ${failure_count} -gt 0 ] && exit 1
    exit 0
}

cmd_resolve() {
    local vault_file_name="$1"
    local vault_file_path="${SCRIPT_DIR}/${vault_file_name}"
    local current_remote_stat merged_local_hash

    if [ -z "${vault_file_name}" ] || [ ! -f "${vault_file_path}" ]; then
        log_message "ERROR: no such file: ${vault_file_path}"
        exit 1
    fi
    if ! has_conflict_marker "${vault_file_path}"; then
        log_message "No conflict marker for ${vault_file_name} — nothing to resolve."
        exit 1
    fi

    # The local file is the freshly merged one. Back up the remote version,
    # push the merge, clear the conflict.
    current_remote_stat=$(fetch_remote_stat "${vault_file_name}")
    if [ "${current_remote_stat}" = "ERROR" ]; then
        log_message "ERROR: could not query the remote — resolve aborted, conflict marker kept."
        exit 1
    fi
    if [ "${current_remote_stat}" != "|" ]; then
        run_rclone copyto "${REMOTE_ALIAS}${vault_file_name}" \
                      "${REMOTE_BACKUP_ROOT}/$(timestamp)_preresolve_${vault_file_name}"
    fi
    merged_local_hash=$(compute_local_hash "${vault_file_path}")
    if run_rclone copyto "${vault_file_path}" "${REMOTE_ALIAS}${vault_file_name}"; then
        write_state_entry \
            "${vault_file_name}" \
            "${merged_local_hash}" \
            "$(fetch_remote_stat "${vault_file_name}")"
        rm -f "$(conflict_marker_path_for "${vault_file_path}")"
        clear_notification_flag "${vault_file_name}"
        log_message "RESOLVED: merged ${vault_file_name} pushed, conflict cleared."
    else
        log_message "ERROR: resolve push failed for ${vault_file_name} — conflict marker kept."
        notify_once "${vault_file_name}-resolve-failed" "Vault Sync: resolve FAILED for ${vault_file_name}"
        exit 1
    fi
}

# Remove a file from syncing entirely: back up local + remote copies, delete
# the remote file, drop the state entry. The local file itself is NOT deleted
# — removing it from disk stays the user's manual step.
cmd_remove() {
    local vault_file_name="$1"
    local vault_file_path="${SCRIPT_DIR}/${vault_file_name}"
    local current_remote_stat

    if [ -z "${vault_file_name}" ]; then
        log_message "ERROR: usage: kdbx-vault-sync.sh remove FILE"
        exit 1
    fi
    if [ -z "$(state_entry_for_file "${vault_file_name}")" ]; then
        log_message "ERROR: ${vault_file_name} is not in the state file — nothing to remove."
        exit 1
    fi

    # 1. Back up the local copy, if any.
    if [ -f "${vault_file_path}" ]; then
        mkdir -p "${LOCAL_BACKUP_DIR}"
        cp -p "${vault_file_path}" \
              "${LOCAL_BACKUP_DIR}/$(timestamp)_pre-remove_${vault_file_name}" &&
            log_message "backed up local ${vault_file_name}"
    fi

    # 2. Back up and delete the remote copy, if any.
    current_remote_stat=$(fetch_remote_stat "${vault_file_name}")
    if [ "${current_remote_stat}" != "|" ]; then
        if run_rclone copyto "${REMOTE_ALIAS}${vault_file_name}" \
                         "${REMOTE_BACKUP_ROOT}/$(timestamp)_remote-pre-remove_${vault_file_name}"; then
            log_message "backed up remote ${vault_file_name}"
            if run_rclone delete "${REMOTE_ALIAS}${vault_file_name}"; then
                log_message "deleted remote ${vault_file_name}"
            else
                log_message "ERROR: could not delete remote ${vault_file_name} — state entry kept, re-run 'remove ${vault_file_name}' later."
                notify_once "${vault_file_name}-remove-failed" \
                    "Vault Sync: FAILED to delete remote ${vault_file_name} during remove."
                exit 1
            fi
        else
            log_message "ERROR: could not back up remote ${vault_file_name} — aborting remove."
            exit 1
        fi
    fi

    # 3. Drop the state entry.
    remove_state_entry "${vault_file_name}"
    clear_notification_flag "${vault_file_name}"
    log_message "REMOVED: ${vault_file_name} is no longer synced (local file kept, remote copy deleted, both backed up)."
    if [ -f "${vault_file_path}" ]; then
        log_message "HINT: the local file ${vault_file_path} still exists. If it is obsolete, delete it manually."
        log_message "      Leaving it in place is fine, but it is no longer tracked — if you later modify it, run"
        log_message "      './kdbx-vault-sync.sh init' to start syncing it again (it would otherwise warn about being untracked)."
    fi
}

# ------------------------------------------------------- launchd plumbing
# (macOS Tahoe: launchd only starts signed binaries inside .app bundles,
#  so a tiny C launcher redirects stdout/stderr into a log and exec's zsh.)

cmd_init_app() {
    local launcher_source_path=$(mktemp /tmp/kdbx-vault-sync-launcher.XXXXXX.c)
    cat > "${launcher_source_path}" <<LAUNCHER_SOURCE
#include <fcntl.h>
#include <unistd.h>
int main(void) {
    int fd = open("${LOG_FILE_PATH}", O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
    char *launcher_args[] = { "/bin/zsh", "${SCRIPT_PATH}", (char *)0 };
    execv("/bin/zsh", launcher_args);
    return 1;
}
LAUNCHER_SOURCE
    echo "Building ${APP_BUNDLE_PATH} ..."
    mkdir -p "$(dirname "${APP_BINARY_PATH}")"
    clang -Os -o "${APP_BINARY_PATH}" "${launcher_source_path}" 2>&1
    rm -f "${launcher_source_path}"
    cat > "${APP_BUNDLE_PATH}/Contents/Info.plist" <<INFO_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key>  <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>  <string>${APP_BUNDLE_ID}</string>
    <key>LSBackgroundOnly</key>    <true/>
    <key>LSUIElement</key>         <true/>
</dict></plist>
INFO_PLIST
    codesign --sign - --force "${APP_BINARY_PATH}" 2>&1
    echo ""
    echo "App created at: ${APP_BUNDLE_PATH}"
    echo "Run: ./kdbx-vault-sync.sh init-background"
    exit 0
}

cmd_init_background() {
    if [ ! -x "${APP_BINARY_PATH}" ]; then
        echo "Error: App binary not found at ${APP_BINARY_PATH}"
        echo "Run './kdbx-vault-sync.sh init-app' first."
        exit 1
    fi
    cat > "${LAUNCHD_PLIST_PATH}" <<LAUNCHD_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>Label</key>
<string>${LAUNCHD_JOB_NAME}</string>
<key>Program</key>
<string>${APP_BINARY_PATH}</string>
<key>EnvironmentVariables</key>
<dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
</dict>
<key>StandardOutPath</key>
<string>${LOG_FILE_PATH}</string>
<key>StandardErrorPath</key>
<string>${LOG_FILE_PATH}</string>
<key>RunAtLoad</key>
<true />
<key>StartInterval</key>
<integer>60</integer>
</dict>
</plist>
LAUNCHD_PLIST
    echo "Created background job at ${LAUNCHD_PLIST_PATH}."
    launchctl bootout "${LAUNCHD_JOB_ID}" 2>/dev/null
    launchctl load -w "${LAUNCHD_PLIST_PATH}"
    echo ""
    echo "Service:      ${LAUNCHD_JOB_NAME}"
    echo "Inspect:      launchctl print ${LAUNCHD_JOB_ID}"
    echo "Stop (keep):  launchctl bootout ${LAUNCHD_JOB_ID}"
    echo "Stop (perm.): launchctl bootout ${LAUNCHD_JOB_ID} && rm ${LAUNCHD_PLIST_PATH}"
    exit 0
}

# Pause the scheduled sync: unload the launchd job (no further scheduled runs
# fire) and drop a marker file so the paused state survives reboots and is
# visible in `status`/manual runs. A run that is already in progress is NOT
# interrupted — killing it could cut a transfer or a state write mid-flight —
# it simply finishes on its own. Nothing is deleted; `resume` restores the
# exact previous setup.
cmd_pause() {
    if launchctl print "${LAUNCHD_JOB_ID}" >/dev/null 2>&1; then
        launchctl bootout "${LAUNCHD_JOB_ID}" 2>/dev/null
        log_message "PAUSED: launchd job ${LAUNCHD_JOB_NAME} unloaded — no further scheduled runs fire."
    else
        log_message "PAUSED: launchd job ${LAUNCHD_JOB_NAME} was not loaded (nothing to unload)."
    fi
    # Report (do not kill) a run that is currently in progress: it may be
    # mid-transfer or mid-state-write, and interrupting it is exactly what
    # pause must never do. It completes normally and releases its own lock.
    local running_pid
    running_pid=$(pgrep -f "kdbx-vault-sync.sh" | grep -v "^$$\$" | head -1)
    if [ -n "${running_pid}" ]; then
        log_message "PAUSED: a sync run is still in progress (pid ${running_pid}) — left alone to finish; no new runs will start."
    fi
    date '+paused at %Y-%m-%d %H:%M:%S' > "${PAUSED_FLAG_PATH}"
    log_message "Run './kdbx-vault-sync.sh resume' to restart the schedule."
}

# Resume the scheduled sync after `pause`: reload the launchd job. Because the
# job plist uses RunAtLoad, the reload triggers a sync run immediately, then
# the usual 60s interval continues.
cmd_resume() {
    if [ ! -f "${LAUNCHD_PLIST_PATH}" ]; then
        log_message "ERROR: no launchd job registered (${LAUNCHD_PLIST_PATH}) — run './kdbx-vault-sync.sh init-background' first."
        exit 1
    fi
    rm -f "${PAUSED_FLAG_PATH}"
    # Clear any half-loaded state first, so `load -w` cannot fail with
    # "already loaded" after an interrupted pause.
    launchctl bootout "${LAUNCHD_JOB_ID}" 2>/dev/null
    launchctl load -w "${LAUNCHD_PLIST_PATH}"
    log_message "RESUMED: launchd job ${LAUNCHD_JOB_NAME} reloaded — a sync run fires immediately (RunAtLoad), then every 60s."
}

# ------------------------------------------------------------------ main

case "$1" in
    init)            shift; INIT_MODE="$1"; cmd_init ;;
    status)          cmd_status ;;
    resolve)         shift; cmd_resolve "$1" ;;
    remove)          shift; cmd_remove "$1" ;;
    pause)           cmd_pause ;;
    resume)          cmd_resume ;;
    init-app)        cmd_init_app ;;
    init-background) cmd_init_background ;;
    *)               cmd_run ;;
esac
