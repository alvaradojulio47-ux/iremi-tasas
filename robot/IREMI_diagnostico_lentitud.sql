-- ===== IREMI · POR QUÉ LA BASE ESTÁ LENTA =====
-- Solo consulta, no modifica nada. Correr en Supabase → SQL Editor.

-- 1) ¿Hay consultas pegadas ahora mismo? (lo más importante)
select pid,
       usename as usuario,
       application_name as quien,
       state as estado,
       now() - xact_start as lleva_abierta,
       now() - query_start as lleva_corriendo,
       wait_event_type as esperando,
       left(regexp_replace(query, '\s+', ' ', 'g'), 110) as consulta
from pg_stat_activity
where pid <> pg_backend_pid() and state <> 'idle'
order by lleva_corriendo desc nulls last
limit 20;

-- 2) Conexiones abiertas por aplicación (si son muchas, algo no está cerrando)
select coalesce(nullif(application_name, ''), '(sin nombre)') as quien,
       state as estado, count(*) as conexiones,
       max(now() - state_change) as la_mas_vieja
from pg_stat_activity where pid <> pg_backend_pid()
group by 1, 2 order by 3 desc;

-- 3) ¿Alguien bloqueando a otro?
select bloqueada.pid as pid_esperando,
       left(regexp_replace(bloqueada.query, '\s+', ' ', 'g'), 70) as consulta_esperando,
       bloqueante.pid as pid_que_bloquea,
       left(regexp_replace(bloqueante.query, '\s+', ' ', 'g'), 70) as consulta_que_bloquea
from pg_stat_activity bloqueada
join lateral unnest(pg_blocking_pids(bloqueada.pid)) as b(pid) on true
join pg_stat_activity bloqueante on bloqueante.pid = b.pid
where cardinality(pg_blocking_pids(bloqueada.pid)) > 0;

-- 4) Tamaño de la base y las 12 tablas más pesadas (el plan gratis tiene 500 MB)
select pg_size_pretty(pg_database_size(current_database())) as tamano_total_base;

select c.relname as tabla,
       pg_size_pretty(pg_total_relation_size(c.oid)) as total,
       pg_size_pretty(pg_relation_size(c.oid)) as datos,
       pg_size_pretty(pg_total_relation_size(c.oid) - pg_relation_size(c.oid)) as indices,
       s.n_live_tup as filas_vivas, s.n_dead_tup as filas_muertas,
       s.last_autovacuum, s.last_autoanalyze
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_stat_user_tables s on s.relid = c.oid
where n.nspname = 'public' and c.relkind = 'r'
order by pg_total_relation_size(c.oid) desc limit 12;

-- 5) ¿Está leyendo de disco en vez de memoria? (bajo 95% = la base sufre)
select round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 1) as porcentaje_en_memoria
from pg_statio_user_tables;

-- 6) Las 8 consultas que más tiempo consumen en total
--    (si da error "pg_stat_statements does not exist", actívala en Database > Extensions y vuelve a correr solo esta parte)
select round(total_exec_time)::bigint as ms_totales, calls as veces,
       round(mean_exec_time)::bigint as ms_promedio,
       left(regexp_replace(query, '\s+', ' ', 'g'), 110) as consulta
from pg_stat_statements order by total_exec_time desc limit 8;
