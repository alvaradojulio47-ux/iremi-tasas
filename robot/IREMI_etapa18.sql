-- ===== APP IREMI · ETAPA 18: la base deja de ahogarse =====
-- Lo que mostró pg_stat_statements: tres consultas se llevaban casi toda la CPU de la base
--   v_diario            195 llamadas × 5,8 s  = 19 minutos de CPU
--   v_mercado_actual    282 llamadas × 2,9 s  = 13 minutos de CPU
--   (y el cuadre, ya corregido en la etapa 15)
-- En el plan gratuito eso agota la CPU y TODO queda lento, incluido el ingreso (14 s).
-- Esta etapa no cambia ningún número: solo hace que esas consultas usen índices.
-- Se puede correr más de una vez (va después de la etapa 17).

-- 1) Índices para el historial de precios que guarda el robot (acelera v_mercado_actual)
do $$
declare cols text[];
begin
  if to_regclass('public.precios_mercado') is null then
    raise notice 'No existe la tabla precios_mercado: me salto esta parte';
    return;
  end if;
  select array_agg(column_name::text) into cols from information_schema.columns
   where table_schema = 'public' and table_name = 'precios_mercado';
  if cols @> array['fiat', 'fecha'] then
    execute 'create index if not exists precios_mercado_fiat_fecha_idx on precios_mercado (fiat, fecha desc)';
    raise notice 'Índice (fiat, fecha) creado';
  end if;
  if cols @> array['fiat', 'lado', 'fecha'] then
    execute 'create index if not exists precios_mercado_fiat_lado_fecha_idx on precios_mercado (fiat, lado, fecha desc)';
    raise notice 'Índice (fiat, lado, fecha) creado';
  end if;
  execute 'analyze precios_mercado';
end $$;

-- 2) Día a día: la parte lenta era buscar cada compra dentro del texto del campo del banco
-- Día a día (misma definición, con la búsqueda de compras por índice en vez de por texto): entró / salió del banco, saldo real, cambios, Transf Local pendiente y sobra/falta
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
co as (select coalesce((select min(b.fecha) from banco_movimientos b where b.categoria = 'compra_usdt' and b.orden_binance is not null and regexp_split_to_array(b.orden_binance, '\s*[,;]\s*') @> array[o.order_number]),
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


-- 3) Cuánto pesa cada cosa ahora
select c.relname as tabla, pg_size_pretty(pg_total_relation_size(c.oid)) as pesa,
       s.n_live_tup as filas
from pg_class c join pg_namespace n on n.oid = c.relnamespace
left join pg_stat_user_tables s on s.relid = c.oid
where n.nspname = 'public' and c.relkind = 'r'
order by pg_total_relation_size(c.oid) desc limit 8;

-- 4) Dejar el contador de consultas en cero para medir desde ahora
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
    perform pg_stat_statements_reset();
    raise notice 'Contador reiniciado: usa la app un rato y vuelve a correr el diagnóstico de lentitud';
  end if;
end $$;

-- ── OPCIONAL · limpiar historial viejo de precios ────────────────────────────
-- El robot guarda los anuncios de Binance cada pocos minutos. Si la tabla pesa mucho,
-- quita esta línea del comentario y córrela: deja los últimos 30 días.
-- delete from precios_mercado where fecha < now() - interval '30 days';
-- vacuum analyze precios_mercado;
