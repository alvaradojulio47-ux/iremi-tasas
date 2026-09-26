#!/usr/bin/env python3
"""IREMI · Mensaje de tasas sugeridas por WhatsApp (08:30 y 15:30, hora de Chile).
Toma el precio P2P de Binance con las MISMAS reglas que usa la app para el flyer y calcula
la tasa IREMI de cada país con 3 márgenes (por defecto 5,5 % · 6 % · 6,5 %), todo en un solo mensaje.
Uso:  python3 /opt/iremi/tasas_whatsapp.py            -> envía el mensaje
      python3 /opt/iremi/tasas_whatsapp.py --ver      -> solo lo muestra en pantalla (no envía)"""
import sys, re, json, math, time, urllib.request, datetime as dt
from zoneinfo import ZoneInfo

CL = ZoneInfo('America/Santiago')
DIAS = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom']
PAISES = [  # (fiat, bandera y nombre, regla)
    ('VES', '🇻🇪 Venezuela (Bs x $1.000)', 'ves'),
    ('COP', '🇨🇴 Colombia', 'desc2'),
    ('PEN', '🇵🇪 Perú', 'noprom2'),
    ('ARS', '🇦🇷 Argentina', 'desc2'),
    ('EUR', '🇪🇸 España', 'noprom2'),
    ('DOP', '🇩🇴 R. Dominicana', 'noprom2'),
    ('MXN', '🇲🇽 México', 'desc2'),
    ('BOB', '🇧🇴 Bolivia', 'noprom2'),
]


