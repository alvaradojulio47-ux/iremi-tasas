#!/bin/bash
# IREMI · Parte 1 (como root): prepara el servidor para el asistente de WhatsApp (Hermes + Claude)
set -e
[ "$(id -u)" = 0 ] || { echo "Ejecútalo como root"; exit 1; }
BASE=https://raw.githubusercontent.com/alvaradojulio47-ux/iremi-tasas/main/robot
H=/home/hermes

echo "1/7 Memoria de respaldo (swap de 2 GB)..."
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
echo "2/7 Programas necesarios (Node.js 20, Python venv, git)..."
apt-get update -qq
if ! command -v node >/dev/null || [ "$(node -v | cut -c2- | cut -d. -f1)" -lt 18 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
apt-get install -y -qq python3-venv git curl >/dev/null
echo "3/7 Protegiendo las llaves del robot (el asistente NO podrá leerlas)..."
chmod 700 /opt/iremi; chmod 600 /opt/iremi/.env
echo "4/7 Usuario separado 'hermes' (sin permisos de administrador)..."
id hermes >/dev/null 2>&1 || useradd -m -s /bin/bash hermes
loginctl enable-linger hermes
echo "5/7 Herramientas IREMI de solo lectura..."
mkdir -p $H/iremi-mcp
for f in iremi_mcp.py SOUL.md configurar_asistente.sh; do curl -sfLo $H/iremi-mcp/$f $BASE/$f; done
python3 -m venv $H/iremi-mcp/venv
$H/iremi-mcp/venv/bin/pip install -q --upgrade pip >/dev/null
$H/iremi-mcp/venv/bin/pip install -q mcp pyyaml
echo "6/7 Usuario del asistente en Supabase (el que creaste en Authentication → Users)"
read -p "   Correo del asistente: " BE
read -s -p "   Contraseña del asistente (no se verá al escribir): " BP; echo
printf 'IREMI_BOT_EMAIL=%s\nIREMI_BOT_PASSWORD=%s\n' "$BE" "$BP" > $H/.iremi_bot.env
chmod 600 $H/.iremi_bot.env; chown -R hermes:hermes $H
echo "7/7 Pruebas..."
if sudo -u hermes cat /opt/iremi/.env >/dev/null 2>&1; then echo "   ⚠ el usuario hermes PUEDE leer las llaves: avísale a Claude"; else echo "   ✅ el asistente no puede leer las llaves del robot"; fi
sudo -u hermes -H $H/iremi-mcp/venv/bin/python - <<'PY'
import sys; sys.path.insert(0, '/home/hermes/iremi-mcp'); import iremi_mcp as M, json
try:
    d = json.loads(M.capital_y_cuadre()); print('   ✅ conexión a Supabase OK · capital:', d.get('total_usdt'), 'USDT')
except Exception as e:
    print('   ✗ no pude leer Supabase:', e, '\n     Revisa el correo/contraseña y que el correo esté agregado en la app (Más → Usuarios).')
PY
echo
echo "Listo la parte 1. Ahora sigue con:  su - hermes"
