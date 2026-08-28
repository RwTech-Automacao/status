-- =====================================================================
--  tests.sql  ·  Testes de fumaca do motor de correlacao
--
--  Roda contra um banco VAZIO, carregado na ordem:
--    schema.sql -> discovery.sql -> ingest_function.sql -> health.sql
--
--    createdb sla
--    for f in schema discovery ingest_function health tests; do
--      psql -d sla -v ON_ERROR_STOP=1 -f $f.sql
--    done
--
--  Qualquer assercao que falhe aborta com exit code 3.
--
--  ------------------------------------------------------------------
--  O que NAO da para testar aqui: concorrencia (Decisao no.5). Numa
--  sessao so, o advisory lock nunca e disputado. Para exercitar de
--  verdade, gere um arquivo com N chamadas -- uma por linha, para que
--  cada uma seja sua propria transacao, como no n8n -- e rode varias
--  sessoes psql em paralelo contra o mesmo fingerprint:
--
--    yes "select ingest_health('{\"source\":\"cloudwatch\",\"state\":\"ALARM\",
--         \"fingerprint\":\"fp-teste\",\"occurredAt\":\"2026-08-23T10:00:00-03:00\",
--         \"metric\":\"EnvironmentHealth\",\"resource\":\"api-corrida-producao\"}'::jsonb);" \
--      | head -300 > race.sql
--    for i in 1 2 3 4; do psql -d sla -q -f race.sql & done; wait
--
--  Invariantes esperados: zero erros, UM incidente para o fingerprint,
--  occurrences = 4 x 300, e UM unico componente auto-criado.
-- =====================================================================
\set ON_ERROR_STOP on
set client_min_messages = notice;

-- ---------------------------------------------------------------------
-- TRAVA: este arquivo INSERE componentes e incidentes ficticios.
-- Rodar no banco que recebe os alarmes reais poluiria o historico -- e
-- historico de SLA nao se reconstroi. Aborta se ja houver qualquer dado.
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.components') is null then
    raise exception 'ABORTADO: schema nao carregado. Rode antes: schema.sql -> discovery.sql -> ingest_function.sql -> health.sql';
  end if;

  if exists (select 1 from components limit 1) then
    raise exception
      'ABORTADO: este banco JA TEM % componente(s). tests.sql insere dados ficticios -- use um banco descartavel (ou um branch do Neon), nunca o que recebe os alarmes reais.',
      (select count(*) from components);
  end if;
end $$;

create or replace function assert_eq(p_caso text, p_obtido anyelement, p_esperado anyelement)
returns void language plpgsql as $$
begin
  if p_obtido is distinct from p_esperado then
    raise exception 'FALHOU [%]: obtido=% esperado=%', p_caso, p_obtido, p_esperado;
  end if;
  raise notice 'ok  %  (%)', p_caso, p_obtido;
end $$;

-- =====================================================================
-- 1. CloudWatch: auto-descoberta + abertura
-- =====================================================================
do $$
declare r record; c record;
begin
  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','ALARM',
    'fingerprint','RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T10:00:00-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-producao',
    'reason','Threshold Crossed','deliveryHash','h1'));

  perform assert_eq('1.1 abre incidente', r.action, 'opened');
  perform assert_eq('1.2 slug sem o ambiente', r.component_slug, 'api-tarefa-megas');
  perform assert_eq('1.3 status do componente', r.component_status::text, 'major_outage');

  select * into c from components where id = r.component_id;
  perform assert_eq('1.4 ambiente virou coluna', c.environment, 'producao');
  perform assert_eq('1.5 nasce DESPUBLICADO', c.published, false);
  perform assert_eq('1.6 meta padrao', c.sla_target, 99.900::numeric);
end $$;

-- =====================================================================
-- 2. Monitor reenvia o mesmo alerta -> UPDATE, nao incidente novo
-- =====================================================================
do $$
declare r record; n int;
begin
  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','ALARM',
    'fingerprint','RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T10:00:30-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-producao','deliveryHash','h2'));
  perform assert_eq('2.1 repeticao vira update', r.action, 'updated');

  select count(*) into n from incidents where fingerprint like '%api-tarefa-megas-producao';
  perform assert_eq('2.2 continua UM incidente', n, 1);
end $$;

-- =====================================================================
-- 3. Entrega FORA DE ORDEM: evento mais antigo puxa started_at para tras
-- =====================================================================
do $$
declare r record; ini timestamptz;
begin
  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','ALARM',
    'fingerprint','RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T09:58:00-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-producao','deliveryHash','h3'));
  select started_at into ini from incidents where id = r.incident_id;
  perform assert_eq('3.1 inicio real e o mais antigo', ini, '2026-08-20T09:58:00-03:00'::timestamptz);
