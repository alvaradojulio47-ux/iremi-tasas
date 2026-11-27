#!/usr/bin/env python3
"""IREMI · Precio del USDT ahora mismo, a pedido.
Consulta Binance P2P en vivo (lado BUY en CLP, igual que el robot), lo compara con los
promedios guardados y manda el aviso por Telegram.
Uso:  python3 /opt/iremi/precio_ahora.py          -> lo envía
      python3 /opt/iremi/precio_ahora.py --ver    -> solo lo muestra, no envía"""
import sys, json, urllib.request

sys.path.insert(0, '/opt/iremi')
import robot as R


def anuncios_clp(rows=20):
    cuerpo = json.dumps({'asset': 'USDT', 'fiat': 'CLP', 'tradeType': 'BUY', 'page': 1,
                         'rows': rows, 'payTypes': [], 'publisherType': None}).encode()
    pet = urllib.request.Request('https://p2p.binance.com/bapi/c2c/v2/friendly/c2c/adv/search',
                                 data=cuerpo, headers={'Content-Type': 'application/json',
                                                       'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(pet, timeout=25) as r:
        return sorted((float(a['adv']['price'])
                       for a in (json.load(r).get('data') or []) if a.get('adv', {}).get('price')),
                      reverse=True)


def plata(x):
    return '$' + format(round(x, 2), ',.2f').replace(',', '·').replace('.', ',').replace('·', '.')


def main():
    precios = anuncios_clp()
    if not precios:
        print('Binance no devolvió precios'); return
    mejor = precios[0]
    top5 = sum(precios[:5]) / len(precios[:5])

    res = {}
    try:
        res = (R.sb('GET', 'precios_resumen', params='select=*') or [{}])[0] or {}
    except Exception as e:
        R.log('No pude leer los promedios guardados:', e)
    prom7 = res.get('prom7')
    min7 = res.get('min7')
    prom30 = res.get('prom30')

    if prom7:
        dif = (mejor - float(prom7)) / float(prom7) * 100
        flecha = '📈' if dif >= 0 else '📉'
        comp = 'sobre' if dif >= 0 else 'bajo'
        cabeza = ('%s USDT/CLP a %s — %s el promedio de 7 días (%s)'
                  % (flecha, plata(mejor), comp, plata(float(prom7))))
    else:
        cabeza = '💵 USDT/CLP a %s' % plata(mejor)

    lineas = [cabeza, 'Mejor oferta: %s · Promedio top 5: %s' % (plata(mejor), plata(top5))]
    extra = []
    if min7:
        extra.append('mín. 7 días ' + plata(float(min7)))
    if prom30:
        extra.append('prom. 30 días ' + plata(float(prom30)))
    if extra:
        lineas.append(' · '.join(extra))
    if min7 and mejor <= float(min7) * 1.002:
        lineas.append('🟢 Está en el mínimo de la semana: buen momento para comprar')
    msg = '\n'.join(lineas)

    if '--ver' in sys.argv:
        print(msg); return
    ok = False
    try:
        ok = R.enviar_telegram(R.config(), msg)
    except AttributeError:
        print('Falta aplicar el parche de Telegram (parche_telegram.py)')
    print(msg)
    print('\nEnviado por Telegram:', 'sí' if ok else 'NO')


if __name__ == '__main__':
    main()
