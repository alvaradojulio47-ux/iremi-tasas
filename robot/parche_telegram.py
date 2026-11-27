#!/usr/bin/env python3
"""IREMI · Agrega Telegram a los avisos del robot.
 - Hace copia de seguridad de robot.py antes de tocarlo.
 - Agrega la función enviar_telegram() al final del módulo.
 - Inserta al inicio de avisar() el envío por Telegram (no quita nada de lo que ya hay).
 - Si el archivo quedara mal, restaura la copia automáticamente.
Se puede correr más de una vez: si ya está parchado, avisa y no hace nada."""
import re, sys, shutil, py_compile, datetime, os

RUTA = sys.argv[1] if len(sys.argv) > 1 else '/opt/iremi/robot.py'

FUNC = '''

# ── Telegram (agregado por el parche) ───────────────────────────────────────
def enviar_telegram(cfg, texto):
    """Manda el texto al Telegram configurado. True si Telegram confirma el envío."""
    import json as _json, urllib.parse as _up, urllib.request as _ur
    cfg = cfg or {}
    tok = (cfg.get('telegram_token') or '').strip()
    chat = (cfg.get('telegram_chat') or '').strip()
    if not tok or not chat:
        return False
    def _mandar(modo):
        campos = {'chat_id': chat, 'text': texto, 'disable_web_page_preview': 'true'}
        if modo:
            campos['parse_mode'] = modo
        pet = _ur.Request('https://api.telegram.org/bot%s/sendMessage' % tok,
                          data=_up.urlencode(campos).encode())
        with _ur.urlopen(pet, timeout=30) as r:
            return _json.load(r)
    for modo in ('Markdown', None):          # si el formato falla, se manda como texto plano
        try:
            if _mandar(modo).get('ok'):
                return True
        except Exception as e:
            ultimo = e
    try:
        log('Telegram no envió el aviso:', locals().get('ultimo', 'respuesta no ok'))
    except Exception:
        pass
    return False
'''

def main():
    if not os.path.exists(RUTA):
        print('✗ No encuentro', RUTA); return 1
    src = open(RUTA, encoding='utf-8').read()
    if 'enviar_telegram' in src:
        print('Ya estaba parchado: no hago nada.'); return 0

    m = re.search(r'^(\s*)def\s+avisar\s*\(', src, re.M)
    if not m:
        print('✗ No encuentro la función avisar() en', RUTA); return 1
    sangria_def = m.group(1)

    # fin de la firma: desde el paréntesis, hasta cerrar paréntesis y encontrar ':'
    i = src.index('(', m.start()); prof = 0
    while i < len(src):
        if src[i] == '(': prof += 1
        elif src[i] == ')':
            prof -= 1
            if prof == 0: break
        i += 1
    fin_firma = src.index('\n', src.index(':', i)) + 1
    firma = src[m.start():fin_firma]
    params = [p.split('=')[0].split(':')[0].strip()
              for p in re.search(r'\((.*)\)', firma, re.S).group(1).split(',') if p.strip()]
    if len(params) < 3:
        print('✗ avisar() tiene', len(params), 'parámetros y esperaba al menos 3 (cfg, tipo, mensaje).')
        print('  Firma encontrada:', firma.strip()[:120]); return 1
    p_cfg = params[0]
    # el parámetro del mensaje: por nombre si se reconoce, si no el tercero
    preferidos = ('msg', 'mensaje', 'texto', 'text', 'body', 'cuerpo')
    p_msg = next((p for p in params if p.lower() in preferidos), None) or params[2]

    cuerpo = src[fin_firma:]
    sangria = re.match(r'[ \t]*', cuerpo.lstrip('\n')).group(0) or (sangria_def + '    ')
    # si lo primero del cuerpo es un docstring, insertar después
    desp = fin_firma
    doc = re.match(r'(\s*)([ruRU]{0,2}("""|\'\'\'))', cuerpo)
    if doc:
        cierre = doc.group(3)
        desp = fin_firma + cuerpo.index(cierre, doc.end() - len(cierre) + len(cierre)) + len(cierre)
        desp = src.index('\n', desp) + 1

    ins = (f'{sangria}try:                      # Telegram (parche)\n'
           f'{sangria}    enviar_telegram({p_cfg}, {p_msg})\n'
           f'{sangria}except Exception:\n'
           f'{sangria}    pass\n')
    nuevo = src[:desp] + ins + src[desp:] + FUNC

    copia = RUTA + '.bak-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    shutil.copy2(RUTA, copia)
    open(RUTA, 'w', encoding='utf-8').write(nuevo)
    try:
        py_compile.compile(RUTA, doraise=True)
    except Exception as e:
        shutil.copy2(copia, RUTA)
        print('✗ El archivo quedaba con error, lo dejé como estaba:', e); return 1
    print('✓ Listo. Copia de seguridad en', copia)
    print('  avisar() ahora manda también por Telegram (parámetros:', p_cfg + ',', p_msg + ')')
    return 0

sys.exit(main())
