-- ===== APP IREMI · ETAPA 15: el cuadre vuelve a ser rápido (se pasaba del tiempo de espera) =====
-- Con los datos de octubre la consulta del capital tardaba demasiado y Supabase la cortaba
-- ("canceling statement due to statement timeout"). Esta etapa no cambia ningún número:
--   1) crea los índices que faltaban,
--   2) busca las órdenes unidas por lista exacta (usa índice) en vez de buscar texto dentro del campo.
-- Se puede correr más de una vez (va después de la etapa 14).

-- 1) Índices
create index if not exists robot_ordenes_buy_idx    on robot_ordenes (tipo, estado, creado desc);
create index if not exists robot_ordenes_creado_idx on robot_ordenes (estado, creado);
create index if not exists robot_ordenes_num_idx    on robot_ordenes (order_number);
create index if not exists banco_mov_fecha_idx      on banco_movimientos (fecha);
create index if not exists banco_mov_cat_fecha_idx  on banco_movimientos (categoria, fecha);
create index if not exists banco_mov_ord_gin_idx    on banco_movimientos
  using gin (regexp_split_to_array(orden_binance, '\s*[,;]\s*')) where orden_binance is not null;
create index if not exists robot_saldos_fecha_idx   on robot_saldos (cuenta, fecha desc);
analyze robot_ordenes; analyze banco_movimientos;

