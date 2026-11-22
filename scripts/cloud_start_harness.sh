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

echo "[Cloud Harness] Configuring modern Wine MT5 baseline, auto-login, and broker assets..."
python3 << 'PYEOF'
import json, subprocess, os, sys, time, urllib.request

EXNESS_CACHE = os.path.expanduser("~/.cache/mt5_exness_wine")
UNIVERSAL_CACHE = os.path.expanduser("~/.cache/mt5_universal_wine")
os.makedirs(EXNESS_CACHE, exist_ok=True)
os.makedirs(UNIVERSAL_CACHE, exist_ok=True)

if not os.path.exists("data/active_accounts.json"):
    print("[Cloud Harness] No active accounts found. Exiting cleanly.")
    sys.exit(0)

with open("data/active_accounts.json") as f:
    active = json.load(f)

def download_installer_on_host(setup_filename, urls):
    host_path = os.path.join("/tmp", setup_filename)
    if os.path.exists(host_path) and os.path.getsize(host_path) > 1024 * 1024:
        return host_path

    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }
    for url in urls:
        print(f"[Cloud Harness] Attempting to download {setup_filename} from {url}...")
        try:
            cmd = [
                "curl", "-sSL",
                "-A", headers["User-Agent"],
                "--connect-timeout", "15",
                "--max-time", "90",
                "-o", host_path,
                url
            ]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode == 0 and os.path.exists(host_path) and os.path.getsize(host_path) > 1024 * 1024:
                print(f"[Cloud Harness] Successfully downloaded {setup_filename} ({os.path.getsize(host_path)} bytes).")
                return host_path
            else:
                print(f"[Cloud Harness] curl failed or file too small for {url}: {res.stderr}")
        except Exception as e:
            print(f"[Cloud Harness] Error downloading from {url}: {e}")

    # Fallback with python urllib
    for url in urls:
        try:
            print(f"[Cloud Harness] Fallback: downloading {setup_filename} via urllib from {url}...")
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=30) as resp, open(host_path, "wb") as out:
                out.write(resp.read())
            if os.path.exists(host_path) and os.path.getsize(host_path) > 1024 * 1024:
                print(f"[Cloud Harness] Successfully downloaded {setup_filename} via urllib ({os.path.getsize(host_path)} bytes).")
                return host_path
        except Exception as e:
            print(f"[Cloud Harness] urllib error for {url}: {e}")
    return None

def ensure_modern_mt5_installed(cname, is_aiwa):
    baseline_type = "universal" if is_aiwa else "exness"
    cache_dir = UNIVERSAL_CACHE if is_aiwa else EXNESS_CACHE
    cached_terminal = os.path.join(cache_dir, "terminal64.exe")

    # Check if cached baseline exists on runner host
    if os.path.exists(cached_terminal) and os.path.getsize(cached_terminal) > 10 * 1024 * 1024:
        print(f"[Cloud Harness] Restoring modern {baseline_type.upper()} MT5 terminal from runner cache into container {cname}...")
        subprocess.run(["docker", "cp", f"{cache_dir}/.", f"{cname}:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/"], check=True)
        return

    print(f"[Cloud Harness] Cache miss for {baseline_type.upper()} MT5! Running Wine-native silent installation in {cname}...")
    if is_aiwa:
        urls = [
            "https://files.metaquotes.net/metaquotes.software.corp/mt5/mt5setup.exe",
            "https://download.mql5.com/cdn/web/metaquotes.ltd/mt5/mt5setup.exe",
            "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
        ]
        setup_file = "mt5setup.exe"
    else:
        urls = [
            "https://files.metaquotes.net/exness.technologies.ltd/mt5/exness5setup.exe",
            "https://download.mql5.com/cdn/web/exness.technologies.ltd/mt5/exness5setup.exe"
        ]
        setup_file = "exness5setup.exe"

    host_setup_path = download_installer_on_host(setup_file, urls)
    if not host_setup_path:
        print(f"[Cloud Harness] ERROR: Could not download {setup_file} from any mirror!")
        return

    print(f"[Cloud Harness] Copying {setup_file} into container {cname}...")
    subprocess.run(["docker", "cp", host_setup_path, f"{cname}:/tmp/{setup_file}"], check=True)

    print(f"[Cloud Harness] Executing Wine unattended setup in {cname} under DISPLAY=:100 (/auto /path:'C:\\Program Files\\MetaTrader 5')...")
    subprocess.Popen([
        "docker", "exec", "-d", "-e", "DISPLAY=:100", cname, "wine", f"/tmp/{setup_file}", "/auto", r"/path:C:\Program Files\MetaTrader 5"
    ])

    installed = False
    for attempt in range(1, 46):
        time.sleep(2)
        check = subprocess.run(["docker", "exec", cname, "test", "-f", "/opt/wineprefix/drive_c/Program Files/MetaTrader 5/terminal64.exe"])
        if check.returncode == 0:
            print(f"[Cloud Harness] Modern MT5 build verified in container {cname} (elapsed: {attempt*2}s)!")
            installed = True
            time.sleep(5)
            break

    if not installed:
        print(f"[Cloud Harness] WARNING: Unattended installation in {cname} did not produce terminal64.exe within 90s.")
        return

    # Terminate installer and temporary terminal to safely finalize files
    subprocess.run(["docker", "exec", cname, "wine", "taskkill", "/IM", setup_file, "/F"], stderr=subprocess.DEVNULL)
    subprocess.run(["docker", "exec", cname, "wine", "taskkill", "/IM", "terminal64.exe", "/F"], stderr=subprocess.DEVNULL)
    time.sleep(2)

    # Cache pristine build on host runner for other containers & future runs
    print(f"[Cloud Harness] Caching modern {baseline_type.upper()} MT5 build to {cache_dir}...")
    subprocess.run(["docker", "cp", f"{cname}:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/.", f"{cache_dir}/"], check=True)
    subprocess.run(["docker", "exec", cname, "rm", "-f", f"/tmp/{setup_file}"], stderr=subprocess.DEVNULL)

