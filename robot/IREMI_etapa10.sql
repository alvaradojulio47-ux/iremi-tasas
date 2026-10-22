-- ===== APP IREMI · ETAPA 10: las compras de USDT se comparan por la fecha en que el banco las pagó =====
-- Se puede correr más de una vez (va después de la etapa 9).
-- Antes, una compra hecha en Binance el 30/09 a las 23:21 y pagada por el banco el 01/10 aparecía como "falta $200.000" en octubre
-- (y como "sobra" en septiembre). Ahora los pesos de cada compra se cuentan el día en que salieron del banco.

-- 2) Día a día: entró / salió del banco, saldo real, cambios, Transf Local pendiente y sobra/falta
drop view if exists v_diario;
create view v_diario with (security_invoker = true) as
with cfg as (
  select coalesce(max(valor) filter (where clave = 'apertura_fecha'), '2026-09-01')::date      as f0,
         coalesce(max(valor) filter (where clave = 'apertura_cartola'), '52')::int             as cart0,
         coalesce(max(valor) filter (where clave = 'apertura_banco_clp'), '1812111')::numeric  as banco0,
         coalesce(max(valor) filter (where clave = 'apertura_usdt'), '1912.16')::numeric       as usdt0,
         coalesce(max(valor) filter (where clave = 'costo_inicial_usdt'), '934.55')::numeric   as costo0
  from robot_config),
hoy as (select (now() at time zone 'America/Santiago')::date as d),
dias as (select generate_series((select min(fecha) from v_operaciones), (select d from hoy), interval '1 day')::date as dia),
op as (select fecha as dia, count(*) filter (where tipo = 'VENTA') as n,
              sum(monto_clp) filter (where tipo = 'VENTA') as clp, sum(ganancia_clp) filter (where tipo = 'VENTA') as gan
       from v_operaciones group by 1),
ga as (select fecha as dia, sum(monto_clp) as gastos from robot_gastos group by 1),
tl as (select fecha as dia, sum(cargo) / 0.96 * 0.04 as com from banco_movimientos where categoria = 'belkys_pago' group by 1),
co as (select coalesce((select min(b.fecha) from banco_movimientos b where b.categoria = 'compra_usdt' and b.orden_binance is not null and position(o.order_number in b.orden_binance) > 0),
                       (o.creado at time zone 'America/Santiago')::date) as dia,
              sum(o.monto_fiat) as compras_clp
       from v_ordenes o where o.tipo = 'BUY' and o.estado = 'COMPLETED' group by 1),
ro as (select (o.creado at time zone 'America/Santiago')::date as dia,
              sum(o.clp_final) filter (where o.tipo = 'SELL' and coalesce(o.revision, '') not in ('gasto', 'transf_local')) as clp_esperado,
              sum(o.clp_final) filter (where o.tipo = 'SELL' and o.revision = 'transf_local') as tl_enviado,
              sum(o.monto_fiat) filter (where o.tipo = 'BUY') as compras_clp,
              sum(case when o.tipo = 'BUY' then o.usdt else -o.usdt end) - sum(coalesce(o.comision, 0)) as usdt_mov,
              count(*) filter (where o.tipo = 'SELL' and o.clp_final is null) as sin_clp
       from v_ordenes o where o.estado = 'COMPLETED' group by 1),
pa as (select (fecha at time zone 'America/Santiago')::date as dia, sum(monto) as usdt
       from v_pay where moneda = 'USDT' and clasificacion_final <> 'traspaso_interno' group by 1),
bk as (select fecha as dia,
              coalesce(sum(abono) filter (where categoria in ('cambio', 'cambio_sin_orden', 'por_revisar')), 0) as plata_clientes,
              coalesce(sum(abono) filter (where categoria = 'belkys_ingreso'), 0) as tl_in,
              coalesce(sum(cargo) filter (where categoria = 'belkys_pago'), 0) as tl_pag,
              sum(abono) as abonos, sum(cargo) as cargos,
              coalesce(sum(cargo) filter (where categoria = 'compra_usdt'), 0) as compras_banco,
              sum(abono - cargo) as neto
       from banco_movimientos, cfg where cartola >= cfg.cart0 group by 1),
