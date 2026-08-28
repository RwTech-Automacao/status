-- =====================================================================
--  schema.sql  ·  Monitoramento de disponibilidade — RWTech
--  Ordem de execucao: schema.sql -> discovery.sql -> ingest_function.sql -> health.sql
--
--  Requer PostgreSQL 14+ (range_agg / multirange em downtime_seconds).
--
--  Principio: incidente e um INTERVALO. Uptime, MTTR e error budget sao
--  derivados desse intervalo -- nunca gravados como numero solto.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Enum de estado
--
-- Uma enum so, em ordem CRESCENTE de gravidade. Isso deixa max() resolver
-- "qual o pior estado aberto?" sem case/when -- ver refresh_component_status().
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'service_state') then
    create type service_state as enum (
      'operational',
      'maintenance',
      'degraded',
      'partial_outage',
      'major_outage'
    );
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. Parametros ajustaveis em runtime
--
-- Tabela em vez de constante no codigo: a "Decisao em aberto no.1"
-- (subir INCIDENT_THRESHOLD de 4 para 5) vira um UPDATE, nao um DDL.
-- ---------------------------------------------------------------------
create table if not exists sla_settings (
  key         text primary key,
  value       text        not null,
  description text,
  updated_at  timestamptz not null default now()
);

insert into sla_settings (key, value, description) values
  ('flap_window_seconds', '120',
   'Janela em que um incidente recem-resolvido REABRE em vez de virar um novo. Contar flapping como N quedas curtas deixa o MTTR lindo e mentiroso.'),
  ('default_sla_target', '99.9',
   'Meta padrao de disponibilidade para componente recem-descoberto.'),
  ('default_environment', 'producao',
   'Ambiente assumido quando o nome do alarme nao traz sufixo. Seguro porque componente novo nasce despublicado (ver discovery.sql).')
on conflict (key) do nothing;

create or replace function setting_num(p_key text, p_default numeric)
returns numeric
language sql stable as $fn$
  select coalesce((select value::numeric from sla_settings where key = p_key), p_default);
$fn$;

create or replace function setting_text(p_key text, p_default text)
returns text
language sql stable as $fn$
  select coalesce((select value from sla_settings where key = p_key), p_default);
$fn$;

-- ---------------------------------------------------------------------
-- 3. Componentes
--
-- Decisao no.2: o ambiente SAI do nome e vira coluna.
-- api-tarefa-megas-producao e api-tarefa-megas-homolog sao o MESMO servico.
-- Sem separar, o SLA de homologacao (que cai o tempo todo) contaminaria producao.
-- ---------------------------------------------------------------------
create table if not exists components (
  id          bigint generated always as identity primary key,
  slug        text          not null,
  name        text          not null,
  environment text          not null default 'producao',
  description text,
  sla_target  numeric(6,3)  not null default 99.900,
  status      service_state not null default 'operational',
  sort_order  int           not null default 100,
  created_at  timestamptz   not null default now(),
  updated_at  timestamptz   not null default now(),

  constraint components_slug_env_key unique (slug, environment),
  constraint components_slug_fmt     check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint components_sla_range    check (sla_target > 0 and sla_target <= 100)
);

comment on column components.environment is
  'producao | homologacao | validacao | desenvolvimento | teste | staging';
comment on column components.status is
  'Derivado, nunca escrito a mao. Ver refresh_component_status().';

