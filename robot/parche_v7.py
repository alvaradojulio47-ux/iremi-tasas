# Parche v7 (idempotente): traspasos entre tus cuentas JULIO ⇄ IREMI
# - Además de Binance Pay, el robot lee los RETIROS y DEPÓSITOS de USDT (incluye "retiro interno" entre cuentas Binance).
# - Un movimiento es "traspaso_interno" si la otra parte es tu otra cuenta: por correo (alvaradojulio47@gmail.com /
#   iremiremesas@gmail.com, editable en robot_config 'cuentas_propias'), por ID de Binance, por el mismo código de
#   transferencia, o porque sale de una cuenta y entra el mismo monto en la otra en menos de 15 minutos.
# - Todo lo demás (otras personas o billeteras) queda "tercero_revisar".
p = '/opt/iremi/robot.py'
s = open(p).read()
if 'def movimientos_cripto' in s:
    print('Parche v7 ya estaba aplicado')
    raise SystemExit
i = s.find('    # 3) Binance Pay (se clasifica traspaso interno si la contraparte es la otra cuenta)')
j = s.find("        log(f'{cuenta}: {len(filas)} movimientos Binance Pay')", i)
if i < 0 or j < 0:
    print('ERROR: no encontré el bloque de Binance Pay. Avísale a Claude (no se cambió nada).')
    raise SystemExit
j = j + len("        log(f'{cuenta}: {len(filas)} movimientos Binance Pay')")

