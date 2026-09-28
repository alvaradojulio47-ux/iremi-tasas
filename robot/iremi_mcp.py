#!/usr/bin/env python3
"""IREMI · Herramientas de SOLO LECTURA para el asistente (Hermes + Claude) por WhatsApp.

Entra a Supabase con un usuario propio del bot (correo + contraseña en /home/hermes/.iremi_bot.env),
así que la base de datos le aplica las mismas reglas que a cualquier usuario de la app:
puede LEER, pero no puede escribir gastos, banco, alertas ni usuarios, y no ve el Libro Excel (solo admin).
No toca Binance ni las llaves del robot.
"""
import json, math, os, time, datetime as dt, urllib.request, urllib.parse, urllib.error
from zoneinfo import ZoneInfo
from mcp.server.fastmcp import FastMCP

SB_URL = 'https://fdzjibkothlkfeqbkqzc.supabase.co'
SB_ANON = ('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZkemppYmtvdGhsa2ZlcWJrcXpjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3'
           'NzQyNjU0MjYsImV4cCI6MjA4OTg0MTQyNn0.AlyciTFOMPGLgNapifPw4auGjKNEjZ1CmFSVokwJzFs')
CRED = os.environ.get('IREMI_BOT_ENV', os.path.expanduser('~/.iremi_bot.env'))
CL = ZoneInfo('America/Santiago')
MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']

mcp = FastMCP('iremi')
_tok = {'access': None, 'refresh': None, 'exp': 0}


# ───────────────────────── acceso a Supabase (como usuario del bot)
def _cred():
    d = {}
    for l in open(CRED):
        if '=' in l and not l.strip().startswith('#'):
            k, v = l.strip().split('=', 1); d[k.strip()] = v.strip()
    return d['IREMI_BOT_EMAIL'], d['IREMI_BOT_PASSWORD']


def _auth(grant, body):
    req = urllib.request.Request(f'{SB_URL}/auth/v1/token?grant_type={grant}', data=json.dumps(body).encode(),
                                 headers={'apikey': SB_ANON, 'Content-Type': 'application/json'}, method='POST')
    with urllib.request.urlopen(req, timeout=20) as r:
        d = json.load(r)
    _tok.update(access=d['access_token'], refresh=d['refresh_token'], exp=time.time() + int(d.get('expires_in', 3600)) - 120)


def _token():
    if not _tok['access'] or time.time() > _tok['exp']:
        try:
            if _tok['refresh']:
                _auth('refresh_token', {'refresh_token': _tok['refresh']}); return _tok['access']
        except Exception:
            pass
        e, p = _cred(); _auth('password', {'email': e, 'password': p})
    return _tok['access']


def sb(path):
    req = urllib.request.Request(f'{SB_URL}/rest/v1/{path}', headers={'apikey': SB_ANON, 'Authorization': 'Bearer ' + _token()})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            t = r.read().decode(); return json.loads(t) if t.strip() else []
    except urllib.error.HTTPError as e:
        raise RuntimeError(f'Supabase {e.code}: {e.read().decode()[:200]}')


def q(v): return urllib.parse.quote(str(v), safe='')


# ───────────────────────── utilidades
def hoy(): return dt.datetime.now(CL).date()


def rango(periodo):
    """'hoy' | 'ayer' | 'semana' (7 días) | 'mes' (mes actual) | 'mes_pasado' | 'YYYY-MM' | 'YYYY-MM-DD:YYYY-MM-DD'"""
    h = hoy(); p = (periodo or 'hoy').strip().lower()
    if p == 'hoy': return h, h
    if p == 'ayer': return h - dt.timedelta(1), h - dt.timedelta(1)
    if p in ('semana', '7d'): return h - dt.timedelta(6), h
    if p in ('mes', 'este mes'): return h.replace(day=1), h
    if p in ('mes_pasado', 'mes pasado'):
        f = h.replace(day=1) - dt.timedelta(1); return f.replace(day=1), f
    if ':' in p:
        a, b = p.split(':'); return dt.date.fromisoformat(a), dt.date.fromisoformat(b)
    if len(p) == 7:
        a = dt.date.fromisoformat(p + '-01'); b = (a.replace(day=28) + dt.timedelta(4)); return a, b - dt.timedelta(b.day)
    d = dt.date.fromisoformat(p); return d, d


def clp(x): return '$' + f'{round(float(x or 0)):,}'.replace(',', '.')


def fT(x):
    if x is None or not math.isfinite(x) or x <= 0: return '—'
    if x >= 1: return f'{math.floor(x * 100 + 1e-9) / 100:.2f}'
    d = 2 - math.floor(math.log10(x)); return f'{math.floor(x * 10 ** d + 1e-9) / 10 ** d:.{d}f}'


