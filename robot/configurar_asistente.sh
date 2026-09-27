#!/bin/bash
# IREMI · Parte 3 (como usuario hermes): conecta las herramientas IREMI, la personalidad y WhatsApp a Hermes
set -e
[ "$(whoami)" = hermes ] || { echo "Ejecútalo como el usuario hermes:  su - hermes"; exit 1; }
M=$HOME/iremi-mcp
HB=$(command -v hermes || echo $HOME/.local/bin/hermes)
[ -x "$HB" ] || { echo "No encuentro Hermes. Primero instálalo (paso 5 de la guía)."; exit 1; }
mkdir -p ~/.hermes && cp $M/SOUL.md ~/.hermes/SOUL.md
read -p "Número(s) que pueden hablar con el asistente, con código de país y sin + (separados por coma) [56999968721]: " NUM
NUM=${NUM:-56999968721}
read -p "Modo WhatsApp: 1 = número aparte para el asistente, 2 = chat contigo mismo [1]: " MODO
[ "$MODO" = 2 ] && WM=self-chat || WM=bot
$M/venv/bin/python - "$NUM" "$WM" "$M" <<'PY'
import sys, os, yaml
num, modo, m = sys.argv[1:4]
home = os.path.expanduser('~')
# 1) .env de Hermes: WhatsApp solo para tus números
envp = f'{home}/.hermes/.env'
lines = [l for l in (open(envp).read().splitlines() if os.path.exists(envp) else [])
         if not l.startswith(('WHATSAPP_ENABLED=', 'WHATSAPP_MODE=', 'WHATSAPP_ALLOWED_USERS=', 'WHATSAPP_ALLOW_ALL_USERS='))]
lines += ['WHATSAPP_ENABLED=true', f'WHATSAPP_MODE={modo}', f'WHATSAPP_ALLOWED_USERS={num.replace(" ", "")}']
open(envp, 'w').write('\n'.join(lines) + '\n'); os.chmod(envp, 0o600)
# 2) config.yaml: sin terminal/archivos/navegador/código, con herramientas IREMI
cp = f'{home}/.hermes/config.yaml'
cfg = (yaml.safe_load(open(cp)) if os.path.exists(cp) else None) or {}
ag = cfg.setdefault('agent', {}) or {}
cfg['agent'] = ag
ag['disabled_toolsets'] = sorted(set((ag.get('disabled_toolsets') or []) + ['terminal', 'file', 'browser', 'execute_code']))
cfg.setdefault('mcp_servers', {})['iremi'] = {'command': f'{m}/venv/bin/python', 'args': [f'{m}/iremi_mcp.py'],
                                               'env': {'IREMI_BOT_ENV': f'{home}/.iremi_bot.env'}}
yaml.safe_dump(cfg, open(cp, 'w'), allow_unicode=True, sort_keys=False)
print('✅ Configuración guardada (WhatsApp modo', modo, '· números', num, ')')
PY
echo "Instalando el servicio para que funcione 24/7..."
$HB gateway install
echo
echo "✅ Listo. Escríbele al asistente por WhatsApp, por ejemplo:  ¿cuánto gané hoy?"