end $$;

-- =====================================================================
-- 4. OK fecha; ALARM dentro da janela de flap REABRE o mesmo incidente
-- =====================================================================
do $$
declare r record; id_orig bigint; n int;
begin
  select id into id_orig from incidents
   where fingerprint like '%api-tarefa-megas-producao' and resolved_at is null;

  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','OK',
    'fingerprint','RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T10:05:00-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-producao','deliveryHash','h4'));
  perform assert_eq('4.1 OK resolve', r.action, 'resolved');
  perform assert_eq('4.2 componente normaliza', r.component_status::text, 'operational');

  -- volta a cair 40s depois: e a MESMA queda piscando
  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','ALARM',
    'fingerprint','RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T10:05:40-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-producao','deliveryHash','h5'));
  perform assert_eq('4.3 flapping reabre', r.action, 'reopened');
  perform assert_eq('4.4 mesmo incidente, nao um novo', r.incident_id, id_orig);

  -- fora da janela (>120s) e queda nova
  perform ingest_health(jsonb_build_object(
    'source','cloudwatch','state','OK',
    'fingerprint','RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T10:10:00-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-producao','deliveryHash','h6'));
  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','ALARM',
    'fingerprint','RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T10:20:00-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-producao','deliveryHash','h7'));
  perform assert_eq('4.5 fora da janela abre nova', r.action, 'opened');

  perform ingest_health(jsonb_build_object(
    'source','cloudwatch','state','OK',
    'fingerprint','RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T10:25:00-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-producao','deliveryHash','h8'));

  select count(*) into n from incidents where fingerprint like '%api-tarefa-megas-producao';
  perform assert_eq('4.6 total de quedas', n, 2);
end $$;

-- =====================================================================
-- 5. Dedup de reentrega + INSUFFICIENT_DATA
-- =====================================================================
do $$
declare r record; n int;
begin
  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','ALARM',
    'fingerprint','RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T10:00:00-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-producao','deliveryHash','h1'));
  perform assert_eq('5.1 reentrega do SNS e descartada', r.action, 'duplicado');

  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','INSUFFICIENT_DATA',
    'fingerprint','RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T11:00:00-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-producao','deliveryHash','h9'));
  perform assert_eq('5.2 cegueira nao e queda', r.action, 'monitor_cego');
  perform assert_eq('5.3 componente segue operacional', r.component_status::text, 'operational');

  select count(*) into n from monitor_signals where signal = 'insufficient_data';
  perform assert_eq('5.4 registrado em monitor_signals', n, 1);

  select count(*) into n from incidents where fingerprint like '%api-tarefa-megas-producao';
  perform assert_eq('5.5 nenhum incidente criado', n, 2);
end $$;

-- =====================================================================
-- 6. Metrica define a gravidade (Decisao no.4)
-- =====================================================================
do $$
declare r record;
begin
  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','ALARM',
    'fingerprint','RWTech - EB - Latency - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T12:00:00-03:00',
    'metric','Latency','resource','api-tarefa-megas-producao','deliveryHash','h10'));
  perform assert_eq('6.1 Latency degrada, nao derruba', r.component_status::text, 'degraded');

  perform assert_eq('6.2 EnvironmentHealth = major',
    impact_from_metric('EnvironmentHealth')::text, 'major_outage');
  perform assert_eq('6.3 CPUUtilization = degraded',
    impact_from_metric('CPUUtilization')::text, 'degraded');
  perform assert_eq('6.4 HTTPCode_Target_5XX = partial',
    impact_from_metric('HTTPCode_Target_5XX_Count')::text, 'partial_outage');
  perform assert_eq('6.5 metrica desconhecida erra para MAIS',
    impact_from_metric('MetricaQueNinguemCadastrou')::text, 'partial_outage');
end $$;

-- =====================================================================
-- 7. Dois problemas simultaneos: so normaliza quando o ultimo fecha
-- =====================================================================
do $$
declare r record;
begin
  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','ALARM',
    'fingerprint','RWTech - EB - EnvironmentHealth - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T12:10:00-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-producao','deliveryHash','h11'));
  perform assert_eq('7.1 o pior estado vence', r.component_status::text, 'major_outage');

  -- fecha SO o major; a latencia continua aberta
  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','OK',
    'fingerprint','RWTech - EB - EnvironmentHealth - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T12:20:00-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-producao','deliveryHash','h12'));
  perform assert_eq('7.2 NAO volta a operational com outro aberto',
    r.component_status::text, 'degraded');

  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','OK',
    'fingerprint','RWTech - EB - Latency - api-tarefa-megas-producao',
    'occurredAt','2026-08-20T12:30:00-03:00',
    'metric','Latency','resource','api-tarefa-megas-producao','deliveryHash','h13'));
  perform assert_eq('7.3 agora sim normaliza', r.component_status::text, 'operational');
