#!/usr/bin/env python3
"""IREMI · Deja constancia de cada aviso: si no se envía, queda registrado y se ve en la app.

Qué hace:
 - Reemplaza, dentro de avisar(), la llamada directa a enviar_telegram() por registrar_aviso().
 - Agrega registrar_aviso(): manda por Telegram y guarda el resultado en la tabla robot_estado
   (aviso_ultimo_ok, aviso_ultima_falla, aviso_fallas_seguidas).
 - No quita nada de lo que ya hay y nunca deja que un error de registro rompa el robot.

Requiere que antes se haya aplicado parche_telegram.py.
Se puede correr más de una vez: si ya está parchado, avisa y no hace nada.

Uso:  python3 /opt/iremi/parche_avisos.py
"""
import re, sys, shutil, py_compile, datetime, os

RUTA = sys.argv[1] if len(sys.argv) > 1 else '/opt/iremi/robot.py'

FUNC = '''

# ── Constancia de los avisos (agregado por el parche) ───────────────────────
def registrar_aviso(cfg, texto):
    """Manda el aviso por Telegram y deja constancia del resultado en robot_estado.

    Guarda tres llaves:
      aviso_ultimo_ok        fecha y hora del ultimo aviso que si se envio
      aviso_ultima_falla     fecha, hora y motivo de la ultima falla
      aviso_fallas_seguidas  cuantas fallas seguidas van (0 cuando se envia bien)
    La app lee estas llaves y las muestra en Inicio, en el cuadro del Robot.
    Nunca levanta una excepcion: si no puede registrar, solo lo anota en el log."""
    try:
        ahora = dt.datetime.now(CHILE).strftime('%Y-%m-%d %H:%M')
    except Exception:
        ahora = time.strftime('%Y-%m-%d %H:%M')
    ok, motivo = False, ''
    try:
        ok = bool(enviar_telegram(cfg, texto))
        if not ok:
            motivo = 'Telegram no confirmo el envio'
    except Exception as e:
        motivo = (str(e) or e.__class__.__name__)[:200]
    try:
        if ok:
            estado_set('aviso_ultimo_ok', ahora)
            estado_set('aviso_fallas_seguidas', '0')
            estado_set('aviso_ultima_falla', '')
        else:
            try:
                n = int(float(estado_get('aviso_fallas_seguidas') or 0))
            except Exception:
                n = 0
            estado_set('aviso_fallas_seguidas', str(n + 1))
            estado_set('aviso_ultima_falla', ahora + ' - ' + (motivo or 'no se pudo enviar'))
            try:
                log('AVISO NO ENVIADO:', motivo or 'sin detalle')
            except Exception:
                pass
    except Exception as e:
        try:
            log('No se pudo registrar el estado del aviso:', e)
        except Exception:
            pass
    return ok
'''


def salir(msg, codigo=1):
    print(msg)
    sys.exit(codigo)


def main():
    if not os.path.exists(RUTA):
        salir('✗ No encuentro %s' % RUTA)
    src = open(RUTA, encoding='utf-8').read()

    if 'def registrar_aviso(' in src:
        salir('✓ Ya estaba parchado: registrar_aviso() ya existe. No toco nada.', 0)

    # el parche de Telegram tiene que estar puesto primero
    if 'def enviar_telegram(' not in src:
        salir('✗ Falta el parche de Telegram. Corre primero:\n'
              '    python3 /opt/iremi/parche_telegram.py')

    # las piezas que usa registrar_aviso tienen que existir en el robot
    faltan = [n for n in ('def estado_set(', 'def estado_get(', 'def log(')
              if n not in src]
    if faltan:
        salir('✗ Este robot.py no tiene %s. No lo toco para no romperlo.'
              % ', '.join(f.replace('def ', '').replace('(', '()') for f in faltan))

    # la llamada que dejó parche_telegram.py dentro de avisar(), con sus nombres reales
    m = re.search(r'^([ \t]*)enviar_telegram\(\s*([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*)\s*\)[ \t]*$',
                  src, re.M)
    if not m:
        salir('✗ No encuentro la línea "enviar_telegram(...)" dentro de avisar().\n'
              '  Puede que el archivo haya cambiado a mano. No toco nada.')

    sangria, p_cfg, p_msg = m.group(1), m.group(2), m.group(3)
    nuevo = (src[:m.start()] +
             '%sregistrar_aviso(%s, %s)' % (sangria, p_cfg, p_msg) +
             src[m.end():] + FUNC)

    copia = RUTA + '.bak-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    shutil.copy2(RUTA, copia)
    open(RUTA, 'w', encoding='utf-8').write(nuevo)
    try:
        py_compile.compile(RUTA, doraise=True)
    except Exception as e:
        shutil.copy2(copia, RUTA)
        salir('✗ El archivo quedaría mal, lo dejé como estaba.\n  Detalle: %s' % e)

    print('✓ Listo. Los avisos ahora quedan registrados.')
    print('  Copia de seguridad: %s' % copia)
    print('  Llamada reemplazada: enviar_telegram(%s, %s) -> registrar_aviso(%s, %s)'
          % (p_cfg, p_msg, p_cfg, p_msg))
    print('\n  Para probar:  python3 /opt/iremi/tasas_whatsapp.py')


if __name__ == '__main__':
    main()
