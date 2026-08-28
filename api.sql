-- =====================================================================
--  api.sql  ·  Camada de leitura para a pagina publica
--  Executar DEPOIS de health.sql.
--
--  PRINCIPIO: a pagina publica nunca toca em `incidents` nem em
--  `health_events`. Ela le UMA funcao -- status_json() -- que ja devolve
--  o payload pronto e higienizado.
--
--  Por que isso e a seguranca, e nao um detalhe de arquitetura:
--
--    incidents.detail guarda a mensagem CRUA da AWS. Um exemplo real:
--      'Incorrect application version found on 1 out of 2 instances.
--       Expected version "17.32_RC1 [Prod] [Douglas]" (deployment 10).
--       ... All instances are in same availability zone (us-east-1a).'
--
--    Nome de pessoa, numero de versao, zona de disponibilidade, contagem
--    de instancias. Nada disso pode chegar ao cliente. Filtrar no front
--    seria uma linha de JS de distancia do vazamento; aqui o campo
--    simplesmente NAO EXISTE na saida.
--
--  O mesmo vale para ambiente: status_json() le de public_components, que
--  so tem published = true E environment = 'producao'. Nao ha parametro
--  que faca a funcao devolver homologacao.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Limiar de cor -- vermelho x amarelo
--
-- Sai do JavaScript e vira parametro do banco, para a pagina e o backend
-- nunca discordarem sobre o que e "um dia ruim".
-- ---------------------------------------------------------------------
insert into sla_settings (key, value, description) values
  ('limiar_vermelho_segundos', '3600',
   'Downtime no DIA acima disto pinta a barra de vermelho; abaixo (e acima de zero), amarelo.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 2. Titulo publico
--
-- O titulo automatico ("Ambiente Degraded") e jargao interno. Esta coluna
-- deixa alguem escrever a frase que o cliente le. Enquanto estiver vazia,
-- a saida usa um rotulo generico derivado do impacto -- nunca a mensagem
-- crua da AWS.
-- ---------------------------------------------------------------------
alter table incidents
  add column if not exists public_title text;

comment on column incidents.public_title is
  'Frase que aparece na pagina publica. Vazio = rotulo generico pelo impacto.';

create or replace function rotulo_publico(p_impacto service_state, p_titulo text, p_fonte text)
returns text
language sql immutable parallel safe as $fn$
  select coalesce(
    nullif(trim(p_titulo), ''),
    case p_impacto
      when 'major_outage'   then 'Indisponibilidade'
      when 'partial_outage' then 'Falha parcial'
      when 'degraded'       then 'Desempenho degradado'
      when 'maintenance'    then 'Manutencao programada'
      else 'Incidente'
    end
  );
$fn$;

-- ---------------------------------------------------------------------
-- 3. public_incidents -- o que o cliente pode ver
--
-- Ausentes de proposito: detail, exclusion_reason, fingerprint, source,
-- occurrences, last_seen_at. Nenhum deles e informacao do cliente.
--
-- Incidentes fora do SLA (deploy, janela de reducao) NAO entram na lista:
-- degradacao esperada durante uma janela de manutencao nao e incidente do
-- ponto de vista de quem consome o servico. Eles continuam no historico
-- interno e no tempo excluido de cada dia.
-- ---------------------------------------------------------------------
create or replace view public_incidents as
  select i.id,
         c.slug,
         c.name                                                as componente,
         i.impact                                              as impacto,
         rotulo_publico(i.impact, i.public_title, i.source)     as titulo,
         i.started_at                                          as inicio,
         i.resolved_at                                         as fim,
         case when i.resolved_at is null
              then extract(epoch from (now() - i.started_at))::int
              else extract(epoch from (i.resolved_at - i.started_at))::int
         end                                                   as duracao_segundos,
         (i.resolved_at is null)                               as em_aberto
    from incidents i
    join public_components c on c.id = i.component_id
   where not i.excluded_from_sla
   order by i.started_at desc;

-- ---------------------------------------------------------------------
-- 4. public_daily_downtime -- os 90 dias de cada componente
--
-- Uma passada so. A versao ingenua chamaria downtime_seconds() 90 vezes
-- por componente -- 900 execucoes numa pagina de 10 servicos, cada uma
-- refazendo o bolo de camadas. Aqui o bolo e montado UMA vez por
-- componente sobre a janela inteira, e cada dia e apenas uma intersecao
-- de multirange (o operador `*`).
--
-- Devolve os dois numeros separados:
--   segundos            -> conta para o SLA, decide a cor
--   segundos_excluidos  -> deploy e janela de reducao, so para o tooltip
-- ---------------------------------------------------------------------
create or replace function public_daily_downtime(
  p_days int  default 90,
  p_tz   text default 'America/Sao_Paulo'
) returns table (
  component_id       bigint,
  dia                date,
  segundos           numeric,
  segundos_excluidos numeric
)
language sql stable as $fn$
  with j as (
    select (now() at time zone p_tz)::date - (p_days - 1) as d_ini,
           (now() at time zone p_tz)::date + 1            as d_fim
  ),
  janela as (
    select (j.d_ini)::timestamp at time zone p_tz as ini,
           (j.d_fim)::timestamp at time zone p_tz as fim
      from j
  ),
  dias as (
    select g::date as dia,
           tstzmultirange(tstzrange(
             (g::date)::timestamp at time zone p_tz,
             ((g::date) + 1)::timestamp at time zone p_tz, '[)')) as faixa
      from j, generate_series(j.d_ini, j.d_fim - 1, interval '1 day') g
  ),
  -- o mesmo desconto de downtime_seconds, aqui por componente
  reducao as (
    select pc.id as component_id,
           janelas_do_periodo(pc.id, ja.ini, ja.fim, p_tz) as mr
      from public_components pc cross join janela ja
  ),
  -- intervalos recortados na janela, separados por "conta ou nao conta"
  base as (
    select i.component_id,
           i.excluded_from_sla                as excl,
           impact_weight(i.impact)            as w,
           tstzrange(greatest(i.started_at, ja.ini),
                     least(coalesce(i.resolved_at, now()), ja.fim), '[)') as faixa
      from incidents i
      join public_components pc on pc.id = i.component_id
      cross join janela ja
     where impact_weight(i.impact) > 0
       and i.started_at < ja.fim
       and coalesce(i.resolved_at, now()) > ja.ini
  ),
  -- uma camada por nivel de peso presente; a altura da fatia e (w - w_ant)
  camadas as (
    select n.component_id, n.excl, n.w,
           lag(n.w, 1, 0::numeric)
             over (partition by n.component_id, n.excl order by n.w) as w_ant,
           (select range_agg(b.faixa)
              from base b
             where b.component_id = n.component_id
               and b.excl = n.excl
               and b.w >= n.w
               and not isempty(b.faixa))                             as mr
      from (select distinct component_id, excl, w from base) n
  )
  select pc.id, d.dia,
         -- conta para o SLA: o que sobra depois de tirar a janela
         coalesce((select sum((c.w - c.w_ant) * (
                    select coalesce(sum(extract(epoch from (upper(x) - lower(x)))), 0)
                      from unnest((c.mr * d.faixa) - r.mr) x))
                     from camadas c
                    where c.component_id = pc.id and not c.excl), 0)::numeric,
         -- nao conta: deploy + o pedaco que caiu dentro da janela.
         -- Continua visivel no tooltip -- esconder seria a diferenca
         -- entre nao contar e fingir que nao houve.
         coalesce((select sum((c.w - c.w_ant) * (
                    select coalesce(sum(extract(epoch from (upper(x) - lower(x)))), 0)
                      from unnest(c.mr * d.faixa) x))
                     from camadas c
                    where c.component_id = pc.id and c.excl), 0)::numeric
       + coalesce((select sum((c.w - c.w_ant) * (
                    select coalesce(sum(extract(epoch from (upper(x) - lower(x)))), 0)
                      from unnest((c.mr * d.faixa) * r.mr) x))
                     from camadas c
                    where c.component_id = pc.id and not c.excl), 0)::numeric
    from public_components pc
   cross join dias d
   join reducao r on r.component_id = pc.id
   order by pc.id, d.dia;
$fn$;

-- ---------------------------------------------------------------------
-- 5. status_json() -- a resposta inteira, num objeto so
--
-- O no do n8n faz `select status_json()` e devolve. Uma ida ao banco por
-- requisicao, nenhuma montagem de JSON no meio do caminho.
-- ---------------------------------------------------------------------
create or replace function status_json(
  p_days int  default 90,
  p_tz   text default 'America/Sao_Paulo'
) returns jsonb
language sql stable as $fn$
  with lim as (
    select setting_num('limiar_vermelho_segundos', 3600) as vermelho
  ),
  d as (
    select * from public_daily_downtime(p_days, p_tz)
  ),
  -- Cada incidente expandido nos dias que ele atravessa, recortado nas
  -- bordas. E o que permite ao tooltip dizer "das 14:20 as 15:37" em vez
  -- de so "1h17 fora" -- e numa queda que passa da meia-noite cada dia
  -- mostra a SUA fatia, nao o intervalo inteiro repetido nos dois.
  --
  -- Expandido de uma vez, e nao por subconsulta em cada celula: 17
  -- servicos x 90 dias seriam 1530 consultas para preencher meia duzia
  -- de tooltips.
  faixas as (
    select i.component_id,
           g::date as dia,
           to_char(greatest(i.started_at, (g::date)::timestamp at time zone p_tz)
                     at time zone p_tz, 'HH24:MI')                    as de,
           to_char(least(coalesce(i.resolved_at, now()),
                         ((g::date) + 1)::timestamp at time zone p_tz)
                     at time zone p_tz, 'HH24:MI')                    as ate,
           i.impact,
           i.excluded_from_sla,
           i.started_at
      from incidents i
      join public_components pc on pc.id = i.component_id
      cross join lateral generate_series(
        greatest((i.started_at at time zone p_tz)::date,
                 (now() at time zone p_tz)::date - (p_days - 1)),
        least((coalesce(i.resolved_at, now()) at time zone p_tz)::date,
              (now() at time zone p_tz)::date),
        interval '1 day') g
  ),
  faixas_do_dia as (
    select f.component_id, f.dia,
           jsonb_agg(jsonb_build_object(
             'de', f.de, 'ate', f.ate,
             'impacto', f.impact,
             'conta', not f.excluded_from_sla
           ) order by f.started_at) as lista
      from faixas f
     group by f.component_id, f.dia
  ),
  por_componente as (
    select pc.id, pc.slug, pc.name, pc.description, pc.status, pc.sla_target, pc.sort_order,
           jsonb_agg(
             jsonb_build_object(
               'dia',                d.dia,
               'segundos',           round(d.segundos)::int,
               'segundos_excluidos', round(d.segundos_excluidos)::int,
               -- a cor sai do banco: a pagina nao decide o que e um dia ruim
               'cor', case when d.segundos > lim.vermelho then 'vermelho'
                           when d.segundos > 0            then 'amarelo'
                           else                                'ok' end
             )
             -- so nos dias que tiveram alguma coisa; nos outros a chave nem
             -- existe, e sao a esmagadora maioria
             || case when fd.lista is null then '{}'::jsonb
                     else jsonb_build_object('faixas', fd.lista) end
             order by d.dia)                                    as dias,
           sum(d.segundos)                                      as total_segundos,
           count(*)                                             as total_dias
      from public_components pc
      join d on d.component_id = pc.id
      left join faixas_do_dia fd
             on fd.component_id = pc.id and fd.dia = d.dia
     cross join lim
     group by pc.id, pc.slug, pc.name, pc.description, pc.status, pc.sla_target, pc.sort_order
  )
  select jsonb_build_object(
    'gerado_em', to_char(now() at time zone p_tz, 'YYYY-MM-DD"T"HH24:MI:SS'),
    'fuso',      p_tz,
    'janela_dias', p_days,
    'limiar_vermelho_segundos', (select vermelho::int from lim),

    'estado_geral', coalesce(
      (select max(status)::text from public_components), 'operational'),

    'uptime_janela', (
      select case when sum(total_dias) > 0
                  then round(100 - sum(total_segundos) / (sum(total_dias) * 864.0), 3)
             end
        from por_componente),

    'componentes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'slug',       p.slug,
               'nome',       p.name,
               'descricao',  p.description,
               'status',     p.status,
               'sla_alvo',   p.sla_target,
               'uptime',     round(100 - p.total_segundos / (p.total_dias * 864.0), 3),
               'dias',       p.dias
             ) order by p.sort_order, p.name)
        from por_componente p), '[]'::jsonb),

    'incidentes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',        pi.id,
               'slug',      pi.slug,
               'componente',pi.componente,
               'impacto',   pi.impacto,
               'titulo',    pi.titulo,
               'inicio',    to_char(pi.inicio at time zone p_tz, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'fim',       to_char(pi.fim    at time zone p_tz, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'duracao_segundos', pi.duracao_segundos,
               'em_aberto', pi.em_aberto,
               'atualizacoes', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'quando', to_char(u.created_at at time zone p_tz, 'YYYY-MM-DD"T"HH24:MI:SS'),
                          'estado', u.status,
                          'texto',  u.body) order by u.created_at)
                   from incident_updates u where u.incident_id = pi.id), '[]'::jsonb)
             ) order by pi.inicio desc)
        from (select * from public_incidents
               where inicio >= now() - make_interval(days => p_days)
               limit 50) pi), '[]'::jsonb)
  );
