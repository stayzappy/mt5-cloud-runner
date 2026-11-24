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

# 2. Pull live account configurations and secrets from Cloudflare Worker
echo "[Cloud Harness] Pulling account profiles and remote configuration from Worker..."
CONTROL_WORKER_URL="${CONTROL_WORKER_URL:-https://mt5-control-studio.zapstream.workers.dev}"

python3 scripts/sync_accounts.py

# 3. Start Docker containers (Hot Boot model: Wine prefix boots with existing Named Pipes)
ACTIVE_SERVICES=""
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

# 4. Wait for MT5 terminal cold first-boot to complete BEFORE profile injection.
#    The lprett/mt5linux image now ships an old terminal build; on first boot MT5 runs its
#    LiveUpdate (which relaunches the terminal at the current build). Profiles injected
#    before that completes are deleted by the running terminal ("Accounts deleted due old
#    version") and the account can never authorize afterwards. We therefore wait for the
#    post-update relaunch first.
echo "[Cloud Harness] Waiting for MT5 terminal cold first-boot (LiveUpdate) to complete..."
python3 << 'EOF'
import json, os, re, sys, time, subprocess

if not os.path.exists('data/active_accounts.json'):
    sys.exit(0)

with open('data/active_accounts.json') as f:
    active = json.load(f)

MT5_DIR = "/opt/wineprefix/drive_c/Program Files/MetaTrader 5"

def all_logs(cname):
    # MT5 build 5616 writes logs under the install dir; some builds write under
    # the AppData/Roaming/MetaQuotes/Terminal/<hash>/logs dir. Search both.
    r = subprocess.run(['docker', 'exec', cname, 'sh', '-c',
                        f'ls -t "{MT5_DIR}/logs/"*.log '
                        f'/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/*/logs/*.log 2>/dev/null | head -5'],
                       capture_output=True, text=True)
    return [l for l in (r.stdout or '').strip().splitlines() if l]

def boot_count(cname, logpath):
    # strip NUL bytes so UTF-16LE log lines decode as plain ASCII
    r = subprocess.run(['docker', 'exec', cname, 'sh', '-c',
                        f'cat "{logpath}" 2>/dev/null | tr -d "\\000"'],
                       capture_output=True)
    txt = (r.stdout or b'').decode('utf-8', errors='ignore')
    boots = txt.lower().count('successfully initialized')
    # A terminal start line with build >= 6000 proves the LiveUpdate relaunch happened.
    builds = [int(m) for m in re.findall(r'build\s+(\d{3,5})', txt, re.IGNORECASE)]
    updated = any(b >= 6000 for b in builds)
    return max(boots, 2 if updated else 0)

for a in active:
    cname = a['container']
    print(f'[Cloud Harness] Waiting for cold first-boot + LiveUpdate in container {cname}...', flush=True)

# Poll ALL containers in parallel (containers boot concurrently; a sequential
# per-container deadline would multiply the total wait by the account count).
deadline = time.time() + 600
pending = {a['container'] for a in active}
last_counts = {}
diagnosed = set()
while pending and time.time() < deadline:
    for cname in list(pending):
        logs = all_logs(cname)
        if logs and cname not in diagnosed:
            print(f'[Cloud Harness] {cname} terminal log(s): {logs}', flush=True)
            diagnosed.add(cname)
        count = max((boot_count(cname, l) for l in logs), default=0)
        last_counts[cname] = count
        if count >= 2:
            pending.discard(cname)
    if pending:
        time.sleep(15)

for cname, count in last_counts.items():
    if count >= 2:
        print(f'[Cloud Harness] Container {cname}: terminal cold first-boot complete ({count} boot(s) logged).', flush=True)
    else:
        print(f'[Cloud Harness] WARNING: container {cname} first-boot not confirmed within 600s; proceeding anyway.', flush=True)
EOF

# 5. Configure auto-login mt5cfg.ini and servers into running containers
echo "[Cloud Harness] Configuring auto-login mt5cfg.ini and Exness servers for active accounts..."
python3 << 'EOF'
import json, subprocess, os, sys

if not os.path.exists('data/active_accounts.json'):
    print('[Cloud Harness] No active accounts found. Exiting cleanly.')
    sys.exit(0)

with open('data/active_accounts.json') as f:
    active = json.load(f)

for a in active:
    cname = a['container']
    env_file = a['env_file']
    print(f'[Cloud Harness] Injecting config for {a["id"]} into container {cname}...')
    with open(env_file) as ef:
        lines = dict(line.strip().split('=', 1) for line in ef if '=' in line and not line.startswith('#'))
    login = lines.get('MT5_LOGIN', '')
    pwd = lines.get('MT5_PASSWORD', '')
    srv = lines.get('MT5_SERVER', 'Exness-MT5Trial9')

    target_dir = "/opt/wineprefix/drive_c/Program Files/MetaTrader 5"
    subprocess.run(['docker', 'exec', cname, 'mkdir', '-p', f'{target_dir}/Config', f'{target_dir}/Bases'], stderr=subprocess.DEVNULL)

    # 1. Inject verified Config/ from pre-authenticated profiles (accounts.dat, servers.dat, terminal.ini)
    profile_cfg = os.path.join('config', 'profiles', cname, 'Config')
    if os.path.isdir(profile_cfg):
        subprocess.run(['docker', 'cp', f'{profile_cfg}/.', f'{cname}:{target_dir}/Config/'], stderr=subprocess.DEVNULL)
    elif os.path.exists('config/servers.dat'):
        subprocess.run(['docker', 'cp', 'config/servers.dat', f'{cname}:{target_dir}/Config/servers.dat'], stderr=subprocess.DEVNULL)

    # 2. Inject all broker Bases (Exness-MT5Real21, Exness-MT5Trial9, AiwaCapital-Server)
    if os.path.isdir('config/bases'):
        for b_name in os.listdir('config/bases'):
            b_src = os.path.join('config/bases', b_name)
            if os.path.isdir(b_src):
                subprocess.run(['docker', 'cp', b_src, f'{cname}:{target_dir}/Bases/'], stderr=subprocess.DEVNULL)

    # 3. Inject AppData Roaming terminal preferences
    profile_appdata = os.path.join('config', 'profiles', cname, 'AppData')
    if os.path.isdir(profile_appdata):
        roaming_target = "/opt/wineprefix/drive_c/users/root/AppData"
        subprocess.run(['docker', 'cp', f'{profile_appdata}/.', f'{cname}:{roaming_target}/'], stderr=subprocess.DEVNULL)

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
EOF

