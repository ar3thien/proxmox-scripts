#!/bin/bash
# ===== ONLY RUN ON BACKUP END =====
PHASE="${1:-}"
MODE="${2:-}"
VMID="${3:-}"
VMTYPE="${VMTYPE:-unknown}"

if [ "$PHASE" != "backup-end" ]; then
    exit 0
fi

# ===== GET VMNAME =====
if [ "$VMTYPE" = "lxc" ]; then
    VMNAME=$(pct config "$VMID" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}')
else
    VMNAME=$(qm config "$VMID" 2>/dev/null | awk -F': ' '/^name:/ {print $2}')
fi

# ===== CONFIG =====
LOG_FILE=$(mktemp)
#trap 'rm -f "$LOG_FILE"' EXIT
RCLONE_BIN="/usr/bin/rclone"
#RCLONE_LOG="--log-file $LOG_FILE --log-level INFO"
RCLONE_LOG=(--log-file "$LOG_FILE" --log-level INFO)
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
#--log-file-max-size 10M --log-file-max-backups 3 

# ===== FUNCTIONS =====
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

log_rclone_result() {
    local exit_code="$1"
    local action="$2"
    local exit_desc=""

    case "$exit_code" in
        0)  exit_desc="SUCCESS - completed without errors" ;;
        1)  exit_desc="GENERIC ERROR - not otherwise categorised" ;;
        2)  exit_desc="USAGE ERROR - syntax or invalid arguments" ;;
        3)  exit_desc="NOT FOUND - source or destination path missing" ;;
        4)  exit_desc="FILE NOT FOUND" ;;
        5)  exit_desc="TEMPORARY ERROR - retry may succeed" ;;
        6)  exit_desc="PARTIAL FAILURE - some transfers failed" ;;
        7)  exit_desc="FATAL ERROR - unrecoverable failure" ;;
        8)  exit_desc="LIMIT REACHED - max transfer exceeded" ;;
        9)  exit_desc="NO TRANSFER - nothing to sync" ;;
        10) exit_desc="DURATION LIMIT - max duration exceeded" ;;
        *)  exit_desc="UNKNOWN EXIT CODE" ;;
    esac

    log "rclone ${action:-operation} code ($exit_code) - $exit_desc"

        # "return" the description via stdout
    echo "$exit_desc"
}

# ===== STEP 0: Ensure log file exists =====
#if [ ! -f "$LOG_FILE" ]; then
#    touch "$LOG_FILE"
#    chmod 644 "$LOG_FILE"
#fi

# ===== STEP 1: Log start =====
log "===== SCRIPT START ====="
log "Phase=$PHASE VMNAME=$VMNAME VMID=$VMID VMTYPE=$VMTYPE Mode=$MODE DumpDir=$DUMPDIR"

# ===== STEP 2: Try to update rclone (non-blocking) =====
log "Checking rclone update..."
#$RCLONE_BIN selfupdate $RCLONE_LOG
"$RCLONE_BIN" selfupdate "${RCLONE_LOG[@]}" --config "$RCLONE_CONFIG"
UPDATE_EXIT=$?
UPDATE_DESC=$(log_rclone_result "$UPDATE_EXIT" "selfupdate")

# ===== STEP 3: Run rclone sync (ONLY ONCE) =====
log "Starting rclone sync..."

"$RCLONE_BIN" sync /var/lib/vz/dump gdrive_union:/pvebackup/PVE2 \
    --modify-window 2s \
    --retries-sleep 31s \
    --delete-before \
    --max-age 335h \
    --delete-excluded \
    --retries 3 \
    --stats-one-line \
    --exclude vzdump-qemu-* \
    --config "$RCLONE_CONFIG" \
    "${RCLONE_LOG[@]}" 
SYNC_EXIT=$?
SYNC_DESC=$(log_rclone_result "$SYNC_EXIT" "sync")

# ===== STEP 4: End log =====
log "===== SCRIPT END ====="

# ===== STEP 5: Send mail =====
MAIL_TO="root"
HOSTNAME=$(hostname)
SUBJECT="[RCLONE] $VMNAME sync=$SYNC_EXIT update=$UPDATE_EXIT on $HOSTNAME"
{
echo "From: rclone@${HOSTNAME}"
echo "To: $MAIL_TO"
echo "Subject: $SUBJECT"
echo "Content-Type: text/plain; charset=UTF-8"
echo
echo "Rclone sync report - $HOSTNAME"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo
echo "Update exit code: $UPDATE_EXIT"
echo "Update description: $UPDATE_DESC"
echo
echo "Sync exit code: $SYNC_EXIT"
echo "Sync description: $SYNC_DESC"
echo
echo "Full log:"
cat "$LOG_FILE"
} | /usr/sbin/sendmail -t

# ===== STEP 6: Cleanup =====
rm -f "$LOG_FILE"