end $$;

-- =====================================================================
-- 8. Beanstalk: maquina de estados + deploy
-- =====================================================================
do $$
declare r record; c record; i record;
begin
  -- Info -> Degraded DURANTE deploy
  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk',
    'occurredAt','2026-08-21T15:11:31-03:00',
    'environmentName','Api-Fechamento-env',
    'applicationName','Api-Fechamento-Validacao',
    'fromState','Info','toState','Degraded',
    'message','Environment health has transitioned from Info to Degraded. Configuration update in progress on 1 instance.',
    'notificationProcessId','npid-1'));
  perform assert_eq('8.1 Degraded abre incidente', r.action, 'opened');
  perform assert_eq('8.2 slug vem da aplicacao', r.component_slug, 'api-fechamento');
  perform assert_eq('8.3 peso 0,5 = partial_outage', r.component_status::text, 'partial_outage');

  select * into c from components where id = r.component_id;
  perform assert_eq('8.4 ambiente veio do nome da APLICACAO', c.environment, 'validacao');

  select * into i from incidents where id = r.incident_id;
  perform assert_eq('8.5 deploy nao queima SLA', i.excluded_from_sla, true);
  perform assert_eq('8.6 mas continua no historico', i.title, 'Ambiente Degraded');

  -- escalou para Severe: deploy que DERRUBA volta a contar (excecao da Decisao no.1)
  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk',
    'occurredAt','2026-08-21T15:14:00-03:00',
    'environmentName','Api-Fechamento-env','applicationName','Api-Fechamento-Validacao',
    'fromState','Degraded','toState','Severe',
    'message','Environment health has transitioned from Degraded to Severe. Configuration update in progress.',
    'notificationProcessId','npid-2'));
  perform assert_eq('8.7 escalou', r.action, 'updated');

  select * into i from incidents where id = r.incident_id;
  perform assert_eq('8.8 Severe reintroduz no SLA', i.excluded_from_sla, false);
  perform assert_eq('8.9 impacto escalou para major', i.impact::text, 'major_outage');

  -- volta a Warning: melhorou sem ficar saudavel -> rebaixa, nao fecha
  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk',
    'occurredAt','2026-08-21T15:16:00-03:00',
    'environmentName','Api-Fechamento-env','applicationName','Api-Fechamento-Validacao',
    'fromState','Severe','toState','Warning',
    'message','Environment health has transitioned from Severe to Warning.',
    'notificationProcessId','npid-3'));
  perform assert_eq('8.10 Warning rebaixa, nao fecha', r.action, 'incidente_rebaixado');
  perform assert_eq('8.11 impacto caiu para degraded', r.component_status::text, 'degraded');

  -- Ok fecha
  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk',
    'occurredAt','2026-08-21T15:18:00-03:00',
    'environmentName','Api-Fechamento-env','applicationName','Api-Fechamento-Validacao',
    'fromState','Warning','toState','Ok',
    'message','Environment health has transitioned from Warning to Ok.',
    'notificationProcessId','npid-4'));
  perform assert_eq('8.12 Ok fecha', r.action, 'resolved');
  perform assert_eq('8.13 componente normaliza', r.component_status::text, 'operational');

  -- dedup pelo NotificationProcessId
  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk','occurredAt','2026-08-21T15:18:00-03:00',
    'environmentName','Api-Fechamento-env','applicationName','Api-Fechamento-Validacao',
    'fromState','Warning','toState','Ok','message','...','notificationProcessId','npid-4'));
  perform assert_eq('8.14 dedup por NotificationProcessId', r.action, 'duplicado');
end $$;

