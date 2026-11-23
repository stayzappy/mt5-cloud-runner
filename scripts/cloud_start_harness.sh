#!/usr/bin/env bash
# ==============================================================================
# MT5 Cloud Runner Harness - Headless Cloud Session Bootstrapper
# Pulls compiled standalone engine over-the-air (OTA) and executes in window-mode
# ==============================================================================
set -euo pipefail
export PYTHONUNBUFFERED=1

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

# 2. Pull modern MT5 pre-packaged build (build 6328) from private release
if [ ! -f "data/mt5_modern_build.tar.gz" ]; then
    echo "[Cloud Harness] Pulling modern MT5 pre-packaged build (build 6328) from release..."
    gh release download latest-engine \
        --repo stayzappy/mt5-forex-bot \
        --pattern "mt5_modern_build.tar.gz" \
        --dir data \
        --clobber || true
fi

if [ -f "data/mt5_modern_build.tar.gz" ]; then
    echo "[Cloud Harness] Extracting modern MT5 binaries..."
    mkdir -p /tmp/mt5_binaries
    tar -xzf data/mt5_modern_build.tar.gz -C /tmp/mt5_binaries 2>/dev/null || true
    find /tmp/mt5_binaries -name "terminal64.exe" -exec cp {} /tmp/mt5_binaries/terminal64.exe \; 2>/dev/null || true
fi

# 3. Pull live account configurations and secrets from Cloudflare Worker
echo "[Cloud Harness] Pulling account profiles and remote configuration from Worker..."
CONTROL_WORKER_URL="${CONTROL_WORKER_URL:-https://mt5-control-studio.zapstream.workers.dev}"

python3 scripts/sync_accounts.py

# 4. Cold-Boot Injection: Create containers while STOPPED, inject profiles, then START
ACTIVE_SERVICES=""
if [ -f "data/active_services.txt" ] && [ -s "data/active_services.txt" ]; then
    ACTIVE_SERVICES=$(tr '\n' ' ' < data/active_services.txt)
fi

echo "[Cloud Harness] Creating cold Docker MT5 container(s): ${ACTIVE_SERVICES:-all}..."
if [ -n "$ACTIVE_SERVICES" ]; then
    docker compose create $ACTIVE_SERVICES
else
    docker compose create
fi

echo "[Cloud Harness] Pre-injecting modern build 6328, profiles, and registry into cold containers..."
python3 << 'PYEOF'
import json, subprocess, os, sys

if not os.path.exists("data/active_accounts.json"):
    print("[Cloud Harness] No active accounts found. Exiting cleanly.")
    sys.exit(0)

with open("data/active_accounts.json") as f:
    active = json.load(f)

target_dir = "/opt/wineprefix/drive_c/Program Files/MetaTrader 5"
modern_terminal = "/tmp/mt5_binaries/terminal64.exe"
if not os.path.exists(modern_terminal):
    cand = subprocess.run(['find', '/tmp/mt5_binaries', '-name', 'terminal64.exe'], capture_output=True, text=True).stdout.strip()
    if cand and os.path.exists(cand.splitlines()[0]):
        modern_terminal = cand.splitlines()[0]

for a in active:
    cname = a['container']
    env_file = a['env_file']
    aid = a['id']
    print(f"[Cloud Harness] Pre-injecting cold files for container {cname} ({aid})...", flush=True)

    with open(env_file) as ef:
        lines = dict(line.strip().split('=', 1) for line in ef if '=' in line and not line.startswith('#'))

    login = lines.get('MT5_LOGIN', '')
    pwd = lines.get('MT5_PASSWORD', '')
    srv = lines.get('MT5_SERVER', 'Exness-MT5Trial9')
    if 'aiwa' in srv.lower() or 'aiwa' in cname.lower() or 'aiwa' in aid.lower():
        srv = 'AiwaCapital-Server'
    elif 'real21' in srv.lower() or 'cent' in aid.lower():
        srv = 'Exness-MT5Real21'
    elif 'trial9' in srv.lower() or 'trial' in srv.lower() or 'funded' in aid.lower():
        srv = 'Exness-MT5Trial9'

    # A. Inject modern terminal64.exe (build 6328)
    if modern_terminal and os.path.exists(modern_terminal):
        subprocess.run(['docker', 'cp', modern_terminal, f'{cname}:{target_dir}/terminal64.exe'], check=True)
        for exe in ['MetaEditor64.exe', 'metatester64.exe']:
            cand_exe = subprocess.run(['find', '/tmp/mt5_binaries', '-name', exe], capture_output=True, text=True).stdout.strip()
            if cand_exe and os.path.exists(cand_exe.splitlines()[0]):
                subprocess.run(['docker', 'cp', cand_exe.splitlines()[0], f'{cname}:{target_dir}/{exe}'], stderr=subprocess.DEVNULL)

    # B. Inject Config/ (accounts.dat, servers.dat, terminal.ini, settings.ini)
    profile_cfg = os.path.join('config', 'profiles', cname, 'Config')
    if os.path.isdir(profile_cfg):
        subprocess.run(['docker', 'cp', f'{profile_cfg}/.', f'{cname}:{target_dir}/Config/'], check=True)

    # C. Inject user.reg (pre-configured Wine registry)
    user_reg = os.path.join('config', 'profiles', cname, 'user.reg')
    if os.path.exists(user_reg):
        subprocess.run(['docker', 'cp', user_reg, f'{cname}:/opt/wineprefix/user.reg'], check=True)

    # D. Inject Bases if available
    if os.path.exists('config/bases'):
        for b_name in os.listdir('config/bases'):
            b_src = os.path.join('config/bases', b_name)
            if os.path.isdir(b_src):
                subprocess.run(['docker', 'cp', b_src, f'{cname}:{target_dir}/Bases/'], stderr=subprocess.DEVNULL)

    # E. Inject auto-login mt5cfg.ini
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
    tmp_cfg = f'/tmp/mt5cfg_{cname}.ini'
    with open(tmp_cfg, 'w') as f:
        f.write(cfg_content)
    subprocess.run(['docker', 'cp', tmp_cfg, f'{cname}:/mt5linux/mt5cfg.ini'], check=True)
    subprocess.run(['docker', 'cp', tmp_cfg, f'{cname}:{target_dir}/mt5cfg.ini'], check=True)

