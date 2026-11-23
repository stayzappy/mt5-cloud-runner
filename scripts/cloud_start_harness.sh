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

# 1b. Ensure data and logs directories
mkdir -p logs data

# 1c. Pull modern MT5 pre-packaged build (build 6328) from private release
if [ ! -f "data/mt5_modern_build.tar.gz" ]; then
    echo "[Cloud Harness] Pulling modern MT5 pre-packaged build (build 6328) from release..."
    gh release download latest-engine \
        --repo stayzappy/mt5-forex-bot \
        --pattern "mt5_modern_build.tar.gz" \
        --dir data \
        --clobber || true
fi

if [ -f "data/mt5_modern_build.tar.gz" ] && [ ! -f "/tmp/mt5_binaries/terminal64.exe" ]; then
    echo "[Cloud Harness] Extracting modern MT5 binaries..."
    mkdir -p /tmp/mt5_binaries
    tar -xzf data/mt5_modern_build.tar.gz -C /tmp/mt5_binaries ./terminal64.exe ./metatester64.exe ./MetaEditor64.exe 2>/dev/null || tar -xzf data/mt5_modern_build.tar.gz -C /tmp/mt5_binaries
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

echo "[Cloud Harness] Configuring MT5 baseline, auto-login, and broker assets..."
python3 << 'PYEOF'
import json, subprocess, os, sys, time

if not os.path.exists("data/active_accounts.json"):
    print("[Cloud Harness] No active accounts found. Exiting cleanly.")
    sys.exit(0)

with open("data/active_accounts.json") as f:
    active = json.load(f)

target_dir = "/opt/wineprefix/drive_c/Program Files/MetaTrader 5"