-- =====================================================================
-- 9. Warning isolado nao abre incidente -- vira registro do dia
-- =====================================================================
do $$
declare r record; n int;
begin
  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk','occurredAt','2026-08-21T16:00:00-03:00',
    'environmentName','Api-Fechamento-env','applicationName','Api-Fechamento-Validacao',
    'fromState','Ok','toState','Warning',
    'message','Environment health has transitioned from Ok to Warning. 1 out of 4 instances are impacted.',
    'notificationProcessId','npid-5'));
  perform assert_eq('9.1 Warning nao abre incidente', r.action, 'registrado_sem_incidente');
  perform assert_eq('9.2 componente segue operacional', r.component_status::text, 'operational');

  -- a trilha guarda TUDO: 2 Warnings do Beanstalk + o espelho do alarme
  -- de Latency do CloudWatch (que abriu incidente 'degraded')
  select count(*) into n from health_events where severity = 3;
  perform assert_eq('9.3 a trilha guarda tudo', n, 3);

  -- ...mas o ranking so conta o que NAO virou incidente
  select count(*) into n from warnings_por_dia;
  perform assert_eq('9.3b warning que virou incidente sai do ranking', n, 1);

  select fora_de_deploy into n from warnings_por_dia where slug='api-fechamento';
  perform assert_eq('9.3c e o Warning solto de 21/08', n, 1);

  -- toState extraido da FRASE quando o parser nao mandou o campo
  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk','occurredAt','2026-08-21T16:30:00-03:00',
    'environmentName','Api-Fechamento-env','applicationName','Api-Fechamento-Validacao',
    'message','Environment health has transitioned from Warning to Ok.',
    'notificationProcessId','npid-6'));
  perform assert_eq('9.4 estado lido da mensagem', r.action, 'noop_sem_incidente_aberto');
end $$;

-- =====================================================================
-- 10. Homologacao NAO contamina producao (Decisao no.2)
-- =====================================================================
do $$
declare r record; n int;
begin
  select * into r from ingest_health(jsonb_build_object(
    'source','cloudwatch','state','ALARM',
    'fingerprint','RWTech - EB - EnvironmentHealth - api-tarefa-megas-homolog',
    'occurredAt','2026-08-21T09:00:00-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-homolog','deliveryHash','h20'));
  perform assert_eq('10.1 mesmo slug', r.component_slug, 'api-tarefa-megas');

  select count(*) into n from components where slug = 'api-tarefa-megas';
  perform assert_eq('10.2 dois componentes, um por ambiente', n, 2);

  select count(*) into n from components c
   where c.slug='api-tarefa-megas' and c.environment='producao' and c.status='operational';
  perform assert_eq('10.3 producao intacta', n, 1);

  perform ingest_health(jsonb_build_object(
    'source','cloudwatch','state','OK',
    'fingerprint','RWTech - EB - EnvironmentHealth - api-tarefa-megas-homolog',
    'occurredAt','2026-08-21T09:30:00-03:00',
    'metric','EnvironmentHealth','resource','api-tarefa-megas-homolog','deliveryHash','h21'));
end $$;

-- =====================================================================
-- 11. downtime_seconds com SOBREPOSICAO (o bolo de camadas)
-- =====================================================================
do $$
declare cid bigint; d numeric;
begin
  insert into components (slug, name, environment, created_at)
  values ('teste-sobreposicao','Teste','producao','2026-01-01') returning id into cid;

  -- degraded (0,25) das 10h as 11h  +  major (1,0) das 10h30 as 10h45
  insert into incidents (component_id,fingerprint,impact,title,started_at,resolved_at,last_seen_at)
  values (cid,'fp-a','degraded','lento',
          '2026-08-10 10:00-03','2026-08-10 11:00-03','2026-08-10 11:00-03'),
         (cid,'fp-b','major_outage','fora',
          '2026-08-10 10:30-03','2026-08-10 10:45-03','2026-08-10 10:45-03');

  d := downtime_seconds(cid,'2026-08-10 00:00-03','2026-08-11 00:00-03');
  -- soma ingenua daria 0,25*3600 + 1,0*900 = 1800 e contaria 10h30-10h45 duas vezes
  perform assert_eq('11.1 integra o PIOR peso ativo', d, 1575::numeric);

  perform assert_eq('11.2 downtime nunca passa do relogio',
    (downtime_seconds(cid,'2026-08-10 10:30-03','2026-08-10 10:45-03') <= 900), true);
end $$;

