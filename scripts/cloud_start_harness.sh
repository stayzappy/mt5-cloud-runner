#!/usr/bin/env bash
# ==============================================================================
# MT5 Cloud Runner Harness - Headless Cloud Session Bootstrapper
# Pulls compiled standalone engine over-the-air (OTA) and executes in window-mode
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p logs data

echo "===================================================================="
echo "   STARTING MT5 CLOUD RUNNER HARNESS (HEADLESS MULTI-ACCOUNT)"
echo "   Host Time (UTC): $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "===================================================================="

# Weekend Dormancy Check (Saturday / Sunday in WAT)
DAY_OF_WEEK=$(TZ="Africa/Lagos" date +%u)
if [ "$DAY_OF_WEEK" -ge 6 ] && [ "${FORCE_RUN:-false}" != "true" ]; then
    echo "[Cloud Harness] Weekend Dormancy: Markets closed. Standby until Monday 00:15 WAT. Clean exit."
    exit 0
fi

# 1. Download compiled standalone engine binary from private release (OTA)
echo "[Cloud Harness] Pulling latest standalone engine binary from private repository..."
gh release download latest-engine \
    --repo stayzappy/mt5-forex-bot \
    --pattern "mt5_trader_engine-linux-x86_64.tar.gz" \
    --clobber

tar -xzf mt5_trader_engine-linux-x86_64.tar.gz
chmod +x mt5_trader_engine

echo "[Cloud Harness] Engine binary verified: $(./mt5_trader_engine --help | head -n 2 | tail -n 1)"

# Check and pull modern MT5 package if available in release
if gh release view latest-engine --repo stayzappy/mt5-forex-bot --json assets -q '.assets[].name' 2>/dev/null | grep -q "mt5_modern_build.tar.gz"; then
    echo "[Cloud Harness] Pulling modern MT5 pre-packaged build from release..."
    gh release download latest-engine \
        --repo stayzappy/mt5-forex-bot \
        --pattern "mt5_modern_build.tar.gz" \
        --dir data \
        --clobber || true
fi

# 2. Pull live account configurations and secrets from Cloudflare Worker
echo "[Cloud Harness] Pulling account profiles and remote configuration from Worker..."
CONTROL_WORKER_URL="${CONTROL_WORKER_URL:-https://mt5-control-studio.zapstream.workers.dev}"

python3 scripts/sync_accounts.py


# 4. Start Docker containers
if [ -f "data/active_services.txt" ] && [ -s "data/active_services.txt" ]; then
    ACTIVE_SERVICES=$(tr '\n' ' ' < data/active_services.txt)
    echo "[Cloud Harness] Starting active Docker MT5 headless container(s): $ACTIVE_SERVICES..."
    docker compose up -d $ACTIVE_SERVICES
else
    echo "[Cloud Harness] Starting Docker MT5 headless containers..."
    docker compose up -d
fi

echo "[Cloud Harness] Waiting 10s for container initialization..."
sleep 10

echo "[Cloud Harness] Configuring auto-login mt5cfg.ini and Exness servers for active accounts..."
python3 scripts/configure_terminals.py

# 5. Wait for active RPyC bridges to become fully ready
echo "[Cloud Harness] Validating active MT5 RPyC bridges..."
python3 << 'EOF'
import os, sys, time, json, subprocess

if not os.path.exists('data/active_accounts.json'):
    sys.exit(0)

with open('data/active_accounts.json') as f:
    active = json.load(f)

