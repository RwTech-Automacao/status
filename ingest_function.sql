-- =====================================================================
--  ingest_function.sql  ·  ingest_alarm(jsonb) -- correlacao atomica
--  Executar DEPOIS de discovery.sql.
--
--  Decisao no.5: abrir/fechar, deduplicar e auto-cadastrar acontecem DENTRO
--  de uma funcao, nao espalhados em nos do n8n. Em nos encadeados, dois
--  alarmes no mesmo segundo (o normal numa queda) se atropelam entre o
--  "existe incidente aberto?" e o "cria incidente". Aqui ha
--  pg_advisory_xact_lock e tudo vive na mesma transacao.
--
--  Formato de entrada (produzido por parser.js / n8n-code-node.js):
--  {
--    "source":       "cloudwatch",
--    "state":        "ALARM" | "OK" | "INSUFFICIENT_DATA",
--    "fingerprint":  "RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao",
--    "occurredAt":   "2026-08-24T15:11:31Z",
--    "org":          "RWTech",
--    "platform":     "ElasticBeanstalk",
--    "metric":       "EnvironmentHealth",
--    "resource":     "api-tarefa-megas-producao",
--    "application":  null,
--    "component":    "api-tarefa-megas",   -- opcional, o parser ja separou
--    "environment":  "producao",           -- opcional
--    "name":         "API Tarefa Megas",   -- opcional, nome de exibicao
--    "title":        "EnvironmentHealth em estado de alarme",
--    "reason":       "Threshold Crossed: ...",
--    "deliveryHash": "sha256:..."          -- opcional, dedup de reentrega
--  }
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Metrica -> gravidade  (Decisao no.4)
--
-- EnvironmentHealth no chao = queda total.
-- Latency/CPU alta = degradacao.
-- Se tudo virasse "fora do ar", o uptime despencaria por um pico de CPU
-- que ninguem sentiu.
--
-- Tabela e nao CASE: metrica nova aparece o tempo todo, e classificar
-- errado distorce o SLA. INSERT resolve; deploy de funcao nao deveria.
-- ---------------------------------------------------------------------
create table if not exists metric_impact_rules (
  pattern     text          primary key,   -- regex, casado com ~* (sem case)
  impact      service_state not null,
  priority    int           not null default 100,  -- menor vence
  description text
);

insert into metric_impact_rules (pattern, impact, priority, description) values
  ('environment.?health',            'major_outage',   10, 'Saude do ambiente no chao: o servico nao responde'),
  ('status.?check.?failed',          'major_outage',   10, 'Instancia nao passa no health check da EC2'),
  ('healthy.?host.?count',           'major_outage',   15, 'Zero hosts saudaveis atras do balanceador'),
  ('service.?down|instance.?severe', 'major_outage',   15, null),

  ('unhealthy.?host',                'partial_outage', 30, 'Parte da frota fora'),
  ('5xx|httpcode.*5',                'partial_outage', 30, 'Erros de servidor: parte das requisicoes falha'),
  ('target.?connection.?error',      'partial_outage', 35, null),
  ('instance.?degraded',             'partial_outage', 35, null),
  ('queue.*(depth|age|old)',         'partial_outage', 40, 'Fila acumulando: processamento parado'),

  ('latency|response.?time|duration','degraded',       60, 'Lento, mas respondendo'),
  ('cpu|memory|mem.?util|swap',      'degraded',       60, null),
  ('disk|storage|iops|volume',       'degraded',       65, null),
  ('connection|throttl|concurrent',  'degraded',       65, null),

  ('maintenance|janela.?de.?manuten','maintenance',     5, 'Manutencao anunciada nao queima SLA')
on conflict (pattern) do nothing;

