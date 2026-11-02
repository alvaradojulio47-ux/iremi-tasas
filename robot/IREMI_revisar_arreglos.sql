-- ===== IREMI · ¿EXISTÍA LA FALLA? QUÉ ARREGLARON LAS ETAPAS 16 Y 17 =====
-- Solo consulta, no modifica nada. Sirve para cualquier mes, aunque ya haya pasado.
-- Para mirar otro mes, cambia la fecha de la línea de abajo (el día 1 del mes que quieras).

-- ⬇️ MES A REVISAR
create temp view p as select date '2026-10-01' as d0, (date '2026-10-01' + interval '1 month - 1 day')::date as d1;

-- 1) ¿Cuántas ventas estaban sin monto y ahora lo tienen? (ese era el problema)
--    'clp'           = cambios cobrados en pesos        → los arregló la etapa 16
--    'tasa_anterior' = no había tasa guardada ese día   → los arregló la etapa 17
select o.metodo_clp as arreglado_por,
       case o.metodo_clp when 'clp' then 'etapa 16 · cobrado en pesos'
                         when 'tasa_anterior' then 'etapa 17 · sin tasa ese día' end as motivo,
       count(*) as ventas,
       round(sum(coalesce(o.clp_manual, o.clp))) as clp_que_faltaba,
       round(sum(coalesce(o.clp_manual, o.clp) - o.usdt * coalesce(
         (select b.precio from robot_ordenes b where b.tipo = 'BUY' and b.estado = 'COMPLETED' and b.creado <= o.creado
           order by b.creado desc limit 1), 0))) as ganancia_que_faltaba
from robot_ordenes o, p
where o.tipo = 'SELL' and o.estado = 'COMPLETED'
  and coalesce(o.revision, '') <> 'gasto'
  and o.metodo_clp in ('clp', 'tasa_anterior')
  and (o.creado at time zone 'America/Santiago')::date between p.d0 and p.d1
group by 1, 2 order by 3 desc;

-- 2) El detalle, una por una
select (o.creado at time zone 'America/Santiago')::date as dia,
       to_char(o.creado at time zone 'America/Santiago', 'HH24:MI') as hora,
       o.cuenta, o.fiat, round(o.monto_fiat) as monto_destino, o.usdt,
       round(coalesce(o.clp_manual, o.clp)) as clp_asignado, o.tasa_usada,
       case o.metodo_clp when 'clp' then 'cobrado en pesos' else 'tasa de otro día' end as caso,
       coalesce(o.revision, 'sin marca') as marca, o.contraparte, o.order_number
from robot_ordenes o, p
where o.tipo = 'SELL' and o.estado = 'COMPLETED'
  and o.metodo_clp in ('clp', 'tasa_anterior')
  and (o.creado at time zone 'America/Santiago')::date between p.d0 and p.d1
order by o.creado;

-- 3) ¿Queda alguna venta sin monto en ese mes?
select count(*) as ventas_sin_monto_que_quedan
from robot_ordenes o, p
where o.tipo = 'SELL' and o.estado = 'COMPLETED' and coalesce(o.clp_manual, o.clp) is null
  and (o.creado at time zone 'America/Santiago')::date between p.d0 and p.d1;

-- 4) Días de ese mes sin tasa guardada (la causa de fondo)
select d::date as dia_sin_tasa, to_char(d, 'TMDay') as cual
from p, generate_series(p.d0, p.d1, interval '1 day') d
where not exists (select 1 from tasas_diarias t where t.fecha = d::date and t.ves is not null)
order by 1;

-- 5) Resumen del mes como queda ahora
select count(*) as cambios,
       round(sum(coalesce(o.clp_manual, o.clp))) as recibido_clp,
       round(sum(coalesce(o.clp_manual, o.clp) - o.usdt * coalesce(
         (select b.precio from robot_ordenes b where b.tipo = 'BUY' and b.estado = 'COMPLETED' and b.creado <= o.creado
           order by b.creado desc limit 1), 0))) as ganancia
from robot_ordenes o, p
where o.tipo = 'SELL' and o.estado = 'COMPLETED' and coalesce(o.revision, '') <> 'gasto'
  and (o.creado at time zone 'America/Santiago')::date between p.d0 and p.d1;