-- =====================================================================
-- 12. Incidente que atravessa a meia-noite
-- =====================================================================
do $$
declare cid bigint;
begin
  insert into components (slug,name,environment,created_at)
  values ('teste-meianoite','Meia-noite','producao','2026-01-01') returning id into cid;

  -- 23h do dia 10 as 02h do dia 11 = 1h no dia 10, 2h no dia 11
  insert into incidents (component_id,fingerprint,impact,title,started_at,resolved_at,last_seen_at)
  values (cid,'fp-mn','major_outage','fora',
          '2026-08-10 23:00-03','2026-08-11 02:00-03','2026-08-11 02:00-03');

  perform assert_eq('12.1 dia 10 recebe 1h',
    downtime_seconds(cid,'2026-08-10 00:00-03','2026-08-11 00:00-03'), 3600::numeric);
  perform assert_eq('12.2 dia 11 recebe 2h',
    downtime_seconds(cid,'2026-08-11 00:00-03','2026-08-12 00:00-03'), 7200::numeric);
  perform assert_eq('12.3 sem dupla contagem no total',
    downtime_seconds(cid,'2026-08-10 00:00-03','2026-08-12 00:00-03'), 10800::numeric);

  perform assert_eq('12.4 uptime do dia 10',
    round(100 - 3600/864.0, 4), 95.8333::numeric);
end $$;

-- =====================================================================
-- 13. Deploy nao entra na conta, mas aparece no historico
-- =====================================================================
do $$
declare cid bigint;
begin
  insert into components (slug,name,environment,created_at)
  values ('teste-deploy','Deploy','producao','2026-01-01') returning id into cid;

  insert into incidents (component_id,fingerprint,impact,title,started_at,resolved_at,last_seen_at,
                         excluded_from_sla,exclusion_reason)
  values (cid,'fp-dep','major_outage','deploy',
          '2026-08-12 10:00-03','2026-08-12 10:04-03','2026-08-12 10:04-03',
          true,'degradacao durante deploy');

  perform assert_eq('13.1 nao queima SLA',
    downtime_seconds(cid,'2026-08-12 00:00-03','2026-08-13 00:00-03'), 0::numeric);
  perform assert_eq('13.2 mas continua visivel',
    (select count(*) from incidents where component_id=cid), 1::bigint);
  perform assert_eq('13.3 fora do MTTR',
    mttr_seconds(cid,'2026-08-12 00:00-03','2026-08-13 00:00-03'), null::numeric);
end $$;

-- =====================================================================
-- 14. uptime_pct / error_budget_month / daily_downtime
-- =====================================================================
do $$
declare cid bigint; b record; n int;
begin
  select id into cid from components where slug='teste-meianoite';
  update components set created_at='2026-08-01', sla_target=99.9 where id=cid;

  perform assert_eq('14.1 uptime de 2 dias com 3h fora',
    uptime_pct(cid,'2026-08-10 00:00-03','2026-08-12 00:00-03'), 93.75::numeric);

  select * into b from error_budget_month(cid,'2026-08-01');
  -- agosto = 31d = 2678400s; 0,1% = 2678,4s de budget; consumidos 10800s
  perform assert_eq('14.2 budget do mes', b.budget_segundos, 2678.4::numeric);
  perform assert_eq('14.3 consumido', b.consumido_segundos, 10800.0::numeric);
  perform assert_eq('14.4 estourou o budget', (b.budget_usado_pct > 100), true);
  perform assert_eq('14.5 restante negativo', (b.restante_segundos < 0), true);

  select count(*) into n from daily_downtime(cid, 30);
  perform assert_eq('14.6 daily_downtime devolve 30 linhas', n, 30);
end $$;

-- =====================================================================
-- 15. Curadoria: discovery_inbox / publish / public_components
-- =====================================================================
do $$
declare n int;
begin
  select count(*) into n from discovery_inbox;
  perform assert_eq('15.1 tudo descoberto esta na fila', (n >= 4), true);

  select count(*) into n from public_components;
  perform assert_eq('15.2 pagina publica comeca vazia', n, 0);

  perform publish_component('api-tarefa-megas','producao','API Tarefa Megas');

  select count(*) into n from public_components;
  perform assert_eq('15.3 publicou um', n, 1);

  select count(*) into n from public_components where slug='api-fechamento';
  perform assert_eq('15.4 validacao nao vaza para o publico', n, 0);

  select count(*) into n from discovery_inbox where slug='api-tarefa-megas' and environment='producao';
  perform assert_eq('15.5 saiu da fila', n, 0);
end $$;