-- ---------------------------------------------------------------------
-- impact_from_metric
--
-- Sem regra que case: 'partial_outage'. Escolha deliberada -- errar para
-- MENOS faria o SLA parecer melhor do que e, que e o erro perigoso.
-- Errar para mais aparece no relatorio e alguem cadastra a regra.
-- ---------------------------------------------------------------------
create or replace function impact_from_metric(p_metric text)
returns service_state
language sql stable as $fn$
  select coalesce(
    (select r.impact
       from metric_impact_rules r
      where coalesce(p_metric, '') ~* r.pattern
      order by r.priority, r.pattern
      limit 1),
    'partial_outage'::service_state
  );
$fn$;

-- ---------------------------------------------------------------------
-- 2. is_duplicate_delivery
--
-- SNS reentrega, n8n reexecuta. Sem deliveryHash a checagem e pulada --
-- perder um evento por falta de hash e pior do que processar duas vezes
-- (o indice incidents_open_uq ja absorve a repeticao).
-- ---------------------------------------------------------------------
create or replace function is_duplicate_delivery(
  p_hash    text,
  p_source  text,
  p_payload jsonb
) returns boolean
language plpgsql as $fn$
declare
  v_inserido text;
begin
  if p_hash is null or p_hash = '' then
    return false;
  end if;

  insert into webhook_deliveries (delivery_hash, source, payload)
  values (p_hash, coalesce(p_source, 'unknown'), p_payload)
  on conflict (delivery_hash) do nothing
  returning delivery_hash into v_inserido;

  return v_inserido is null;
end $fn$;

-- ---------------------------------------------------------------------
-- 3. open_or_extend_incident -- a correlacao propriamente dita
--
-- Reusada por ingest_alarm (CloudWatch) e por ingest_health (Beanstalk),
-- porque as duas trilhas tem exatamente o mesmo problema de pareamento.
--
-- Ordem de tentativa:
--   a) existe incidente ABERTO com esse fingerprint  -> atualiza
--   b) existe um resolvido dentro da janela de flap  -> REABRE o mesmo
--   c) nenhum dos dois                               -> abre novo
--
-- (b) e o tratamento de flapping: cai, resolve, cai de novo em 20s. Contar
-- como duas quedas de 30s deixa o MTTR lindo e mentiroso -- a realidade e
-- uma queda so, intermitente.
-- ---------------------------------------------------------------------
create or replace function open_or_extend_incident(
  p_component    bigint,
  p_fingerprint  text,
  p_impact       service_state,
  p_title        text,
  p_detail       text,
  p_source       text,
  p_occurred_at  timestamptz,
  p_excluded     boolean default false,
  p_excl_reason  text    default null
) returns table (action text, incident_id bigint)
language plpgsql as $fn$
declare
  v_id        bigint;
  v_inicio    timestamptz;
  v_flap      int;