-- ---------------------------------------------------------------------
-- 4. Incidentes -- a tabela que sustenta o SLA
--
-- So entra aqui o que representa QUEDA REAL. Warning e transicao de rotina
-- vivem em health_events (health.sql). Misturar polui o SLA.
-- ---------------------------------------------------------------------
create table if not exists incidents (
  id                bigint generated always as identity primary key,
  component_id      bigint        not null references components(id) on delete cascade,

  -- Chave de identidade estavel do alerta. E o que amarra o evento de erro
  -- ao evento de OK. Sem fingerprint nao ha pareamento e a duracao vira chute.
  fingerprint       text          not null,

  impact            service_state not null,
  title             text          not null,
  detail            text,
  source            text          not null default 'unknown',  -- cloudwatch | beanstalk | manual

  -- started_at vem SEMPRE do evento, nunca de now(): webhook atrasado
  -- nao pode encurtar o incidente.
  started_at        timestamptz   not null,
  resolved_at       timestamptz,
  last_seen_at      timestamptz   not null,
  occurrences       int           not null default 1,

  -- Decisao no.1: deploy nao queima SLA, mas continua VISIVEL no historico.
  excluded_from_sla boolean       not null default false,
  exclusion_reason  text,

  created_at        timestamptz   not null default now(),
  updated_at        timestamptz   not null default now(),

  constraint incidents_impact_not_ok check (impact <> 'operational'),
  constraint incidents_window        check (resolved_at is null or resolved_at >= started_at),
  constraint incidents_exclusion     check (excluded_from_sla = false or exclusion_reason is not null)
);

-- Armadilha: monitor reenvia o mesmo alerta a cada 30s.
-- Este indice faz a repeticao virar UPDATE, nao incidente novo.
create unique index if not exists incidents_open_uq
  on incidents (component_id, fingerprint)
  where resolved_at is null;

create index if not exists incidents_component_time_idx
  on incidents (component_id, started_at desc);

-- Para timeline_do_dia(): varre por janela de tempo, incluindo o que atravessa a meia-noite.
create index if not exists incidents_window_idx
  on incidents (started_at, resolved_at);

create index if not exists incidents_fingerprint_idx
  on incidents (fingerprint, started_at desc);

-- ---------------------------------------------------------------------
-- 5. Notas de acompanhamento (o "investigating -> identified -> resolved")
-- ---------------------------------------------------------------------
create table if not exists incident_updates (
  id          bigint generated always as identity primary key,
  incident_id bigint      not null references incidents(id) on delete cascade,
  status      text        not null check (status in ('investigating','identified','monitoring','resolved')),
  body        text        not null,
  author      text,
  created_at  timestamptz not null default now()
);

create index if not exists incident_updates_incident_idx
  on incident_updates (incident_id, created_at);

-- ---------------------------------------------------------------------
-- 6. Deduplicacao de entrega
--
-- SNS reentrega, n8n reexecuta. O hash e calculado pelo parser sobre o
-- CONTEUDO do evento (nao sobre o envelope) -- ver parser.js.
-- ---------------------------------------------------------------------
create table if not exists webhook_deliveries (
  delivery_hash text primary key,
  source        text        not null,
  received_at   timestamptz not null default now(),
  payload       jsonb
);

create index if not exists webhook_deliveries_received_idx
  on webhook_deliveries (received_at desc);

-- ---------------------------------------------------------------------
-- 7. Sinais de monitor
--
-- Decisao no.6: INSUFFICIENT_DATA nao e queda, e CEGUEIRA. O alarme parou de
-- receber metrica. Tratar como ALARM enche a pagina de falso positivo;
-- ignorar esconde monitor quebrado. Fica aqui, sem abrir incidente.
-- ---------------------------------------------------------------------
create table if not exists monitor_signals (
  id           bigint generated always as identity primary key,
  component_id bigint references components(id) on delete set null,
  fingerprint  text        not null,
  signal       text        not null,   -- insufficient_data | monitor_recovered
  occurred_at  timestamptz not null,
  detail       text,
  raw          jsonb,
  created_at   timestamptz not null default now()
);

create index if not exists monitor_signals_time_idx
  on monitor_signals (occurred_at desc);

create index if not exists monitor_signals_fingerprint_idx
  on monitor_signals (fingerprint, occurred_at desc);

-- ---------------------------------------------------------------------
-- 8. touch de updated_at
-- ---------------------------------------------------------------------
create or replace function touch_updated_at()
returns trigger
language plpgsql as $fn$
begin
  new.updated_at := now();
  return new;
end $fn$;

