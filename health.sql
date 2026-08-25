-- =====================================================================
--  health.sql  ·  Trilha de eventos de saude + ingest_health(jsonb)
--  Executar DEPOIS de ingest_function.sql. Ultimo arquivo da ordem.
--
--  DUAS TRILHAS QUE NAO SE MISTURAM:
--
--    health_events  -> TODA transicao de estado, inclusive Warning e deploy.
--                      Serve para relatorio diario e ranking de warnings.
--    incidents      -> so o que representa queda real. Serve para o SLA.
--
--  Misturar e o erro classico: ou o SLA fica poluido com deploy e warning,
--  ou se perde o historico que mostra qual API esta sofrendo.
--
--  Formato de entrada (Elastic Beanstalk, produzido por n8n-code-beanstalk.js):
--  {
--    "source":                "beanstalk",
--    "occurredAt":            "2026-08-24T15:11:31Z",   -- do "Timestamp:" do corpo
--    "environmentName":       "Api-Fechamento-env",
--    "applicationName":       "Api-Fechamento-Validacao",
--    "fromState":             "Info",
--    "toState":               "Degraded",
--    "message":               "Environment health has transitioned from Info to Degraded. ...",
--    "notificationProcessId": "...",
--    "deliveryHash":          "sha256:..."
--  }
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Limiar de incidente
--
-- Decisao em aberto no.1: se na pratica Degraded for quase sempre ruido de
-- deploy, subir para 5 e tratar Degraded como registro, igual ao Warning.
-- Como decidir: contar quantos Degraded acontecem FORA de deploy --
-- ranking_warnings_30d e degraded_fora_de_deploy_30d respondem isso.
--
-- E um UPDATE, nao um deploy:
--   update sla_settings set value = '5' where key = 'incident_threshold';
-- ---------------------------------------------------------------------
insert into sla_settings (key, value, description) values
  ('incident_threshold', '4',
   'Severidade minima que ABRE incidente. 4 = Degraded. Subir para 5 faz so Severe abrir.')
on conflict (key) do nothing;

create or replace function incident_threshold()
returns int
language sql stable as $fn$
  select setting_num('incident_threshold', 4)::int;
$fn$;

-- ---------------------------------------------------------------------
-- 2. Maquina de estados do Beanstalk
--
-- Aqui NAO existe par ALARM/OK. O ambiente anda numa escala e o incidente e
-- deduzido do cruzamento do limiar -- para baixo abre, de volta ao topo fecha.
-- ---------------------------------------------------------------------
-- Atencao ao "No Data": a AWS escreve COM ESPACO. Normalizamos separadores
-- antes de comparar -- 'No Data', 'no_data' e 'NoData' caem todos em 2.
create or replace function eb_severity(p_estado text)
returns int
language sql immutable parallel safe as $fn$
  select case regexp_replace(lower(trim(coalesce(p_estado, ''))), '[\s_-]+', '', 'g')
           when 'ok'        then 0
           when 'info'      then 1
           when 'pending'   then 1
           when 'unknown'   then 2
           when 'nodata'    then 2
           when 'suspended' then 2
           when 'warning'   then 3
           when 'degraded'  then 4
           when 'severe'    then 5
           else null
         end;
$fn$;

create or replace function eb_state_label(p_sev int)
returns text
language sql immutable parallel safe as $fn$
  select case p_sev
           when 0 then 'Ok' when 1 then 'Info' when 2 then 'Sem dados'
           when 3 then 'Warning' when 4 then 'Degraded' when 5 then 'Severe'
         end;
$fn$;

-- Severidade -> impacto. Degraded vale partial_outage (peso 0,5) e nao
-- major: o ambiente responde, mal.
create or replace function impact_from_severity(p_sev int)
returns service_state
language sql immutable parallel safe as $fn$
  select case
           when p_sev >= 5 then 'major_outage'
           when p_sev  = 4 then 'partial_outage'
           when p_sev in (2,3) then 'degraded'
           else 'operational'
         end::service_state;
