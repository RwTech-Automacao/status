-- =====================================================================
--  janelas.sql  ·  Horários de máquina reduzida
--  Executar DEPOIS de picos.sql.
--
--  Degradação num horário em que a máquina foi propositalmente reduzida é
--  esperada, igual à degradação durante deploy. Mesma decisão, mesmo
--  tratamento: o incidente CONTINUA no histórico, mas não queima SLA.
--
--  Duas escolhas que valem explicar:
--
--  1. SUBTRAI O TEMPO DENTRO DA JANELA, não o incidente inteiro. Uma queda
--     das 21h30 às 23h com janela a partir das 22h deve queimar 30 minutos,
--     não zero -- meia hora de indisponibilidade aconteceu com a máquina
--     cheia. Excluir o incidente todo seria conveniente e falso.
--
--  2. A JANELA É RECORRENTE, não uma data. "Todo dia das 22h às 6h" é
--     como a redução realmente funciona; cadastrar data a data seria
--     trabalho manual eterno e a primeira semana esquecida viraria queda.
-- =====================================================================

create table if not exists janelas_reducao (
  id           bigint generated always as identity primary key,

  -- NULL = vale para todos os componentes. É o caso comum: a redução
  -- costuma ser do cluster inteiro, não de um serviço.
  component_id bigint      references components(id) on delete cascade,

  -- NULL = todos os dias. 0=domingo .. 6=sábado (mesmo do extract(dow)).
  dia_semana   int,

  hora_inicio  time        not null,
  hora_fim     time        not null,

  motivo       text        not null,
  ativa        boolean     not null default true,
  created_at   timestamptz not null default now(),

  constraint janelas_dow check (dia_semana is null or dia_semana between 0 and 6)
);

comment on table janelas_reducao is
  'Horarios de maquina reduzida. hora_fim <= hora_inicio significa que a janela atravessa a meia-noite.';

create index if not exists janelas_reducao_comp_idx
  on janelas_reducao (component_id) where ativa;