begin
  v_flap := setting_num('flap_window_seconds', 120)::int;

  -- (a) ja existe aberto
  select i.id, i.started_at into v_id, v_inicio
    from incidents i
   where i.component_id = p_component
     and i.fingerprint  = p_fingerprint
     and i.resolved_at is null
   for update;

  if v_id is not null then
    update incidents i
       set -- webhook atrasado / fora de ordem: o inicio real e o mais antigo
           started_at   = least(i.started_at, p_occurred_at),
           last_seen_at = greatest(i.last_seen_at, p_occurred_at),
           occurrences  = i.occurrences + 1,
           -- so escala: uma queda que virou major nao volta a degraded
           -- porque o alarme leve reenviou
           impact       = greatest(i.impact, p_impact),
           detail       = coalesce(p_detail, i.detail),
           -- se ja contava para o SLA, continua contando
           excluded_from_sla = i.excluded_from_sla and p_excluded,
           exclusion_reason  = case when i.excluded_from_sla and p_excluded
                                    then coalesce(i.exclusion_reason, p_excl_reason)
                                    else null end
     where i.id = v_id;

    return query select 'updated'::text, v_id;
    return;
  end if;

  -- (b) resolvido ha pouco -> e a mesma queda piscando
  select i.id into v_id
    from incidents i
   where i.component_id = p_component
     and i.fingerprint  = p_fingerprint
     and i.resolved_at is not null
     and i.resolved_at >= p_occurred_at - make_interval(secs => v_flap)
   order by i.resolved_at desc
   limit 1
   for update;

  if v_id is not null then
    update incidents i
       set resolved_at  = null,
           started_at   = least(i.started_at, p_occurred_at),
           last_seen_at = greatest(i.last_seen_at, p_occurred_at),
           occurrences  = i.occurrences + 1,
           impact       = greatest(i.impact, p_impact),
           detail       = coalesce(p_detail, i.detail),
           excluded_from_sla = i.excluded_from_sla and p_excluded,
           exclusion_reason  = case when i.excluded_from_sla and p_excluded
                                    then coalesce(i.exclusion_reason, p_excl_reason)
                                    else null end
     where i.id = v_id;

    return query select 'reopened'::text, v_id;
    return;
  end if;

  -- (c) queda nova
  insert into incidents (
    component_id, fingerprint, impact, title, detail, source,
    started_at, last_seen_at, excluded_from_sla, exclusion_reason
  ) values (
    p_component, p_fingerprint, p_impact, p_title, p_detail,
    coalesce(p_source, 'unknown'),
    p_occurred_at, p_occurred_at, p_excluded,
    case when p_excluded then coalesce(p_excl_reason, 'excluido do SLA') end
  )
  returning id into v_id;

  return query select 'opened'::text, v_id;
end $fn$;

-- ---------------------------------------------------------------------
-- 4. close_incident
--
-- resolved_at = greatest(evento, started_at): um OK que chega com timestamp
-- anterior ao inicio (relogio torto, entrega fora de ordem) geraria
-- duracao negativa e estouraria incidents_window.
-- ---------------------------------------------------------------------
create or replace function close_incident(
  p_component   bigint,
  p_fingerprint text,
  p_occurred_at timestamptz
) returns table (action text, incident_id bigint)
language plpgsql as $fn$
declare
  v_id bigint;
begin
  select i.id into v_id
    from incidents i
   where i.component_id = p_component
     and i.fingerprint  = p_fingerprint
     and i.resolved_at is null
   for update;

  if v_id is null then
    return query select 'noop_sem_incidente_aberto'::text, null::bigint;
    return;
  end if;

  update incidents i
     set resolved_at  = greatest(p_occurred_at, i.started_at),
         last_seen_at = greatest(i.last_seen_at, p_occurred_at)
   where i.id = v_id;

  return query select 'resolved'::text, v_id;
end $fn$;

-- ---------------------------------------------------------------------
-- 5. ingest_alarm(jsonb) -- ponto de entrada do formato CloudWatch
--
-- Um parametro so, jsonb. O no Postgres do n8n manda
--   select * from ingest_alarm($1::jsonb)
-- com {{ JSON.stringify($json) }}. Placeholders posicionais e onde o n8n
-- quebra silenciosamente.
-- ---------------------------------------------------------------------
create or replace function ingest_alarm(p jsonb)
returns table (
  action           text,
  incident_id      bigint,
  component_id     bigint,
  component_slug   text,
  component_status service_state,
  detail           text
)
language plpgsql as $fn$
declare
  v_state    text;
  v_fp       text;
  v_at       timestamptz;
  v_metric   text;
  v_resource text;
  v_comp     bigint;
  v_slug     text;
  v_impact   service_state;
  v_action   text;
  v_inc      bigint;
  v_status   service_state;
  v_title    text;