-- =====================================================================
-- 16. merge_components com incidente aberto colidindo
-- =====================================================================
do $$
declare a bigint; b bigint; r record; ini timestamptz; oc int;
begin
  insert into components (slug,name,environment,created_at)
  values ('dup-origem','Origem','producao','2026-01-01') returning id into a;
  insert into components (slug,name,environment,created_at)
  values ('dup-destino','Destino','producao','2026-01-01') returning id into b;

  -- MESMO fingerprint aberto nos dois: mover cru violaria incidents_open_uq
  insert into incidents (component_id,fingerprint,impact,title,started_at,last_seen_at,occurrences)
  values (a,'fp-x','major_outage','fora','2026-08-15 08:00-03','2026-08-15 08:30-03',3),
         (b,'fp-x','degraded','lento','2026-08-15 09:00-03','2026-08-15 09:10-03',2);
  -- e um que nao colide
  insert into incidents (component_id,fingerprint,impact,title,started_at,resolved_at,last_seen_at)
  values (a,'fp-y','degraded','outro','2026-08-15 07:00-03','2026-08-15 07:30-03','2026-08-15 07:30-03');

  select * into r from merge_components('dup-origem','producao','dup-destino','producao');
  perform assert_eq('16.1 um fundido', r.incidentes_fundidos, 1);
  perform assert_eq('16.2 um movido',   r.incidentes_movidos, 1);

  select started_at, occurrences into ini, oc
    from incidents where component_id=b and fingerprint='fp-x';
  perform assert_eq('16.3 vale o inicio mais antigo', ini, '2026-08-15 08:00-03'::timestamptz);
  perform assert_eq('16.4 ocorrencias somadas', oc, 5);
  perform assert_eq('16.5 origem apagada',
    (select count(*) from components where slug='dup-origem'), 0::bigint);
  perform assert_eq('16.6 slug antigo virou apelido',
    (select component_id from component_aliases where alias='dup-origem'), b);
end $$;

-- =====================================================================
-- 17. Relatorios
-- =====================================================================
do $$
declare n int; r record;
begin
  select count(*) into n from timeline_do_dia('2026-08-21');
  perform assert_eq('17.1 timeline do dia 21 tem eventos', (n > 0), true);

  select count(*) into n from timeline_do_dia('2026-08-11')
   where tipo = 'queda_em_curso';
  perform assert_eq('17.2 queda que veio de ontem aparece', n, 1);

  select count(*) into n from resumo_do_dia('2026-08-10');
  perform assert_eq('17.3 resumo lista os componentes', (n > 0), true);

  select * into r from resumo_do_dia('2026-08-12') where slug='teste-deploy';
  perform assert_eq('17.4 deploy fora do downtime', r.downtime_segundos, 0::numeric);
  perform assert_eq('17.5 mas contado como queda em deploy', r.quedas_em_deploy, 1::bigint);
  perform assert_eq('17.6 e nao como queda de SLA', r.quedas, 0::bigint);

  perform assert_eq('17.7 ranking existe',
    (select count(*) >= 0 from ranking_warnings_30d), true);
end $$;

-- =====================================================================
-- 18. Subir o limiar reclassifica Degraded (Decisao em aberto no.1)
-- =====================================================================
do $$
declare r record;
begin
  update sla_settings set value='5' where key='incident_threshold';
  perform assert_eq('18.1 limiar subiu', incident_threshold(), 5);

  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk','occurredAt','2026-08-22T10:00:00-03:00',
    'environmentName','Api-Limiar-env','applicationName','Api-Limiar-Producao',
    'fromState','Ok','toState','Degraded',
    'message','Environment health has transitioned from Ok to Degraded.',
    'notificationProcessId','npid-10'));
  perform assert_eq('18.2 Degraded vira registro, nao incidente',
    r.action, 'registrado_sem_incidente');

  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk','occurredAt','2026-08-22T10:05:00-03:00',
    'environmentName','Api-Limiar-env','applicationName','Api-Limiar-Producao',
    'fromState','Degraded','toState','Severe',
    'message','Environment health has transitioned from Degraded to Severe.',
    'notificationProcessId','npid-11'));
  perform assert_eq('18.3 Severe ainda abre', r.action, 'opened');

  perform assert_eq('18.4 Degraded entra no ranking de warnings',
    (select fora_de_deploy from ranking_warnings_30d where slug='api-limiar'), 1::bigint);

  update sla_settings set value='4' where key='incident_threshold';
end $$;