$fn$;

-- ---------------------------------------------------------------------
-- 3. looks_like_deploy  (Decisao no.1)
--
-- Degradacao durante deploy e ESPERADA. As frases denunciam. O incidente
-- continua sendo criado e fica no historico -- descartar seria mais simples,
-- mas perderia a visibilidade de "esse deploy derrubou o ambiente por 4 min".
-- So o excluded_from_sla muda.
-- ---------------------------------------------------------------------
create table if not exists deploy_patterns (
  pattern     text primary key,
  description text
);

insert into deploy_patterns (pattern, description) values
  ('configuration update',            'Mudanca de configuracao do ambiente'),
  ('deployment\s+\d+',                '"...during deployment 42"'),
  ('incorrect application version',   'Instancia ainda com a versao antiga'),
  ('application update',              null),
  ('environment update',              null),
  ('command execution',               'Comando de deploy em curso'),
  ('deploying|deployment in progress',null),
  ('new application version',         'Aviso de deploy sem transicao de saude junto'),
  ('was deployed to running',         null)
on conflict (pattern) do nothing;

create or replace function looks_like_deploy(p_mensagem text)
returns boolean
language sql stable as $fn$
  select exists (
    select 1 from deploy_patterns d
     where coalesce(p_mensagem, '') ~* d.pattern
  );
$fn$;

-- ---------------------------------------------------------------------
-- 4. health_events -- a trilha completa
-- ---------------------------------------------------------------------
create table if not exists health_events (
  id                      bigint generated always as identity primary key,
  component_id            bigint      references components(id) on delete cascade,
  fingerprint             text        not null,
  source                  text        not null,
  from_state              text,
  to_state                text,
  severity                int,
  occurred_at             timestamptz not null,
  is_deploy               boolean     not null default false,
  opened_incident         boolean     not null default false,
  incident_id             bigint      references incidents(id) on delete set null,
  message                 text,
  raw                     jsonb,
  notification_process_id text,
  created_at              timestamptz not null default now()
);

-- Dedup natural do Beanstalk: o proprio NotificationProcessId.
create unique index if not exists health_events_npid_uq
  on health_events (notification_process_id)
  where notification_process_id is not null;

create index if not exists health_events_time_idx
  on health_events (occurred_at desc);

create index if not exists health_events_component_time_idx
  on health_events (component_id, occurred_at desc);

create index if not exists health_events_severity_idx
  on health_events (severity, occurred_at desc);

-- ---------------------------------------------------------------------
-- 5. ingest_health(jsonb) -- a UNICA porta de entrada
--
-- O no Postgres do n8n chama so isto:
--   select * from ingest_health($1::jsonb)   com  {{ JSON.stringify($json) }}
--
-- Um parametro so. Placeholder posicional e onde o n8n quebra em silencio.
--
-- Despacha por formato: payload com state ALARM/OK/INSUFFICIENT_DATA e
-- CloudWatch e vai para ingest_alarm(); o resto e maquina de estados do
-- Beanstalk e e resolvido aqui.
-- ---------------------------------------------------------------------
create or replace function ingest_health(p jsonb)
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
  v_src      text;
  v_state    text;
  v_at       timestamptz;
  v_env_name text;
  v_app_name text;
  v_msg      text;
  v_npid     text;
  v_fp       text;
  v_sev      int;
  v_from_sev int;
  v_deploy   boolean;
  v_excl     boolean;
  v_reason   text;
  v_comp     bigint;
  v_slug     text;
  v_impact   service_state;
  v_action   text;
  v_inc      bigint;
  v_status   service_state;
  v_thr      int;
  v_marco_deploy boolean;
  v_r        record;