-- 2) Estado de caja con el resumen "debería / hay" separado para banco, USDT y total
-- Estado de caja de un período: todo lo que entró y salió, según el banco y según Binance, y la diferencia explicada
create or replace function estado_caja(p_desde date, p_hasta date) returns jsonb
language plpgsql volatile security invoker set search_path = public as $$
declare
  r jsonb; ini_b numeric; fin_b numeric; ini_u numeric; fin_u numeric; costo numeric; tl_in numeric; tl_pag numeric;
  v_clp numeric; v_usdt numeric; v_n int; v_fam_usdt numeric; v_gan numeric; v_condep_n int; v_condep_clp numeric; v_sindep_n int; v_sindep_clp numeric;
  c_clp numeric; c_usdt numeric; c_n int; com numeric; pay numeric; cb_in numeric; cb_in_n int; dep_sin numeric; dep_sin_n int; dep_con numeric;
  comp_b numeric; comp_b_n int; gas_b numeric; gas_b_n int; otros_b numeric; otros_b_n int; aportes numeric; ap_n int; trasp_out numeric;
  usdt_esp numeric; bh date; parcial boolean; dep_otro numeric; dep_otro_n int; v_otro_clp numeric; v_otro_n int; ajustes numeric; ajustes_n int; dif_cli numeric; uni_dif numeric; uni_n int; tl_n int; tl_env numeric; tl_usdt numeric; tl_gan numeric; tl_pend numeric; b_deb numeric;
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
  -- Lista de órdenes que tienen un depósito unido (se arma una sola vez: antes se buscaba una por una)
  create temp table if not exists _enl (ord text primary key, en_per boolean) on commit drop;
  delete from _enl;
  insert into _enl (ord, en_per)
  select x.ord, bool_or(x.fecha between p_desde and p_hasta)
  from (select unnest(regexp_split_to_array(b.orden_binance, '\s*[,;]\s*')) as ord, b.fecha
          from banco_movimientos b where b.orden_binance is not null) x
  where x.ord <> '' group by x.ord;
  analyze _enl;
  -- Binance: ventas (sin los envíos a familia) y compras
  select count(*), coalesce(sum(o.clp_final), 0), coalesce(sum(o.usdt), 0),
         coalesce(sum(o.clp_final - o.usdt * o.costo_usdt), 0),
         count(*) filter (where e.ord is not null),
         coalesce(sum(o.clp_final) filter (where e.ord is not null), 0)
    into v_n, v_clp, v_usdt, v_gan, v_condep_n, v_condep_clp
  from v_ordenes o left join _enl e on e.ord = o.order_number
  where o.tipo = 'SELL' and o.estado = 'COMPLETED' and coalesce(o.revision, '') not in ('gasto', 'transf_local')
   and (o.creado at time zone 'America/Santiago')::date between p_desde and p_hasta;
  select count(*), coalesce(sum(clp_final), 0), coalesce(sum(usdt), 0), coalesce(sum(clp_final - usdt * costo_usdt), 0) into tl_n, tl_env, tl_usdt, tl_gan
  from v_ordenes o where o.tipo = 'SELL' and o.estado = 'COMPLETED' and o.revision = 'transf_local'
   and (o.creado at time zone 'America/Santiago')::date between p_desde and p_hasta;
  v_sindep_n := v_n - v_condep_n; v_sindep_clp := v_clp - v_condep_clp;
  -- ventas del período cuyo depósito quedó fuera del período (lo pagaron antes o después)
  select count(*), coalesce(sum(coalesce(o.clp_manual, o.clp)), 0) into v_otro_n, v_otro_clp
  from robot_ordenes o join _enl e on e.ord = o.order_number
  where o.tipo = 'SELL' and o.estado = 'COMPLETED' and coalesce(o.revision, '') not in ('gasto', 'transf_local')
   and (o.creado at time zone 'America/Santiago')::date between p_desde and p_hasta and not e.en_per;
  select coalesce(sum(usdt), 0) into v_fam_usdt from v_ordenes o where o.tipo = 'SELL' and o.estado = 'COMPLETED' and o.revision = 'gasto'
   and (o.creado at time zone 'America/Santiago')::date between p_desde and p_hasta;
  select count(*), coalesce(sum(usdt), 0) into c_n, c_usdt
  from v_ordenes o where o.tipo = 'BUY' and o.estado = 'COMPLETED' and (o.creado at time zone 'America/Santiago')::date between p_desde and p_hasta;
  -- pesos de las compras: por la fecha en que el banco pagó (si la orden está unida a su pago), si no por la fecha de Binance
  select coalesce(sum(o.monto_fiat), 0) into c_clp
  from v_ordenes o where o.tipo = 'BUY' and o.estado = 'COMPLETED'
   and coalesce((select min(b.fecha) from banco_movimientos b where b.categoria = 'compra_usdt' and b.orden_binance is not null and regexp_split_to_array(b.orden_binance, '\s*[,;]\s*') @> array[o.order_number]),
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
  select count(*), coalesce(sum(b.abono), 0) into dep_otro_n, dep_otro
  from banco_movimientos b where b.fecha between p_desde and p_hasta and b.abono > 0 and b.categoria = 'cambio' and b.orden_binance is not null
   and not exists (select 1 from unnest(regexp_split_to_array(b.orden_binance, '\s*[,;]\s*')) u(ord)
                    join robot_ordenes o on o.order_number = u.ord
                   where (o.creado at time zone 'America/Santiago')::date between p_desde and p_hasta);
  select count(*), coalesce(sum(monto_clp), 0) into ajustes_n, ajustes from caja_ajustes where fecha between p_desde and p_hasta;
  -- depósitos unidos del período que valen más (+) o menos (−) que los cambios a los que están unidos (ej.: $360.000 que pagan $310.000 de cambios)
  select count(*), coalesce(sum(b.abono - s.clp), 0) into uni_n, uni_dif
  from banco_movimientos b
  join lateral (select coalesce(sum(coalesce(o.clp_manual, o.clp)), 0) as clp
                from unnest(regexp_split_to_array(b.orden_binance, '\s*[,;]\s*')) u(ord)
                join robot_ordenes o on o.order_number = u.ord) s on true
  where b.fecha between p_desde and p_hasta and b.abono > 0 and b.categoria = 'cambio' and b.orden_binance is not null
    and abs(b.abono - s.clp) >= 1;
  -- clientes: solo cuenta lo que NO está unido (un cambio unido a su depósito cuadra solo, sea cual sea la fecha del depósito) + las diferencias de monto en uniones
  dif_cli := dep_sin - v_sindep_clp + uni_dif;
  tl_pend := tl_in - tl_pag / 0.96 - tl_env;                      -- plata de Transf Local que aún no se envía (no es tuya)
  b_deb := coalesce(fin_b, 0) - dif_cli - (c_clp - comp_b);   -- lo que debería haber en el banco: lo que hay, más lo que falta por explicar
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
       'diferencia', round(dif_cli),
       'depositos_de_otro_periodo', round(dep_otro), 'depositos_de_otro_periodo_n', dep_otro_n,
       'ventas_pagadas_otro_periodo', round(v_otro_clp), 'ventas_pagadas_otro_periodo_n', v_otro_n,
       'uniones_dif', round(uni_dif), 'uniones_dif_n', uni_n),
    'compras', jsonb_build_object('binance_n', c_n, 'binance_clp', round(c_clp), 'binance_usdt', round(c_usdt, 2), 'banco_n', comp_b_n, 'banco_clp', round(comp_b),
       'diferencia', round(c_clp - comp_b)),
    'resumen', jsonb_build_object(
       'banco_deberia', round(b_deb), 'banco_hay', round(fin_b), 'banco_dif', round(coalesce(fin_b, 0) - b_deb),
       'usdt_deberian', round(usdt_esp, 2), 'usdt_hay', round(fin_u, 2), 'usdt_dif', case when fin_u is null then null else round(fin_u - usdt_esp, 2) end,
       'usdt_dif_clp', case when fin_u is null then null else round((fin_u - usdt_esp) * costo) end,
       'tl_pendiente', round(tl_pend), 'tl_enviado', round(tl_env), 'tl_enviado_n', tl_n,
       'total_deberia', round(b_deb + usdt_esp * costo - tl_pend), 'total_hay', round(coalesce(fin_b, 0) + coalesce(fin_u, 0) * costo - tl_pend),
       'total_dif', case when fin_u is null then null else round(coalesce(fin_b, 0) - b_deb + (fin_u - usdt_esp) * costo) end,
       'ajustes', round(ajustes), 'ajustes_n', ajustes_n,
       'total_dif_ajustado', case when fin_u is null then null else round(coalesce(fin_b, 0) - b_deb + (fin_u - usdt_esp) * costo - ajustes) end,
       'dif_clientes', round(dif_cli), 'dif_compras', round(c_clp - comp_b)),
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
       'gap_clientes', round(dif_cli),
       'gap_compras', round(c_clp - comp_b),
       'gap_usdt_clp', case when fin_u is null or ini_u is null then null else round((fin_u - usdt_esp) * costo) end));
  return r;
