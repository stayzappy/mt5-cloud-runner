#!/usr/bin/env python3
import urllib.request
import json
import os

worker_url = os.getenv('CONTROL_WORKER_URL', 'https://mt5-control-studio.zapstream.workers.dev').rstrip('/')
req = urllib.request.Request(f'{worker_url}/api/dashboard?secrets=true', headers={'User-Agent': 'Mozilla/5.0'})

try:
    raw = urllib.request.urlopen(req, timeout=12).read().decode('utf-8')
    data = json.loads(raw)
    accounts = data.get('accounts', [])
    tg_token = data.get('telegram_bot_token') or os.getenv('TELEGRAM_BOT_TOKEN', '8867158689:AAFjM-QYCjMMMFA2_kpw98wCi-yzxzrACHA')
    tg_chat = data.get('telegram_chat_id') or os.getenv('TELEGRAM_CHAT_ID', '1239030524')

    for acc in accounts:
        aid = acc.get('id')
        env_file = f'.env.{aid}'
        is_w80 = aid == 'weekly80' or acc.get('weekly80_mode') is True
        strat_name = str(acc.get('name', aid)).replace(' ', '_')
        with open(env_file, 'w') as f:
            f.write(f'ACCOUNT_ID={aid}\n')
            f.write(f'MT5_LOGIN={acc.get("mt5_login")}\n')
            f.write(f'MT5_PASSWORD={acc.get("mt5_password")}\n')
            f.write(f'MT5_SERVER={acc.get("mt5_server", "Exness-MT5Trial9")}\n')
            f.write(f'RPYC_HOST=localhost\n')
            f.write(f'RPYC_PORT={acc.get("rpyc_port", 18812)}\n')
            f.write(f'MAGIC_NUMBER={acc.get("magic_number", 1001)}\n')
            f.write(f'SYMBOL={acc.get("symbol", "EURUSDm")}\n')
            f.write(f'STRATEGY_MODE={acc.get("strategy_mode", "STANDARD")}\n')
            f.write(f'STRATEGY_NAME={strat_name}\n')
            f.write(f'RISK_MODE={acc.get("risk_mode", "FLUID_6_BULLET")}\n')
            f.write(f'TOP_ANCHOR={acc.get("top_anchor", 200000.0)}\n')
            f.write(f'MAX_DRAWDOWN={acc.get("max_drawdown", 200000.0)}\n')
            f.write(f'GOAL_TARGET_PCT={acc.get("goal_target_pct", 15.0)}\n')
            f.write(f'WEEKLY80_MODE={is_w80}\n')
            f.write(f'SL_PIPS={acc.get("sl_pips", 6.3)}\n')
            f.write(f'TP_PIPS={acc.get("tp_pips", 11.0)}\n')
            f.write(f'BE_TRIGGER_PIPS={acc.get("be_trigger_pips", 11.0 if is_w80 else 6.3)}\n')
            f.write(f'BE_LOCK_PIPS={acc.get("be_lock_pips", 0.0 if is_w80 else 0.2)}\n')
            f.write(f'PROFIT_LOCK_TRIGGER_PIPS={acc.get("profit_lock_trigger_pips", 99.0)}\n')
            f.write(f'PROFIT_LOCK_SL_PIPS={acc.get("profit_lock_sl_pips", 99.0)}\n')
            f.write(f'HOR_BARS={acc.get("hor_bars", 32)}\n')
            f.write(f'SPREAD_PIPS={acc.get("spread_pips", 0.8)}\n')
            f.write(f'TELEGRAM_BOT_TOKEN={tg_token}\n')
            f.write(f'TELEGRAM_CHAT_ID={tg_chat}\n')
            f.write(f'STATE_FILE=data/state_{aid}.json\n')
            f.write(f'LOG_FILE=logs/{aid}.log\n')
            f.write(f'CONTROL_WORKER_URL={worker_url}\n')
    print(f'Successfully loaded {len(accounts)} dynamic account profiles with live Telegram credentials.')
except Exception as e:
    print(f'Warning: Could not fetch accounts from Worker: {e}')