begin
  v_src   := lower(coalesce(p->>'source', ''));
  v_state := upper(coalesce(p->>'state', ''));

  ------------------------------------------------------------------
  -- 5.1 Formato CloudWatch: delega, e depois espelha em health_events
  --     para o relatorio diario enxergar as duas fontes.
  ------------------------------------------------------------------
  if v_state in ('ALARM','OK','INSUFFICIENT_DATA') or v_src = 'cloudwatch' then

    select * into v_r from ingest_alarm(p);

    if v_r.component_id is not null then
      insert into health_events (
        component_id, fingerprint, source, from_state, to_state, severity,
        occurred_at, is_deploy, opened_incident, incident_id, message, raw
      ) values (
        v_r.component_id,
        coalesce(p->>'fingerprint', 'cw:desconhecido'),
        coalesce(p->>'source','cloudwatch'),
        null,
        initcap(lower(v_state)),
        case v_state
          when 'OK'                then 0
          when 'INSUFFICIENT_DATA' then 2
          else case (select impact_from_metric(p->>'metric'))
                 when 'major_outage'   then 5
                 when 'partial_outage' then 4
                 else 3
               end
        end,
        coalesce((p->>'occurredAt')::timestamptz, now()),
        false,
        v_r.action in ('opened','reopened'),
        v_r.incident_id,
        p->>'reason',
        p
      );
    end if;

    return query select v_r.action, v_r.incident_id, v_r.component_id,
                        v_r.component_slug, v_r.component_status, v_r.detail;
    return;
  end if;

  ------------------------------------------------------------------
  -- 5.2 Formato Beanstalk
  ------------------------------------------------------------------
  v_env_name := nullif(trim(coalesce(p->>'environmentName', p->>'environment_name', '')), '');
  v_app_name := nullif(trim(coalesce(p->>'applicationName', p->>'application_name', '')), '');
  v_msg      := p->>'message';
  v_npid     := nullif(trim(coalesce(p->>'notificationProcessId', '')), '');

  -- toState pode vir explicito do parser ou ser extraido da frase
  -- "Environment health has transitioned from Info to Degraded."
  v_sev := eb_severity(coalesce(
             p->>'toState',
             substring(coalesce(v_msg,'') from 'transitioned from\s+\w+\s+to\s+(\w+)')));

  v_from_sev := eb_severity(coalesce(
                  p->>'fromState',
                  substring(coalesce(v_msg,'') from 'transitioned from\s+(\w+)\s+to\s+')));

  if v_env_name is null then
    return query select 'ignorado_sem_ambiente'::text, null::bigint, null::bigint,
                        null::text, null::service_state,
                        'payload sem environmentName'::text;
    return;
  end if;

  -- "New application version was deployed to running EC2 instances." nao traz
  -- transicao de saude nenhuma -- e o unico aviso INEQUIVOCO de deploy no
  -- feed. Descartar joga fora a informacao que sustenta a Decisao no.1;
  -- guardamos como marco na trilha, sem tocar em incidente.
  v_marco_deploy := (lower(coalesce(p->>'eventType','')) = 'deploy')
                    or (v_sev is null and looks_like_deploy(v_msg));

  if v_sev is null and not v_marco_deploy then
    return query select 'ignorado_estado_desconhecido'::text, null::bigint, null::bigint,
                        null::text, null::service_state,
                        format('toState nao reconhecido: %s', coalesce(p->>'toState','<null>'))::text;
    return;
  end if;

  -- occurredAt vem do "Timestamp:" do CORPO do e-mail, nunca da data de
  -- recebimento: o atraso do IMAP inflaria o MTTR.
  v_at := coalesce((p->>'occurredAt')::timestamptz, now());

  ------------------------------------------------------------------ dedup
  if v_npid is not null
     and exists (select 1 from health_events he where he.notification_process_id = v_npid) then
    return query select 'duplicado'::text, null::bigint, null::bigint,
                        null::text, null::service_state,
                        'NotificationProcessId ja processado'::text;
    return;
  end if;

  if is_duplicate_delivery(p->>'deliveryHash', coalesce(p->>'source','beanstalk'), p) then
    return query select 'duplicado'::text, null::bigint, null::bigint,
                        null::text, null::service_state,
                        'deliveryHash ja processado'::text;
    return;
  end if;

  ------------------------------------------------------------------ travas
  -- Fingerprint = um fluxo de saude por ambiente. E o que faz a transicao
  -- para Degraded e a volta para Ok pertencerem ao mesmo incidente.
  v_fp := 'eb:health:' || coalesce(slugify(v_env_name), lower(v_env_name));

  perform pg_advisory_xact_lock(1, hashtext(v_fp));

  ------------------------------------------------------------------ componente
  -- O sufixo de ambiente pode estar no nome da APLICACAO e nao do environment:
  --   Api-Fechamento-env + Api-Fechamento-Validacao -> api-fechamento / validacao
  v_comp := resolve_component(
              p_raw       => v_env_name,
              p_raw_alt   => v_app_name,
              p_env_hint  => p->>'environment',
              p_name_hint => p->>'name');

  perform pg_advisory_xact_lock(2, v_comp::int);

  select c.slug into v_slug from components c where c.id = v_comp;

  ------------------------------------------------------------------ deploy?
  v_deploy := looks_like_deploy(v_msg);

  -- Excecao da Decisao no.1: deploy que DEGRADA e esperado; deploy que
  -- DERRUBA nao. Severe volta a queimar SLA mesmo durante deploy.
  v_excl   := v_deploy and v_sev < 5;
  v_reason := case when v_excl then 'degradacao durante deploy' end;

  v_thr    := incident_threshold();
  v_impact := impact_from_severity(v_sev);

  ------------------------------------------------------------------ despacho
  -- Marco de deploy vem PRIMEIRO: sem severidade, nenhuma das comparacoes
  -- abaixo seria verdadeira e a mensagem cairia no ramo final, que tentaria
  -- rebaixar o incidente para 'operational' e estouraria incidents_impact_not_ok.
  if v_sev is null then
    v_action := 'deploy_registrado';
    v_inc    := null;

  elsif v_sev >= v_thr then
    -- cruzou o limiar para baixo: abre (ou estende / reabre)
    select r.action, r.incident_id into v_action, v_inc
      from open_or_extend_incident(
             p_component   => v_comp,
             p_fingerprint => v_fp,
             p_impact      => v_impact,
             p_title       => format('Ambiente %s', eb_state_label(v_sev)),
             p_detail      => v_msg,
             p_source      => coalesce(p->>'source','beanstalk'),
             p_occurred_at => v_at,
             p_excluded    => v_excl,
             p_excl_reason => v_reason) r;

  elsif v_sev <= 1 then
    -- Ok / Info: saude restabelecida, fecha
    select r.action, r.incident_id into v_action, v_inc
      from close_incident(v_comp, v_fp, v_at) r;

  elsif v_sev = 2 then
    -- Unknown / No Data / Suspended -- Decisao no.6 aplicada ao Beanstalk.
    --
    -- O ambiente nao ficou melhor: a AWS PAROU DE ENXERGAR. Nos dados reais
    -- isso aparece como "Severe -> No Data". Tratar como as demais faixas
    -- rebaixaria um major_outage (peso 1,0) para degraded (0,25) -- o SLA
    -- melhoraria justamente porque perdemos a visao. E o pior erro possivel
    -- aqui, entao esta faixa NAO toca no incidente: nem abre, nem fecha,
    -- nem muda o impacto. So registra a cegueira.
    insert into monitor_signals (component_id, fingerprint, signal, occurred_at, detail, raw)
    values (v_comp, v_fp, 'insufficient_data', v_at, v_msg, p);

    select i.id into v_inc
      from incidents i
     where i.component_id = v_comp and i.fingerprint = v_fp and i.resolved_at is null;

    v_action := case when v_inc is not null
                     then 'cego_com_incidente_aberto'
                     else 'cego_sem_incidente' end;

  else
    -- Warning (e Degraded, se o limiar subir para 5).
    -- NAO abre incidente -- vira registro do dia. Mas se ja havia incidente
    -- aberto, o ambiente melhorou sem ficar saudavel: rebaixa o impacto em
    -- vez de fechar. Fechar aqui inventaria uma recuperacao que nao houve.
    --
    -- E o que segura a oscilacao Warning<->Degraded vista nos dados reais
    -- (29 transicoes num episodio so): o incidente unico atravessa toda ela
    -- e so fecha no Ok final.
    update incidents i
       set impact       = v_impact,
           last_seen_at = greatest(i.last_seen_at, v_at)
     where i.component_id = v_comp
       and i.fingerprint  = v_fp
       and i.resolved_at is null
       and i.impact > v_impact
    returning i.id into v_inc;

    v_action := case when v_inc is not null
                     then 'incidente_rebaixado'
                     else 'registrado_sem_incidente' end;
  end if;

  ------------------------------------------------------------------ trilha
  insert into health_events (
    component_id, fingerprint, source, from_state, to_state, severity,
    occurred_at, is_deploy, opened_incident, incident_id, message, raw,
    notification_process_id
  ) values (
    v_comp, v_fp, coalesce(p->>'source','beanstalk'),
    eb_state_label(v_from_sev),
    coalesce(eb_state_label(v_sev), 'Deploy'), v_sev,
    v_at, v_deploy or v_marco_deploy, v_action in ('opened','reopened'), v_inc, v_msg, p,
    v_npid
  );

  ------------------------------------------------------------------ status
  v_status := refresh_component_status(v_comp);

  return query select v_action, v_inc, v_comp, v_slug, v_status,
                      case
                        when v_sev is null then 'marco de deploy: nao toca em incidente'
                        when v_excl then 'deploy: fica no historico, fora do SLA'
                        when v_deploy and v_sev >= 5 then 'deploy que derrubou o ambiente: conta para o SLA'
                        when v_sev = 2 then 'sem dados: incidente preservado como estava'
                        when v_sev between 3 and v_thr - 1 then
                          format('%s abaixo do limiar %s: registro do dia', eb_state_label(v_sev), v_thr)
                      end::text;