-- =====================================================================
-- 19. "No Data" -- cegueira NAO e melhora  (achado nos dados reais)
-- =====================================================================
do $$
declare r record; i record; n int;
begin
  perform assert_eq('19.1 "No Data" com espaco vira sev 2', eb_severity('No Data'), 2);
  perform assert_eq('19.2 e as variantes tambem', eb_severity('NoData'), eb_severity('no_data'));

  -- ambiente cai de vez
  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk','occurredAt','2026-08-23T08:00:00-03:00',
    'environmentName','Api-Cego-env','applicationName','Api-Cego-Producao',
    'fromState','Ok','toState','Severe',
    'message','Environment health has transitioned from Ok to Severe. 100.0 % of the requests are failing.',
    'notificationProcessId','npid-20'));
  perform assert_eq('19.3 Severe abre queda total', r.component_status::text, 'major_outage');

  -- e a AWS perde a visao
  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk','occurredAt','2026-08-23T08:05:00-03:00',
    'environmentName','Api-Cego-env','applicationName','Api-Cego-Producao',
    'fromState','Severe','toState','No Data',
    'message','Environment health has transitioned from Severe to No Data.',
    'notificationProcessId','npid-21'));
  perform assert_eq('19.4 registrado como cegueira', r.action, 'cego_com_incidente_aberto');
  perform assert_eq('19.5 componente NAO melhorou', r.component_status::text, 'major_outage');

  select * into i from incidents where id = r.incident_id;
  perform assert_eq('19.6 incidente segue aberto', i.resolved_at, null::timestamptz);
  perform assert_eq('19.7 peso 1,0 preservado -- nao virou degraded', i.impact::text, 'major_outage');

  select count(*) into n from monitor_signals ms
    join components c on c.id = ms.component_id where c.slug = 'api-cego';
  perform assert_eq('19.8 foi para monitor_signals', n, 1);

  -- so o Ok de verdade fecha
  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk','occurredAt','2026-08-23T08:20:00-03:00',
    'environmentName','Api-Cego-env','applicationName','Api-Cego-Producao',
    'fromState','No Data','toState','Ok',
    'message','Environment health has transitioned from No Data to Ok.',
    'notificationProcessId','npid-22'));
  perform assert_eq('19.9 Ok fecha', r.action, 'resolved');
  perform assert_eq('19.10 duracao inteira preservada',
    (select extract(epoch from (resolved_at - started_at))::int from incidents where id = r.incident_id),
    1200);
end $$;

-- =====================================================================
-- 20. Marco de deploy sem transicao de saude
-- =====================================================================
do $$
declare r record; n int;
begin
  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk','eventType','deploy',
    'occurredAt','2026-08-23T09:00:00-03:00',
    'environmentName','Api-Cego-env','applicationName','Api-Cego-Producao',
    'message','New application version was deployed to running EC2 instances.',
    'notificationProcessId','npid-23'));
  perform assert_eq('20.1 registrado, nao descartado', r.action, 'deploy_registrado');
  perform assert_eq('20.2 nao abre incidente', r.incident_id, null::bigint);
  perform assert_eq('20.3 nao mexe no status', r.component_status::text, 'operational');

  select count(*) into n from health_events he
    join components c on c.id = he.component_id
   where c.slug='api-cego' and he.severity is null and he.is_deploy;
  perform assert_eq('20.4 fica na trilha marcado como deploy', n, 1);

  select count(*) into n from timeline_do_dia('2026-08-23') where slug='api-cego';
  perform assert_eq('20.5 aparece na linha do tempo do dia', (n >= 4), true);
end $$;

-- =====================================================================
-- 21. Oscilacao Warning<->Degraded  (episodio real dos assuntos: 29 saltos)
--
-- O episodio mais longo dos dados: Ok->Degraded, depois seis idas e voltas
-- Degraded<->Warning, e finalmente Warning->Ok. Contar cada salto como uma
-- queda daria 7 incidentes de poucos minutos e um MTTR lindo e falso.
-- =====================================================================
do $$
declare r record; inc record; n int; k int;
begin
  perform ingest_health(jsonb_build_object(
    'source','beanstalk','occurredAt','2026-08-23T10:00:00-03:00',
    'environmentName','Api-Oscila-env','applicationName','Api-Oscila-Producao',
    'fromState','Ok','toState','Degraded',
    'message','Environment health has transitioned from Ok to Degraded. 20.0 % of the requests are failing with HTTP 5xx.',
    'notificationProcessId','npid-osc-0'));

  for k in 1..6 loop
    perform ingest_health(jsonb_build_object(
      'source','beanstalk',
      'occurredAt', (timestamptz '2026-08-23T10:00:00-03:00' + make_interval(mins => k*10 - 5)),
      'environmentName','Api-Oscila-env','applicationName','Api-Oscila-Producao',
      'fromState','Degraded','toState','Warning',
      'message','Environment health has transitioned from Degraded to Warning.',
      'notificationProcessId', 'npid-osc-w' || k));
    perform ingest_health(jsonb_build_object(
      'source','beanstalk',
      'occurredAt', (timestamptz '2026-08-23T10:00:00-03:00' + make_interval(mins => k*10)),
      'environmentName','Api-Oscila-env','applicationName','Api-Oscila-Producao',
      'fromState','Warning','toState','Degraded',
      'message','Environment health has transitioned from Warning to Degraded. 18.0 % of the requests are failing.',
      'notificationProcessId', 'npid-osc-d' || k));
  end loop;

  select * into r from ingest_health(jsonb_build_object(
    'source','beanstalk','occurredAt','2026-08-23T11:10:00-03:00',
    'environmentName','Api-Oscila-env','applicationName','Api-Oscila-Producao',
    'fromState','Warning','toState','Ok',
    'message','Environment health has transitioned from Warning to Ok.',
    'notificationProcessId','npid-osc-fim'));
  perform assert_eq('21.1 fecha no Ok final', r.action, 'resolved');

  select count(*) into n from incidents x join components c on c.id=x.component_id
   where c.slug='api-oscila';
  perform assert_eq('21.2 UM incidente, nao sete', n, 1);

  select x.* into inc from incidents x join components c on c.id=x.component_id
   where c.slug='api-oscila';
  perform assert_eq('21.3 duracao real: 70 min de ponta a ponta',
    extract(epoch from (inc.resolved_at - inc.started_at))::int, 4200);
  perform assert_eq('21.4 impacto final = o pior visto', inc.impact::text, 'partial_outage');

  select count(*) into n from health_events he join components c on c.id=he.component_id
   where c.slug='api-oscila';
  perform assert_eq('21.5 mas a trilha guarda os 14 saltos', n, 14);