drop trigger if exists components_touch on components;
create trigger components_touch before update on components
  for each row execute function touch_updated_at();

drop trigger if exists incidents_touch on incidents;
create trigger incidents_touch before update on incidents
  for each row execute function touch_updated_at();

-- =====================================================================
--  METRICAS DERIVADAS
-- =====================================================================

-- ---------------------------------------------------------------------
-- impact_weight -- Decisao no.4: a metrica define a gravidade.
--
-- EnvironmentHealth no chao = queda total. Latency/CPU alta = degradacao.
-- Se tudo virasse "fora do ar", o uptime despencaria por um pico de CPU
-- que ninguem sentiu.
-- ---------------------------------------------------------------------
create or replace function impact_weight(p_impact service_state)
returns numeric
language sql immutable parallel safe as $fn$
  select case p_impact
           when 'major_outage'   then 1.00
           when 'partial_outage' then 0.50
           when 'degraded'       then 0.25
           else                       0.00   -- maintenance, operational
         end::numeric;
$fn$;

-- ---------------------------------------------------------------------
-- refresh_component_status
--
-- Armadilha: dois problemas simultaneos no mesmo servico. O componente so
-- volta a 'operational' se NENHUM incidente aberto sobrou -- por isso
-- max() sobre os abertos, e nao "fechei um, entao esta tudo bem".
-- ---------------------------------------------------------------------
create or replace function refresh_component_status(p_component bigint)
returns service_state
language plpgsql as $fn$
declare
  v_state service_state;
begin
  select coalesce(max(impact), 'operational')
    into v_state
    from incidents
   where component_id = p_component
     and resolved_at is null;

  update components
     set status = v_state
   where id = p_component
     and status is distinct from v_state;

  return v_state;
end $fn$;

-- ---------------------------------------------------------------------
-- Gatilho: components.status acompanha incidents SEMPRE
--
-- refresh_component_status() era chamada so pela ingest_health(). Bastava
-- alguem mexer em incidents por SQL -- apagar um teste, fechar na mao,
-- corrigir um impacto -- para a coluna congelar no valor antigo. E o
-- sintoma e cruel: a pagina mostra "tudo operacional" pintado de vermelho,
-- porque o texto vem da contagem de incidentes abertos e a cor vem da
-- coluna. Duas fontes para a mesma verdade.
--
-- Aconteceu de verdade: um incidente de teste apagado com DELETE deixou o
-- componente preso em major_outage sem nenhuma queda aberta.
--
-- Por linha e nao por instrucao: a escala aqui e de centenas de linhas, e
-- a versao por instrucao exigiria tres gatilhos com tabelas de transicao
-- diferentes para ganhar nada.
-- ---------------------------------------------------------------------
create or replace function incidents_refresh_status()
returns trigger
language plpgsql as $fn$
begin
  perform refresh_component_status(coalesce(new.component_id, old.component_id));

  -- UPDATE que move o incidente de componente precisa acertar os dois
  if tg_op = 'UPDATE' and new.component_id is distinct from old.component_id then
    perform refresh_component_status(old.component_id);
  end if;

  return null;
end $fn$;

drop trigger if exists incidents_status on incidents;
create trigger incidents_status
  after insert or update or delete on incidents
  for each row execute function incidents_refresh_status();