rs as (select dia, sum(total) as usdt_real from (
         select distinct on (cuenta, (fecha at time zone 'America/Santiago')::date)
                cuenta, (fecha at time zone 'America/Santiago')::date as dia, total
         from robot_saldos order by cuenta, (fecha at time zone 'America/Santiago')::date, fecha desc) x
       group by dia having count(*) = (select count(distinct cuenta) from robot_saldos)),
bh as (select max(fecha) as hasta from banco_movimientos),
base as (
  select d.dia, cfg.f0, cfg.banco0, cfg.usdt0, bh.hasta as banco_hasta,
         coalesce(op.n, 0) as cambios, coalesce(op.clp, 0) as clp_cambios, coalesce(op.gan, 0) as ganancia,
         coalesce(tl.com, 0) as comision_tl, coalesce(ga.gastos, 0) as gastos,
         case when d.dia >= cfg.f0 then coalesce(ro.clp_esperado, 0) else 0 end as clp_esperado,
         case when d.dia >= cfg.f0 then coalesce(co.compras_clp, 0) else 0 end as compras_clp,
         case when d.dia >= cfg.f0 then coalesce(ro.usdt_mov, 0) + coalesce(pa.usdt, 0) else 0 end as usdt_mov,
         case when d.dia >= cfg.f0 then coalesce(ro.sin_clp, 0) else 0 end as sin_clp,
         case when d.dia >= cfg.f0 then coalesce(bk.plata_clientes, 0) else 0 end as plata_clientes,
         coalesce(bk.abonos, 0) as abonos, coalesce(bk.cargos, 0) as cargos, coalesce(bk.tl_in, 0) as tl_in, coalesce(bk.tl_pag, 0) as tl_pag,
         case when d.dia >= cfg.f0 then coalesce(ro.tl_enviado, 0) else 0 end as tl_enviado,
         case when d.dia >= cfg.f0 then coalesce(bk.compras_banco, 0) else 0 end as compras_banco,
         coalesce(bk.neto, 0) as banco_neto, rs.usdt_real,
         coalesce((select b.precio from robot_ordenes b where b.tipo = 'BUY' and b.estado = 'COMPLETED'
                    and (b.creado at time zone 'America/Santiago')::date <= d.dia order by b.creado desc limit 1), cfg.costo0) as costo_usdt
  from dias d cross join cfg cross join bh
  left join op on op.dia = d.dia left join ga on ga.dia = d.dia left join tl on tl.dia = d.dia
  left join ro on ro.dia = d.dia left join co on co.dia = d.dia left join pa on pa.dia = d.dia left join bk on bk.dia = d.dia left join rs on rs.dia = d.dia),
acum as (
  select b.*,
         b.ganancia + b.comision_tl - b.gastos as utilidad_dia,
         sum(b.ganancia + b.comision_tl - b.gastos) over w as utilidad_acum,
         sum(b.ganancia + b.comision_tl - b.gastos) over (partition by date_trunc('month', b.dia) order by b.dia) as utilidad_mes,
         sum(b.clp_esperado) over w as clp_esperado_acum, sum(b.plata_clientes) over w as plata_clientes_acum,
         sum(b.compras_clp) over w as compras_clp_acum, sum(b.compras_banco) over w as compras_banco_acum,
         b.usdt0 + sum(b.usdt_mov) over w as usdt_esperado,
         b.banco0 + sum(b.banco_neto) over w as banco_saldo,
         sum(b.tl_in - b.tl_pag / 0.96 - b.tl_enviado) over w as tl_pendiente
  from base b window w as (order by b.dia))