end $fn$;

comment on function ingest_health(jsonb) is
  'Porta unica de ingestao (CloudWatch + Beanstalk). n8n: select * from ingest_health($1::jsonb)';

-- =====================================================================
--  RELATORIOS
-- =====================================================================

-- ---------------------------------------------------------------------
-- warnings_por_dia
--
-- "Warning" aqui = degradacao que NAO virou incidente. Duas exclusoes:
--
--   severity < incident_threshold()  -- nao cruzou o limiar
--   incident_id is null              -- e nao encostou em incidente nenhum
--
-- A segunda importa mais do que parece. Um evento pode estar na faixa de
-- warning e ainda assim pertencer a um incidente em dois casos: o espelho de
-- um alarme CloudWatch 'degraded' (que abre incidente por outra regra), e o
-- Warning que apenas REBAIXA um incidente ja aberto. Contar esses dois no
-- ranking misturaria "a API piscou" com "a API estava caida e melhorou um
-- pouco" -- e o ranking existe justamente para achar o primeiro caso.
--
-- Se o limiar subir para 5, Degraded entra automaticamente nesta conta --
-- que e o comportamento pedido pela Decisao em aberto no.1.
-- ---------------------------------------------------------------------
create or replace view warnings_por_dia as
  select (he.occurred_at at time zone 'America/Sao_Paulo')::date as dia,
         c.id           as component_id,
         c.slug,
         c.name,
         c.environment,
         count(*)                                        as total,
         count(*) filter (where not he.is_deploy)        as fora_de_deploy,
         count(*) filter (where he.is_deploy)            as em_deploy,
         max(he.occurred_at)                             as ultimo
    from health_events he
    join components c on c.id = he.component_id
   where he.severity >= 3
     and he.severity <  incident_threshold()
     and he.incident_id is null
   group by 1,2,3,4,5;

