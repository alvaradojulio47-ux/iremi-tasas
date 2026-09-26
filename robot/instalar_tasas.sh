#!/bin/bash
# IREMI · instala el mensaje de tasas por WhatsApp a las 08:30 y 15:30 (hora de Chile)
set -e
cd /opt/iremi
echo "1/4 Descargando el programa..."
curl -sfLo tasas_whatsapp.py https://raw.githubusercontent.com/alvaradojulio47-ux/iremi-tasas/main/robot/tasas_whatsapp.py
echo "2/4 Programando 08:30 y 15:30..."
cat > /etc/systemd/system/iremi-tasas.service <<'UNIT'
[Unit]
Description=IREMI mensaje de tasas por WhatsApp
After=network-online.target
[Service]
Type=oneshot
WorkingDirectory=/opt/iremi
ExecStart=/usr/bin/python3 /opt/iremi/tasas_whatsapp.py
UNIT
cat > /etc/systemd/system/iremi-tasas.timer <<'UNIT'
[Unit]
Description=IREMI tasas 08:30 y 15:30 (hora de Chile)
[Timer]
OnCalendar=*-*-* 08:30:00 America/Santiago
OnCalendar=*-*-* 15:30:00 America/Santiago
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now iremi-tasas.timer
echo "3/4 Guardando la configuración en Supabase..."
python3 - <<'PY'
import sys; sys.path.insert(0, '/opt/iremi'); import robot as R
R.sb('POST', 'robot_config', [
  {'clave': 'tasas_msg_activo', 'valor': 'si', 'descripcion': 'Mensaje de tasas por WhatsApp a las 08:30 y 15:30 (si / no)'},
  {'clave': 'tasas_msg_margenes', 'valor': '5.5, 6, 6.5', 'descripcion': 'Márgenes del mensaje de tasas, separados por coma (máximo 4)'}],
  params='on_conflict=clave', prefer='resolution=ignore-duplicates,return=minimal')
print('   listo')
PY
echo "4/4 Vista previa (todavía NO se envía):"
echo "--------------------------------------------"
python3 /opt/iremi/tasas_whatsapp.py --ver
echo "--------------------------------------------"
systemctl list-timers iremi-tasas.timer --no-pager
echo "✅ Instalado. Para enviarlo ahora mismo de prueba:  python3 /opt/iremi/tasas_whatsapp.py"