begin
  ---------------------------------------------------------------- entrada
  v_state    := upper(coalesce(p->>'state', ''));
  v_fp       := nullif(trim(coalesce(p->>'fingerprint', '')), '');
  v_metric   := p->>'metric';
  v_resource := coalesce(p->>'resource', p->>'component', v_fp);

  -- started_at vem do EVENTO, nunca de now(). Fallback so quando a fonte
  -- realmente nao mandou hora (Telegram sem timestamp no corpo).
  v_at := coalesce((p->>'occurredAt')::timestamptz, now());

  if v_fp is null then
    return query select 'ignorado_sem_fingerprint'::text, null::bigint, null::bigint,
                        null::text, null::service_state,
                        'sem fingerprint nao ha pareamento ALARM/OK'::text;
    return;
  end if;

  if v_state not in ('ALARM','OK','INSUFFICIENT_DATA') then
    return query select 'ignorado_estado_desconhecido'::text, null::bigint, null::bigint,
                        null::text, null::service_state,
                        format('state=%s', coalesce(p->>'state','<null>'))::text;
    return;
  end if;

  ---------------------------------------------------------------- dedup
  if is_duplicate_delivery(p->>'deliveryHash', coalesce(p->>'source','cloudwatch'), p) then
    return query select 'duplicado'::text, null::bigint, null::bigint,
                        null::text, null::service_state,
                        'deliveryHash ja processado'::text;
    return;
  end if;

  ---------------------------------------------------------------- travas
  -- Namespace 1 = alerta. Serializa dois eventos do MESMO alarme chegando
  -- no mesmo segundo, que e exatamente o que acontece numa queda.
  perform pg_advisory_xact_lock(1, hashtext(v_fp));

  ---------------------------------------------------------------- componente
  v_comp := resolve_component(
              p_raw       => v_resource,
              p_raw_alt   => p->>'application',
              p_env_hint  => p->>'environment',
              p_name_hint => p->>'name',
              p_slug_hint => p->>'component');

  -- Namespace 2 = componente. Mesma trava usada por merge_components().
  perform pg_advisory_xact_lock(2, v_comp::int);

  select c.slug into v_slug from components c where c.id = v_comp;

  ---------------------------------------------------------------- despacho
  if v_state = 'INSUFFICIENT_DATA' then
    -- Decisao no.6: nao e queda, e CEGUEIRA. O alarme parou de receber
    -- metrica. Nao abre nem fecha incidente -- so registra que o monitor
    -- ficou sem visao, para nao esconder monitor quebrado.
    insert into monitor_signals (component_id, fingerprint, signal, occurred_at, detail, raw)
    values (v_comp, v_fp, 'insufficient_data', v_at, p->>'reason', p);

    select c.status into v_status from components c where c.id = v_comp;

    return query select 'monitor_cego'::text, null::bigint, v_comp, v_slug, v_status,
                        'sem metrica; incidente nao foi tocado'::text;
    return;

  elsif v_state = 'ALARM' then
    v_impact := impact_from_metric(v_metric);
    v_title  := coalesce(
                  nullif(trim(coalesce(p->>'title','')), ''),
                  format('%s em alarme', coalesce(v_metric, 'Alarme')));

    select r.action, r.incident_id into v_action, v_inc
      from open_or_extend_incident(
             p_component   => v_comp,
             p_fingerprint => v_fp,
             p_impact      => v_impact,
             p_title       => v_title,
             p_detail      => p->>'reason',
             p_source      => coalesce(p->>'source','cloudwatch'),
             p_occurred_at => v_at) r;

  else  -- OK
    select r.action, r.incident_id into v_action, v_inc
      from close_incident(v_comp, v_fp, v_at) r;
  end if;

  ---------------------------------------------------------------- status
  -- So volta a 'operational' se NENHUM incidente aberto sobrou.
  v_status := refresh_component_status(v_comp);

  return query select v_action, v_inc, v_comp, v_slug, v_status,
                      case when v_metric is not null
                            and not exists (select 1 from metric_impact_rules r
                                             where v_metric ~* r.pattern)
                           then format('metrica "%s" sem regra: assumido partial_outage', v_metric)
                      end::text;
end $fn$;

comment on function ingest_alarm(jsonb) is
  'Ponto de entrada CloudWatch. Uso no n8n: select * from ingest_alarm($1::jsonb)';
