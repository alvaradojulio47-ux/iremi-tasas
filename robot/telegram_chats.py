#!/usr/bin/env python3
"""IREMI · Muestra los chats de Telegram que el bot puede usar (privados y grupos).

Sirve para averiguar el número (chat id) de un grupo nuevo y así mandarle los avisos.

Antes de correrlo:
  1. Crea el grupo en Telegram y agrega al bot.
  2. Dentro del grupo escribe:  /start@tu_bot
     (en los grupos el bot solo ve los mensajes que lo nombran, por eso hace falta)

Uso:  python3 /opt/iremi/telegram_chats.py

No muestra el token en pantalla."""
import sys, json, urllib.parse, urllib.request

sys.path.insert(0, '/opt/iremi')
import robot as R

API = 'https://api.telegram.org/bot%s/%s'


def pedir(tok, metodo, **params):
    url = API % (tok, metodo)
    if params:
        url += '?' + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def main():
    cfg = R.config()
    tok = (cfg.get('telegram_token') or '').strip()
    actual = (cfg.get('telegram_chat') or '').strip()
    if not tok:
        print('✗ No hay telegram_token guardado en robot_config.')
        return 1

    try:
        yo = pedir(tok, 'getMe')
    except Exception as e:
        print('✗ No pude hablar con Telegram: %s' % e)
        return 1
    if not yo.get('ok'):
        print('✗ Telegram rechazó el token: %s' % yo.get('description'))
        return 1
    b = yo['result']
    print('Bot: %s · usuario: @%s' % (b.get('first_name', ''), b.get('username', '')))
    print('Chats configurados ahora: %s\n' % (actual or '(ninguno)'))

    try:
        up = pedir(tok, 'getUpdates', limit=100, timeout=0)
    except Exception as e:
        print('✗ No pude leer los mensajes recientes: %s' % e)
        return 1

    vistos = {}
    for u in up.get('result', []):
        for llave in ('message', 'edited_message', 'channel_post', 'my_chat_member'):
            ch = (u.get(llave) or {}).get('chat')
            if ch and ch.get('id') is not None:
                vistos[ch['id']] = ch

    if not vistos:
        print('No veo ningún chat todavía.')
        print('En el grupo escribe  /start@%s  y vuelve a correr esto.' % b.get('username', 'tu_bot'))
        print('(Telegram solo guarda los mensajes de las últimas 24 horas.)')
        return 0

    print('%-16s  %-10s  %s' % ('CHAT ID', 'TIPO', 'NOMBRE'))
    print('-' * 60)
    for cid, ch in sorted(vistos.items()):
        nombre = ch.get('title') or ' '.join(x for x in (ch.get('first_name'), ch.get('last_name')) if x) \
                 or ch.get('username') or ''
        marca = '  <- ya configurado' if str(cid) in [c.strip() for c in actual.replace(';', ',').split(',')] else ''
        print('%-16s  %-10s  %s%s' % (cid, ch.get('type', ''), nombre, marca))

    print('\nLos grupos tienen el número en negativo. Para mandar los avisos a varios,')
    print('guarda los números separados por coma en robot_config.telegram_chat.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