select dia, cambios, clp_cambios, round(abonos) as abonos, round(cargos) as cargos, round(tl_in) as tl_in, round(tl_pag) as tl_pag, round(tl_pendiente) as tl_pendiente, round(ganancia) as ganancia, round(comision_tl) as comision_tl, round(gastos) as gastos,
       round(utilidad_dia) as utilidad_dia, round(utilidad_acum) as utilidad_acum, round(utilidad_mes) as utilidad_mes,
       -- contraste Binance vs banco (desde la apertura y solo con cartola cargada)
       (dia >= f0 and dia <= banco_hasta) as banco_al_dia, banco_hasta, sin_clp,
       case when dia >= f0 then round(clp_esperado) end as clp_esperado,
       case when dia >= f0 then round(plata_clientes) end as plata_clientes,
       case when dia >= f0 and dia <= banco_hasta then round(plata_clientes_acum - clp_esperado_acum) end as dif_pesos_acum,
       case when dia >= f0 and dia <= banco_hasta then round(compras_banco_acum - compras_clp_acum) end as dif_compras_acum,
       case when dia >= f0 then round(usdt_esperado, 2) end as usdt_esperado,
       round(usdt_real, 2) as usdt_real,
       case when dia >= f0 and usdt_real is not null then round(usdt_real - usdt_esperado, 2) end as dif_usdt,
       round(costo_usdt, 2) as costo_usdt,
       -- ¿falta plata? (+ sobra / − falta): pesos de clientes que no llegaron + compras pagadas de más + USDT que faltan
       case when dia >= f0 and dia <= banco_hasta and usdt_real is not null then
            round((plata_clientes_acum - clp_esperado_acum) - (compras_banco_acum - compras_clp_acum) + (usdt_real - usdt_esperado) * costo_usdt) end as falta_sobra,
       case when dia >= f0 then round(banco_saldo) end as banco_saldo,
       case when dia >= f0 and dia <= banco_hasta then banco_saldo_al(dia) end as banco_real,
       case when dia >= f0 and usdt_real is not null then round(banco_saldo + usdt_real * costo_usdt) end as capital_real
from acum
order by dia;
revoke all on v_diario from anon;

-- 2b) Estado de caja con el resumen "debería / hay" separado para banco, USDT y total
-- Estado de caja de un período: todo lo que entró y salió, según el banco y según Binance, y la diferencia explicada
create or replace function estado_caja(p_desde date, p_hasta date) returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare
  r jsonb; ini_b numeric; fin_b numeric; ini_u numeric; fin_u numeric; costo numeric; tl_in numeric; tl_pag numeric;
  v_clp numeric; v_usdt numeric; v_n int; v_fam_usdt numeric; v_gan numeric; v_condep_n int; v_condep_clp numeric; v_sindep_n int; v_sindep_clp numeric;
  c_clp numeric; c_usdt numeric; c_n int; com numeric; pay numeric; cb_in numeric; cb_in_n int; dep_sin numeric; dep_sin_n int; dep_con numeric;
  comp_b numeric; comp_b_n int; gas_b numeric; gas_b_n int; otros_b numeric; otros_b_n int; aportes numeric; ap_n int; trasp_out numeric;
  usdt_esp numeric; bh date; parcial boolean; tl_n int; tl_env numeric; tl_usdt numeric; tl_gan numeric; tl_pend numeric; b_deb numeric;
