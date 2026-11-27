-- ===== APP IREMI · ETAPA 19: el Día a día se calcula una vez, no en cada pantalla =====
--
-- El problema que apareció el 27/11:
--   Inicio mostraba "⏱ la base tardó demasiado" en Gastos del mes, Utilidad del mes,
--   Capital total y ¿Falta plata?. Todos esos cuadros salen de la vista v_diario.
--   v_diario recalcula TODOS los días desde la primera operación hasta hoy (~1.200 días)
--   cada vez que se abre Inicio. Las sumas acumuladas (sum() over) obligan a calcular el
--   historial completo aunque la app pida solo los últimos días: el filtro se aplica
--   después, no antes. Con la CPU compartida del plan gratuito eso superaba el límite de
--   tiempo de Supabase y la consulta se cortaba.
--
-- La solución: guardar el resultado ya calculado (vista materializada) y refrescarlo solo
-- cuando hace falta, en vez de recalcularlo en cada pantalla.
--
-- No cambia ningún número: es exactamente el mismo select de v_diario.
-- Se puede correr más de una vez. Va después de la etapa 18.

-- ── 1) La copia ya calculada ────────────────────────────────────────────────
drop materialized view if exists v_diario_m cascade;
create materialized view v_diario_m as select * from v_diario;

-- el índice único es obligatorio para poder refrescar sin bloquear a quien esté leyendo
create unique index if not exists v_diario_m_dia_idx on v_diario_m (dia);

-- nadie la consulta directo: se entra por la vista de abajo, que aplica los permisos
revoke all on v_diario_m from anon, authenticated;

-- ── 2) La puerta de entrada para la app ─────────────────────────────────────
-- Mismas reglas de siempre: solo los usuarios que están en app_usuarios ven datos.
-- (Esta vista corre con los permisos de su dueño, por eso puede leer la copia de arriba;
--  el filtro es_usuario_app() es el que deja afuera a cualquier otro.)
create or replace view v_diario_rapido as
  select * from v_diario_m where es_usuario_app();

grant select on v_diario_rapido to authenticated;
revoke all on v_diario_rapido from anon;

-- ── 3) Refrescar la copia ───────────────────────────────────────────────────
-- Tiene un freno: si ya se refrescó hace menos de p_minutos, no gasta CPU de nuevo.
-- Así la app puede llamarla cada vez que guarda algo sin miedo a recargar la base.
create or replace function refrescar_diario(p_minutos int default 2)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  ultimo timestamptz;
begin
  select max(actualizado) into ultimo from robot_estado where clave = 'diario_refrescado';
  ultimo := coalesce(ultimo, 'epoch'::timestamptz);

  if now() - ultimo < make_interval(mins => greatest(p_minutos, 0)) then
    return ultimo;                      -- recién refrescado, no hay nada que hacer
  end if;

  refresh materialized view concurrently v_diario_m;

  insert into robot_estado (clave, valor, actualizado)
       values ('diario_refrescado',
               to_char(now() at time zone 'America/Santiago', 'YYYY-MM-DD HH24:MI'), now())
  on conflict (clave) do update
       set valor = excluded.valor, actualizado = excluded.actualizado;

  return now();
end $$;

revoke all on function refrescar_diario(int) from public, anon;
grant execute on function refrescar_diario(int) to authenticated;

-- ── 4) Que se refresque solo, si el servidor lo permite ─────────────────────
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'refrescar_diario';
    perform cron.schedule('refrescar_diario', '*/10 * * * *', 'select refrescar_diario(0)');
    raise notice 'pg_cron activo: el Día a día se refresca solo cada 10 minutos';
  else
    raise notice 'pg_cron no está activo. El Día a día se refresca igual cuando la app '
                 'guarda algo o cuando tocas Actualizar. Si quieres que además se refresque '
                 'solo, activa la extensión pg_cron en Database → Extensions y vuelve a '
                 'correr esta etapa.';
  end if;
exception when others then
  raise notice 'No pude programar el refresco automático (%). No es grave: la app lo '
               'refresca cuando guardas algo o tocas Actualizar.', sqlerrm;
end $$;

-- ── 5) Comprobación ─────────────────────────────────────────────────────────
-- Debe decir 0 diferencias: la copia tiene exactamente lo mismo que la vista original.
select (select count(*) from v_diario_m)                                   as dias_guardados,
       (select count(*) from (select * from v_diario
                              except select * from v_diario_m) x)          as diferencias,
       (select valor from robot_estado where clave = 'diario_refrescado')  as refrescado;
