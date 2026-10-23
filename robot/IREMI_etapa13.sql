-- ===== APP IREMI · ETAPA 13: unir entradas de Transf Local con el pago a Florelvi/Belkys que las envió =====
-- Se puede correr más de una vez (va después de la etapa 12).
-- Una entrada TL (Fidel, Angélica, Lilibeth) queda explicada de una de dos formas:
--   a) unida a un cambio de Binance con que se envió (etapa 12, orden_binance), o
--   b) unida al pago a Florelvi/Belkys que la envió (esta etapa, tl_ref = id del pago; varias entradas pueden ir en un mismo pago).

alter table banco_movimientos add column if not exists tl_ref bigint;
create index if not exists banco_mov_tl_ref_idx on banco_movimientos (tl_ref) where tl_ref is not null;

create or replace function vincular_tl(p_pago bigint, p_entradas bigint[])
returns text language plpgsql security invoker set search_path = public as $$
declare p record; quien text := coalesce(auth.jwt() ->> 'email', 'app');
begin
  select * into p from banco_movimientos where id = p_pago and categoria = 'belkys_pago' and cargo > 0;
  if not found then raise exception 'El movimiento % no es un pago de Transf Local', p_pago; end if;
  update banco_movimientos set tl_ref = p_pago, nota = coalesce(nullif(nota, ''), 'Pagada a Florelvi/Belkys el ' || to_char(p.fecha, 'DD/MM') || ' · unido por ' || quien)
   where id = any(p_entradas) and categoria = 'belkys_ingreso' and abono > 0;
  return 'ok';
end $$;

create or replace function desvincular_tl(p_entrada bigint)
returns text language plpgsql security invoker set search_path = public as $$
begin
  update banco_movimientos set tl_ref = null, nota = case when nota like 'Pagada a Florelvi%' then null else nota end
   where id = p_entrada and categoria = 'belkys_ingreso';
  return 'ok';
end $$;
revoke all on function vincular_tl(bigint, bigint[]), desvincular_tl(bigint) from public, anon;
grant execute on function vincular_tl(bigint, bigint[]), desvincular_tl(bigint) to authenticated;

-- 3) Un cambio pagado con varios depósitos toma como CLP la suma de todos sus depósitos (no el último)
create or replace function recalc_clp_orden(p_orden text)
returns void language plpgsql security invoker set search_path = public as $$
declare n int; s numeric;
begin
  select count(*), coalesce(sum(b.abono), 0) into n, s
  from banco_movimientos b where b.abono > 0 and b.orden_binance is not null
   and p_orden = any(regexp_split_to_array(b.orden_binance, '\s*[,;]\s*'))
   and array_length(regexp_split_to_array(b.orden_binance, '\s*[,;]\s*'), 1) = 1;   -- depósitos que pagan solo esta orden
  if n >= 1 then update robot_ordenes set clp_manual = s where order_number = p_orden; end if;
end $$;
revoke all on function recalc_clp_orden(text) from public, anon;
grant execute on function recalc_clp_orden(text) to authenticated;

create or replace function vincular_deposito(p_banco_id bigint, p_ordenes text[], p_nota text default null)
returns text language plpgsql security invoker set search_path = public as $$
declare b record; quien text := coalesce(auth.jwt() ->> 'email', 'app'); o text;
begin
  select * into b from banco_movimientos where id = p_banco_id;
  if not found then raise exception 'No existe el movimiento %', p_banco_id; end if;
  if coalesce(array_length(p_ordenes, 1), 0) = 0 then           -- cambio aceptado sin orden (efectivo, otra cuenta, libro)
    if b.categoria = 'belkys_ingreso' then return 'ok'; end if;
    update banco_movimientos set categoria = 'cambio_sin_orden', nota = coalesce(nullif(p_nota, ''), 'Aceptado por ' || quien) where id = p_banco_id;
    return 'ok';
  end if;
  if b.categoria = 'belkys_ingreso' then                        -- entrada de Transf Local unida al cambio con que se envió
    update banco_movimientos set orden_binance = array_to_string(p_ordenes, ','), tl_ref = null,
           nota = coalesce(nullif(p_nota, ''), 'TL enviada con cambio · unido por ' || quien) where id = p_banco_id;
    update robot_ordenes set revision = 'transf_local', revisado_por = quien, revisado_en = now(),
           nota = coalesce(nota, 'Resto Transf Local enviado a Venezuela') where order_number = any(p_ordenes);
  else
    update banco_movimientos set categoria = 'cambio', orden_binance = array_to_string(p_ordenes, ','),
           nota = coalesce(nullif(p_nota, ''), 'Unido a mano por ' || quien) where id = p_banco_id;
    update robot_ordenes set revision = 'cambio', revisado_por = quien, revisado_en = now() where order_number = any(p_ordenes);
  end if;
  delete from robot_gastos where orden_binance = any(p_ordenes);
  foreach o in array p_ordenes loop perform recalc_clp_orden(o); end loop;
  return 'ok';
end $$;

create or replace function desvincular_deposito(p_banco_id bigint)
returns text language plpgsql security invoker set search_path = public as $$
declare b record; o text; ords text[];
begin
  select * into b from banco_movimientos where id = p_banco_id;
  if not found then raise exception 'No existe el movimiento %', p_banco_id; end if;
  ords := regexp_split_to_array(coalesce(b.orden_binance, ''), '\s*[,;]\s*');
  if b.categoria = 'belkys_ingreso' then
    update banco_movimientos set orden_binance = null, nota = null where id = p_banco_id;
  else
    update banco_movimientos set categoria = 'por_revisar', orden_binance = null, nota = null where id = p_banco_id;
  end if;
  if b.orden_binance is not null then
    foreach o in array ords loop
      if o <> '' then
        -- si a la orden no le queda ningún depósito, vuelve a "sin revisar" y a su CLP estimado; si le quedan, recalcula la suma
        if not exists (select 1 from banco_movimientos x where x.orden_binance is not null and o = any(regexp_split_to_array(x.orden_binance, '\s*[,;]\s*'))) then
          update robot_ordenes set revision = null, clp_manual = null where order_number = o;
        else
          perform recalc_clp_orden(o);
        end if;
      end if;
    end loop;
  end if;
  return 'ok';
end $$;
