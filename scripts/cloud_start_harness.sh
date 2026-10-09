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

python3 -c "
import urllib.request, json, os

worker_url = os.getenv('CONTROL_WORKER_URL', 'https://mt5-control-studio.zapstream.workers.dev').rstrip('/')
req = urllib.request.Request(f'{worker_url}/api/dashboard?secrets=true', headers={'User-Agent': 'Mozilla/5.0'})
try:
    raw = urllib.request.urlopen(req, timeout=12).read().decode('utf-8')
    data = json.loads(raw)
    accounts = data.get('accounts', [])
    for acc in accounts:
        aid = acc.get('id')
        env_file = f'.env.{aid}'
        is_w80 = aid == 'weekly80' or acc.get('weekly80_mode') is True
        with open(env_file, 'w') as f:
            f.write(f'ACCOUNT_ID={aid}\n')
            f.write(f'MT5_LOGIN={acc.get(\"mt5_login\")}\n')
            f.write(f'MT5_PASSWORD={acc.get(\"mt5_password\")}\n')
            f.write(f'MT5_SERVER={acc.get(\"mt5_server\", \"Exness-MT5Trial9\")}\n')
            f.write(f'RPYC_HOST=localhost\n')
            f.write(f'RPYC_PORT={acc.get(\"rpyc_port\", 18812)}\n')
            f.write(f'MAGIC_NUMBER={acc.get(\"magic_number\", 1001)}\n')
            f.write(f'SYMBOL={acc.get(\"symbol\", \"EURUSDm\")}\n')
            f.write(f'STRATEGY_MODE={acc.get(\"strategy_mode\", \"STANDARD\")}\n')
            f.write(f'STRATEGY_NAME={acc.get(\"name\", aid).replace(\" \", \"_\")}\n')
            f.write(f'RISK_MODE={acc.get(\"risk_mode\", \"FLUID_6_BULLET\")}\n')
            f.write(f'TOP_ANCHOR={acc.get(\"top_anchor\", 200000.0)}\n')
            f.write(f'MAX_DRAWDOWN={acc.get(\"max_drawdown\", 200000.0)}\n')
            f.write(f'GOAL_TARGET_PCT={acc.get(\"goal_target_pct\", 15.0)}\n')
            f.write(f'WEEKLY80_MODE={is_w80}\n')
            f.write(f'SL_PIPS={acc.get(\"sl_pips\", 6.3)}\n')
            f.write(f'TP_PIPS={acc.get(\"tp_pips\", 11.0)}\n')
            f.write(f'BE_TRIGGER_PIPS={acc.get(\"be_trigger_pips\", 11.0 if is_w80 else 6.3)}\n')
            f.write(f'BE_LOCK_PIPS={acc.get(\"be_lock_pips\", 0.0 if is_w80 else 0.2)}\n')
            f.write(f'PROFIT_LOCK_TRIGGER_PIPS={acc.get(\"profit_lock_trigger_pips\", 99.0)}\n')
            f.write(f'PROFIT_LOCK_SL_PIPS={acc.get(\"profit_lock_sl_pips\", 99.0)}\n')
            f.write(f'HOR_BARS={acc.get(\"hor_bars\", 32)}\n')
            f.write(f'SPREAD_PIPS={acc.get(\"spread_pips\", 0.8)}\n')
            f.write(f'STATE_FILE=data/state_{aid}.json\n')
            f.write(f'LOG_FILE=logs/{aid}.log\n')
            f.write(f'CONTROL_WORKER_URL={worker_url}\n')
    print(f'Successfully loaded {len(accounts)} dynamic account profiles.')
except Exception as e:
    print(f'Warning: Could not fetch accounts from Worker: {e}')
"


# 4. Start Docker containers
echo "[Cloud Harness] Starting Docker MT5 headless containers..."
docker compose up -d

echo "[Cloud Harness] Waiting 15s for Wine initialization..."
sleep 15

# Helper: Auto-login injection into container
inject_mt5_cfg() {
    local container="$1"
    local env_file="$2"
    if [ ! -f "$env_file" ]; then return 0; fi

    local login password server
    login=$(grep '^MT5_LOGIN=' "$env_file" | cut -d'=' -f2 | tr -d ' "\r')
    password=$(grep '^MT5_PASSWORD=' "$env_file" | cut -d'=' -f2 | tr -d ' "\r')
    server=$(grep '^MT5_SERVER=' "$env_file" | cut -d'=' -f2 | tr -d ' "\r')

    if [ -n "$login" ] && [ -n "$password" ] && [ -n "$server" ]; then
        docker exec "$container" bash -c "
cat > /opt/wineprefix/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/mt5cfg.ini <<'EOF'
[Start]
Profile=default
Login=$login
Password=$password
Server=$server
EOF
" 2>/dev/null || true
    fi
}

inject_mt5_cfg mt5_headless .env.strategy_a
inject_mt5_cfg mt5_headless_b .env.strategy_b
inject_mt5_cfg mt5_headless_c .env.funded_500k
inject_mt5_cfg mt5_headless_d .env.weekly80
docker restart mt5_headless mt5_headless_b mt5_headless_c mt5_headless_d >/dev/null 2>&1 || true
sleep 15

# 5. Wait for all 4 RPyC bridges to become ready
echo "[Cloud Harness] Waiting for MT5 bridges on ports 18812, 18813, 18814 & 18815..."
python3 -c "
import socket, time, sys
for port in [18812, 18813, 18814, 18815]:
    ok = False
    for _ in range(90):
        try:
            with socket.create_connection(('localhost', port), timeout=1.0):
                ok = True
                break
        except (socket.error, OSError):
            time.sleep(1.0)
    if not ok:
        print(f'Warning: Port {port} did not respond within timeout.', file=sys.stderr)
print('All MT5 RPyC bridges are ready.')
"

# 6. Launch all 4 bots via compiled standalone binary
echo "[Cloud Harness] Launching 4 bots in --window-mode via compiled native binary..."
./mt5_trader_engine --env .env.strategy_a --window-mode &
PID_A=$!

./mt5_trader_engine --env .env.strategy_b --window-mode &
PID_B=$!

./mt5_trader_engine --env .env.funded_500k --window-mode &
PID_C=$!

./mt5_trader_engine --env .env.weekly80 --window-mode &
PID_D=$!

echo "[Cloud Harness] 4 bots executing in background (PIDs: $PID_A, $PID_B, $PID_C, $PID_D)."
wait "$PID_A" "$PID_B" "$PID_C" "$PID_D"
echo "[Cloud Harness] Session complete. Clean exit."