print("[Cloud Harness] Cold pre-injection completed successfully.")
PYEOF

# 5. Start containers (Wine boots with all files in place, zero wizards, zero restarts)
if [ -n "$ACTIVE_SERVICES" ]; then
    echo "[Cloud Harness] Starting Docker MT5 container(s): $ACTIVE_SERVICES..."
    docker compose start $ACTIVE_SERVICES
else
    echo "[Cloud Harness] Starting all Docker MT5 containers..."
    docker compose start
fi

echo "[Cloud Harness] Waiting 15s for Wine and MT5 bridge initialization..."
sleep 15

# 6. Validate active MT5 RPyC bridges and broker authentication (Direct Host RPyC Probe)
echo "[Cloud Harness] Installing pinned rpyc==5.2.3 on host runner for protocol parity..."
python3 -m pip install --quiet 'rpyc==5.2.3'

echo "[Cloud Harness] Validating active MT5 RPyC bridges and broker authentication..."
python3 << 'EOF'
import json, socket, time, os, sys, rpyc

# Prevent socket hanging indefinitely
socket.setdefaulttimeout(15.0)

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
    expected_login = int(a.get('mt5_login', 0))
    print(f'[Cloud Harness] Probing MT5 RPyC bridge on 127.0.0.1:{port} for account {aid} ({cname})...', flush=True)
    ok = False
    for attempt in range(1, 46):
        try:
            conn = rpyc.classic.connect('127.0.0.1', port)
            conn._config['sync_request_timeout'] = 10
            mt5 = conn.modules['MetaTrader5']
            init_ok = mt5.initialize()
            if not init_ok:
                init_ok = mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
            acc = mt5.account_info()
            login = int(getattr(acc, 'login', 0)) if acc else 0
            bal = float(getattr(acc, 'balance', 0.0)) if acc else 0.0
            ccy = str(getattr(acc, 'currency', '')) if acc else ''
            err = None
            if not (init_ok and (login > 0 or expected_login == 0)):
                try:
                    err = mt5.last_error()
                except Exception:
                    pass
            try:
                conn.close()
            except Exception:
                pass

            if init_ok and (login > 0 or expected_login == 0):
                print(f'[Cloud Harness] MT5 {aid} is FULLY AUTHENTICATED on port {port}: Login #{login} | Balance: {bal:,.2f} {ccy} (attempt {attempt}).', flush=True)
                ready_accounts.append(a)
                ok = True
                break
            else:
                print(f'[Cloud Harness] Attempt {attempt}/45: Bridge listening, MT5 initializing (init={init_ok}, login={login}, err={err})...', flush=True)
        except Exception as ex:
            if attempt % 5 == 0 or attempt == 1:
                print(f'[Cloud Harness] Attempt {attempt}/45: Waiting for bridge on port {port} ({ex.__class__.__name__}: {ex})...', flush=True)
        time.sleep(2.0)

    if not ok:
        print(f'[Cloud Harness] ERROR: Container {cname} bridge failed to bind on host port {port} within 90s!', file=sys.stderr)
        failed_accounts.append(a)

if not ready_accounts:
    print('[Cloud Harness] ERROR: None of the active accounts bound to their RPyC bridge!', file=sys.stderr)
    sys.exit(1)

print(f'[Cloud Harness] Active accounts ready: {len(ready_accounts)}/{len(active)}')
with open('data/active_accounts.json', 'w') as f:
    json.dump(ready_accounts, f, indent=2)

with open('data/active_accounts.txt', 'w') as f:
    for a in ready_accounts:
        f.write(f"{a['id']}\n")
EOF
sleep 3

# 7. Launch bots dynamically for active accounts
RUN_FLAGS=""
if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "[Cloud Harness] DRY RUN MODE ENABLED: Bot will simulate operations without live order execution."
    RUN_FLAGS="$RUN_FLAGS --dry-run"
fi

if [ "${WINDOW_MODE:-false}" = "true" ] || [ "${EVENT_NAME:-}" = "schedule" ]; then
    echo "[Cloud Harness] Running with auto-exit --window-mode..."
    RUN_FLAGS="$RUN_FLAGS --window-mode"
else
    echo "[Cloud Harness] Discretionary / Manual session triggered (Event: ${EVENT_NAME:-manual}). Running in CONTINUOUS mode..."
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
    echo "[Cloud Harness] Launching Unified Master-Slave Fleet Runner ($NUM_ACCOUNTS accounts, Flags: '$RUN_FLAGS')..."
    ./mt5_trader_engine --fleet $RUN_FLAGS
else
    PIDS=()
    while IFS= read -r aid; do
        [ -z "$aid" ] && continue
        env_file=".env.$aid"
        if [ -f "$env_file" ]; then
            echo "[Cloud Harness] Launching bot for $aid via native binary (Flags: '$RUN_FLAGS')..."
            ./mt5_trader_engine --env "$env_file" $RUN_FLAGS &
            PIDS+=($!)
        fi
    done < data/active_accounts.txt
    echo "[Cloud Harness] ${#PIDS[@]} bot(s) executing in background (PIDs: ${PIDS[*]})."
    wait "${PIDS[@]}"
fi
echo "[Cloud Harness] Session complete. Clean exit."