for a in active:
    cname = a['container']
    env_file = a['env_file']
    aid = a['id']
    print(f"[Cloud Harness] Configuring container {cname} for account {aid}...")

    with open(env_file) as ef:
        lines = dict(line.strip().split('=', 1) for line in ef if '=' in line and not line.startswith('#'))

    login = lines.get('MT5_LOGIN', '')
    pwd = lines.get('MT5_PASSWORD', '')
    srv = lines.get('MT5_SERVER', 'Exness-MT5Trial9')
    is_aiwa = 'aiwa' in srv.lower() or 'aiwa' in cname.lower() or 'aiwa' in aid.lower()
    if is_aiwa:
        srv = 'AiwaCapital-Server'
    elif 'real21' in srv.lower() or 'cent' in aid.lower():
        srv = 'Exness-MT5Real21'
    elif 'trial9' in srv.lower() or 'trial' in srv.lower() or 'funded' in aid.lower():
        srv = 'Exness-MT5Trial9'

    # 0. Upgrade MT5 terminal to modern build 6328 if package available
    modern_terminal = '/tmp/mt5_binaries/terminal64.exe'
    if os.path.exists(modern_terminal):
        print(f"[Cloud Harness] Upgrading MT5 terminal in {cname} to modern build 6328...", flush=True)
        subprocess.run(['docker', 'exec', cname, 'mkdir', '-p', target_dir], stderr=subprocess.DEVNULL)
        subprocess.run(['docker', 'exec', cname, 'wine', 'taskkill', '/IM', 'terminal64.exe', '/F'], stderr=subprocess.DEVNULL)
        subprocess.run(['docker', 'cp', modern_terminal, f'{cname}:{target_dir}/terminal64.exe'], check=True)
        subprocess.run(['docker', 'exec', cname, 'chmod', '755', f'{target_dir}/terminal64.exe'], stderr=subprocess.DEVNULL)
        for exe in ['MetaEditor64.exe', 'metatester64.exe']:
            p = f'/tmp/mt5_binaries/{exe}'
            if os.path.exists(p):
                subprocess.run(['docker', 'cp', p, f'{cname}:{target_dir}/{exe}'], stderr=subprocess.DEVNULL)
                subprocess.run(['docker', 'exec', cname, 'chmod', '755', f'{target_dir}/{exe}'], stderr=subprocess.DEVNULL)

    # 1. Prepare Config folder & ensure standard mode (matching verified local environment)
    subprocess.run(['docker', 'exec', cname, 'mkdir', '-p', f'{target_dir}/Config'], stderr=subprocess.DEVNULL)
    subprocess.run(['docker', 'exec', cname, 'rm', '-f', f'{target_dir}/portable.txt'], stderr=subprocess.DEVNULL)
    subprocess.run(['docker', 'exec', cname, 'sed', '-i', 's/terminal64.exe \\/portable \\/config:mt5cfg.ini/terminal64.exe \\/config:mt5cfg.ini/g', '/mt5linux/start.sh'], stderr=subprocess.DEVNULL)

    # 2. Inject pre-authenticated profiles, servers.dat and pre-compiled bases
    roaming_term = '/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075'
    profile_cfg = os.path.join('config', 'profiles', cname, 'Config')

    for d_path in [
        f'{target_dir}/Config',
        f'{roaming_term}/config',
        f'{roaming_term}/Config',
    ]:
        subprocess.run(['docker', 'exec', cname, 'mkdir', '-p', d_path], stderr=subprocess.DEVNULL)
        if os.path.isdir(profile_cfg):
            subprocess.run(['docker', 'cp', f'{profile_cfg}/.', f'{cname}:{d_path}/'], stderr=subprocess.DEVNULL)
        elif os.path.exists('config/servers.dat'):
            subprocess.run(['docker', 'cp', 'config/servers.dat', f'{cname}:{d_path}/servers.dat'], stderr=subprocess.DEVNULL)

    if os.path.exists('config/bases'):
        for b_path in [
            f'{target_dir}/Bases',
            f'{roaming_term}/bases',
            f'{roaming_term}/Bases',
        ]:
            subprocess.run(['docker', 'exec', cname, 'mkdir', '-p', b_path], stderr=subprocess.DEVNULL)
            for b_name in os.listdir('config/bases'):
                b_src = os.path.join('config/bases', b_name)
                if os.path.isdir(b_src):
                    subprocess.run(['docker', 'cp', b_src, f'{cname}:{b_path}/'], stderr=subprocess.DEVNULL)

    # 3. Inject mt5cfg.ini (matching verified Friday baseline)
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
    p = subprocess.Popen(['docker', 'exec', '-i', cname, 'sh', '-c', f'cat > "{target_dir}/mt5cfg.ini" && cp "{target_dir}/mt5cfg.ini" /mt5linux/mt5cfg.ini'], stdin=subprocess.PIPE)
    p.communicate(input=cfg_content.encode())

    print(f'[Cloud Harness] Restarting container {cname} to load MT5 configuration...')
    subprocess.run(['docker', 'restart', cname], check=True)
    time.sleep(5)

    # Diagnostic: dump running processes and MT5 terminal logs
    print(f'=== Diagnostics for container {cname} ===')
    ps_res = subprocess.run(['docker', 'exec', cname, 'ps', 'aux'], capture_output=True, text=True)
    print(f'Running processes in {cname}:\n{ps_res.stdout}')
    log_res = subprocess.run(['docker', 'exec', cname, 'sh', '-c', 'find /opt/wineprefix -name "*.log" -exec echo "--- LOG: {} ---" \\; -exec cat {} \\; 2>/dev/null'], capture_output=True)
    raw = log_res.stdout or b''
    try:
        decoded = raw.decode('utf-16le', errors='replace')
    except Exception:
        decoded = raw.decode('utf-8', errors='replace')
    print(f'MT5 log snapshot:\n{decoded[-2000:]}')
PYEOF

