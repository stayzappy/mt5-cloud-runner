#!/usr/bin/env python3
import json
import subprocess
import os
import sys

# Ensure real-time unbuffered logging in CI
sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

def main():
    if not os.path.exists('data/active_accounts.json'):
        print('[Cloud Harness] No active accounts found. Exiting cleanly.', flush=True)
        sys.exit(0)

    with open('data/active_accounts.json') as f:
        active = json.load(f)

    for a in active:
        cname = a['container']
        env_file = a['env_file']
        aid = a.get('id', '')
        print(f'[Cloud Harness] Configuring MT5 container {cname} for account {aid}...', flush=True)

        with open(env_file) as ef:
            lines = dict(line.strip().split('=', 1) for line in ef if '=' in line)
        login = lines.get('MT5_LOGIN', '')
        pwd = lines.get('MT5_PASSWORD', '')
        raw_srv = lines.get('MT5_SERVER', 'Exness-MT5Trial9')

        # Determine direct broker server connection endpoint
        if 'aiwa' in raw_srv.lower() or 'aiwa' in cname.lower() or 'aiwa' in aid.lower():
            srv = 'AiwaCapital-Server'
        elif 'real21' in raw_srv.lower() or 'cent' in aid.lower():
            srv = 'Exness-MT5Real21'
        elif 'trial9' in raw_srv.lower() or 'trial' in raw_srv.lower() or 'funded' in aid.lower():
            srv = 'Exness-MT5Trial9'
        else:
            srv = raw_srv

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

        # Enable portable mode
        subprocess.run(['docker', 'exec', cname, 'touch', '/opt/wineprefix/drive_c/Program Files/MetaTrader 5/portable.txt'], stderr=subprocess.DEVNULL)
        subprocess.run(['docker', 'exec', cname, 'sed', '-i', 's/terminal64.exe \\/config:mt5cfg.ini/terminal64.exe \\/portable \\/config:mt5cfg.ini/g', '/mt5linux/start.sh'], stderr=subprocess.DEVNULL)

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