-- ---------------------------------------------------------------------
-- janelas_do_periodo -- as ocorrências concretas dentro de uma janela
--
-- A janela é uma REGRA ("todo dia 22h-6h"); o cálculo precisa de
-- INTERVALOS ("26/08 22:00 até 27/08 06:00"). Esta função expande um no
-- outro.
--
-- Atravessar a meia-noite é o caso normal, não a exceção: reduzir máquina
-- de madrugada é justamente reduzir das 22h às 6h. Quando hora_fim é menor
-- ou igual a hora_inicio, o fim cai no dia seguinte.
--
-- O dia_semana é conferido no INÍCIO da janela: uma janela de segunda que
-- vai até terça de manhã pertence à segunda inteira.
-- ---------------------------------------------------------------------
create or replace function janelas_do_periodo(
  p_component bigint,
  p_de        timestamptz,
  p_ate       timestamptz,
  p_tz        text default 'America/Sao_Paulo'
) returns tstzmultirange
language sql stable as $fn$
  with dias as (
    -- um dia a mais de cada lado: a janela da véspera pode invadir p_de,
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
-- downtime_seconds, agora descontando as janelas
--
-- Mesma integral de antes -- a união dos intervalos por nível de peso --
-- com um passo a mais: `- janelas`. O operador de diferença de multirange
-- faz o recorte exato, inclusive quando a janela pega só um pedaço da
-- queda. É por isso que o modelo é de intervalos e não de durações: uma
-- duração solta não teria como ser recortada.
-- ---------------------------------------------------------------------
create or replace function downtime_seconds(
  p_component bigint,
  p_from      timestamptz,
  p_to        timestamptz
) returns numeric
language sql stable as $fn$
  with janelas as (
    select janelas_do_periodo(p_component, p_from, p_to) as mr
  ),
  base as (
    select impact_weight(i.impact) as w,
           tstzrange(greatest(i.started_at, p_from),
                     least(coalesce(i.resolved_at, now()), p_to), '[)') as faixa
      from incidents i
     where i.component_id = p_component
       and not i.excluded_from_sla
       and impact_weight(i.impact) > 0
       and i.started_at < p_to
       and coalesce(i.resolved_at, now()) > p_from
  ),
  niveis as (
    select w, lag(w, 1, 0::numeric) over (order by w) as w_anterior
      from (select distinct w from base) d
  ),
  camadas as (
    select n.w, n.w_anterior,
           (select range_agg(b.faixa) from base b
             where b.w >= n.w and not isempty(b.faixa)) as faixas
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
-- Idem para a série de 90 dias da página pública.
--
-- O tempo recortado pela janela NÃO some: entra em `segundos_excluidos`,
-- junto com o deploy. Continua visível no tooltip -- "2h fora do SLA
-- (deploy ou manutenção)" -- porque esconder seria a diferença entre
-- não contar e fingir que não houve.
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
  reducao as (
    select pc.id as component_id,
           janelas_do_periodo(pc.id, ja.ini, ja.fim, p_tz) as mr
      from public_components pc cross join janela ja
  ),
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
  camadas as (
    select n.component_id, n.excl, n.w,
           lag(n.w, 1, 0::numeric)
             over (partition by n.component_id, n.excl order by n.w) as w_ant,
           (select range_agg(b.faixa)
              from base b
             where b.component_id = n.component_id
               and b.excl = n.excl
               and b.w >= n.w
               and not isempty(b.faixa)) as mr
      from (select distinct component_id, excl, w from base) n
  ),
  bruto as (
    select pc.id as component_id, d.dia,
           -- conta para o SLA: fora da janela de reducao
           coalesce((select sum((c.w - c.w_ant) * (
                      select coalesce(sum(extract(epoch from (upper(x) - lower(x)))), 0)
                        from unnest((c.mr * d.faixa) - r.mr) x))
                       from camadas c
                      where c.component_id = pc.id and not c.excl), 0)::numeric as conta,
           -- nao conta: deploy...
           coalesce((select sum((c.w - c.w_ant) * (
                      select coalesce(sum(extract(epoch from (upper(x) - lower(x)))), 0)
                        from unnest(c.mr * d.faixa) x))
                       from camadas c
                      where c.component_id = pc.id and c.excl), 0)::numeric as por_deploy,
           -- ...e o pedaco que caiu dentro da janela de reducao
           coalesce((select sum((c.w - c.w_ant) * (
                      select coalesce(sum(extract(epoch from (upper(x) - lower(x)))), 0)
                        from unnest((c.mr * d.faixa) * r.mr) x))
                       from camadas c
                      where c.component_id = pc.id and not c.excl), 0)::numeric as por_janela
      from public_components pc
     cross join dias d
      join reducao r on r.component_id = pc.id
  )
  select b.component_id, b.dia, b.conta, b.por_deploy + b.por_janela
    from bruto b
   order by b.component_id, b.dia;
$fn$;

-- ---------------------------------------------------------------------
-- Ajuda para cadastrar sem decorar o formato
--
--   select cadastrar_janela('22:00','06:00','maquina reduzida de madrugada');
--   select cadastrar_janela('00:00','08:00','fim de semana', p_dia_semana => 0);
--   select cadastrar_janela('22:00','06:00','so a api-zk', p_slug => 'api-zk');
-- ---------------------------------------------------------------------
create or replace function cadastrar_janela(
  p_hora_inicio time,
  p_hora_fim    time,
  p_motivo      text,
  p_slug        text default null,
  p_ambiente    text default 'producao',
  p_dia_semana  int  default null
) returns janelas_reducao
language plpgsql as $fn$
declare
  v_comp bigint;
  v_row  janelas_reducao;
begin
  if p_slug is not null then
    select id into v_comp from components
     where slug = p_slug and environment = p_ambiente;
    if v_comp is null then
      raise exception 'cadastrar_janela: componente %/% nao existe', p_slug, p_ambiente;
    end if;
  end if;

  insert into janelas_reducao (component_id, dia_semana, hora_inicio, hora_fim, motivo)
  values (v_comp, p_dia_semana, p_hora_inicio, p_hora_fim, p_motivo)
  returning * into v_row;

  return v_row;
end $fn$;

create or replace view janelas_ativas as
  select j.id,
         coalesce(c.slug, '(todos)')     as componente,
         coalesce(c.environment, '—')    as ambiente,
         case j.dia_semana
           when 0 then 'domingo'  when 1 then 'segunda' when 2 then 'terca'
           when 3 then 'quarta'   when 4 then 'quinta'  when 5 then 'sexta'
           when 6 then 'sabado'   else 'todo dia'
         end                             as quando,
         j.hora_inicio, j.hora_fim,
         (j.hora_fim <= j.hora_inicio)   as atravessa_meia_noite,
         j.motivo
    from janelas_reducao j
    left join components c on c.id = j.component_id
   where j.ativa
   order by j.hora_inicio;