end $$;



-- 4) Última compra de USDT (para el cuadro de la app)
create or replace view v_ultima_compra with (security_invoker = true) as
select o.order_number, o.cuenta, o.creado, o.precio, o.usdt, o.monto_fiat, o.contraparte,
       (select round(coalesce(sum(b.precio * b.usdt) / nullif(sum(b.usdt), 0), 0), 2)
          from robot_ordenes b where b.tipo = 'BUY' and b.estado = 'COMPLETED'
           and b.creado >= (now() - interval '30 days')) as precio_prom_30d
from robot_ordenes o
where o.tipo = 'BUY' and o.estado = 'COMPLETED'
order by o.creado desc limit 1;
revoke all on v_ultima_compra from anon;


-- 3) Órdenes sin depósito: misma lógica, pero buscando por lista exacta (usa el índice nuevo)
create or replace view v_ordenes_sin_deposito with (security_invoker = true) as
select o.order_number, o.cuenta, o.fiat, o.monto_fiat, o.usdt, o.contraparte, o.creado, o.clp_final, o.metodo_clp,
       o.costo_usdt, o.tasa_usada, o.revision, o.revisado_por, o.revisado_en,
       (o.creado at time zone 'America/Santiago')::date as dia
from v_ordenes o
where o.tipo = 'SELL' and o.estado = 'COMPLETED' and o.creado >= '2026-09-01 00:00-03'
  and not exists (select 1 from banco_movimientos b where b.orden_binance is not null
                   and regexp_split_to_array(b.orden_binance, '\s*[,;]\s*') @> array[o.order_number])
  and (o.creado at time zone 'America/Santiago')::date <= (select max(fecha) + 1 from banco_movimientos);
revoke all on v_ordenes_sin_deposito from anon;

select jsonb_pretty(estado_caja(date_trunc('month', current_date)::date, current_date) -> 'resumen');
