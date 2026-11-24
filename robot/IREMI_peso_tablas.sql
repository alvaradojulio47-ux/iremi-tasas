-- ===== IREMI · ¿QUÉ PESA Y CUÁNTO SE LEE DE DISCO? (una pantalla) =====
-- Solo consulta. Correr en Supabase → SQL Editor.

with t as (
  select c.relname::text as tabla,
         pg_total_relation_size(c.oid) as bytes,
         s.n_live_tup as filas,
         round(100.0 * coalesce(io.heap_blks_hit, 0)
               / nullif(coalesce(io.heap_blks_hit, 0) + coalesce(io.heap_blks_read, 0), 0), 1) as en_memoria_pct
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  left join pg_stat_user_tables s on s.relid = c.oid
  left join pg_statio_user_tables io on io.relid = c.oid
  where n.nspname = 'public' and c.relkind = 'r')
select 0 as orden, 'TOTAL BASE (tope del plan gratis: 500 MB)' as tabla,
       pg_size_pretty(pg_database_size(current_database())) as pesa,
       null::bigint as filas, null::numeric as en_memoria_pct
union all
(select 1, tabla, pg_size_pretty(bytes), filas, en_memoria_pct from t order by bytes desc limit 10)
order by orden, 3;