def anuncios(fiat, lado, rows=20):
    body = json.dumps({'asset': 'USDT', 'fiat': fiat, 'tradeType': lado, 'page': 1, 'rows': rows,
                       'payTypes': [], 'publisherType': None}).encode()
    req = urllib.request.Request('https://p2p.binance.com/bapi/c2c/v2/friendly/c2c/adv/search', data=body,
                                 headers={'Content-Type': 'application/json', 'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=20) as r:
        return [(float(a['adv']['price']), a['adv'].get('classify') or 'normal')
                for a in (json.load(r).get('data') or []) if a.get('adv', {}).get('price')]


def elegir(ads, regla):
    """Mismas reglas que la app (pantalla Tasas)."""
    if not ads:
        return None
    top10 = ads[:10]
    if regla == 'clp':                                   # BUY: el más alto de los 10 primeros
        return max(p for p, _ in top10)
    if regla == 'desc2':                                 # COP / ARS / MXN: 2° más alto de los 10 primeros
        v = sorted((p for p, _ in top10), reverse=True)
        return v[1] if len(v) > 1 else v[0]
    if regla == 'noprom2':                               # EUR / PEN / DOP / BOB: sin promocionados, 2° en orden de Binance
        n = [p for p, c in top10 if c != 'promoted']
        return (n[1] if len(n) > 1 else (n[0] if n else None))
    if regla == 'ves':                                   # VES: sin promocionados, ±2 % de la media de posiciones 3-8, 2° precio
        vs = sorted((p for p, c in ads if c != 'promoted' and p > 0), reverse=True)
        if not vs:
            return None
        mid = vs[2:min(8, len(vs))]
        med = sum(mid) / len(mid) if mid else vs[len(vs) // 2]
        cl = [p for p in vs if abs(p - med) / med <= 0.02]
        fin = cl if len(cl) >= 2 else vs
        return fin[1] if len(fin) > 1 else fin[0]


def fT(x):
    """3 cifras significativas, redondeando hacia abajo (a favor de IREMI). Igual que el flyer."""
    if x is None or not math.isfinite(x) or x <= 0:
        return '—'
    if x >= 1:
        return f'{math.floor(x * 100 + 1e-9) / 100:.2f}'
    d = 2 - math.floor(math.log10(x))
    return f'{math.floor(x * 10 ** d + 1e-9) / 10 ** d:.{d}f}'


def flecha(nuevo, viejo):
    if not viejo:
        return ''
    pct = (nuevo / viejo - 1) * 100
    if abs(pct) < 0.05:
        return ' (= sin cambio)'
    return f" ({'▲' if pct > 0 else '▼'} {abs(pct):.1f}%)"


def armar(mercado, margenes, ultimo=None, publicada=None, resumen=None, ahora=None):
    ahora = ahora or dt.datetime.now(CL)
    clp = mercado['CLP']
    L = [f'📊 *IREMI · Tasas sugeridas*', f'🗓 {DIAS[ahora.weekday()]} {ahora:%d/%m} · {ahora:%H:%M}', '']
    ref = f" vs {ultimo['cuando']}" if ultimo and ultimo.get('cuando') else ''
    L.append(f"💵 USDT/CLP: *${clp:,.2f}*{flecha(clp, (ultimo or {}).get('clp'))}".replace(',', 'X').replace('.', ',').replace('X', '.') + ref)
    if resumen and resumen.get('prom7'):
        L.append(f"     prom. 7 días ${float(resumen['prom7']):,.0f} · mín. 7 días ${float(resumen.get('min7') or 0):,.0f}".replace(',', '.'))
    if mercado.get('VES'):
        L.append(f"🇻🇪 USDT/VES: {mercado['VES']:,.2f} Bs{flecha(mercado['VES'], (ultimo or {}).get('ves'))}".replace(',', 'X').replace('.', ',').replace('X', '.'))
    if publicada:
        L.append(f"📌 Última tasa VES publicada: {publicada['valor']} ({publicada['fecha']})")
    L += ['', '*Margen → ' + ' | '.join(f"{m:g}%".replace('.', ',') for m in margenes) + '*']
    for fiat, nombre, _ in PAISES:
        px = mercado.get(fiat)
        if not px:
            L.append(f'{nombre}: sin anuncios'); continue
        if fiat == 'VES':
            vals = [str(round(px / clp * (1 - m / 100) * 1000)) for m in margenes]
        else:
            vals = [fT(px / clp * (1 - m / 100)) for m in margenes]
        L.append(f"{nombre}: {' | '.join(vals)}")
    L.append(f"🇵🇦🇪🇨 Panamá · Ecuador · Zelle · USDT: {' | '.join(fT(1 / clp * (1 - m / 100)) for m in margenes)}")
    L.append(f"💳 PayPal: {' | '.join(fT(0.95 / clp * (1 - m / 100)) for m in margenes)}")
    L += ['', '_Precios P2P de Binance con las reglas del flyer._']
    return '\n'.join(L)


def main():
    sys.path.insert(0, '/opt/iremi')
    import robot as R
    cfg = R.config()
    try:
        extra = {f['clave']: f['valor'] for f in R.sb('GET', 'robot_config', params='select=clave,valor&clave=like.tasas_msg*') or []}
    except Exception:
        extra = {}
    if (extra.get('tasas_msg_activo') or 'si').strip().lower() in ('no', '0', 'off') and '--ver' not in sys.argv and '--forzar' not in sys.argv:
        R.log('Mensaje de tasas desactivado (tasas_msg_activo = no)'); return
    margenes = [float(x) for x in re.findall(r'\d+(?:\.\d+)?', (extra.get('tasas_msg_margenes') or '5.5,6,6.5').replace(' ', ''))][:4] or [5.5, 6, 6.5]
    mercado = {}
    mercado['CLP'] = elegir(anuncios('CLP', 'BUY'), 'clp')
    for fiat, _, regla in PAISES:
        try:
            mercado[fiat] = elegir(anuncios(fiat, 'SELL'), regla)
        except Exception as e:
            R.log('Sin precio', fiat, e); mercado[fiat] = None
        time.sleep(0.4)
    if not mercado['CLP']:
        R.log('No hay precio USDT/CLP: no se envía'); return
    ultimo = None
    try:
        ultimo = json.loads(R.estado_get('tasas_msg_ultimo') or 'null')
    except Exception:
        pass
    publicada = None
    try:
        t = R.sb('GET', 'tasas_diarias', params='select=fecha,ves&ves=not.is.null&order=fecha.desc&limit=1') or []
        if t:
            v = float(t[0]['ves']); publicada = {'valor': round(v * 1000) if v < 5 else round(v), 'fecha': t[0]['fecha'][8:10] + '/' + t[0]['fecha'][5:7]}
    except Exception:
        pass
    resumen = None
    try:
        resumen = (R.sb('GET', 'precios_resumen', params='select=*') or [None])[0]
    except Exception:
        pass
    ahora = dt.datetime.now(CL)
    msg = armar(mercado, margenes, ultimo, publicada, resumen, ahora)
    if '--ver' in sys.argv:
        print(msg); return
    R.avisar(cfg, 'tasas', msg)
    R.estado_set('tasas_msg_ultimo', json.dumps({'clp': mercado['CLP'], 'ves': mercado.get('VES'),
                                                 'cuando': f"{DIAS[ahora.weekday()]} {ahora:%H:%M}"}))


if __name__ == '__main__':
    main()