end $$;

-- =====================================================================
-- 22. components.status acompanha incidents mexido POR SQL
--
-- Achado em producao: um incidente de teste apagado com DELETE deixou o
-- componente preso em major_outage sem nenhuma queda aberta -- e a pagina
-- mostrou "tudo operacional" pintado de vermelho.
-- =====================================================================
do $$
declare cid bigint; iid bigint;
begin
  insert into components (slug,name,environment,created_at)
  values ('teste-gatilho','Gatilho','producao', now()-interval '10 days')
  returning id into cid;

  perform assert_eq('22.1 nasce operacional',
    (select status::text from components where id=cid), 'operational');

  -- INSERT direto, sem passar por ingest_health
  insert into incidents (component_id,fingerprint,impact,title,started_at,last_seen_at)
  values (cid,'fp-g','major_outage','fora', now()-interval '5 minutes', now())
  returning id into iid;
  perform assert_eq('22.2 INSERT por SQL ja reflete',
    (select status::text from components where id=cid), 'major_outage');

  -- UPDATE do impacto
  update incidents set impact='degraded' where id=iid;
  perform assert_eq('22.3 UPDATE de impacto reflete',
    (select status::text from components where id=cid), 'degraded');

  -- fechar na mao
  update incidents set resolved_at=now() where id=iid;
  perform assert_eq('22.4 fechar por SQL normaliza',
    (select status::text from components where id=cid), 'operational');

  -- reabrir volta a pintar -- com o impacto ATUAL (degraded, do 22.3),
  -- nao com o que o incidente tinha quando nasceu
  update incidents set resolved_at=null where id=iid;
  perform assert_eq('22.5 reabrir volta a pintar, no impacto atual',
    (select status::text from components where id=cid), 'degraded');
end $$;

do $$
declare cid bigint;
begin
  select id into cid from components where slug='teste-gatilho';
  update incidents set impact='major_outage' where component_id=cid;

  delete from incidents where component_id=cid;
  perform assert_eq('22.6 DELETE normaliza o componente',
    (select status::text from components where id=cid), 'operational');
end $$;

-- dois abertos: apagar UM nao pode normalizar o componente
do $$
declare cid bigint; a bigint; b bigint;
begin
  select id into cid from components where slug='teste-gatilho';
  insert into incidents (component_id,fingerprint,impact,title,started_at,last_seen_at)
  values (cid,'fp-h','major_outage','fora',now()-interval '9 minutes',now()) returning id into a;
  insert into incidents (component_id,fingerprint,impact,title,started_at,last_seen_at)
  values (cid,'fp-i','degraded','lento',now()-interval '8 minutes',now()) returning id into b;
  perform assert_eq('22.7 o pior vence', (select status::text from components where id=cid), 'major_outage');

  delete from incidents where id=a;
  perform assert_eq('22.8 apagou o pior, sobra o outro',
    (select status::text from components where id=cid), 'degraded');

  delete from incidents where id=b;
  perform assert_eq('22.9 apagou o ultimo, normaliza',
    (select status::text from components where id=cid), 'operational');
end $$;

select '=========  TODOS OS TESTES PASSARAM  =========' as resultado;


