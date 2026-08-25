-- =====================================================================
--  conferir.sql  ·  Diagnostico depois que a ingestao comeca a rodar
--
--    psql -d "postgresql://...?sslmode=require" -f conferir.sql
--
--  So leitura. Rode sempre que quiser saber se esta entrando coisa certa.
--
--  IMPORTANTE: o que o parser DESCARTOU nao aparece aqui -- eventos com
--  _route='skip' morrem no NoOp do n8n e nunca chegam ao banco. Para ver
--  descarte, olhe as execucoes do n8n no ramo "Nao e alarme".
-- =====================================================================
\pset border 2

\echo ''
\echo '=== 1. Entrou alguma coisa? ==='
select (select count(*) from health_events)   as eventos,
       (select count(*) from incidents)       as incidentes,
       (select count(*) from components)      as componentes,
       (select count(*) from components where published) as publicados,
       (select max(occurred_at) from health_events) as evento_mais_recente;

\echo ''
\echo '=== 2. De onde vem, e a hora e confiavel? ==='
-- timeSource = body_timestamp / StateChangeTime -> hora REAL do evento.
-- email_delivery / telegram_delivery -> hora da ENTREGA: infla o MTTR.
select source,
       raw->>'transport'  as transporte,
       raw->>'timeSource' as fonte_da_hora,
       count(*)           as eventos,
       min(occurred_at)::date as desde
  from health_events
 group by 1,2,3
 order by 4 desc;

\echo ''
\echo '=== 3. Atraso do transporte (Decisao em aberto no.2) ==='
-- created_at = quando o banco gravou. occurred_at = quando o evento ocorreu.
-- A diferenca e o atraso do caminho inteiro: AWS -> e-mail -> IMAP -> n8n.
-- E o numero que voce compara com o webhook da KXC quando ele existir.
-- So faz sentido onde a hora e real -- por isso o filtro.
select raw->>'transport' as transporte,
       count(*)                                                          as amostras,
       round(avg(extract(epoch from (created_at - occurred_at))))::int    as atraso_medio_seg,
       round(percentile_cont(0.5) within group (order by extract(epoch from (created_at - occurred_at))))::int as mediana_seg,
       round(max(extract(epoch from (created_at - occurred_at))))::int    as pior_caso_seg
  from health_events
 where raw->>'timeSource' in ('body_timestamp','StateChangeTime')
 group by 1;

\echo ''
\echo '=== 4. Fila de aprovacao (componentes descobertos sozinhos) ==='
select slug, environment, incidentes, incidentes_abertos, ultimo_sinal, descoberto_em
  from discovery_inbox;

\echo ''
\echo '=== 5. Esta caindo alguma coisa agora? ==='
select * from incidents_abertos;

\echo ''
\echo '=== 6. Disponibilidade por componente (90 dias) ==='
select slug, environment, status, uptime_90d, quedas_90d,
       (mttr_90d_segundos/60)::int as mttr_min
  from componentes_90d
 order by uptime_90d nulls last;

\echo ''
\echo '=== 7. Ranking de warnings -- ordenado por FORA de deploy ==='
select slug, environment, total, fora_de_deploy, em_deploy, dias_afetados
  from ranking_warnings_30d
 limit 15;

\echo ''
\echo '=== 8. RESPOSTA da Decisao em aberto no.1 ==='
-- Quantos Degraded acontecem FORA de deploy? Perto de zero -> subir
-- INCIDENT_THRESHOLD para 5. Longe de zero -> manter em 4.
select coalesce(slug,'(nenhum Degraded ainda)') as slug,
       environment, degraded_total, fora_de_deploy, em_deploy
  from degraded_fora_de_deploy_30d
 union all
 select '(total)', null,
        sum(degraded_total), sum(fora_de_deploy), sum(em_deploy)
   from degraded_fora_de_deploy_30d;
