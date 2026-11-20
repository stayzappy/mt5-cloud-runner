#!/usr/bin/env python3
import json
import subprocess
import os
import sys
import time

# Ensure real-time unbuffered logging in CI
sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

UPGRADE_SCRIPT_CONTENT = '''#!/usr/bin/env bash
set -e
export WINEPREFIX="/opt/wineprefix"
export DISPLAY=":100"

echo "[Upgrade $(date '+%H:%M:%S')] Terminating running MT5 and Python..."
wine taskkill /IM terminal64.exe /F 2>/dev/null || true
wine taskkill /IM python.exe /F 2>/dev/null || true
pkill -9 -f terminal64 2>/dev/null || true
pkill -9 -f python 2>/dev/null || true
sleep 2

echo "[Upgrade $(date '+%H:%M:%S')] Pre-upgrade terminal64.exe:"
ls -la "/opt/wineprefix/drive_c/Program Files/MetaTrader 5/terminal64.exe" || true

echo "[Upgrade $(date '+%H:%M:%S')] Launching mt5setup.exe /auto..."
wine /tmp/mt5setup.exe /auto /path:"C:\\\\Program Files\\\\MetaTrader 5" &
SETUP_PID=$!
echo "[Upgrade $(date '+%H:%M:%S')] mt5setup.exe spawned with PID $SETUP_PID. Monitoring installation..."

for step in $(seq 1 40); do
    sleep 2
    RUNNING_PROCS=$(ps aux | grep -iE "setup|terminal64" | grep -v grep || true)
    echo "[Upgrade $(date '+%H:%M:%S')] Step $step procs: $RUNNING_PROCS"
    if echo "$RUNNING_PROCS" | grep -iq "terminal64.exe"; then
        echo "[Upgrade $(date '+%H:%M:%S')] Installer completed and spawned terminal64.exe!"
        break
    fi
    if ! kill -0 $SETUP_PID 2>/dev/null; then
        echo "[Upgrade $(date '+%H:%M:%S')] mt5setup.exe finished."
        break
    fi
done

sleep 3
echo "[Upgrade $(date '+%H:%M:%S')] Cleaning up installer and terminal processes..."
wine taskkill /IM mt5setup.exe /F 2>/dev/null || true
wine taskkill /IM terminal64.exe /F 2>/dev/null || true
pkill -9 -f mt5setup 2>/dev/null || true
pkill -9 -f terminal64 2>/dev/null || true
rm -f /tmp/mt5setup.exe
sleep 2

echo "[Upgrade $(date '+%H:%M:%S')] Post-upgrade terminal64.exe:"
ls -la "/opt/wineprefix/drive_c/Program Files/MetaTrader 5/terminal64.exe" || true
'''

def main():
    if not os.path.exists('data/active_accounts.json'):
        print('[Cloud Harness] No active accounts found. Exiting cleanly.', flush=True)
        sys.exit(0)

    with open('data/active_accounts.json') as f:
        active = json.load(f)

    print('[Cloud Harness] Fetching latest official MT5 setup (build 6000+) to satisfy broker requirements...', flush=True)
    subprocess.run(['curl', '-sL', 'https://download.mql5.com/cdn/web/metaquotes.ltd/mt5/mt5setup.exe', '-o', '/tmp/mt5setup.exe'], check=True)

    with open('/tmp/upgrade_mt5.sh', 'w') as f:
        f.write(UPGRADE_SCRIPT_CONTENT)

    for a in active:
        cname = a['container']
        env_file = a['env_file']
        print(f'[Cloud Harness] Upgrading MT5 terminal in container {cname} to latest build (>= 6000)...', flush=True)
        subprocess.run(['docker', 'cp', '/tmp/mt5setup.exe', f'{cname}:/tmp/mt5setup.exe'], check=True)
        subprocess.run(['docker', 'cp', '/tmp/upgrade_mt5.sh', f'{cname}:/tmp/upgrade_mt5.sh'], check=True)
        subprocess.run(['docker', 'exec', cname, 'chmod', '+x', '/tmp/upgrade_mt5.sh'], check=True)
        
        # Execute upgrade script and stream output
        res = subprocess.run(['docker', 'exec', cname, 'bash', '/tmp/upgrade_mt5.sh'])
        if res.returncode != 0:
            print(f'[Cloud Harness] WARNING: Upgrade script exited with code {res.returncode}', flush=True)

        print(f'[Cloud Harness] Injecting config for {a["id"]} into container {cname}...', flush=True)
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

        print(f'[Cloud Harness] Restarting container {cname} to load MT5 configuration...', flush=True)
        subprocess.run(['docker', 'restart', cname], check=True)

if __name__ == '__main__':
    main()