-- ---------------------------------------------------------------------
-- ranking_warnings_30d  (Decisao no.7)
--
-- Ordena por fora_de_deploy, NAO pelo total. Warning durante deploy e ruido
-- previsivel; fora dele e sintoma. Ordenar pelo total faria as APIs com mais
-- deploy parecerem as mais problematicas.
-- ---------------------------------------------------------------------
create or replace view ranking_warnings_30d as
  select c.id as component_id,
         c.slug,
         c.name,
         c.environment,
         count(*)                                  as total,
         count(*) filter (where not he.is_deploy)  as fora_de_deploy,
         count(*) filter (where he.is_deploy)      as em_deploy,
         round(
           count(*) filter (where he.is_deploy)::numeric
           / nullif(count(*), 0) * 100, 1)         as pct_em_deploy,
         count(distinct (he.occurred_at at time zone 'America/Sao_Paulo')::date) as dias_afetados,
         max(he.occurred_at)                       as ultimo
    from health_events he
    join components c on c.id = he.component_id
   where he.occurred_at >= now() - interval '30 days'
     and he.severity >= 3
     and he.severity <  incident_threshold()
     and he.incident_id is null
   group by c.id, c.slug, c.name, c.environment
   order by count(*) filter (where not he.is_deploy) desc, count(*) desc;