for a in active:
    cname = a['container']
    port = int(a['rpyc_port'])
    aid = a['id']
    print(f'[Cloud Harness] Probing MT5 RPyC bridge in container {cname} (port 18812 / host {port} for {aid})...')
    ok = False
    for attempt in range(1, 46):
        cmd = ['docker', 'exec', cname, 'python3', '-c', 'import socket; s = socket.socket(); s.settimeout(2.0); s.connect(("127.0.0.1", 18812)); s.close()']
        res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode == 0:
            ok = True
            print(f'[Cloud Harness] MT5 RPyC bridge in container {cname} is LISTENING and READY (attempt {attempt}).')
            # Diagnostic: Dump MT5 internal terminal daily log to inspect broker connection state
            print(f'=== MT5 Terminal Daily Connection Logs for {cname} ({aid}) ===')
            log_res = subprocess.run(['docker', 'exec', cname, 'sh', '-c', 'LOG=$(find /opt/wineprefix -name "202*.log" -printf "%T@ %p\\n" 2>/dev/null | sort -nr | head -n 1 | cut -d" " -f2-); if [ -n "$LOG" ]; then cat "$LOG"; else echo "No daily log found"; fi'], capture_output=True)
            raw_bytes = log_res.stdout or b''
            try:
                decoded = raw_bytes.decode('utf-16le', errors='replace')
            except Exception:
                decoded = raw_bytes.decode('utf-8', errors='replace')
            for line in decoded.splitlines()[-40:]:
                if line.strip():
                    print(f'   [{cname}] {line.strip()}')
            break
        time.sleep(2.0)
    if not ok:
        print(f'[Cloud Harness] ERROR: Container {cname} bridge failed to initialize within 90s.', file=sys.stderr)
        print(f'=== Container logs for {cname} ===', file=sys.stderr)
        subprocess.run(['docker', 'logs', '--tail', '50', cname])
        try:
            tg_msg = (
                f"🚨 <b>CLOUD RUNNER BOOT FAULT</b>\n\n"
                f"👤 <b>Account:</b> {aid} (Container: <code>{cname}</code>)\n"
                f"❌ <b>Error:</b> MT5 RPyC bridge failed to bind on port 18812 within 90s!\n"
                f"👉 <i>Runner terminated early to prevent hanging. Check runner logs.</i>"
            )
            subprocess.run([
                "curl", "-s", "-m", "5", "-X", "POST",
                "https://api.telegram.org/bot8867158689:AAENm3RlSVivy3ZDlqngO7v0fzNBwpBGG_M/sendMessage",
                "-d", "chat_id=1239030524",
                "-d", f"text={tg_msg}",
                "-d", "parse_mode=HTML"
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
        sys.exit(1)
print('[Cloud Harness] All active MT5 RPyC bridges verified ready.')
EOF
sleep 3

# 6. Launch bots dynamically for active accounts
WINDOW_FLAG="--window-mode"
if [ "${CONTINUOUS_SESSION:-false}" = "true" ] || [ "${EVENT_NAME:-}" != "schedule" ]; then
    echo "[Cloud Harness] Discretionary / Mobile session triggered (Event: ${EVENT_NAME:-manual}). Running in CONTINUOUS mode..."
    WINDOW_FLAG=""
else
    echo "[Cloud Harness] Automated scheduled cron session. Running with auto-exit --window-mode..."
fi

NUM_ACCOUNTS=0
if [ -f "data/active_accounts.txt" ]; then
    NUM_ACCOUNTS=$(grep -c '[^[:space:]]' data/active_accounts.txt || echo 0)
fi

if [ "$NUM_ACCOUNTS" -eq 0 ]; then
    echo "[Cloud Harness] No active accounts to run. Clean exit."
    exit 0
fi

# Multi-account: Run Unified Master-Slave Fleet Runner to conserve cloud runner resources
if [ "$NUM_ACCOUNTS" -gt 1 ]; then
    echo "[Cloud Harness] Launching Unified Master-Slave Fleet Runner ($NUM_ACCOUNTS accounts, Flags: '${WINDOW_FLAG:-continuous}')..."
    ./mt5_trader_engine --fleet $WINDOW_FLAG
else
    PIDS=()
    while IFS= read -r aid; do
        [ -z "$aid" ] && continue
        env_file=".env.$aid"
        if [ -f "$env_file" ]; then
            echo "[Cloud Harness] Launching bot for $aid via native binary (Flags: '${WINDOW_FLAG:-continuous}')..."
            ./mt5_trader_engine --env "$env_file" $WINDOW_FLAG &
            PIDS+=($!)
        fi
    done < data/active_accounts.txt
    echo "[Cloud Harness] ${#PIDS[@]} bot(s) executing in background (PIDs: ${PIDS[*]})."
    wait "${PIDS[@]}"
fi
echo "[Cloud Harness] Session complete. Clean exit."