for a in active:
    cname = a['container']
    env_file = a['env_file']
    aid = a['id']
    print(f"[Cloud Harness] Injecting config & baseline for account {aid} into container {cname}...")

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

    # 1. Ensure modern MT5 baseline is in place
    ensure_modern_mt5_installed(cname, is_aiwa)

    # 2. Prepare Config folder & portable mode
    subprocess.run(['docker', 'exec', cname, 'mkdir', '-p', '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config'], stderr=subprocess.DEVNULL)
    subprocess.run(['docker', 'exec', cname, 'touch', '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/portable.txt'], stderr=subprocess.DEVNULL)
    subprocess.run(['docker', 'exec', cname, 'sed', '-i', 's/terminal64.exe \\/config:mt5cfg.ini/terminal64.exe \\/portable \\/config:mt5cfg.ini/g', '/mt5linux/start.sh'], stderr=subprocess.DEVNULL)

    # 3. Inject servers.dat and pre-compiled bases
    if os.path.exists('config/servers.dat'):
        subprocess.run(['docker', 'cp', 'config/servers.dat', f'{cname}:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config/servers.dat'], stderr=subprocess.DEVNULL)
    if os.path.exists('config/bases'):
        subprocess.run(['docker', 'exec', cname, 'mkdir', '-p', '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Bases'], stderr=subprocess.DEVNULL)
        for b_name in os.listdir('config/bases'):
            b_path = os.path.join('config/bases', b_name)
            if os.path.isdir(b_path):
                subprocess.run(['docker', 'cp', b_path, f'{cname}:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Bases/'], stderr=subprocess.DEVNULL)

    # 4. Inject mt5cfg.ini (with Api=0 to prevent headless GUI modal prompt hangs)
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

    print(f'[Cloud Harness] Restarting container {cname} to load modern MT5 baseline & configuration...')
    subprocess.run(['docker', 'restart', cname], check=True)
PYEOF

# 4. Wait for active RPyC bridges to become fully ready (Isolated per container)
echo "[Cloud Harness] Validating active MT5 RPyC bridges..."
python3 << 'EOF'
import json, socket, time, os, sys, urllib.request

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

# Dispatch real-time Telegram alerts for failed container bridges
if failed_accounts:
    tg_token = os.getenv('TELEGRAM_BOT_TOKEN')
    tg_chat = os.getenv('TELEGRAM_CHAT_ID')
    if tg_token and tg_chat:
        for fa in failed_accounts:
            msg = (
                f"🚨 <b>SYSTEM FAULT DETECTED [CRITICAL]</b>\n\n"
                f"👤 <b>Account:</b> {fa['id']} (<code>#{fa.get('mt5_login', 'unknown')}</code>)\n"
                f"❌ <b>Error Type:</b> <code>CONTAINER_RPYC_BRIDGE_UNRESPONSIVE</code>\n"
                f"📝 <b>Details:</b> Container {fa['container']} bridge failed to bind on host port {fa['rpyc_port']} within 60s.\n"
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
                print(f"[Cloud Harness] Dispatched Telegram alert for unresponsive container {fa['container']}.")
            except Exception as tg_err:
                print(f"[Cloud Harness] Failed to send Telegram alert: {tg_err}")

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