FUNCS = r'''
def movimientos_cripto(cuenta, desde_ms, hasta_ms):
    """Retiros y depósitos de USDT (incluye 'retiro interno' entre cuentas Binance). Ventanas de 89 días."""
    out = []
    ini = desde_ms
    while ini < hasta_ms:
        fin = min(ini + 89 * DIA_MS, hasta_ms)
        try:
            for w in bn(cuenta, 'GET', '/sapi/v1/capital/withdraw/history', coin='USDT', startTime=ini, endTime=fin, limit=1000) or []:
                if int(w.get('status', 0)) != 6:      # 6 = completado
                    continue
                t = dt.datetime.strptime(w['applyTime'], '%Y-%m-%d %H:%M:%S').replace(tzinfo=dt.timezone.utc)
                interno = int(w.get('transferType', 0)) == 1
                out.append({'id': f"{cuenta}-W-{w['id']}", 'cuenta': cuenta, 'fecha': t.isoformat(),
                            'monto': -(float(w['amount']) + float(w.get('transactionFee') or 0)), 'moneda': 'USDT',
                            'tipo': 'RETIRO' + (' INTERNO' if interno else ''),
                            'contraparte': ('Binance interno · ' if interno else '') + str(w.get('address', ''))[:24],
                            'ref': str(w.get('txId') or ''), '_interno': interno})
        except Exception as e:
            log(f'Aviso {cuenta}: no pude leer retiros:', e)
        try:
            for d in bn(cuenta, 'GET', '/sapi/v1/capital/deposit/hisrec', coin='USDT', startTime=ini, endTime=fin, limit=1000) or []:
                if int(d.get('status', 0)) not in (1, 6):  # 1/6 = acreditado
                    continue
                t = dt.datetime.fromtimestamp(int(d['insertTime']) / 1000, dt.timezone.utc)
                interno = int(d.get('transferType', 0)) == 1
                out.append({'id': f"{cuenta}-D-{d.get('id') or d.get('txId')}", 'cuenta': cuenta, 'fecha': t.isoformat(),
                            'monto': float(d['amount']), 'moneda': 'USDT',
                            'tipo': 'DEPOSITO' + (' INTERNO' if interno else ''),
                            'contraparte': ('Binance interno · ' if interno else '') + str(d.get('address', ''))[:24],
                            'ref': str(d.get('txId') or ''), '_interno': interno})
        except Exception as e:
            log(f'Aviso {cuenta}: no pude leer depósitos:', e)
        ini = fin + 1
    return out


def _correo_coincide(texto, correos):
    """Compara correos aunque Binance los muestre enmascarados (ej. alv***@gmail.com)."""
    t = (texto or '').strip().lower()
    if not t or '@' not in t:
        return False
    for c in correos:
        if t == c:
            return True
        u, _, dom = t.partition('@'); cu, _, cdom = c.partition('@')
        if '*' in u and dom == cdom and cu.startswith(u.split('*')[0]) and len(u.split('*')[0]) >= 2:
            return True
    return False


def clasificar_propios(filas, uids, correos):
    """Marca 'traspaso_interno' lo que va o viene de tu otra cuenta; el resto 'tercero_revisar'."""
    for f in filas:
        cp = f.pop('_cp', {}) or {}
        otra = uids.get('IREMI' if f['cuenta'] == 'JULIO' else 'JULIO')
        ids = {str(cp.get('binanceId', '')), str(cp.get('accountId', ''))}
        propio = (otra and otra in ids) or _correo_coincide(cp.get('email'), correos) or _correo_coincide(f.get('contraparte'), correos)
        f['clasificacion'] = 'traspaso_interno' if propio else 'tercero_revisar'
    # mismo código de transferencia en las dos cuentas (retiro interno)
    por_ref = {}
    for f in filas:
        if f.get('ref'):
            por_ref.setdefault(f['ref'], []).append(f)
    for grupo in por_ref.values():
        if len({g['cuenta'] for g in grupo}) == 2:
            for g in grupo: g['clasificacion'] = 'traspaso_interno'
    # sale de una cuenta y entra el mismo monto en la otra (±15 min): se marcan las dos puntas
    t = lambda f: dt.datetime.fromisoformat(f['fecha']).timestamp()
    usadas = set()
    for sa in sorted((f for f in filas if f['monto'] < 0), key=t):
        for en in sorted((f for f in filas if f['monto'] > 0 and f['id'] not in usadas), key=t):
            if en['cuenta'] != sa['cuenta'] and en.get('moneda') == sa.get('moneda') \
               and abs(abs(sa['monto']) - en['monto']) <= max(0.02, abs(sa['monto']) * 0.002) and abs(t(sa) - t(en)) <= 900:
                sa['clasificacion'] = en['clasificacion'] = 'traspaso_interno'; usadas.add(en['id']); break
    for f in filas:
        f.pop('_interno', None)
    return filas

'''
NEW3 = r'''    # 3) Binance Pay + retiros/depósitos de USDT. Traspasos entre tus dos cuentas = 'traspaso_interno'
    correos = [c.strip().lower() for c in (config().get('cuentas_propias') or 'alvaradojulio47@gmail.com,iremiremesas@gmail.com').split(',') if c.strip()]
    todas = []
    for cuenta in CUENTAS:
        for p in pagos(cuenta, desde_ms, ahora_ms):
            monto = float(p['amount'])
            cp = (p.get('receiverInfo') if monto < 0 else p.get('payerInfo')) or {}
            todas.append({'id': f"{cuenta}-{p['transactionId']}", 'cuenta': cuenta,
                          'fecha': dt.datetime.fromtimestamp(p['transactionTime'] / 1000, dt.timezone.utc).isoformat(),
                          'monto': monto, 'moneda': p.get('currency'), 'tipo': p.get('orderType'),
                          'contraparte': cp.get('email') or cp.get('name') or str(cp.get('binanceId', '')),
                          'ref': str(p.get('transactionId') or ''), '_cp': cp})
        todas += movimientos_cripto(cuenta, desde_ms, ahora_ms)
    clasificar_propios(todas, uids, correos)
    todas = list({f['id']: f for f in todas}.values())   # sin repetidos
    for cuenta in CUENTAS:
        filas = [f for f in todas if f['cuenta'] == cuenta]
        if filas:
            upsert('robot_pay', filas, 'id')
        n_int = sum(1 for f in filas if f['clasificacion'] == 'traspaso_interno')
        log(f'{cuenta}: {len(filas)} movimientos Pay/retiros/depósitos ({n_int} traspasos entre tus cuentas)')'''

s = s[:i] + NEW3 + s[j:]
s = s.replace('# ------------------------------------------------------------------ ciclo principal', FUNCS + '# ------------------------------------------------------------------ ciclo principal', 1)
s = s.replace("            'telegram_token': '', 'telegram_chat': ''}", "            'telegram_token': '', 'telegram_chat': '', 'cuentas_propias': ''}", 1)
open(p + '.antes_v7', 'w').write(open(p).read())
open(p, 'w').write(s)
print('Parche v7 aplicado (copia de respaldo en /opt/iremi/robot.py.antes_v7)')
