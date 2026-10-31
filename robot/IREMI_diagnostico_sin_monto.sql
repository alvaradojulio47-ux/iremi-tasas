-- ===== IREMI · DIAGNÓSTICO: cambios que quedaron sin monto en pesos =====
-- Solo consulta, no modifica nada. Muestra qué ventas no tienen "CLP del cliente"
-- (por eso no dan ganancia y se quedan en "por revisar").

-- 1) Resumen por mes y moneda
select to_char(o.creado at time zone 'America/Santiago', 'YYYY-MM') as mes,
       o.fiat,
       count(*) as ventas_sin_monto,
       round(sum(o.usdt), 2) as usdt_entregados,
       round(sum(o.usdt) * 950) as valor_aprox_en_pesos
from robot_ordenes o
where o.tipo = 'SELL' and o.estado = 'COMPLETED'
  and coalesce(o.clp_manual, o.clp) is null
group by 1, 2
order by 1 desc, 3 desc;

-- 2) Detalle de este año, una por una
select (o.creado at time zone 'America/Santiago')::date as dia,
       to_char(o.creado at time zone 'America/Santiago', 'HH24:MI') as hora,
       o.cuenta, o.fiat, round(o.monto_fiat) as monto_destino, o.usdt, o.metodo_clp,
       o.order_number, o.contraparte,
       -- ¿había tasa guardada ese día para esa moneda?
       (select case o.fiat when 'VES' then t.ves when 'COP' then t.cop when 'PEN' then t.pen
                           when 'ARS' then t.ars when 'EUR' then t.eur when 'DOP' then t.dop
                           when 'MXN' then t.mxn when 'BOB' then t.bob when 'PAB' then t.pab
                           when 'USD' then t.zelle end
          from tasas_diarias t where t.fecha = (o.creado at time zone 'America/Santiago')::date) as tasa_de_ese_dia,
       -- la última tasa conocida antes de ese día
       (select case o.fiat when 'VES' then t.ves when 'COP' then t.cop when 'PEN' then t.pen
                           when 'ARS' then t.ars when 'EUR' then t.eur when 'DOP' then t.dop
                           when 'MXN' then t.mxn when 'BOB' then t.bob when 'PAB' then t.pab
                           when 'USD' then t.zelle end
          from tasas_diarias t where t.fecha <= (o.creado at time zone 'America/Santiago')::date
           and case o.fiat when 'VES' then t.ves when 'COP' then t.cop when 'PEN' then t.pen
                           when 'ARS' then t.ars when 'EUR' then t.eur when 'DOP' then t.dop
                           when 'MXN' then t.mxn when 'BOB' then t.bob when 'PAB' then t.pab
                           when 'USD' then t.zelle end is not null
          order by t.fecha desc limit 1) as ultima_tasa_conocida
from robot_ordenes o
where o.tipo = 'SELL' and o.estado = 'COMPLETED'
  and coalesce(o.clp_manual, o.clp) is null
  and o.creado >= '2026-01-01'
order by o.creado desc;

-- 3) Días sin tasa guardada de este mes (para saber si el problema es que falta guardar la tasa)
select d::date as dia_sin_tasa
from generate_series(date_trunc('month', current_date), current_date, interval '1 day') d
where not exists (select 1 from tasas_diarias t where t.fecha = d::date and t.ves is not null)
order by 1;
