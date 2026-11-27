#!/usr/bin/env python3
"""IREMI · Deja un solo envío por Telegram (hoy manda dos veces).

El robot ya traía su propio envío por Telegram dentro de avisar(), dormido porque no
había token ni chat configurados. Al configurarlos quedaron dos caminos activos:
  1. el viejo, que manda en texto plano y da por enviado sin mirar la respuesta
  2. el del parche, que manda con formato, verifica y deja constancia

Este parche quita el viejo y deja el del parche, pero conserva lo bueno del viejo:
anotar 'telegram' en el registro de alertas — ahora solo cuando de verdad se envió.

Hace copia de seguridad, verifica que el archivo quede bien y lo restaura si algo falla.
Se puede correr más de una vez.

Uso:  python3 /opt/iremi/parche_telegram_unico.py
"""
import re, sys, shutil, py_compile, datetime, os

RUTA = sys.argv[1] if len(sys.argv) > 1 else '/opt/iremi/robot.py'


def salir(msg, codigo=1):
    print(msg)
    sys.exit(codigo)


def main():
    if not os.path.exists(RUTA):
        salir('✗ No encuentro %s' % RUTA)
    src = open(RUTA, encoding='utf-8').read()

    if '_tg_ok' in src:
        salir('✓ Ya estaba parchado: el envío por Telegram ya es uno solo. No toco nada.', 0)
    if 'def registrar_aviso(' not in src:
        salir('✗ Falta el parche de constancia. Corre primero:\n'
              '    python3 /opt/iremi/parche_avisos.py')

    # ── 1) guardar el resultado del envío del parche ────────────────────────
    bloque = re.compile(
        r'^([ \t]*)try:[ \t]*#[ \t]*Telegram \(parche\)[ \t]*\n'
        r'([ \t]*)registrar_aviso\(\s*([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*)\s*\)[ \t]*\n'
        r'([ \t]*)except Exception:[ \t]*\n'
        r'([ \t]*)pass[ \t]*\n', re.M)
    m = bloque.search(src)
    if not m:
        salir('✗ No encuentro el bloque que dejó el parche de Telegram dentro de avisar().\n'
              '  Puede que el archivo haya cambiado a mano. No toco nada.')
    s1, s2, p_cfg, p_msg = m.group(1), m.group(2), m.group(3), m.group(4)
    nuevo_bloque = (
        '%s_tg_ok = False               # Telegram (parche)\n'
        '%stry:\n'
        '%s_tg_ok = registrar_aviso(%s, %s)\n'
        '%sexcept Exception:\n'
        '%spass\n' % (s1, s1, s2, p_cfg, p_msg, s1, s2))
    src = src[:m.start()] + nuevo_bloque + src[m.end():]

    # ── 2) quitar el envío viejo, dejando solo la anotación del canal ───────
    viejo = re.compile(
        r'^([ \t]*)if cfg\.get\(\'telegram_token\'\) and cfg\.get\(\'telegram_chat\'\):[ \t]*\n'
        r'(?:[ \t]*q = urllib\.parse\.urlencode\(.*\n)'
        r'(?:[ \t]*urllib\.request\.urlopen\(.*\n)'
        r'([ \t]*)canales\.append\(\'telegram\'\)[ \t]*\n', re.M)
    m2 = viejo.search(src)
    if not m2:
        salir('✗ No encuentro el envío viejo de Telegram dentro de avisar().\n'
              '  Si ya lo quitaste a mano, no hay nada que hacer. No toco nada.')
    reemplazo = ('%sif _tg_ok:        # el envío ya lo hizo registrar_aviso(), con confirmación\n'
                 '%scanales.append(\'telegram\')\n' % (m2.group(1), m2.group(2)))
    src = src[:m2.start()] + reemplazo + src[m2.end():]

    # ── 3) guardar con red de seguridad ─────────────────────────────────────
    copia = RUTA + '.bak-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    shutil.copy2(RUTA, copia)
    open(RUTA, 'w', encoding='utf-8').write(src)
    try:
        py_compile.compile(RUTA, doraise=True)
    except Exception as e:
        shutil.copy2(copia, RUTA)
        salir('✗ El archivo quedaría mal, lo dejé como estaba.\n  Detalle: %s' % e)

    print('✓ Listo. Ahora el aviso se manda una sola vez.')
    print('  Copia de seguridad: %s' % copia)
    print('  - El envío viejo (texto plano, sin confirmar) quedó fuera.')
    print('  - Se mantiene el envío con formato, que verifica y deja constancia.')
    print('  - El registro de alertas anota "telegram" solo cuando de verdad se envió.')
    print('\n  Para probar:  python3 /opt/iremi/tasas_whatsapp.py')


if __name__ == '__main__':
    main()
