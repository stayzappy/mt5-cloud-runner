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

# Check and pull modern official MT5 terminal build (build 6328+) if available in release
if gh release view latest-engine --repo stayzappy/mt5-forex-bot --json assets -q '.assets[].name' 2>/dev/null | grep -q "mt5_modern_build.tar.gz"; then
    echo "[Cloud Harness] Pulling modern MT5 terminal package (build 6328+) from release..."
    gh release download latest-engine \
        --repo stayzappy/mt5-forex-bot \
        --pattern "mt5_modern_build.tar.gz" \
        --clobber || true
    if [ -f "mt5_modern_build.tar.gz" ]; then
        mkdir -p /tmp/mt5_modern
        tar -xzf mt5_modern_build.tar.gz -C /tmp/mt5_modern
        echo "[Cloud Harness] Modern MT5 build unpacked successfully."
    fi
fi

# 2. Pull live account configurations and secrets from Cloudflare Worker
echo "[Cloud Harness] Pulling account profiles and remote configuration from Worker..."
CONTROL_WORKER_URL="${CONTROL_WORKER_URL:-https://mt5-control-studio.zapstream.workers.dev}"

python3 scripts/sync_accounts.py

# 3. Start Docker containers
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

echo "[Cloud Harness] Configuring auto-login mt5cfg.ini and broker configs for active accounts..."
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
        lines = dict(line.strip().split('=', 1) for line in ef if '=' in line and not line.startswith('#'))

    login = lines.get('MT5_LOGIN', '')
    pwd = lines.get('MT5_PASSWORD', '')
    srv = lines.get('MT5_SERVER', 'Exness-MT5Trial9')
    if 'aiwa' in srv.lower() or 'aiwa' in cname.lower() or 'aiwa' in a.get('id', '').lower():
        srv = 'AiwaCapital-Server'
    elif 'real21' in srv.lower() or 'cent' in a.get('id', '').lower():
        srv = 'Exness-MT5Real21'
    elif 'trial9' in srv.lower() or 'trial' in srv.lower() or 'funded' in a.get('id', '').lower():
        srv = 'Exness-MT5Trial9'

    subprocess.run(['docker', 'exec', cname, 'mkdir', '-p', '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config'], stderr=subprocess.DEVNULL)
    subprocess.run(['docker', 'exec', cname, 'touch', '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/portable.txt'], stderr=subprocess.DEVNULL)
    subprocess.run(['docker', 'exec', cname, 'sed', '-i', 's/terminal64.exe \\/config:mt5cfg.ini/terminal64.exe \\/portable \\/config:mt5cfg.ini/g', '/mt5linux/start.sh'], stderr=subprocess.DEVNULL)

    if os.path.exists('/tmp/mt5_modern/terminal64.exe'):
        print(f'[Cloud Harness] Injecting modern MT5 build (build 6328+) into container {cname}...')
        subprocess.run(['docker', 'cp', '/tmp/mt5_modern/.', f'{cname}:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/'], check=True)
        subprocess.run(['docker', 'exec', cname, 'touch', '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/portable.txt'], stderr=subprocess.DEVNULL)

    if os.path.exists('config/servers.dat'):
        subprocess.run(['docker', 'cp', 'config/servers.dat', f'{cname}:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config/servers.dat'], stderr=subprocess.DEVNULL)
    if os.path.exists('config/bases'):
        subprocess.run(['docker', 'exec', cname, 'mkdir', '-p', '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Bases'], stderr=subprocess.DEVNULL)
        for b_name in os.listdir('config/bases'):
            b_path = os.path.join('config/bases', b_name)
            if os.path.isdir(b_path):
                subprocess.run(['docker', 'cp', b_path, f'{cname}:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Bases/'], stderr=subprocess.DEVNULL)

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
Api=1
[Events]
Enable=0
NewsEnable=0
'''
    p = subprocess.Popen(['docker', 'exec', '-i', cname, 'sh', '-c', 'cat > \"/opt/wineprefix/drive_c/Program Files/MetaTrader 5/mt5cfg.ini\" && cp \"/opt/wineprefix/drive_c/Program Files/MetaTrader 5/mt5cfg.ini\" /mt5linux/mt5cfg.ini'], stdin=subprocess.PIPE)
    p.communicate(input=cfg_content.encode())

    print(f'[Cloud Harness] Restarting container {cname} to load MT5 configuration...')
    subprocess.run(['docker', 'restart', cname], check=True)
"

# 4. Wait for active RPyC bridges to become fully ready (Isolated per container)
echo "[Cloud Harness] Validating active MT5 RPyC bridges..."
python3 << 'EOF'
import json, socket, time, os, sys, subprocess

if not os.path.exists('data/active_accounts.json'):
    sys.exit(0)

with open('data/active_accounts.json') as f:
    active = json.load(f)

ready_accounts = []
failed_accounts = []

for a in active:
    cname = a['container']
    port = int(a['rpyc_port'])
    aid = a['id']
    print(f'[Cloud Harness] Probing MT5 RPyC bridge in container {cname} on host port {port} (Account: {aid})...')
    ok = False
    for attempt in range(1, 31):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2.0)
        try:
            s.connect(('127.0.0.1', port))
            s.close()
            ok = True
            print(f'[Cloud Harness] MT5 RPyC bridge in container {cname} is LISTENING and READY (attempt {attempt}).')
            ready_accounts.append(a)
            break
        except Exception:
            s.close()
            time.sleep(2.0)

    if not ok:
        print(f'[Cloud Harness] WARNING: Container {cname} bridge failed to bind on host port {port} within 60s! Skipping container.')
        failed_accounts.append(a)

if not ready_accounts:
    print('[Cloud Harness] ERROR: None of the active accounts bound to their RPyC bridge!')
    sys.exit(1)

print(f'[Cloud Harness] Active accounts ready: {len(ready_accounts)}/{len(active)}')
with open('data/active_accounts.json', 'w') as f:
    json.dump(ready_accounts, f, indent=2)

with open('data/active_accounts.txt', 'w') as f:
    for a in ready_accounts:
        f.write(f"{a['id']}\n")
EOF
sleep 3

# 5. Launch bots dynamically for active accounts
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
