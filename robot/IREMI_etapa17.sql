-- ===== APP IREMI · ETAPA 17: ningún cambio se queda sin monto por falta de tasa del día =====
-- Si el día de la operación no quedó guardada la tasa de esa moneda, la venta se quedaba sin
-- "CLP del cliente": no daba ganancia y vivía en "por revisar". Ahora se usa la última tasa
-- conocida de esa moneda (hasta 7 días antes) y queda marcada como 'tasa_anterior' para que
-- se vea que es una estimación, no un dato exacto. También se agrega PAB (Panamá).
-- No pisa ningún monto que ya exista ni ningún CLP puesto a mano. Se puede correr más de una vez.

-- 1) La tasa de una moneda en una fecha: la del día, o la última conocida hasta 7 días antes
create or replace function tasa_para(p_fiat text, p_dia date)
returns table(valor numeric, dia_tasa date)
language sql stable set search_path = public as $$
  select v, t.fecha from (
    select t.fecha,
           case upper(p_fiat) when 'VES' then t.ves when 'COP' then t.cop when 'PEN' then t.pen
                              when 'ARS' then t.ars when 'EUR' then t.eur when 'DOP' then t.dop
                              when 'MXN' then t.mxn when 'BOB' then t.bob when 'PAB' then t.pab
                              when 'USD' then t.zelle end as v
      from tasas_diarias t where t.fecha <= p_dia and t.fecha >= p_dia - 7) t
  where v is not null and v > 0 order by t.fecha desc limit 1;
$$;

-- 2) Completar las ventas que están sin monto
with faltan as (
  select o.order_number, o.monto_fiat, (o.creado at time zone 'America/Santiago')::date as dia, o.fiat
    from robot_ordenes o
   where o.tipo = 'SELL' and o.estado = 'COMPLETED' and o.clp is null and o.clp_manual is null
     and o.monto_fiat is not null and o.fiat <> 'CLP'),
calc as (select f.*, t.valor, t.dia_tasa from faltan f cross join lateral tasa_para(f.fiat, f.dia) t)
update robot_ordenes o
   set clp = round(c.monto_fiat / c.valor),
       tasa_usada = c.valor,
       metodo_clp = case when c.dia_tasa = c.dia then 'base' else 'tasa_anterior' end
  from calc c where c.order_number = o.order_number;

-- 3) De ahora en adelante: al guardar la tasa del día, las ventas de ese día que estén
--    sin monto se completan solas con la tasa exacta de ese día (no con una estimación)
create or replace function completar_ventas_del_dia() returns trigger
language plpgsql set search_path = public as $$
begin
  update robot_ordenes o
     set clp = round(o.monto_fiat / v.tasa), tasa_usada = v.tasa, metodo_clp = 'base'
    from (select case upper(x.fiat) when 'VES' then new.ves when 'COP' then new.cop when 'PEN' then new.pen
                                    when 'ARS' then new.ars when 'EUR' then new.eur when 'DOP' then new.dop
                                    when 'MXN' then new.mxn when 'BOB' then new.bob when 'PAB' then new.pab
                                    when 'USD' then new.zelle end as tasa, x.order_number
            from robot_ordenes x
           where x.tipo = 'SELL' and x.estado = 'COMPLETED' and x.clp is null and x.clp_manual is null
             and x.monto_fiat is not null and x.fiat <> 'CLP'
             and (x.creado at time zone 'America/Santiago')::date = new.fecha) v
   where v.order_number = o.order_number and v.tasa is not null and v.tasa > 0;
  return new;
end $$;
drop trigger if exists trg_completar_ventas on tasas_diarias;
create trigger trg_completar_ventas after insert or update on tasas_diarias
for each row execute function completar_ventas_del_dia();

-- 4) Comprobar cómo quedó
select coalesce(metodo_clp, '(vacío)') as metodo, count(*) as ventas,
       count(*) filter (where coalesce(clp_manual, clp) is null) as aun_sin_monto
  from robot_ordenes where tipo = 'SELL' and estado = 'COMPLETED'
   and creado >= date_trunc('month', current_date) - interval '2 months'
group by 1 order by 2 desc;

select count(*) as ventas_sin_monto_que_quedan_mas_de_7_dias_sin_tasa
  from robot_ordenes where tipo = 'SELL' and estado = 'COMPLETED' and coalesce(clp_manual, clp) is null;