def elegir(det, regla):
    """Reglas del flyer (iguales a la app)."""
    ads = [(float(p), c or 'normal') for p, c in (det or [])]
    if not ads: return None
    top = ads[:10]
    if regla == 'clp': return max(p for p, _ in top)
    if regla == 'desc2':
        v = sorted((p for p, _ in top), reverse=True); return v[1] if len(v) > 1 else v[0]
    if regla == 'noprom2':
        n = [p for p, c in top if c != 'promoted']; return n[1] if len(n) > 1 else (n[0] if n else None)
    vs = sorted((p for p, c in ads if c != 'promoted' and p > 0), reverse=True)
    if not vs: return None
    mid = vs[2:min(8, len(vs))]; med = sum(mid) / len(mid) if mid else vs[len(vs) // 2]
    cl = [p for p in vs if abs(p - med) / med <= 0.02]; fin = cl if len(cl) >= 2 else vs
    return fin[1] if len(fin) > 1 else fin[0]


REGLA = {'VES': 'ves', 'COP': 'desc2', 'ARS': 'desc2', 'MXN': 'desc2', 'EUR': 'noprom2', 'PEN': 'noprom2', 'DOP': 'noprom2', 'BOB': 'noprom2'}
NOMBRE = {'VES': 'Venezuela', 'COP': 'Colombia', 'PEN': 'Perú', 'ARS': 'Argentina', 'EUR': 'España', 'DOP': 'R. Dominicana',
          'MXN': 'México', 'BOB': 'Bolivia', 'USD': 'Panamá/Ecuador/Zelle/USDT'}


# ───────────────────────── HERRAMIENTAS (todas de solo lectura)
@mcp.tool()
def resumen_operaciones(periodo: str = 'hoy') -> str:
    """Cambios realizados (ventas de USDT a clientes) y compras de USDT en un período, con ganancia, margen,
    detalle por país de destino y por cuenta. periodo: 'hoy', 'ayer', 'semana', 'mes', 'mes_pasado', 'YYYY-MM' o 'YYYY-MM-DD:YYYY-MM-DD'.
    Incluye libro de cambios (hasta ago-2026) y robot (desde sep-2026)."""
    a, b = rango(periodo)
    ops = sb(f'v_operaciones?select=origen,fecha,tipo,monto_clp,usdt,destino,ganancia_clp,detalle&fecha=gte.{a}&fecha=lte.{b}&limit=5000')
    v = [o for o in ops if o['tipo'] == 'VENTA']; c = [o for o in ops if o['tipo'] == 'COMPRA']
    tot = sum(float(o['monto_clp'] or 0) for o in v); g = sum(float(o['ganancia_clp'] or 0) for o in v)
    por = {}
    for o in v:
        r = por.setdefault(o['destino'] or '¿?', [0, 0.0, 0.0]); r[0] += 1; r[1] += float(o['monto_clp'] or 0); r[2] += float(o['ganancia_clp'] or 0)
    cuentas = {}
    for o in v:
        if o['origen'] == 'robot' and o.get('detalle'):
            k = o['detalle'].split(' · ')[0]; cuentas[k] = cuentas.get(k, 0) + 1
    out = {'periodo': f'{a} a {b}', 'cambios': len(v), 'clp_recibido': clp(tot), 'ganancia': clp(g),
           'margen_%': round(g / tot * 100, 2) if tot else None,
           'compras_usdt': len(c), 'clp_en_compras': clp(sum(float(o['monto_clp'] or 0) for o in c)),
           'usdt_comprados': round(sum(float(o['usdt'] or 0) for o in c), 2),
           'por_pais': {k: {'cambios': n, 'clp': clp(t), 'ganancia': clp(gg), 'margen_%': round(gg / t * 100, 2) if t else None}
                        for k, (n, t, gg) in sorted(por.items(), key=lambda x: -x[1][1])},
           'cambios_por_cuenta_robot': cuentas}
    return json.dumps(out, ensure_ascii=False)


@mcp.tool()
def mercado_y_tasas_sugeridas(margenes: str = '5.5,6,6.5') -> str:
    """Precio P2P actual de Binance (guardado por el robot cada 10 min) y la tasa IREMI sugerida para cada país
    con los márgenes pedidos (misma fórmula y reglas del flyer). También trae promedio y mínimo de 7 días del USDT/CLP
    y la última tasa VES publicada. margenes: lista separada por coma, ej '5.5,6,6.5'."""
    ms = [float(x) for x in margenes.replace(' ', '').split(',') if x][:5] or [5.5, 6, 6.5]
    mk = {r['fiat']: r for r in sb('v_mercado_actual?select=fiat,fecha,detalle')}
    if 'CLP' not in mk: return 'El robot aún no tiene precios de mercado.'
    edad = round((dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(mk['CLP']['fecha'].replace('Z', '+00:00'))).total_seconds() / 60)
    c = elegir(mk['CLP']['detalle'], 'clp')
    precios = {'USDT/CLP (compra)': c}
    tasas = {}
    for f, rg in REGLA.items():
        p = elegir((mk.get(f) or {}).get('detalle'), rg); precios[f'USDT/{f}'] = p
        if not p: continue
        tasas[NOMBRE[f] + (' (Bs por $1.000)' if f == 'VES' else '')] = {f'{m:g}%': (round(p / c * (1 - m / 100) * 1000) if f == 'VES' else fT(p / c * (1 - m / 100))) for m in ms}
    tasas[NOMBRE['USD']] = {f'{m:g}%': fT(1 / c * (1 - m / 100)) for m in ms}
    res = (sb('precios_resumen?select=*') or [{}])[0]
    pub = sb('tasas_diarias?select=fecha,ves,margen&ves=not.is.null&order=fecha.desc&limit=1')
    out = {'precios_hace_min': edad, 'precios_mercado': precios, 'usdt_clp_prom7': res.get('prom7'), 'usdt_clp_min7': res.get('min7'),
           'usdt_clp_prom30': res.get('prom30'),
           'ultima_tasa_ves_publicada': ({'fecha': pub[0]['fecha'], 'bs_por_1000': round(float(pub[0]['ves']) * 1000) if float(pub[0]['ves']) < 5 else pub[0]['ves'],
                                          'margen': pub[0].get('margen')} if pub else None),
           'tasas_sugeridas': tasas}
    return json.dumps(out, ensure_ascii=False)


@mcp.tool()
def capital_y_cuadre() -> str:
    """Saldo USDT actual de las cuentas JULIO e IREMI (leído por el robot) y el cuadre de caja: saldo que debería haber
    según las órdenes vs saldo real, y la diferencia."""
    sal = sb('robot_saldos?select=cuenta,total,fecha&order=fecha.desc&limit=10'); ult = {}
    for s in sal: ult.setdefault(s['cuenta'], s)
    cq = (sb('v_cuadre?select=*') or [{}])[0]
    return json.dumps({'saldos': {k: {'usdt': round(float(v['total']), 2), 'leido': v['fecha']} for k, v in ult.items()},
                       'total_usdt': round(sum(float(v['total']) for v in ult.values()), 2), 'cuadre': cq}, ensure_ascii=False)


@mcp.tool()
def buscar_operaciones(texto: str = '', monto: int = 0, periodo: str = 'mes', limite: int = 20) -> str:
    """Busca cambios/compras por texto (nombre de contraparte, comentario, cuenta) y/o monto exacto en CLP dentro de un período
    ('hoy','semana','mes','mes_pasado','YYYY-MM', o 'todo')."""
    f = '' if periodo == 'todo' else '&fecha=gte.{}&fecha=lte.{}'.format(*rango(periodo))
    p = f'v_operaciones?select=origen,fecha,tipo,monto_clp,usdt,destino,tasa_iremi,ganancia_clp,detalle{f}&order=fecha.desc&limit={min(int(limite), 100)}'
    if monto: p += f'&monto_clp=eq.{int(monto)}'
    if texto: p += f'&detalle=ilike.*{q(texto)}*'
    return json.dumps(sb(p), ensure_ascii=False)


@mcp.tool()
def resumen_mensual(desde: str = '2025-08') -> str:
    """Una fila por mes desde 'desde' (YYYY-MM): cambios, CLP cambiado, ganancia (lo que va a boleta), comisión Transf Local 4%,
    gastos y utilidad interna."""
    return json.dumps(sb(f'v_resumen_mensual?select=mes,origen,cambios,clp_cambiado,ganancia,comision_belkys,gastos,utilidad&mes=gte.{desde}-01&order=mes.asc'), ensure_ascii=False)


@mcp.tool()
def cuadre_banco_vs_libro() -> str:
    """Comparación mes a mes entre los cambios del libro/robot y la plata que llegó a la cuenta BancoEstado de la empresa,
    compras de USDT libro vs banco, movimientos por revisar y salvedades."""
    return json.dumps(sb('v_conciliacion_mensual?select=*&order=mes.desc'), ensure_ascii=False)


@mcp.tool()
def banco_por_revisar(limite: int = 30) -> str:
    """Movimientos de la cartola bancaria que todavía no están clasificados (categoria 'por_revisar'), los más recientes primero."""
    return json.dumps(sb(f'banco_movimientos?select=fecha,cartola,descripcion,cargo,abono,nota&categoria=eq.por_revisar&order=fecha.desc&limit={min(int(limite), 100)}'), ensure_ascii=False)


@mcp.tool()
def transf_local(mes: str = '') -> str:
    """Flujo Transf Local (antes 'Belkys') por mes: entradas (Fidel, Angélica, Lilibeth), pagado a Belkys/Florelvis (96%),
    comisión 4% de Julio y resto enviado a Venezuela. mes: 'YYYY-MM' o vacío para todos."""
    f = f'&mes=eq.{mes}-01' if mes else ''
    return json.dumps(sb(f'v_belkys_mes?select=*{f}&order=mes.desc'), ensure_ascii=False)


@mcp.tool()
def gastos(periodo: str = 'mes') -> str:
    """Gastos anotados (contador, IVA/SII, sueldos, retiro socio, otros) en un período, con total por categoría."""
    a, b = rango(periodo)
    g = sb(f'robot_gastos?select=fecha,categoria,descripcion,monto_clp&fecha=gte.{a}&fecha=lte.{b}&order=fecha.asc')
    cat = {}
    for x in g: cat[x['categoria']] = cat.get(x['categoria'], 0) + float(x['monto_clp'] or 0)
    return json.dumps({'periodo': f'{a} a {b}', 'total': clp(sum(cat.values())), 'por_categoria': {k: clp(v) for k, v in cat.items()}, 'detalle': g}, ensure_ascii=False)


@mcp.tool()
def historial_tasas(pais: str = 'ves', dias: int = 30) -> str:
    """Tasa IREMI publicada día a día para un país (ves, cop, pen, ars, eur, dop, mxn, bob, pab, zelle, usdt) y el margen real
    que se ganó esos días. dias: cuántos días hacia atrás (máx. 400)."""
    col = pais.lower().strip(); desde = hoy() - dt.timedelta(min(int(dias), 400))
    t = sb(f'tasas_diarias?select=fecha,{col},margen,fuente&fecha=gte.{desde}&order=fecha.asc')
    fiat = {'ves': 'VES', 'cop': 'COP', 'pen': 'PEN', 'ars': 'ARS', 'eur': 'EUR', 'dop': 'DOP', 'mxn': 'MXN', 'bob': 'BOB', 'zelle': 'USD'}.get(col)
    mr = {r['fecha']: r for r in sb(f'v_margen_diario?select=fecha,n,clp,ganancia&destino=eq.{fiat}&fecha=gte.{desde}')} if fiat else {}
    return json.dumps([{'fecha': x['fecha'], 'tasa': x[col], 'margen_teorico': x.get('margen'),
                        'cambios': (mr.get(x['fecha']) or {}).get('n'),
                        'margen_real_%': round(float(mr[x['fecha']]['ganancia']) / float(mr[x['fecha']]['clp']) * 100, 2) if x['fecha'] in mr and float(mr[x['fecha']]['clp'] or 0) else None}
                       for x in t if x.get(col) is not None], ensure_ascii=False)


@mcp.tool()
def precio_usdt_clp_historico(dias: int = 7) -> str:
    """Evolución del precio USDT/CLP (compra P2P) registrado por el robot: mínimo, máximo, promedio y precio por hora de los últimos días."""
    desde = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=min(int(dias), 60))).isoformat()
    r = sb(f'precios_p2p?select=fecha,clp_min&fecha=gte.{q(desde)}&order=fecha.asc&limit=5000')
    v = [float(x['clp_min']) for x in r if x.get('clp_min')]
    if not v: return 'Sin datos de precio.'
    horas = {}
    for x in r:
        if x.get('clp_min'):
            k = dt.datetime.fromisoformat(x['fecha'].replace('Z', '+00:00')).astimezone(CL).strftime('%d/%m %Hh'); horas[k] = float(x['clp_min'])
    return json.dumps({'dias': dias, 'min': min(v), 'max': max(v), 'promedio': round(sum(v) / len(v), 2), 'actual': v[-1],
                       'por_hora': dict(list(horas.items())[-72:])}, ensure_ascii=False)


@mcp.tool()
def estado_robot_y_alertas() -> str:
    """Última sincronización del robot con Binance y las últimas alertas enviadas por WhatsApp."""
    return json.dumps({'estado': sb('robot_estado?select=clave,valor,actualizado'),
                       'alertas': sb('robot_alertas?select=fecha,tipo,mensaje&order=fecha.desc&limit=5')}, ensure_ascii=False)


@mcp.tool()
def ordenes_por_corregir(limite: int = 20) -> str:
    """Órdenes del robot cuyo monto en CLP es estimado o no tiene tasa (hay que confirmarlas en la app, pantalla Movimientos)."""
    return json.dumps(sb(f'v_ordenes?select=creado,cuenta,fiat,monto_fiat,usdt,contraparte,clp_final,metodo_clp&estado=eq.COMPLETED&tipo=eq.SELL'
                         f'&clp_manual=is.null&revision=is.null&metodo_clp=in.(estimado,sin_tasa)&order=creado.desc&limit={min(int(limite), 50)}'), ensure_ascii=False)


if __name__ == '__main__':
    mcp.run()