-- ---------------------------------------------------------------------
-- degraded_fora_de_deploy_30d
--
-- A consulta que RESPONDE a Decisao em aberto no.1: quantos Degraded
-- acontecem fora de deploy? Perto de zero -> subir INCIDENT_THRESHOLD para 5.
-- ---------------------------------------------------------------------
create or replace view degraded_fora_de_deploy_30d as
  select c.slug,
         c.environment,
         count(*)                                       as degraded_total,
         count(*) filter (where not he.is_deploy)       as fora_de_deploy,
         count(*) filter (where he.is_deploy)           as em_deploy
    from health_events he
    join components c on c.id = he.component_id
   where he.occurred_at >= now() - interval '30 days'
     and he.severity = 4
   group by c.slug, c.environment
   order by 4 desc;

-- ---------------------------------------------------------------------
-- timeline_do_dia(dia)
--
-- Linha do tempo de UM dia, com as tres origens juntas em ordem
-- cronologica: transicoes de saude, bordas de incidente e cegueira de
-- monitor.
--
-- Armadilha tratada: incidente que atravessa a meia-noite. As bordas so
-- aparecem no dia em que de fato ocorreram, mas o incidente EM CURSO
-- aparece no inicio do dia como 'queda_em_curso' -- senao um dia inteiro
-- fora do ar apareceria como um dia sem nenhum evento.
-- ---------------------------------------------------------------------
create or replace function timeline_do_dia(
  p_dia date default (now() at time zone 'America/Sao_Paulo')::date,
  p_tz  text default 'America/Sao_Paulo'
) returns table (
  horario     timestamptz,
  tipo        text,
  slug        text,
  componente  text,
  ambiente    text,
  severidade  text,
  descricao   text,
  conta_sla   boolean,
  incident_id bigint
)
language sql stable as $fn$
  with janela as (
    select (p_dia)::timestamp at time zone p_tz              as ini,
           (p_dia + 1)::timestamp at time zone p_tz          as fim
  )
  -- inicio de queda dentro do dia
  select i.started_at, 'queda_inicio', c.slug, c.name, c.environment,
         i.impact::text, i.title, not i.excluded_from_sla, i.id
    from incidents i join components c on c.id = i.component_id, janela j
   where i.started_at >= j.ini and i.started_at < j.fim

  union all
  -- fim de queda dentro do dia
  select i.resolved_at, 'queda_fim', c.slug, c.name, c.environment,
         i.impact::text,
         format('Normalizado apos %s',
                to_char(i.resolved_at - i.started_at, 'HH24:MI:SS')),
         not i.excluded_from_sla, i.id
    from incidents i join components c on c.id = i.component_id, janela j
   where i.resolved_at >= j.ini and i.resolved_at < j.fim

  union all
  -- ja estava fora do ar quando o dia comecou
  select j.ini, 'queda_em_curso', c.slug, c.name, c.environment,
         i.impact::text,
         format('Fora do ar desde %s',
                to_char(i.started_at at time zone p_tz, 'DD/MM HH24:MI')),
         not i.excluded_from_sla, i.id
    from incidents i join components c on c.id = i.component_id, janela j
   where i.started_at < j.ini
     and coalesce(i.resolved_at, now()) > j.ini

  union all
  -- transicoes de saude que nao viraram borda de incidente
  select he.occurred_at, 'transicao', c.slug, c.name, c.environment,
         coalesce(he.to_state, he.severity::text),
         coalesce(he.message, format('%s -> %s', he.from_state, he.to_state))
           || case when he.is_deploy then '  [deploy]' else '' end,
         not he.is_deploy, he.incident_id
    from health_events he join components c on c.id = he.component_id, janela j
   where he.occurred_at >= j.ini and he.occurred_at < j.fim
     and not he.opened_incident

  union all
  -- monitor sem metrica (nao e queda, e cegueira)
  select ms.occurred_at, 'monitor_cego', c.slug, c.name, c.environment,
         'INSUFFICIENT_DATA', coalesce(ms.detail, 'alarme sem metrica'), false, null
    from monitor_signals ms join components c on c.id = ms.component_id, janela j
   where ms.occurred_at >= j.ini and ms.occurred_at < j.fim

   order by 1;