# 4. Wait for active RPyC bridges to become fully ready (Isolated per container)
echo "[Cloud Harness] Validating active MT5 RPyC bridges..."
python3 << 'EOF'
import json, socket, time, os, sys, urllib.request, subprocess

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
    print(f'[Cloud Harness] Probing MT5 RPyC bridge in container {cname} (port 18812 / host {port} for {aid})...')
    ok = False
    for attempt in range(1, 46):
        # 1. Deep probe via Wine Python RPyC: verify bridge, mt5.initialize(), and broker login
        cmd = [
            'docker', 'exec', cname, 'wine', 'python', '-c',
            "import rpyc; conn = rpyc.classic.connect('127.0.0.1', 18812); mt5 = conn.modules['MetaTrader5']; ok = mt5.initialize(); acc = mt5.account_info(); l = getattr(acc, 'login', 0); b = getattr(acc, 'balance', 0); c = getattr(acc, 'currency', ''); print('READY=' + str(ok and (l > 0)) + '|INIT=' + str(ok) + '|LOGIN=' + str(l) + '|BAL=' + str(b) + ' ' + str(c)); conn.close()"
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        out = (res.stdout or '').strip()
        print(f"[Cloud Harness] Attempt {attempt}/45 for {cname}: {out or 'connecting...'}", flush=True)
        if 'READY=True' in out or (res.returncode == 0 and 'INIT=True' in out):
            # 2. Verify host port forwarding is also open and reachable
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(2.0)
                s.connect(('127.0.0.1', port))
                s.close()
                ok = True
                print(f'[Cloud Harness] MT5 in container {cname} is FULLY INITIALIZED and READY ({out}, attempt {attempt}).')
                ready_accounts.append(a)
                break
            except Exception:
                pass
        elif attempt % 5 == 0:
            print(f'[Cloud Harness] Waiting for {cname} MT5 initialization ({out or "booting..."}, attempt {attempt}/45)...')
        time.sleep(2.0)

    if not ok:
        print(f'[Cloud Harness] WARNING: Container {cname} bridge failed to bind on host port {port} within 60s! Skipping container.')
        failed_accounts.append(a)

# Dispatch real-time Telegram alerts for failed container bridges
is_dry_run = os.getenv('DRY_RUN', 'false').lower() == 'true'
is_force_run = os.getenv('FORCE_RUN', 'false').lower() == 'true'

if failed_accounts:
    if is_dry_run or is_force_run:
        print(f"[Cloud Harness] Suppressing Telegram alerts for {len(failed_accounts)} failed container(s) during dry-run / force test.")
    else:
        tg_token = os.getenv('TELEGRAM_BOT_TOKEN')
        tg_chat = os.getenv('TELEGRAM_CHAT_ID')
        cooldown_file = 'data/bridge_cooldowns.json'
        cooldowns = {}
        try:
            if os.path.exists(cooldown_file):
                with open(cooldown_file) as cf:
                    cooldowns = json.load(cf)
        except Exception:
            pass

        now_ts = time.time()
        if tg_token and tg_chat:
            for fa in failed_accounts:
                cname = fa['container']
                last_alert = cooldowns.get(cname, 0.0)
                if (now_ts - last_alert) < 3600.0:
                    print(f"[Cloud Harness] Throttling Telegram alert for {cname} (cooldown active: {int(now_ts - last_alert)}s / 3600s).")
                    continue

                msg = (
                    f"🚨 <b>SYSTEM FAULT DETECTED [CRITICAL]</b>\n\n"
                    f"👤 <b>Account:</b> {fa['id']} (<code>#{fa.get('mt5_login', 'unknown')}</code>)\n"
                    f"❌ <b>Error Type:</b> <code>CONTAINER_RPYC_BRIDGE_UNRESPONSIVE</code>\n"
                    f"📝 <b>Details:</b> Container {fa['container']} bridge failed to bind on host port {fa['rpyc_port']} within 90s.\n"
                    f"🕒 <b>Time:</b> <i>{time.strftime('%Y-%m-%d %H:%M:%S UTC')}</i>\n\n"
                    f"👉 <i>Check Cloud Runner logs for container diagnostics.</i>"
                )
                try:
                    data = json.dumps({'chat_id': tg_chat, 'text': msg, 'parse_mode': 'HTML'}).encode()
                    req = urllib.request.Request(
                        f"https://api.telegram.org/bot{tg_token}/sendMessage",
                        data=data,
                        headers={'Content-Type': 'application/json'}
                    )
                    urllib.request.urlopen(req, timeout=10)
                    cooldowns[cname] = now_ts
                    print(f"[Cloud Harness] Dispatched Telegram alert for unresponsive container {fa['container']}.")
                except Exception as tg_err:
                    print(f"[Cloud Harness] Failed to send Telegram alert: {tg_err}")

            try:
                os.makedirs('data', exist_ok=True)
                with open(cooldown_file, 'w') as cf:
                    json.dump(cooldowns, cf)
            except Exception:
                pass

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
RUN_FLAGS=""
if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "[Cloud Harness] DRY RUN MODE ENABLED: Bot will simulate operations without live order execution."
    RUN_FLAGS="$RUN_FLAGS --dry-run"
fi

if [ "${CONTINUOUS_SESSION:-false}" = "true" ] || [ "${EVENT_NAME:-}" != "schedule" ]; then
    echo "[Cloud Harness] Discretionary / Manual session triggered (Event: ${EVENT_NAME:-manual}). Running in CONTINUOUS mode..."
else
    echo "[Cloud Harness] Automated scheduled cron session. Running with auto-exit --window-mode..."
    RUN_FLAGS="$RUN_FLAGS --window-mode"
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