-- ---------------------------------------------------------------------
-- Horarios de maquina reduzida
--
-- Mora aqui, e nao num arquivo a parte, porque downtime_seconds() depende
-- dela. Tentei separar antes: janelas.sql redefinia downtime_seconds e
-- public_daily_downtime por cima. Bastava rodar schema.sql ou api.sql de
-- novo -- coisa normal ao aplicar qualquer mudanca -- para o desconto
-- sumir e o uptime subir sozinho, sem erro nenhum na tela. Definicao
-- duplicada de funcao e uma armadilha de tempo: funciona no dia em que
-- voce escreve e falha meses depois, na ordem errada.
--
-- Degradacao com a maquina propositalmente reduzida e esperada, igual a
-- degradacao durante deploy. Mesma decisao, mesmo tratamento: continua no
-- historico, nao queima SLA.
-- ---------------------------------------------------------------------
create table if not exists janelas_reducao (
  id           bigint generated always as identity primary key,

  -- NULL = vale para todos. E o caso comum: a reducao costuma ser do
  -- cluster inteiro, nao de um servico.
  component_id bigint      references components(id) on delete cascade,

  -- NULL = todos os dias. 0=domingo .. 6=sabado (igual ao extract(dow)).
  dia_semana   int,

  hora_inicio  time        not null,
  hora_fim     time        not null,

  motivo       text        not null,
  ativa        boolean     not null default true,
  created_at   timestamptz not null default now(),

  constraint janelas_dow check (dia_semana is null or dia_semana between 0 and 6)
);

comment on table janelas_reducao is
  'Horarios de maquina reduzida. hora_fim <= hora_inicio: a janela atravessa a meia-noite.';

create index if not exists janelas_reducao_comp_idx
  on janelas_reducao (component_id) where ativa;

-- ---------------------------------------------------------------------
-- janelas_do_periodo -- a regra vira intervalos concretos
--
-- A janela e uma REGRA ("todo dia 22h-6h"); o calculo precisa de
-- INTERVALOS ("26/08 22:00 ate 27/08 06:00").
--
-- Atravessar a meia-noite e o caso normal, nao a excecao: reduzir maquina
-- de madrugada e justamente das 19h as 6h30. Quando hora_fim <=
-- hora_inicio, o fim cai no dia seguinte.
--
-- O dia da semana e conferido no INICIO: uma janela de segunda que vai
-- ate terca de manha pertence a segunda.
-- ---------------------------------------------------------------------
create or replace function janelas_do_periodo(
  p_component bigint,
  p_de        timestamptz,
  p_ate       timestamptz,
  p_tz        text default 'America/Sao_Paulo'
) returns tstzmultirange
language sql stable as $fn$
  with dias as (
    -- um dia a mais de cada lado: a janela da vespera pode invadir p_de,
    -- e a de hoje pode terminar depois de p_ate
    select g::date as dia
      from generate_series(
             ((p_de  at time zone p_tz)::date - 1),
             ((p_ate at time zone p_tz)::date + 1),
             interval '1 day') g
  ),
  ocorrencias as (
    select tstzrange(
             (d.dia + j.hora_inicio)::timestamp at time zone p_tz,
             (d.dia
                + case when j.hora_fim <= j.hora_inicio then 1 else 0 end
                + j.hora_fim)::timestamp at time zone p_tz,
             '[)') as faixa
      from dias d
      join janelas_reducao j
        on j.ativa
       and (j.component_id is null or j.component_id = p_component)
       and (j.dia_semana   is null or j.dia_semana   = extract(dow from d.dia)::int)
  )
  select coalesce(
           range_agg(o.faixa * tstzrange(p_de, p_ate, '[)')),
           '{}'::tstzmultirange)
    from ocorrencias o
   where o.faixa && tstzrange(p_de, p_ate, '[)');
$fn$;