$fn$;

-- ---------------------------------------------------------------------
-- resumo_do_dia(dia)
--
-- O cabecalho da pagina de consulta diaria: um numero por componente.
-- Inclui componentes despublicados de proposito -- e relatorio interno.
-- ---------------------------------------------------------------------
create or replace function resumo_do_dia(
  p_dia date default (now() at time zone 'America/Sao_Paulo')::date,
  p_tz  text default 'America/Sao_Paulo'
) returns table (
  slug              text,
  componente        text,
  ambiente          text,
  publicado         boolean,
  downtime_segundos numeric,
  uptime_pct        numeric,
  quedas            bigint,
  quedas_em_deploy  bigint,
  warnings          bigint,
  mttr_segundos     numeric
)
language sql stable as $fn$
  with j as (
    select (p_dia)::timestamp at time zone p_tz     as ini,
           (p_dia + 1)::timestamp at time zone p_tz as fim
  )
  select c.slug,
         c.name,
         c.environment,
         c.published,
         round(downtime_seconds(c.id, j.ini, j.fim), 1),
         round(100 - downtime_seconds(c.id, j.ini, j.fim) / 864.0, 4),
         (select count(*) from incidents i, j j2
           where i.component_id = c.id
             and i.started_at >= j2.ini and i.started_at < j2.fim
             and not i.excluded_from_sla),
         (select count(*) from incidents i, j j2
           where i.component_id = c.id
             and i.started_at >= j2.ini and i.started_at < j2.fim
             and i.excluded_from_sla),
         (select count(*) from health_events he, j j2
           where he.component_id = c.id
             and he.occurred_at >= j2.ini and he.occurred_at < j2.fim
             and he.severity >= 3 and he.severity < incident_threshold()
             and he.incident_id is null),   -- mesmo criterio de warnings_por_dia
         (select round(avg(extract(epoch from (i.resolved_at - i.started_at)))::numeric, 1)
            from incidents i, j j2
           where i.component_id = c.id
             and i.resolved_at is not null
             and not i.excluded_from_sla
             and i.started_at >= j2.ini and i.started_at < j2.fim)
    from components c, j
   order by downtime_seconds(c.id, j.ini, j.fim) desc, c.name;
$fn$;
