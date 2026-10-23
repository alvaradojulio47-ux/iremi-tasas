-- ===== APP IREMI · ETAPA 12: una entrada de Transf Local (Fidel, Angélica, Lilibeth) se puede unir a su cambio en Binance =====
-- Se puede correr más de una vez (va después de la etapa 11).
-- Al unir una entrada TL con una o más órdenes: la entrada sigue siendo "Transf Local · entrada" (no pasa a cambio de cliente),
-- las órdenes quedan marcadas 🤝 transf_local y enlazadas; el cuadre las cuenta como TL enviado, no como cambios sin depósito.

create or replace function vincular_deposito(p_banco_id bigint, p_ordenes text[], p_nota text default null)
returns text language plpgsql security invoker set search_path = public as $$
declare b record; quien text := coalesce(auth.jwt() ->> 'email', 'app');
begin
  select * into b from banco_movimientos where id = p_banco_id;
  if not found then raise exception 'No existe el movimiento %', p_banco_id; end if;
  if coalesce(array_length(p_ordenes, 1), 0) = 0 then           -- cambio aceptado sin orden (efectivo, otra cuenta, libro)
    if b.categoria = 'belkys_ingreso' then return 'ok'; end if;
    update banco_movimientos set categoria = 'cambio_sin_orden', nota = coalesce(nullif(p_nota, ''), 'Aceptado por ' || quien) where id = p_banco_id;
    return 'ok';
  end if;
  if b.categoria = 'belkys_ingreso' then                        -- entrada de Transf Local unida al cambio con que se envió
    update banco_movimientos set orden_binance = array_to_string(p_ordenes, ','),
           nota = coalesce(nullif(p_nota, ''), 'TL enviada con cambio · unido por ' || quien) where id = p_banco_id;
    update robot_ordenes set revision = 'transf_local', revisado_por = quien, revisado_en = now(),
           nota = coalesce(nota, 'Resto Transf Local enviado a Venezuela'),
           clp_manual = case when array_length(p_ordenes, 1) = 1 then b.abono else clp_manual end
     where order_number = any(p_ordenes);
    delete from robot_gastos where orden_binance = any(p_ordenes);
    return 'ok';
  end if;
  update banco_movimientos set categoria = 'cambio', orden_binance = array_to_string(p_ordenes, ','),
         nota = coalesce(nullif(p_nota, ''), 'Unido a mano por ' || quien) where id = p_banco_id;
  update robot_ordenes set revision = 'cambio', revisado_por = quien, revisado_en = now(),
         clp_manual = case when array_length(p_ordenes, 1) = 1 then b.abono else clp_manual end
   where order_number = any(p_ordenes);
  delete from robot_gastos where orden_binance = any(p_ordenes);
  return 'ok';
end $$;

-- Deshacer: una entrada TL vuelve a quedar sin cambio, pero sigue siendo TL (no pasa a "por revisar")
create or replace function desvincular_deposito(p_banco_id bigint)
returns text language plpgsql security invoker set search_path = public as $$
declare b record;
begin
  select * into b from banco_movimientos where id = p_banco_id;
  if not found then raise exception 'No existe el movimiento %', p_banco_id; end if;
  if b.orden_binance is not null then
    update robot_ordenes set revision = null, clp_manual = null
     where order_number = any(string_to_array(b.orden_binance, ',')) and clp_manual = b.abono;
    update robot_ordenes set revision = null where order_number = any(string_to_array(b.orden_binance, ','));
  end if;
  if b.categoria = 'belkys_ingreso' then
    update banco_movimientos set orden_binance = null, nota = null where id = p_banco_id;
  else
    update banco_movimientos set categoria = 'por_revisar', orden_binance = null, nota = null where id = p_banco_id;
  end if;
  return 'ok';
end $$;