# 6. Validate active MT5 bridges with a real MT5-level readiness gate (not just TCP).
#    Connects through the RPyC bridge inside each container and verifies initialize()
#    and the expected account, then dumps full diagnostics if a container is not ready.
echo "[Cloud Harness] Validating active MT5 RPyC bridges (MT5-level deep gate)..."
python3 << 'EOF'
import json, os, sys, time, subprocess

if not os.path.exists('data/active_accounts.json'):
    sys.exit(0)

with open('data/active_accounts.json') as f:
    active = json.load(f)

PROBE = r'''
import rpyc
try:
    c = rpyc.classic.connect("127.0.0.1", 18812)
    c._config["sync_request_timeout"] = 30
    m = c.modules["MetaTrader5"]
    ok = m.initialize()
    acc = m.account_info()
    print("GATE_RESULT", ok, m.last_error(), (acc.login, acc.server, round(acc.balance, 2)) if acc else None, flush=True)
    c.close()
except Exception as e:
    print("GATE_ERROR", e, flush=True)
'''

def dump_diag(cname, aid):
    print(f'=== DIAGNOSTICS for {cname} ({aid}) ===', file=sys.stderr)
    subprocess.run(['docker', 'exec', cname, 'sh', '-c', 'ps aux | grep -E "terminal64|mt5linux" | grep -v grep'])
    subprocess.run(['docker', 'exec', cname, 'sh', '-c',
                    'cat "/opt/wineprefix/drive_c/Program Files/MetaTrader 5/mt5cfg.ini" 2>/dev/null | tr -d "\\000" | head -8'])
    subprocess.run(['docker', 'exec', cname, 'sh', '-c',
                    'tail -25 "$(ls -t /opt/wineprefix/drive_c/Program\\ Files/MetaTrader\\ 5/logs/*.log 2>/dev/null | head -1)" 2>/dev/null | tr -d "\\000" | tail -20'])
    subprocess.run(['docker', 'logs', '--tail', '30', cname])

failed = []
for a in active:
    cname = a['container']
    port = int(a['rpyc_port'])
    aid = a['id']
    expected_login = None
    env_file = a.get('env_file')
    if env_file and os.path.exists(env_file):
        for line in open(env_file):
            if line.startswith('MT5_LOGIN='):
                try:
                    expected_login = int(line.split('=', 1)[1].strip())
                except ValueError:
                    expected_login = None
    print(f'[Cloud Harness] Deep-gating MT5 bridge in container {cname} (port 18812 / host {port} for {aid})...', flush=True)
    ok = False
    for attempt in range(1, 31):
        try:
            res = subprocess.run(['docker', 'exec', cname, 'sh', '-c', f'cd /mt5linux && wine python -c {PROBE!r}'],
                                 capture_output=True, text=True, timeout=90)
            out = (res.stdout or '') + (res.stderr or '')
            if 'GATE_RESULT True' in out:
                if expected_login is None or f'({expected_login},' in out.replace('GATE_RESULT True ', '('):
                    print(f'[Cloud Harness] Container {cname}: MT5 READY (attempt {attempt}). {out.strip().splitlines()[-1]}', flush=True)
                    ok = True
                    break
            elif attempt % 3 == 0:
                print(f'[Cloud Harness] Container {cname} not ready yet (attempt {attempt}): {out.strip().splitlines()[-1] if out.strip() else "no output"}', flush=True)
        except Exception as e:
            pass
        time.sleep(10)
    if not ok:
        print(f'[Cloud Harness] ERROR: Container {cname} failed MT5 readiness gate within 300s.', file=sys.stderr)
        dump_diag(cname, aid)
        failed.append(cname)

if failed:
    print(f'[Cloud Harness] FATAL: {len(failed)} container(s) not ready: {failed}', file=sys.stderr)
    sys.exit(1)
print('[Cloud Harness] All active MT5 bridges verified ready (account info confirmed).')
EOF

# 7. Launch bots dynamically for active accounts
RUN_FLAGS=""
if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "[Cloud Harness] DRY RUN MODE ENABLED: Bot will simulate operations without live order execution."
    RUN_FLAGS="$RUN_FLAGS --dry-run"
fi

if [ "${WINDOW_MODE:-false}" = "true" ] || [ "${EVENT_NAME:-}" = "schedule" ] || [ "${EVENT_NAME:-}" = "repository_dispatch" ]; then
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
