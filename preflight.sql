-- =====================================================================
--  preflight.sql  ·  Este Postgres aguenta o schema?
--
--  Aponte para qualquer candidato ANTES de migrar:
--    psql "postgresql://user:senha@host:5432/db" -f preflight.sql
--
--  So faz leitura -- nao cria nada, nao altera nada. Pode rodar em
--  producao alheia sem susto.
-- =====================================================================
\set ON_ERROR_STOP off
\pset format aligned
\pset border 2

select
  case when current_setting('server_version_num')::int >= 140000
       then 'OK   ' else 'FALHA' end                        as res,
  'PostgreSQL 14+'                                          as requisito,
  version()                                                 as encontrado,
  'range_agg/multirange, usado em downtime_seconds()'       as porque;

-- O calculo de downtime nao e soma de duracoes: integra o PIOR peso ativo
-- em cada instante, via uniao de intervalos. Sem multirange nao ha como
-- fazer isso sem uma varredura manual bem mais lenta.
select
  case when (
    select coalesce(sum(extract(epoch from (upper(f) - lower(f)))), 0)
      from unnest((
        select range_agg(r)
          from (values (tstzrange('2026-01-01 10:00Z','2026-01-01 11:00Z')),
                       (tstzrange('2026-01-01 10:30Z','2026-01-01 10:45Z'))) v(r)
      )) as f
  ) = 3600 then 'OK   ' else 'FALHA' end                    as res,
  'range_agg sobre tstzrange + unnest'                      as requisito,
  'uniao de intervalos sobrepostos'                         as encontrado,
  'sem isso o downtime conta o mesmo minuto duas vezes'     as porque;

-- Decisao no.5. Trava de TRANSACAO, nao de sessao -- de proposito: sobrevive
-- a pooling em modo transaction (PgBouncer/Supavisor/RDS Proxy). Trava de
-- sessao quebraria nesses.
begin;
select
  case when pg_try_advisory_xact_lock(999001, 999002) then 'OK   ' else 'FALHA' end as res,
  'pg_advisory_xact_lock'                                   as requisito,
  'concedida'                                               as encontrado,
  'correlacao atomica: dois alarmes no mesmo segundo'       as porque;
commit;

select
  case when exists (select 1 from pg_language where lanname = 'plpgsql')
       then 'OK   ' else 'FALHA' end                        as res,
  'plpgsql'                                                 as requisito,
  coalesce((select lanname from pg_language where lanname='plpgsql'), 'ausente') as encontrado,
  'ingest_health, resolve_component, merge_components'      as porque;

select
  case when exists (select 1 from pg_timezone_names where name = 'America/Sao_Paulo')
       then 'OK   ' else 'FALHA' end                        as res,
  'tzdata America/Sao_Paulo'                                as requisito,
  coalesce((select utc_offset::text from pg_timezone_names where name='America/Sao_Paulo'), 'ausente') as encontrado,
  'recorte de dia em timeline_do_dia e daily_downtime'      as porque;

select
  case when has_database_privilege(current_user, current_database(), 'CREATE')
       then 'OK   ' else 'FALHA' end                        as res,
  'CREATE no banco'                                         as requisito,
  current_user                                              as encontrado,
  'criar tipo, tabela, indice parcial, funcao e gatilho'    as porque;

-- Volume: o schema e minusculo. Isto e so para constatar que qualquer
-- plano serve -- a decisao deve ser operacional, nao de capacidade.
-- Medido: 217 eventos reais do Beanstalk ingeridos num banco limpo dao
-- 1,1 MB somando TUDO -- tabelas, indices e o overhead fixo das ~20 relacoes
-- vazias. A maior parte desse numero e o overhead, nao os dados.
select
  'INFO '                                                   as res,
  'volume medido'                                           as requisito,
  '217 eventos = 1,1 MB (schema + indices + dados)'         as encontrado,
  'nenhum limite de linha ou disco pesa aqui'               as porque;

\echo ''
\echo 'Cuidados que este script NAO consegue testar:'
\echo '  · Driver HTTP/serverless (ex.: @neondatabase/serverless em modo fetch)'
\echo '    executa uma instrucao por requisicao, SEM transacao. O advisory lock'
\echo '    e liberado na hora e a correlacao perde a atomicidade.'
\echo '    Use sempre a connection string Postgres normal no no do n8n.'
\echo '  · Pooling em modo SESSION com limite baixo de conexoes pode segurar'
\echo '    a trava alem da transacao. Prefira modo TRANSACTION.'
\echo '  · Bancos "compativeis com Postgres" que nao sao Postgres (CockroachDB,'
\echo '    YugabyteDB) nao tem range_agg nem advisory lock: o schema nao sobe.'