$fn$;

comment on function status_json(int, text) is
  'Payload completo da pagina publica. Uso no n8n: select status_json()';

-- =====================================================================
--  PAPEL DE MENOR PRIVILEGIO  (opcional, mas e a defesa que sobra
--  quando alguem erra a query no futuro)
--
--  Crie um usuario que so consegue chamar status_json(). Mesmo que um dia
--  alguem troque a query do no do n8n por "select * from incidents", o
--  banco recusa -- o usuario nao tem permissao de ler a tabela.
--
--  Rode UMA vez, trocando a senha, e use essa credencial no no publico:
--
--    create role status_api login password 'TROQUE-ISTO';
--    grant connect on database neondb to status_api;
--    grant usage   on schema public   to status_api;
--    grant execute on function status_json(int, text) to status_api;
--
--  E so. Sem grant de select em tabela nenhuma: status_json() e STABLE e
--  roda com os privilegios de quem a criou apenas se for SECURITY DEFINER.
--  Para que o papel restrito consiga ler as tabelas por dentro da funcao,
--  marque-a assim -- e por isso o search_path fixo, que impede sequestro
--  de nome:
--
--    alter function status_json(int, text) security definer;
--    alter function status_json(int, text) set search_path = public, pg_temp;
--    alter function public_daily_downtime(int, text) security definer;
--    alter function public_daily_downtime(int, text) set search_path = public, pg_temp;
--
--  Depois, revogue o acesso publico as funcoes internas de ingestao:
--    revoke execute on function ingest_health(jsonb) from public;
-- =====================================================================
