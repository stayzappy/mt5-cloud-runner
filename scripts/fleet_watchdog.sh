#!/usr/bin/env bash
# ==============================================================================
# MT5 Fleet Watchdog
# Dispatches a replacement cloud session when the fleet is offline and no
# healthy session is running. Safe by construction:
#   - never dispatches while a run is active and younger than 25 minutes
#     (that run is cold-booting; the harness needs ~15 minutes)
#   - only replaces an older run (>= 25 min) whose fleet is verifiably DOWN
#   - never dispatches outside the 00:15-17:30 WAT trading window or weekends
#   - never dispatches when the Worker API is unreachable (fail-safe standby)
# ==============================================================================
set -euo pipefail

REPO="${WATCHDOG_REPO:-stayzappy/mt5-cloud-runner}"
WORKFLOW_FILE="${WATCHDOG_WORKFLOW:-cloud_trading.yml}"
WORKER_URL="${CONTROL_WORKER_URL:-https://mt5-control-studio.zapstream.workers.dev}"

log() { echo "[watchdog $(TZ="Africa/Lagos" date '+%H:%M:%S')] $*"; }

# 1. Trading window guard (WAT). Market open Mon 00:15 -> Fri 17:30 WAT.
eval "$(TZ="Africa/Lagos" date '+WDAY=%u WHOUR=%H WMIN=%M')"
MINUTES=$((10#$WHOUR * 60 + 10#$WMIN))
if [ "$WDAY" -ge 6 ]; then log "Weekend (WAT weekday=$WDAY): market closed. Standby."; exit 0; fi
if [ "$MINUTES" -lt 15 ] || [ "$MINUTES" -ge 1050 ]; then
    log "Outside 00:15-17:30 WAT trading window (min=$MINUTES). Standby."
    exit 0
fi

# 2. Fleet state from the Cloudflare Worker dashboard.
RESP=$(curl -s --max-time 25 "$WORKER_URL/api/dashboard" || true)
if [ -z "$RESP" ]; then log "Worker API unreachable. Standby."; exit 0; fi
STATE=$(printf '%s' "$RESP" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('api_error'); raise SystemExit
accs = [a for a in d.get('accounts', []) if a.get('enabled', True)]
if not accs:
    print('no_accounts'); raise SystemExit
labels = [(a.get('ui_view') or {}).get('status', {}).get('state_label') for a in accs]
print('all_online' if all(l == 'ONLINE' for l in labels) else 'down:' + ','.join(str(l) for l in labels))
")
case "$STATE" in
    all_online) log "Fleet ONLINE. Standby."; exit 0 ;;
    api_error|no_accounts) log "Fleet state '$STATE' (uninformative). Standby."; exit 0 ;;
esac
log "Fleet DOWN ($STATE). Checking for an active session..."

# 3. Active session check (most recent run of the trading workflow).
#    A healthy cold boot connects within ~20 minutes; anything older than 40
#    minutes with the fleet still down is treated as a zombie and replaced.
ACTIVE=$(gh run list --repo "$REPO" --workflow "$WORKFLOW_FILE" --limit 1 \
           --json status,startedAt --jq '.[0] | "\(.status) \(.startedAt)"' 2>/dev/null || true)
STATUS=$(printf '%s' "$ACTIVE" | awk '{print $1}')
STARTED=$(printf '%s' "$ACTIVE" | awk '{print $2}')

if [ -n "$STATUS" ] && [ "$STATUS" != "null" ] && [ "$STATUS" != "completed" ] && [ "$STATUS" != "cancelled" ] && [ "$STATUS" != "failure" ] && [ "$STATUS" != "success" ]; then
    # A run is in progress/queued. Give it time to cold-boot before judging it.
    NOW=$(date -u +%s)
    START_TS=$(date -u -d "$STARTED" +%s 2>/dev/null || echo 0)
    AGE=$(( (NOW - START_TS) / 60 ))
    if [ "$AGE" -lt 40 ]; then
        log "Active session (status=$STATUS, age=${AGE}m) is still booting. Standby."
        exit 0
    fi
    log "Active session is a ZOMBIE (status=$STATUS, age=${AGE}m, fleet down). Replacing it."
else
    log "No active session and fleet is down."
fi

# 4. Dispatch a replacement session (continuous mode; next cron takes over).
#    Phase 1 safety: dispatch into the SAME slot as the zombie so per-slot
#    concurrency cancels it before the replacement boots (single-trader
#    guarantee). Phase 2 warm-standby flips this to the alternate slot.
ACTIVE_SLOT=$(gh run list --repo "$REPO" --workflow "$WORKFLOW_FILE" --limit 5 \
              --json status,displayTitle 2>/dev/null | python3 -c "
import json, sys
try:
    runs = json.load(sys.stdin)
except Exception:
    raise SystemExit
for r in runs:
    if r.get('status') in ('in_progress', 'queued'):
        t = str(r.get('displayTitle') or '')
        if 'green' in t.lower():
            print('green'); raise SystemExit
        if 'blue' in t.lower():
            print('blue'); raise SystemExit
raise SystemExit
" || true)
DISPATCH_SLOT="${ACTIVE_SLOT:-blue}"

DISPATCH_CMD=(gh workflow run "$WORKFLOW_FILE" --repo "$REPO"
              -f force=false -f dry_run=false -f window_mode=false -f target_account=
              -f slot="$DISPATCH_SLOT")
if [ "${WATCHDOG_DRY_RUN:-0}" = "1" ]; then
    log "DRY RUN - would dispatch: ${DISPATCH_CMD[*]}"
    exit 0
fi
log "Dispatching replacement session (slot=$DISPATCH_SLOT, active slot='${ACTIVE_SLOT:-none}'): ${DISPATCH_CMD[*]}"
"${DISPATCH_CMD[@]}"
log "Replacement session dispatched."