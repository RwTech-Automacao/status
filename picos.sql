-- =====================================================================
--  picos.sql  ·  Visão operacional: onde a máquina está sofrendo
--  Executar DEPOIS de api.sql.
--
--  A página pública responde "o serviço está no ar?". Esta responde
--  "qual API está piscando mais, e desde quando?" -- que é outra
--  pergunta, com outro público e outra janela de tempo.
--
--  DIFERENÇA DE EXPOSIÇÃO, e ela é deliberada:
--
--    status_json()  -> só produção publicada, mensagem da AWS NUNCA sai
--    picos_json()   -> todos os ambientes, mensagem crua INCLUÍDA
--
--  A mensagem crua é o que serve aqui ("Incorrect application version
--  found on 1 out of 2 instances") e é exatamente o que não pode vazar
--  lá ("Expected version 17.32_RC1 [Prod] [Douglas]"). Por isso
--  /api/picos fica atrás do login no middleware. Se algum dia alguém
--  abrir esse endpoint, o vazamento é imediato.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tamanho do balde
--
-- Janela curta pede balde fino; semana inteira com balde de 10 min viraria
-- mil pontos ilegíveis. Escolhido pela função para a página não ter que
-- decidir -- e para o eixo do gráfico nunca discordar dos números.
-- ---------------------------------------------------------------------
create or replace function balde_para(p_de timestamptz, p_ate timestamptz)
returns interval
language sql immutable parallel safe as $fn$
  select case
           when p_ate - p_de <= interval '6 hours'  then interval '10 minutes'
           when p_ate - p_de <= interval '48 hours' then interval '1 hour'
           when p_ate - p_de <= interval '14 days'  then interval '6 hours'
           else                                          interval '1 day'
         end;
$fn$;

-- ---------------------------------------------------------------------
-- 2. Intervalos de estado
--
-- health_events guarda TRANSIÇÕES, não durações. "Quanto tempo a API
-- passou em Warning" sai do intervalo entre um evento e o próximo do
-- mesmo fingerprint -- daí o lead().
--
-- O olhar para trás importa: uma API que entrou em Warning às 2h e ainda
-- está lá às 14h não tem nenhum evento dentro da janela "últimas 3h".
-- Sem buscar o estado anterior, ela apareceria como saudável justamente
-- por estar mal há muito tempo. Sete dias de folga cobrem qualquer caso
-- real sem varrer a tabela inteira.
-- ---------------------------------------------------------------------
create or replace function estados_no_periodo(
  p_de  timestamptz,
  p_ate timestamptz
) returns table (
  component_id bigint,
  fingerprint  text,
  severity     int,
  is_deploy    boolean,
  ini          timestamptz,
  fim          timestamptz,
  segundos     numeric
)
language sql stable as $fn$
  with e as (
    select he.component_id, he.fingerprint, he.severity, he.is_deploy,
           he.occurred_at,
           lead(he.occurred_at) over (partition by he.component_id, he.fingerprint
                                          order by he.occurred_at) as proximo
      from health_events he
     where he.severity is not null
       and he.occurred_at >= p_de - interval '7 days'
       and he.occurred_at <  p_ate
  )
  select e.component_id, e.fingerprint, e.severity, e.is_deploy,
         greatest(e.occurred_at, p_de)                          as ini,
         least(coalesce(e.proximo, p_ate), p_ate)               as fim,
         extract(epoch from (least(coalesce(e.proximo, p_ate), p_ate)
                             - greatest(e.occurred_at, p_de)))::numeric as segundos
    from e
   where least(coalesce(e.proximo, p_ate), p_ate) > greatest(e.occurred_at, p_de);
$fn$;

-- ---------------------------------------------------------------------
-- 3. picos_json(de, ate) -- a resposta inteira
--
-- Um objeto só: resumo por componente, série para o gráfico e a lista de
-- eventos. Uma ida ao banco por carregamento de tela.
-- ---------------------------------------------------------------------
create or replace function picos_json(
  p_de    timestamptz default now() - interval '3 hours',
  p_ate   timestamptz default now(),
  p_tz    text        default 'America/Sao_Paulo',
  p_limite int        default 300
) returns jsonb
language sql stable as $fn$
  with j as (
    select p_de as de, p_ate as ate,
           balde_para(p_de, p_ate) as balde,
           incident_threshold()    as limiar
  ),
  -- eventos da janela, já com o rótulo de "isto é um pico?"
  ev as (
    select he.id, he.component_id, he.occurred_at, he.severity, he.is_deploy,
           he.from_state, he.to_state, he.message, he.incident_id,
           c.slug, c.name, c.environment,
           (he.severity >= 3 and he.severity < j.limiar and he.incident_id is null) as e_pico
      from health_events he
      join components c on c.id = he.component_id
     cross join j
     where he.occurred_at >= j.de and he.occurred_at < j.ate
  ),
  -- tempo em cada faixa, por componente
  tempo as (
    select ep.component_id,
           sum(ep.segundos) filter (where ep.severity >= 3 and ep.severity < j.limiar) as seg_warning,
           sum(ep.segundos) filter (where ep.severity >= j.limiar)                     as seg_incidente,
           max(ep.severity)                                                            as pior
      from estados_no_periodo(p_de, p_ate) ep
     cross join j
     group by ep.component_id
  ),
  resumo as (
    select c.id, c.slug, c.name, c.environment, c.published,
           count(*) filter (where ev.e_pico)                          as picos,
           count(*) filter (where ev.e_pico and not ev.is_deploy)     as fora_de_deploy,
           count(*) filter (where ev.e_pico and ev.is_deploy)         as em_deploy,
           count(*) filter (where ev.incident_id is not null
                              and ev.severity >= (select limiar from j)) as eventos_de_queda,
           max(ev.occurred_at)                                        as ultimo,
           coalesce(round(t.seg_warning   / 60.0), 0)                 as min_em_warning,
           coalesce(round(t.seg_incidente / 60.0), 0)                 as min_em_queda,
           coalesce(t.pior, 0)                                        as pior_severidade
      from components c
      join ev on ev.component_id = c.id
      left join tempo t on t.component_id = c.id
     group by c.id, c.slug, c.name, c.environment, c.published,
              t.seg_warning, t.seg_incidente, t.pior
  ),
  serie as (
    select date_bin((select balde from j), ev.occurred_at, (select de from j)) as inicio,
           count(*) filter (where ev.e_pico)                      as picos,
           count(*) filter (where ev.e_pico and ev.is_deploy)     as em_deploy,
           count(*) filter (where ev.severity >= (select limiar from j)) as quedas
      from ev
     group by 1
  )
  select jsonb_build_object(
    'de',   to_char(p_de  at time zone p_tz, 'YYYY-MM-DD"T"HH24:MI:SS'),
    'ate',  to_char(p_ate at time zone p_tz, 'YYYY-MM-DD"T"HH24:MI:SS'),
    'fuso', p_tz,
    'balde_minutos', (select (extract(epoch from balde)/60)::int from j),
    'limiar_incidente', (select limiar from j),
    'gerado_em', to_char(now() at time zone p_tz, 'YYYY-MM-DD"T"HH24:MI:SS'),

    'total_picos',    coalesce((select sum(picos) from resumo), 0),
    'total_quedas',   coalesce((select sum(eventos_de_queda) from resumo), 0),
    'componentes_afetados', (select count(*) from resumo where picos > 0),

    -- Ordenado por FORA de deploy, não pelo total (Decisão nº7): Warning
    -- durante deploy é ruído previsível; fora dele é sintoma. Ordenar pelo
    -- total faria as APIs com mais deploy parecerem as mais problemáticas.
    'componentes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'slug',            r.slug,
               'nome',            r.name,
               'ambiente',        r.environment,
               'publicado',       r.published,
               'picos',           r.picos,
               'fora_de_deploy',  r.fora_de_deploy,
               'em_deploy',       r.em_deploy,
               'quedas',          r.eventos_de_queda,
               'min_em_warning',  r.min_em_warning,
               'min_em_queda',    r.min_em_queda,
               'pior_severidade', r.pior_severidade,
               'pior_estado',     eb_state_label(r.pior_severidade),
               'ultimo',          to_char(r.ultimo at time zone p_tz, 'YYYY-MM-DD"T"HH24:MI:SS')
             ) order by r.fora_de_deploy desc, r.picos desc, r.min_em_warning desc)
        from resumo r), '[]'::jsonb),

    'serie', coalesce((
      select jsonb_agg(jsonb_build_object(
               'inicio',    to_char(s.inicio at time zone p_tz, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'picos',     s.picos,
               'em_deploy', s.em_deploy,
               'quedas',    s.quedas
             ) order by s.inicio)
        from serie s), '[]'::jsonb),

    'eventos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'quando',     to_char(x.occurred_at at time zone p_tz, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'slug',       x.slug,
               'componente', x.name,
               'ambiente',   x.environment,
               'de',         x.from_state,
               'para',       x.to_state,
               'severidade', x.severity,
               'pico',       x.e_pico,
               'deploy',     x.is_deploy,
               'queda',      (x.incident_id is not null),
               -- mensagem CRUA: é o que serve para diagnosticar, e é o que
               -- torna este endpoint interno por obrigação
               'mensagem',   left(x.message, 400)
             ) order by x.occurred_at desc)
        from (select * from ev order by occurred_at desc limit p_limite) x), '[]'::jsonb),

    'eventos_truncados', (select greatest(count(*) - p_limite, 0) from ev)
  );
$fn$;

comment on function picos_json(timestamptz, timestamptz, text, int) is
  'Visão operacional interna. Contém mensagem crua da AWS -- NUNCA expor sem autenticação.';