-- ---------------------------------------------------------------------
-- downtime_seconds -- segundos ponderados de indisponibilidade
--
-- Nao e uma soma simples de duracoes. Dois motivos:
--
--  a) Recorte de janela: "incidente atravessa a meia-noite" resolve-se com
--     greatest(started_at, p_from) / least(resolved_at, p_to).
--
--  b) SOBREPOSICAO: se dois incidentes do mesmo componente correm juntos,
--     somar duracoes contaria o mesmo minuto duas vezes e o downtime podia
--     passar do tempo de relogio. O certo e integrar o PIOR peso ativo em
--     cada instante. Isso e feito por "bolo de camadas": para cada nivel de
--     peso w, mede-se a UNIAO dos intervalos com peso >= w (range_agg) e
--     multiplica-se pela altura da fatia (w - peso_anterior).
--
--     Ex.: degraded (0,25) das 10h as 11h, major (1,0) das 10h30 as 10h45.
--       camada 0,25 -> uniao dos com peso >= 0,25 = 3600s, altura 0,25 -> 900s
--       camada 1,00 -> uniao dos com peso >= 1,00 =  900s, altura 0,75 -> 675s
--       total = 1575s
--     A soma ingenua daria 3600*0,25 + 900*1,0 = 1800s, contando o trecho
--     10h30-10h45 duas vezes. (Coberto por tests.sql, caso 11.1.)
--
-- Incidentes com excluded_from_sla = true ficam de fora (deploy).
-- ---------------------------------------------------------------------
create or replace function downtime_seconds(
  p_component bigint,
  p_from      timestamptz,
  p_to        timestamptz
) returns numeric
language sql stable as $fn$
  with janelas as (
    -- o tempo em que a maquina estava reduzida sai da conta, recortado na
    -- borda: queda das 21h30 as 23h com janela a partir das 22h queima 30
    -- minutos, nao zero -- meia hora aconteceu com a maquina cheia
    select janelas_do_periodo(p_component, p_from, p_to) as mr
  ),
  base as (
    select i.impact,
           impact_weight(i.impact) as w,
           greatest(i.started_at, p_from)                        as ini,
           least(coalesce(i.resolved_at, now()), p_to)           as fim
      from incidents i
     where i.component_id = p_component
       and not i.excluded_from_sla
       and impact_weight(i.impact) > 0
       and i.started_at < p_to
       and coalesce(i.resolved_at, now()) > p_from
  ),
  niveis as (
    select w,
           lag(w, 1, 0::numeric) over (order by w) as w_anterior
      from (select distinct w from base) d
  ),
  camadas as (
    select n.w,
           n.w_anterior,
           (select range_agg(tstzrange(b.ini, b.fim, '[)'))
              from base b
             where b.w >= n.w
               and b.fim > b.ini) as faixas
      from niveis n
  )
  select coalesce(sum(
           (c.w - c.w_anterior) * (
             select coalesce(sum(extract(epoch from (upper(f) - lower(f)))), 0)
               from unnest(c.faixas - (select mr from janelas)) as f
           )
         ), 0)::numeric
    from camadas c;
$fn$;

-- ---------------------------------------------------------------------
-- uptime_pct
--
-- A janela e recortada em components.created_at: nao afirmamos
-- disponibilidade sobre um periodo em que nao estavamos medindo.
-- Componente criado hoje mostra uptime do que foi observado hoje.
-- ---------------------------------------------------------------------
create or replace function uptime_pct(
  p_component bigint,
  p_from      timestamptz,
  p_to        timestamptz
) returns numeric
language sql stable as $fn$
  select case
           when j.segundos <= 0 then 100::numeric
           else round(100 - (downtime_seconds(p_component, j.ini, p_to) / j.segundos * 100), 4)
         end
    from (
      select greatest(p_from, c.created_at) as ini,
             extract(epoch from (p_to - greatest(p_from, c.created_at)))::numeric as segundos
        from components c
       where c.id = p_component
    ) j;
$fn$;

-- ---------------------------------------------------------------------
-- daily_downtime -- alimenta o grafico assinatura do status.html
--
-- Uma linha por dia, com os segundos ponderados fora do ar. O front aplica
-- pow(x, 0.25) para que 1 minuto continue visivel ao lado de 3 horas.
-- ---------------------------------------------------------------------
create or replace function daily_downtime(
  p_component bigint,
  p_days      int default 90,
  p_tz        text default 'America/Sao_Paulo'
) returns table (
  dia               date,
  downtime_segundos numeric,
  uptime_pct        numeric
)
language sql stable as $fn$
  select d.dia,
         downtime_seconds(p_component, d.ini, d.fim) as downtime_segundos,
         round(100 - downtime_seconds(p_component, d.ini, d.fim) / 864.0, 4) as uptime_pct
    from (
      select g::date                                             as dia,
             (g::date)::timestamp at time zone p_tz               as ini,
             ((g::date + 1))::timestamp at time zone p_tz         as fim
        from generate_series(
               (now() at time zone p_tz)::date - (p_days - 1),
               (now() at time zone p_tz)::date,
               interval '1 day'
             ) g
    ) d
   order by d.dia;
