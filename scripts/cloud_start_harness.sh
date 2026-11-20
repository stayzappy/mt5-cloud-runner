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

# Helper: Auto-login injection into container
inject_mt5_cfg() {
    local cname="$1"
    local env_file="$2"
    if [ ! -f "$env_file" ]; then return 0; fi

    local login_val pwd_val srv_val
    login_val=$(grep '^MT5_LOGIN=' "$env_file" | cut -d= -f2- | tr -d ' "\r')
    pwd_val=$(grep '^MT5_PASSWORD=' "$env_file" | cut -d= -f2- | tr -d ' "\r')
    srv_val=$(grep '^MT5_SERVER=' "$env_file" | cut -d= -f2- | tr -d ' "\r')
    if echo "$srv_val" | grep -iq "aiwa"; then
        srv_val="198.244.200.119:443"
    elif echo "$srv_val" | grep -iq "real21" || echo "$cname" | grep -iq "cent"; then
        srv_val="96.0.47.188:443"
    elif echo "$srv_val" | grep -iq "trial9" || echo "$srv_val" | grep -iq "trial" || echo "$cname" | grep -iq "funded"; then
        srv_val="96.0.46.31:443"
    fi

    docker exec "$cname" mkdir -p "/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config" 2>/dev/null || true
    docker exec "$cname" touch "/opt/wineprefix/drive_c/Program Files/MetaTrader 5/portable.txt" 2>/dev/null || true
    docker exec "$cname" sed -i 's/terminal64.exe \/config:mt5cfg.ini/terminal64.exe \/portable \/config:mt5cfg.ini/g' /mt5linux/start.sh 2>/dev/null || true
    docker exec "$cname" mkdir -p "/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/config" 2>/dev/null || true
    docker exec "$cname" mkdir -p "/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/bases" 2>/dev/null || true

    if [ -d "config/profiles/$cname/Config" ]; then
        docker cp "config/profiles/$cname/Config/." "$cname:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config/" 2>/dev/null || true
        docker cp "config/profiles/$cname/Config/." "$cname:/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/config/" 2>/dev/null || true
    elif [ -f "config/servers.dat" ]; then
        docker cp "config/servers.dat" "$cname:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config/servers.dat" 2>/dev/null || true
        docker cp "config/servers.dat" "$cname:/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/config/servers.dat" 2>/dev/null || true
    fi
    if [ -d "config/bases" ]; then
        docker exec "$cname" mkdir -p "/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Bases" 2>/dev/null || true
        for b_dir in config/bases/*; do
            if [ -d "$b_dir" ]; then
                docker cp "$b_dir" "$cname:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Bases/" 2>/dev/null || true
                docker cp "$b_dir" "$cname:/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/bases/" 2>/dev/null || true
            fi
        done
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
Api=1
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
    if 'aiwa' in srv.lower() or 'aiwa' in cname.lower() or 'aiwa' in a.get('id', '').lower():
        srv = 'AiwaCapital-Server'
    elif 'real21' in srv.lower() or 'cent' in a.get('id', '').lower():
        srv = 'Exness-MT5Real21'
    elif 'trial9' in srv.lower() or 'trial' in srv.lower() or 'funded' in a.get('id', '').lower():
        srv = 'Exness-MT5Trial9'

    # Ensure directories exist in both Program Files and AppData Roaming
    for d_path in [
        '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config',
        '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Bases',
        '/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/Config',
        '/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/config',
        '/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/Bases',
        '/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/bases',
    ]:
        subprocess.run(['docker', 'exec', cname, 'mkdir', '-p', d_path], stderr=subprocess.DEVNULL)

    profile_cfg = os.path.join('config', 'profiles', cname, 'Config')
    if os.path.isdir(profile_cfg):
        subprocess.run(['docker', 'cp', f'{profile_cfg}/.', f'{cname}:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config/'], stderr=subprocess.DEVNULL)
        subprocess.run(['docker', 'cp', f'{profile_cfg}/.', f'{cname}:/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/Config/'], stderr=subprocess.DEVNULL)
        subprocess.run(['docker', 'cp', f'{profile_cfg}/.', f'{cname}:/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/config/'], stderr=subprocess.DEVNULL)
    elif os.path.exists('config/servers.dat'):
        subprocess.run(['docker', 'cp', 'config/servers.dat', f'{cname}:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Config/servers.dat'], stderr=subprocess.DEVNULL)
        subprocess.run(['docker', 'cp', 'config/servers.dat', f'{cname}:/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/Config/servers.dat'], stderr=subprocess.DEVNULL)
        subprocess.run(['docker', 'cp', 'config/servers.dat', f'{cname}:/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/config/servers.dat'], stderr=subprocess.DEVNULL)
    if os.path.exists('config/bases'):
        for b_name in os.listdir('config/bases'):
            b_path = os.path.join('config/bases', b_name)
            if os.path.isdir(b_path):
                subprocess.run(['docker', 'cp', b_path, f'{cname}:/opt/wineprefix/drive_c/Program Files/MetaTrader 5/Bases/'], stderr=subprocess.DEVNULL)
                subprocess.run(['docker', 'cp', b_path, f'{cname}:/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/Bases/'], stderr=subprocess.DEVNULL)
                subprocess.run(['docker', 'cp', b_path, f'{cname}:/opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/bases/'], stderr=subprocess.DEVNULL)

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
            # Diagnostic: Dump MT5 internal terminal logs to inspect broker connection state
            print(f'=== MT5 Terminal Logs for {cname} ({aid}) ===')
            log_res = subprocess.run(['docker', 'exec', cname, 'sh', '-c', 'find /opt/wineprefix -name "*.log" -exec echo "--- LOG: {} ---" \\; -exec cat {} \\; 2>/dev/null || echo "No log found"'], capture_output=True)
            raw_bytes = log_res.stdout or b''
            try:
                decoded = raw_bytes.decode('utf-16le', errors='replace')
            except Exception:
                decoded = raw_bytes.decode('utf-8', errors='replace')
            for line in decoded.splitlines()[-50:]:
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