begin
  select coalesce((select b.precio from robot_ordenes b where b.tipo = 'BUY' and b.estado = 'COMPLETED'
                     and (b.creado at time zone 'America/Santiago')::date <= p_hasta order by b.creado desc limit 1),
                  (select valor::numeric from robot_config where clave = 'costo_inicial_usdt'), 0) into costo;
  select max(fecha) into bh from banco_movimientos;
  parcial := bh is null or bh < p_hasta;
  if bh is not null and bh < p_hasta then p_hasta := bh; end if;   -- todo se compara hasta la última cartola
  if bh is null or p_hasta < p_desde then
    return jsonb_build_object('desde', p_desde, 'hasta', p_hasta, 'banco_hasta', bh, 'parcial', true, 'sin_banco', true);
  end if;
  ini_b := banco_saldo_al(p_desde - 1);  fin_b := banco_saldo_al(p_hasta);
  ini_u := coalesce(usdt_real_al(p_desde - 1),
                    (select case when p_desde <= coalesce(max(valor) filter (where clave = 'apertura_fecha'), '2026-09-01')::date
                                 then max(valor) filter (where clave = 'apertura_usdt') end::numeric from robot_config));
  fin_u := usdt_real_al(p_hasta);
  -- Binance: ventas (sin los envíos a familia) y compras
  select count(*), coalesce(sum(clp_final), 0), coalesce(sum(usdt), 0),
         coalesce(sum(clp_final - usdt * costo_usdt), 0),
         count(*) filter (where exists (select 1 from banco_movimientos b where b.orden_binance is not null and position(o.order_number in b.orden_binance) > 0)),
         coalesce(sum(clp_final) filter (where exists (select 1 from banco_movimientos b where b.orden_binance is not null and position(o.order_number in b.orden_binance) > 0)), 0)
    into v_n, v_clp, v_usdt, v_gan, v_condep_n, v_condep_clp
  from v_ordenes o where o.tipo = 'SELL' and o.estado = 'COMPLETED' and coalesce(o.revision, '') not in ('gasto', 'transf_local')
   and (o.creado at time zone 'America/Santiago')::date between p_desde and p_hasta;
  select count(*), coalesce(sum(clp_final), 0), coalesce(sum(usdt), 0), coalesce(sum(clp_final - usdt * costo_usdt), 0) into tl_n, tl_env, tl_usdt, tl_gan
  from v_ordenes o where o.tipo = 'SELL' and o.estado = 'COMPLETED' and o.revision = 'transf_local'
   and (o.creado at time zone 'America/Santiago')::date between p_desde and p_hasta;
  v_sindep_n := v_n - v_condep_n; v_sindep_clp := v_clp - v_condep_clp;
  select coalesce(sum(usdt), 0) into v_fam_usdt from v_ordenes o where o.tipo = 'SELL' and o.estado = 'COMPLETED' and o.revision = 'gasto'
   and (o.creado at time zone 'America/Santiago')::date between p_desde and p_hasta;
  select count(*), coalesce(sum(usdt), 0) into c_n, c_usdt
  from v_ordenes o where o.tipo = 'BUY' and o.estado = 'COMPLETED' and (o.creado at time zone 'America/Santiago')::date between p_desde and p_hasta;
  -- pesos de las compras: por la fecha en que el banco pagó (si la orden está unida a su pago), si no por la fecha de Binance
  select coalesce(sum(o.monto_fiat), 0) into c_clp
  from v_ordenes o where o.tipo = 'BUY' and o.estado = 'COMPLETED'
   and coalesce((select min(b.fecha) from banco_movimientos b where b.categoria = 'compra_usdt' and b.orden_binance is not null and position(o.order_number in b.orden_binance) > 0),
                (o.creado at time zone 'America/Santiago')::date) between p_desde and p_hasta;
  select coalesce(sum(comision), 0) into com from v_ordenes o where o.estado = 'COMPLETED' and (o.creado at time zone 'America/Santiago')::date between p_desde and p_hasta;
  select coalesce(sum(monto), 0) into pay from v_pay where moneda = 'USDT' and clasificacion_final <> 'traspaso_interno'
   and (fecha at time zone 'America/Santiago')::date between p_desde and p_hasta;
  usdt_esp := coalesce(ini_u, 0) + c_usdt - v_usdt - tl_usdt - v_fam_usdt - com + pay;
  -- Banco
  select coalesce(sum(abono) filter (where categoria = 'cambio'), 0),
         count(*) filter (where categoria in ('cambio_sin_orden', 'por_revisar') and abono > 0), coalesce(sum(abono) filter (where categoria in ('cambio_sin_orden', 'por_revisar')), 0),
         coalesce(sum(abono) filter (where categoria = 'belkys_ingreso'), 0), coalesce(sum(cargo) filter (where categoria = 'belkys_pago'), 0),
         count(*) filter (where categoria = 'compra_usdt' and cargo > 0), coalesce(sum(cargo) filter (where categoria = 'compra_usdt'), 0),
         count(*) filter (where categoria = 'gasto' and cargo > 0), coalesce(sum(cargo) filter (where categoria = 'gasto'), 0),
         count(*) filter (where cargo > 0 and categoria not in ('compra_usdt', 'belkys_pago', 'gasto', 'traspaso_propio')), coalesce(sum(cargo) filter (where categoria not in ('compra_usdt', 'belkys_pago', 'gasto', 'traspaso_propio')), 0),
         count(*) filter (where categoria = 'traspaso_propio' and abono > 0), coalesce(sum(abono) filter (where categoria = 'traspaso_propio'), 0),
         coalesce(sum(cargo) filter (where categoria = 'traspaso_propio'), 0)
    into dep_con, dep_sin_n, dep_sin, tl_in, tl_pag, comp_b_n, comp_b, gas_b_n, gas_b, otros_b_n, otros_b, ap_n, aportes, trasp_out
  from banco_movimientos where fecha between p_desde and p_hasta;
  cb_in := dep_con + dep_sin; cb_in_n := dep_sin_n;
  tl_pend := tl_in - tl_pag / 0.96 - tl_env;                      -- plata de Transf Local que aún no se envía (no es tuya)
  b_deb := coalesce(ini_b, 0) + v_clp + tl_in + aportes - c_clp - tl_pag - gas_b - otros_b - trasp_out;   -- lo que debería haber en el banco
  r := jsonb_build_object(
    'desde', p_desde, 'hasta', p_hasta, 'banco_hasta', bh, 'parcial', parcial, 'usdt_fecha', (select max((fecha at time zone 'America/Santiago')::date) from robot_saldos where (fecha at time zone 'America/Santiago')::date <= p_hasta), 'costo_usdt', round(costo, 2),
    'banco', jsonb_build_object('inicial', round(ini_b), 'final', round(fin_b),
       'entradas', jsonb_build_object('clientes_con_orden', round(dep_con), 'clientes_sin_orden', round(dep_sin), 'clientes_sin_orden_n', dep_sin_n,
                                      'transf_local', round(tl_in), 'aportes_propios', round(aportes), 'aportes_n', ap_n),
       'salidas', jsonb_build_object('compras_usdt', round(comp_b), 'compras_n', comp_b_n, 'transf_local_pagos', round(tl_pag),
                                     'gastos', round(gas_b), 'gastos_n', gas_b_n, 'otros', round(otros_b), 'otros_n', otros_b_n, 'traspasos_salida', round(trasp_out)),
       'cuadra', abs(coalesce(ini_b, 0) + dep_con + dep_sin + tl_in + aportes - comp_b - tl_pag - gas_b - otros_b - trasp_out - coalesce(fin_b, 0)) < 1),
    'usdt', jsonb_build_object('inicial', round(ini_u, 2), 'comprados', round(c_usdt, 2), 'vendidos', round(v_usdt, 2), 'envio_familia', round(v_fam_usdt, 2),
       'comisiones', round(com, 2), 'binance_pay', round(pay, 2), 'esperado', round(usdt_esp, 2), 'real', round(fin_u, 2),
       'diferencia', case when fin_u is null or ini_u is null then null else round(fin_u - usdt_esp, 2) end),
    'clientes', jsonb_build_object('ventas_n', v_n, 'ventas_clp', round(v_clp), 'ganancia', round(v_gan),
       'con_deposito_n', v_condep_n, 'con_deposito_clp', round(v_condep_clp), 'sin_deposito_n', v_sindep_n, 'sin_deposito_clp', round(v_sindep_clp),
       'depositos_con_orden', round(dep_con), 'depositos_sin_orden', round(dep_sin), 'depositos_sin_orden_n', dep_sin_n,
       'transf_local_in', round(tl_in), 'transf_local_pagos', round(tl_pag), 'comision_tl', round(tl_pag / 0.96 * 0.04), 'resto_tl', round(tl_in - tl_pag / 0.96),
       'diferencia', round(dep_con + dep_sin - v_clp)),
    'compras', jsonb_build_object('binance_n', c_n, 'binance_clp', round(c_clp), 'binance_usdt', round(c_usdt, 2), 'banco_n', comp_b_n, 'banco_clp', round(comp_b),
       'diferencia', round(c_clp - comp_b)),
    'resumen', jsonb_build_object(
       'banco_deberia', round(b_deb), 'banco_hay', round(fin_b), 'banco_dif', round(coalesce(fin_b, 0) - b_deb),
       'usdt_deberian', round(usdt_esp, 2), 'usdt_hay', round(fin_u, 2), 'usdt_dif', case when fin_u is null then null else round(fin_u - usdt_esp, 2) end,
       'usdt_dif_clp', case when fin_u is null then null else round((fin_u - usdt_esp) * costo) end,
       'tl_pendiente', round(tl_pend), 'tl_enviado', round(tl_env), 'tl_enviado_n', tl_n,
       'total_deberia', round(b_deb + usdt_esp * costo - tl_pend), 'total_hay', round(coalesce(fin_b, 0) + coalesce(fin_u, 0) * costo - tl_pend),
       'total_dif', case when fin_u is null then null else round(coalesce(fin_b, 0) - b_deb + (fin_u - usdt_esp) * costo) end,
       'dif_clientes', round(dep_con + dep_sin - v_clp), 'dif_compras', round(c_clp - comp_b)),
    'capital', jsonb_build_object('inicial', round(coalesce(ini_b, 0) + coalesce(ini_u, 0) * costo), 'final', round(coalesce(fin_b, 0) + coalesce(fin_u, 0) * costo),
       'banco_final', round(fin_b), 'usdt_final_clp', round(coalesce(fin_u, 0) * costo),
       'delta_real', round(coalesce(fin_b, 0) + coalesce(fin_u, 0) * costo - coalesce(ini_b, 0) - coalesce(ini_u, 0) * costo - tl_pend),
       'ganancia_libro', round(v_gan + tl_gan), 'ajuste_usdt', round((v_clp - v_usdt * costo) + (tl_env - tl_usdt * costo) - v_gan - tl_gan), 'tl_pendiente', round(tl_pend), 'comision_tl', round(tl_pag / 0.96 * 0.04), 'gastos_banco', round(gas_b + otros_b),
       'ajuste_compras', round(c_usdt * costo - c_clp), 'otros_usdt', round(-(com + v_fam_usdt - pay) * costo),
       'utilidad', round((v_clp - v_usdt * costo) + (tl_env - tl_usdt * costo) + tl_pag / 0.96 * 0.04 - gas_b - otros_b + (c_usdt * costo - c_clp) - (com + v_fam_usdt - pay) * costo - (tl_in - tl_pag / 0.96 - tl_env)),
       'aportes', round(aportes - trasp_out),
       'delta_libros', round((v_clp - v_usdt * costo) + (tl_env - tl_usdt * costo) + tl_pag / 0.96 * 0.04 - gas_b - otros_b + (c_usdt * costo - c_clp) - (com + v_fam_usdt - pay) * costo - (tl_in - tl_pag / 0.96 - tl_env) + aportes - trasp_out),
       'gap', case when fin_u is null or ini_u is null then null else
              round((coalesce(fin_b, 0) + fin_u * costo - coalesce(ini_b, 0) - ini_u * costo - tl_pend)
                    - ((v_clp - v_usdt * costo) + (tl_env - tl_usdt * costo) + tl_pag / 0.96 * 0.04 - gas_b - otros_b + (c_usdt * costo - c_clp) - (com + v_fam_usdt - pay) * costo - (tl_in - tl_pag / 0.96 - tl_env) + aportes - trasp_out)) end,
       'gap_clientes', round(dep_con + dep_sin - v_clp),
       'gap_compras', round(c_clp - comp_b),
       'gap_usdt_clp', case when fin_u is null or ini_u is null then null else round((fin_u - usdt_esp) * costo) end));
  return r;
end $$;


select jsonb_pretty(estado_caja('2026-10-01', '2026-10-31') -> 'compras');

-- 3) Ventas que Binance reporta directamente en pesos chilenos (fiat = CLP): su monto en CLP es el monto mismo
update robot_ordenes set clp = monto_fiat, tasa_usada = 1, metodo_clp = 'clp'
 where tipo = 'SELL' and fiat = 'CLP' and clp is null;