$fn$;

-- ---------------------------------------------------------------------
-- error_budget_month
--
-- O budget mensal e calculado sobre o MES INTEIRO (e o que a meta promete);
-- o consumo, sobre o que ja passou. Assim "gastei 40% do budget no dia 10"
-- e uma frase com sentido.
-- ---------------------------------------------------------------------
create or replace function error_budget_month(
  p_component bigint,
  p_month     date default date_trunc('month', now())::date,
  p_tz        text default 'America/Sao_Paulo'
) returns table (
  mes                 date,
  sla_target          numeric,
  budget_segundos     numeric,
  consumido_segundos  numeric,
  restante_segundos   numeric,
  budget_usado_pct    numeric,
  uptime_pct          numeric
)
language sql stable as $fn$
  with j as (
    select date_trunc('month', p_month::timestamp)::date            as mes_ini,
           (date_trunc('month', p_month::timestamp) + interval '1 month')::date as mes_fim
  ),
  w as (
    select j.mes_ini,
           (j.mes_ini)::timestamp at time zone p_tz                 as ini,
           (j.mes_fim)::timestamp at time zone p_tz                 as fim_mes,
           least((j.mes_fim)::timestamp at time zone p_tz, now())   as fim_obs,
           c.sla_target
      from j cross join components c
     where c.id = p_component
  ),
  calc as (
    select w.mes_ini,
           w.sla_target,
           extract(epoch from (w.fim_mes - w.ini))::numeric * (1 - w.sla_target / 100) as budget,
           downtime_seconds(p_component, w.ini, w.fim_obs)                             as consumido,
           uptime_pct(p_component, w.ini, w.fim_obs)                                   as up
      from w
  )
  select mes_ini,
         sla_target,
         round(budget, 1),
         round(consumido, 1),
         round(budget - consumido, 1),
         case when budget > 0 then round(consumido / budget * 100, 2) else null end,
         up
    from calc;
$fn$;

-- ---------------------------------------------------------------------
-- mttr_seconds -- tempo medio de resolucao
--
-- So conta incidente FECHADO e que conte para SLA. Incluir os abertos
-- puxaria a media para baixo justamente durante a queda em curso.
-- ---------------------------------------------------------------------
create or replace function mttr_seconds(
  p_component bigint,
  p_from      timestamptz,
  p_to        timestamptz
) returns numeric
language sql stable as $fn$
  select round(avg(extract(epoch from (resolved_at - started_at)))::numeric, 1)
    from incidents
   where component_id = p_component
     and not excluded_from_sla
     and resolved_at is not null
     and started_at >= p_from
     and started_at <  p_to;
$fn$;

-- ---------------------------------------------------------------------
-- Visoes de conveniencia
-- ---------------------------------------------------------------------
create or replace view incidents_abertos as
  select i.id,
         c.slug,
         c.name        as componente,
         c.environment as ambiente,
         i.impact,
         i.title,
         i.started_at,
         i.last_seen_at,
         i.occurrences,
         i.excluded_from_sla,
         extract(epoch from (now() - i.started_at))::int as aberto_ha_segundos
    from incidents i
    join components c on c.id = i.component_id
   where i.resolved_at is null
   order by i.impact desc, i.started_at;

create or replace view componentes_90d as
  select c.id,
         c.slug,
         c.name,
         c.environment,
         c.status,
         c.sla_target,
         uptime_pct(c.id, now() - interval '90 days', now())     as uptime_90d,
         mttr_seconds(c.id, now() - interval '90 days', now())   as mttr_90d_segundos,
         (select count(*) from incidents i
           where i.component_id = c.id
             and not i.excluded_from_sla
             and i.started_at >= now() - interval '90 days')     as quedas_90d
    from components c;
