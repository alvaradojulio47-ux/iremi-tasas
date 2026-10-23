-- ===== APP IREMI · ETAPA 14: cierre de Transf Local =====
-- Varias entradas (Fidel, Angélica, Lilibeth) se cierran contra: uno o más pagos a Florelvi/Belkys (que dejan tu 4%)
-- y/o uno o más cambios de Binance con los que enviaste el resto a Venezuela (esos cambios no tienen depósito).
-- Cuadra así:  entradas = pagos / 0,96 + resto enviado por cambios    ·    tu comisión = pagos / 0,96 × 4%
-- Se puede correr más de una vez (va después de la etapa 13).

create sequence if not exists tl_grupo_seq;
alter table banco_movimientos add column if not exists tl_grupo bigint;
alter table robot_ordenes   add column if not exists tl_grupo bigint;
create index if not exists banco_mov_tl_grupo_idx on banco_movimientos (tl_grupo) where tl_grupo is not null;
create index if not exists robot_ord_tl_grupo_idx on robot_ordenes (tl_grupo) where tl_grupo is not null;

-- Cierra un grupo: entradas + pagos a Florelvi + cambios con que se envió el resto
create or replace function cerrar_tl(p_entradas bigint[], p_pagos bigint[] default '{}', p_ordenes text[] default '{}', p_nota text default null)
returns bigint language plpgsql security invoker set search_path = public as $$
declare g bigint; quien text := coalesce(auth.jwt() ->> 'email', 'app'); n_ent int;
begin
  select count(*) into n_ent from banco_movimientos
   where id = any(p_entradas) and categoria = 'belkys_ingreso' and abono > 0;
  if n_ent = 0 then raise exception 'Elige al menos una entrada de Transf Local'; end if;
  g := nextval('tl_grupo_seq');
  update banco_movimientos set tl_grupo = g, tl_ref = case when array_length(p_pagos,1) = 1 then p_pagos[1] else tl_ref end,
         nota = coalesce(nullif(p_nota, ''), 'Cierre Transf Local #' || g || ' · ' || quien)
   where id = any(p_entradas) and categoria = 'belkys_ingreso';
  if coalesce(array_length(p_pagos,1),0) > 0 then
    update banco_movimientos set tl_grupo = g where id = any(p_pagos) and categoria = 'belkys_pago';
  end if;
  if coalesce(array_length(p_ordenes,1),0) > 0 then
    update robot_ordenes set tl_grupo = g, revision = 'transf_local', revisado_por = quien, revisado_en = now(),
           nota = coalesce(nota, 'Resto Transf Local enviado a Venezuela · cierre #' || g)
     where order_number = any(p_ordenes);
    delete from robot_gastos where orden_binance = any(p_ordenes);
  end if;
  return g;
end $$;

-- Deshace un cierre completo
create or replace function abrir_tl(p_grupo bigint)
returns text language plpgsql security invoker set search_path = public as $$
begin
  update robot_ordenes set tl_grupo = null, revision = null where tl_grupo = p_grupo;
  update banco_movimientos set tl_grupo = null, tl_ref = null,
         nota = case when nota like 'Cierre Transf Local%' then null else nota end
   where tl_grupo = p_grupo;
  return 'ok';
end $$;

revoke all on function cerrar_tl(bigint[], bigint[], text[], text), abrir_tl(bigint) from public, anon;
grant execute on function cerrar_tl(bigint[], bigint[], text[], text), abrir_tl(bigint) to authenticated;
grant usage, select on sequence tl_grupo_seq to authenticated;

-- Resumen de cada cierre: cuánto entró, cuánto se pagó a Florelvi, cuánto se envió por cambio, tu 4% y si cuadra
create or replace view v_tl_cierres with (security_invoker = true) as
select g.tl_grupo as grupo,
       min(g.fecha) as desde, max(g.fecha) as hasta,
       sum(g.abono) filter (where g.categoria = 'belkys_ingreso') as entradas,
       count(*) filter (where g.categoria = 'belkys_ingreso') as entradas_n,
       sum(g.cargo) filter (where g.categoria = 'belkys_pago') as pagos,
       round(sum(g.cargo) filter (where g.categoria = 'belkys_pago') / 0.96) as pagos_en_entradas,
       round(sum(g.cargo) filter (where g.categoria = 'belkys_pago') / 0.96 * 0.04) as comision_4,
       (select round(coalesce(sum(coalesce(o.clp_manual, o.clp)), 0)) from robot_ordenes o where o.tl_grupo = g.tl_grupo) as enviado_cambios,
       (select count(*) from robot_ordenes o where o.tl_grupo = g.tl_grupo) as cambios_n,
       round(coalesce(sum(g.abono) filter (where g.categoria = 'belkys_ingreso'), 0)
             - coalesce(sum(g.cargo) filter (where g.categoria = 'belkys_pago'), 0) / 0.96
             - (select coalesce(sum(coalesce(o.clp_manual, o.clp)), 0) from robot_ordenes o where o.tl_grupo = g.tl_grupo)) as pendiente
from banco_movimientos g
where g.tl_grupo is not null
group by g.tl_grupo;
revoke all on v_tl_cierres from anon;
