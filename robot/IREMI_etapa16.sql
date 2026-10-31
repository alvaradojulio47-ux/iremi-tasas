-- ===== APP IREMI · ETAPA 16: los cambios cobrados en pesos (fiat CLP) toman su monto automáticamente =====
-- Cuando un cliente paga en pesos chilenos y recibe USDT, Binance informa la orden con moneda CLP.
-- El robot no le calcula el "CLP del cliente" (no hay tasa que aplicar: el monto YA está en pesos),
-- así que la orden quedaba sin monto, sin ganancia y siempre "por revisar".
-- Esta etapa lo corrige para las que ya existen y para todas las que entren de ahora en adelante.
-- Se puede correr más de una vez (va después de la etapa 15).

-- 1) Las que ya están cargadas
update robot_ordenes
   set clp = coalesce(clp, monto_fiat),
       tasa_usada = coalesce(tasa_usada, 1),
       metodo_clp = 'clp'
 where fiat = 'CLP' and monto_fiat is not null
   and (clp is null or coalesce(metodo_clp, '') in ('', 'sin_tasa', 'estimado'));

-- 2) Las que entren de ahora en adelante (el robot sigue igual; la base lo completa sola)
create or replace function completar_clp_fiat_clp() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.fiat = 'CLP' and new.monto_fiat is not null and (new.clp is null or coalesce(new.metodo_clp, '') in ('', 'sin_tasa', 'estimado')) then
    new.clp := coalesce(new.clp, new.monto_fiat);
    new.tasa_usada := coalesce(new.tasa_usada, 1);
    -- el monto ya viene exacto en pesos: deja de estar "estimado" o "sin tasa" (así sale de la lista por revisar)
    if coalesce(new.metodo_clp, '') in ('', 'sin_tasa', 'estimado') then new.metodo_clp := 'clp'; end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_completar_clp on robot_ordenes;
create trigger trg_completar_clp before insert or update on robot_ordenes
for each row execute function completar_clp_fiat_clp();

-- 3) Comprobar: no debería quedar ninguna sin monto
select count(*) filter (where clp is null) as sin_monto,
       count(*) filter (where coalesce(metodo_clp,'') in ('', 'sin_tasa', 'estimado')) as aun_por_revisar,
       count(*) as total_ventas_en_pesos
  from robot_ordenes where fiat = 'CLP';
