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

# Weekend Dormancy Check (Saturday / Sunday)
DAY_OF_WEEK=$(date -u +%u)
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

# 2. Pull live account configurations and secrets from Cloudflare Worker
echo "[Cloud Harness] Pulling account profiles and remote configuration from Worker..."
CONTROL_WORKER_URL="${CONTROL_WORKER_URL:-https://mt5-control-studio.zapstream.workers.dev}"

python3 scripts/sync_accounts.py


# 4. Start Docker containers
echo "[Cloud Harness] Starting Docker MT5 headless containers..."
docker compose up -d

echo "[Cloud Harness] Waiting 15s for Wine initialization..."
sleep 15

# Helper: Auto-login injection into container
inject_mt5_cfg() {
    local cname="$1"
    local env_file="$2"
    if [ ! -f "$env_file" ]; then return 0; fi

    local login_val pwd_val srv_val
    login_val=$(grep '^MT5_LOGIN=' "$env_file" | cut -d= -f2- | tr -d ' "\r')
    pwd_val=$(grep '^MT5_PASSWORD=' "$env_file" | cut -d= -f2- | tr -d ' "\r')
    srv_val=$(grep '^MT5_SERVER=' "$env_file" | cut -d= -f2- | tr -d ' "\r')

    docker exec "$cname" mkdir -p "/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config" 2>/dev/null || true
    if [ -f "config/servers.dat" ]; then
        docker cp "config/servers.dat" "$cname:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config/servers.dat" 2>/dev/null || true
    fi

    if [ -n "$login_val" ] && [ -n "$pwd_val" ]; then
        docker exec "$cname" sh -c "cat > '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/mt5cfg.ini' <<EOF
[Common]
Login=${login_val}
Password=${pwd_val}
Server=${srv_val}
NewsEnable=0
Profile=Blank
ProxyEnable=0
[Charts]
MaxBars=1000000
SelectOneClick=1
[Experts]
Enabled=1
Account=0
Profile=0
Chart=0
Api=0
[Events]
Enable=0
NewsEnable=0
EOF
cp '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/mt5cfg.ini' /mt5linux/mt5cfg.ini 2>/dev/null || true"
    fi
}

echo "[Cloud Harness] Configuring auto-login mt5cfg.ini and Exness servers for active accounts..."
python3 -c "
import json, subprocess, os, sys

if not os.path.exists('data/active_accounts.json'):
    print('[Cloud Harness] No active accounts found. Exiting cleanly.')
    sys.exit(0)

with open('data/active_accounts.json') as f:
    active = json.load(f)

for a in active:
    cname = a['container']
    env_file = a['env_file']
    print(f'[Cloud Harness] Injecting config for {a[\"id\"]} into container {cname}...')
    with open(env_file) as ef:
        lines = dict(line.strip().split('=', 1) for line in ef if '=' in line)
    login = lines.get('MT5_LOGIN', '')
    pwd = lines.get('MT5_PASSWORD', '')
    srv = lines.get('MT5_SERVER', 'Exness-MT5Trial9')

    subprocess.run(['docker', 'exec', cname, 'mkdir', '-p', '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config'], stderr=subprocess.DEVNULL)
    if os.path.exists('config/servers.dat'):
        subprocess.run(['docker', 'cp', 'config/servers.dat', f'{cname}:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config/servers.dat'], stderr=subprocess.DEVNULL)

    cfg_content = f'''[Common]
Login={login}
Password={pwd}
Server={srv}
NewsEnable=0
Profile=Blank
ProxyEnable=0
[Charts]
MaxBars=1000000
SelectOneClick=1
[Experts]
Enabled=1
Account=0
Profile=0
Chart=0
Api=0
[Events]
Enable=0
NewsEnable=0
'''
    p = subprocess.Popen(['docker', 'exec', '-i', cname, 'sh', '-c', 'cat > \"/opt/wineprefix/drive_c/Program Files/MetaTrader 5/mt5cfg.ini\" && cp \"/opt/wineprefix/drive_c/Program Files/MetaTrader 5/mt5cfg.ini\" /mt5linux/mt5cfg.ini'], stdin=subprocess.PIPE)
    p.communicate(input=cfg_content.encode())

    print(f'[Cloud Harness] Restarting container {cname} to load MT5 configuration...')
    subprocess.run(['docker', 'restart', cname], check=True)
"

# 5. Wait for active RPyC bridges to become fully ready (verifying real RPyC handshake)
echo "[Cloud Harness] Validating active MT5 RPyC bridges..."
if ! python3 -c "import rpyc" 2>/dev/null; then
    echo "[Cloud Harness] Installing rpyc for host bridge probe..."
    pip3 install --quiet --break-system-packages rpyc 2>/dev/null || pip3 install --quiet rpyc
fi

python3 -c "
import os, sys, time, json, rpyc

if not os.path.exists('data/active_accounts.json'):
    sys.exit(0)

with open('data/active_accounts.json') as f:
    active = json.load(f)

for a in active:
    port = int(a['rpyc_port'])
    aid = a['id']
    print(f'[Cloud Harness] Probing MT5 RPyC bridge on port {port} ({aid})...')
    ok = False
    for attempt in range(1, 46):
        try:
            conn = rpyc.classic.connect('localhost', port)
            conn._config['sync_request_timeout'] = 15
            _ = conn.modules['MetaTrader5']
            conn.close()
            ok = True
            print(f'[Cloud Harness] MT5 RPyC bridge on port {port} ({aid}) is READY (attempt {attempt}).')
            break
        except Exception:
            time.sleep(2.0)
    if not ok:
        print(f'[Cloud Harness] ERROR: Bridge on port {port} for {aid} failed to initialize within 90s.', file=sys.stderr)
        sys.exit(1)
print('[Cloud Harness] All active MT5 RPyC bridges verified ready.')
"

# 6. Launch bots dynamically for active accounts
WINDOW_FLAG="--window-mode"
if [ "${CONTINUOUS_SESSION:-false}" = "true" ] || [ "${EVENT_NAME:-}" != "schedule" ]; then
    echo "[Cloud Harness] Discretionary / Mobile session triggered (Event: ${EVENT_NAME:-manual}). Running in CONTINUOUS mode..."
    WINDOW_FLAG=""
else
    echo "[Cloud Harness] Automated scheduled cron session. Running with auto-exit --window-mode..."
fi

PIDS=()
if [ -f "data/active_accounts.txt" ]; then
    while IFS= read -r aid; do
        [ -z "$aid" ] && continue
        env_file=".env.$aid"
        if [ -f "$env_file" ]; then
            echo "[Cloud Harness] Launching bot for $aid via native binary (Flags: '${WINDOW_FLAG:-continuous}')..."
            ./mt5_trader_engine --env "$env_file" $WINDOW_FLAG &
            PIDS+=($!)
        fi
    done < data/active_accounts.txt
fi

if [ ${#PIDS[@]} -eq 0 ]; then
    echo "[Cloud Harness] No active accounts to run. Clean exit."
    exit 0
fi

echo "[Cloud Harness] ${#PIDS[@]} bot(s) executing in background (PIDs: ${PIDS[*]})."
wait "${PIDS[@]}"
echo "[Cloud Harness] Session complete. Clean exit."

