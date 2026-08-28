-- =====================================================================
--  discovery.sql  ·  Auto-descoberta e curadoria de componentes
--  Executar DEPOIS de schema.sql.
--
--  Decisao no.3: componente novo NASCE DESPUBLICADO.
--  Alarme de servico desconhecido cria o componente automaticamente -- ele ja
--  acumula historico desde o primeiro minuto -- mas fica na discovery_inbox
--  ate alguem aprovar. Sem isso, um alarme de teste ou um nome com typo
--  vira componente publico.
-- =====================================================================

alter table components
  add column if not exists published boolean not null default false;

alter table components
  add column if not exists discovered_from text;

comment on column components.published is
  'false = so aparece na discovery_inbox. publish_component() promove.';
comment on column components.discovered_from is
  'String bruta do alarme que criou o componente. Ajuda a julgar na aprovacao.';

create index if not exists components_published_idx
  on components (published, environment, sort_order);

-- ---------------------------------------------------------------------
-- 1. Sufixos de ambiente
--
-- Tabela e nao CASE: quando aparecer um "-uat" novo em producao as 3h da
-- manha, e um INSERT, nao um deploy de funcao.
-- ---------------------------------------------------------------------
create table if not exists environment_aliases (
  token       text primary key,
  environment text not null
);

insert into environment_aliases (token, environment) values
  ('prod','producao'), ('producao','producao'), ('production','producao'),
  ('prd','producao'), ('live','producao'),

  ('homolog','homologacao'), ('homologacao','homologacao'),
  ('homol','homologacao'), ('hml','homologacao'), ('hom','homologacao'),

  ('validacao','validacao'), ('valid','validacao'), ('vld','validacao'),

  ('dev','desenvolvimento'), ('desenvolvimento','desenvolvimento'),
  ('develop','desenvolvimento'),

  ('teste','teste'), ('test','teste'), ('qa','teste'),

  ('staging','staging'), ('stage','staging'), ('stg','staging'),
  ('sandbox','staging'), ('uat','staging')
on conflict (token) do nothing;

-- ---------------------------------------------------------------------
-- 2. slugify
--
-- translate() em vez da extensao unaccent: uma dependencia a menos no banco,
-- e o conjunto de acentos que aparece em nome de recurso AWS e pequeno.
-- ---------------------------------------------------------------------
create or replace function slugify(p_texto text)
returns text
language sql immutable parallel safe as $fn$
  select nullif(
           trim(both '-' from
             regexp_replace(
               translate(lower(coalesce(p_texto, '')),
                         'áàâãäéèêëíìîïóòôõöúùûüçñ',
                         'aaaaaeeeeiiiiooooouuuucn'),
               '[^a-z0-9]+', '-', 'g')),
           '');
$fn$;

-- ---------------------------------------------------------------------
-- 3. split_environment -- Decisao no.2 em codigo
--
--   api-tarefa-megas-producao  ->  slug api-tarefa-megas   env producao
--   Api-Fechamento-env         ->  slug api-fechamento     env <default>
--   Api-Fechamento-Validacao   ->  slug api-fechamento     env validacao
--
-- Devolve `matched` para o chamador saber se o ambiente foi RECONHECIDO ou
-- apenas assumido -- e o que permite tentar o nome da aplicacao como segunda
-- fonte quando o nome do environment nao traz sufixo.
-- ---------------------------------------------------------------------
create or replace function split_environment(p_raw text)
returns table (slug text, environment text, matched boolean)
language plpgsql stable as $fn$
declare
  v_slug      text;
  v_token     text;
  v_penultimo text;
  v_env       text;
begin
  v_slug := slugify(p_raw);

  if v_slug is null then
    return query select null::text, setting_text('default_environment','producao'), false;
    return;
  end if;

  -- Beanstalk nomeia o ambiente como "<App>-env". O sufixo nao identifica nada.
  v_slug := coalesce(nullif(regexp_replace(v_slug, '-env$', ''), ''), v_slug);

  v_token := substring(v_slug from '([a-z0-9]+)$');

  select ea.environment into v_env
    from environment_aliases ea
   where ea.token = v_token;

  if v_env is not null then
    -- so remove se houver o que sobrar depois: "producao" sozinho continua "producao"
    v_slug := coalesce(nullif(regexp_replace(v_slug, '-' || v_token || '$', ''), ''), v_slug);
    return query select v_slug, v_env, true;
  end if;

  -- Sufixo numerado: "Api-blue-comandos-prod-2" e a SEGUNDA instancia de
  -- producao, nao um servico chamado "...-prod-2". Olhando so o ultimo
  -- pedaco, o "2" escondia o "prod" e o ambiente caia no padrao -- com o
  -- "prod" preso dentro do slug, exatamente onde a Decisao no.2 diz que
  -- ele nao pode ficar. O numero continua no slug: e ele que distingue
  -- uma instancia da outra.
  if v_token ~ '^[0-9]+$' then
    v_penultimo := substring(v_slug from '([a-z0-9]+)-[0-9]+$');

    select ea.environment into v_env
      from environment_aliases ea
     where ea.token = v_penultimo;

    if v_env is not null then
      v_slug := coalesce(
        nullif(regexp_replace(v_slug,
                 '-' || v_penultimo || '-' || v_token || '$',
                 '-' || v_token), ''),
        v_slug);
      return query select v_slug, v_env, true;
    end if;
  end if;

  return query select v_slug, setting_text('default_environment','producao'), false;
end $fn$;

-- ---------------------------------------------------------------------
-- 4. Apelidos
--
-- Mapeia a string BRUTA do alarme -> componente. E o que permite que
-- "RWTech - EB - EnvironmentHealth - api-x-producao" e "Api-X-env" apontem
-- para o mesmo lugar depois de um merge_components().
-- ---------------------------------------------------------------------
create table if not exists component_aliases (
  alias        text primary key,
  component_id bigint      not null references components(id) on delete cascade,
  created_at   timestamptz not null default now()
);

create index if not exists component_aliases_component_idx
  on component_aliases (component_id);

create or replace function normalize_alias(p_raw text)
returns text
language sql immutable parallel safe as $fn$
  select nullif(lower(trim(regexp_replace(coalesce(p_raw,''), '\s+', ' ', 'g'))), '');
$fn$;

-- ---------------------------------------------------------------------
-- 5. resolve_component -- o coracao da auto-descoberta
--
-- p_raw      : identificador principal (nome do recurso / do environment)
-- p_raw_alt  : segunda fonte de ambiente (nome da APLICACAO no Beanstalk --
--              e onde mora "Validacao" quando o environment se chama "-env")
-- p_env_hint : ambiente ja decidido pelo parser; vence tudo
-- p_name_hint: nome de exibicao sugerido
--
-- Cria o componente se nao existir -- sempre com published = false.
-- ---------------------------------------------------------------------
create or replace function resolve_component(
  p_raw       text,
  p_raw_alt   text default null,
  p_env_hint  text default null,
  p_name_hint text default null,
  p_slug_hint text default null
) returns bigint
language plpgsql as $fn$
declare
  v_alias   text;
  v_id      bigint;
  v_slug    text;
  v_env     text;
  v_matched boolean;
  v_nome    text;
begin
  v_alias := normalize_alias(p_raw);

  if v_alias is null then
    raise exception 'resolve_component: identificador vazio';
  end if;

  -- 5.1 apelido conhecido resolve na hora (e o caminho quente)
  select ca.component_id into v_id
    from component_aliases ca
   where ca.alias = v_alias;

  if v_id is not null then
    return v_id;
  end if;

  -- 5.2 derivar slug + ambiente
  select s.slug, s.environment, s.matched
    into v_slug, v_env, v_matched
    from split_environment(p_raw) s;

  -- O nome do environment nao trouxe sufixo? Tenta o nome da aplicacao.
  if not v_matched and p_raw_alt is not null then
    declare
      a_slug text; a_env text; a_matched boolean;
    begin
      select s.slug, s.environment, s.matched
        into a_slug, a_env, a_matched
        from split_environment(p_raw_alt) s;
      if a_matched then
        v_env  := a_env;
        v_slug := coalesce(v_slug, a_slug);
      end if;
    end;
  end if;

  v_slug := coalesce(slugify(p_slug_hint), v_slug, slugify(p_raw));
  v_env  := coalesce(slugify(p_env_hint), v_env, setting_text('default_environment','producao'));

  if v_slug is null then
    raise exception 'resolve_component: nao foi possivel derivar slug de %', p_raw;
  end if;

  -- 5.3 componente ja existe para esse (slug, ambiente)?
  select c.id into v_id
    from components c
   where c.slug = v_slug and c.environment = v_env;

  -- 5.4 nao existe: nasce agora, despublicado
  if v_id is null then
    v_nome := coalesce(
      nullif(trim(p_name_hint), ''),
      initcap(replace(v_slug, '-', ' '))
    );

    insert into components (slug, name, environment, sla_target, discovered_from, published)
    values (v_slug, v_nome, v_env,
            setting_num('default_sla_target', 99.9),
            left(p_raw, 500),
            false)
    on conflict (slug, environment) do update
      set slug = excluded.slug          -- no-op só para o RETURNING vir preenchido
    returning id into v_id;
  end if;

  -- 5.5 memoriza o apelido para a proxima vez
  insert into component_aliases (alias, component_id)
  values (v_alias, v_id)
  on conflict (alias) do nothing;

  return v_id;
end $fn$;

-- ---------------------------------------------------------------------
-- 6. discovery_inbox -- a fila de aprovacao
--
-- Mostra o que o sistema descobriu sozinho, com material suficiente para
-- decidir: quantas quedas ja teve, quando apareceu, e a string bruta que
-- deu origem (onde o typo aparece).
-- ---------------------------------------------------------------------
create or replace view discovery_inbox as
  select c.id,
         c.slug,
         c.name,
         c.environment,
         c.discovered_from,
         c.created_at                                as descoberto_em,
         count(i.id)                                 as incidentes,
         count(i.id) filter (where i.resolved_at is null) as incidentes_abertos,
         max(i.last_seen_at)                         as ultimo_sinal,
         array_agg(distinct ca.alias)                as apelidos
    from components c
    left join incidents i          on i.component_id = c.id
    left join component_aliases ca on ca.component_id = c.id
   where c.published = false
   group by c.id
   order by max(i.last_seen_at) desc nulls last, c.created_at desc;

-- ---------------------------------------------------------------------
-- 7. public_components -- o que a pagina publica enxerga
--
-- published = true E ambiente de producao. Homologacao existe, acumula
-- historico e aparece nos relatorios internos -- so nao vaza pro cliente.
-- ---------------------------------------------------------------------
create or replace view public_components as
  select c.id,
         c.slug,
         c.name,
         c.description,
         c.status,
         c.sla_target,
         c.sort_order
    from components c
   where c.published = true
     and c.environment = 'producao'
   order by c.sort_order, c.name;

-- ---------------------------------------------------------------------
-- 8. publish_component / unpublish_component
-- ---------------------------------------------------------------------
create or replace function publish_component(
  p_slug        text,
  p_environment text default 'producao',
  p_name        text default null,
  p_description text default null,
  p_sla_target  numeric default null
) returns components
language plpgsql as $fn$
declare
  v_row components;
begin
  update components c
     set published   = true,
         name        = coalesce(nullif(trim(p_name), ''), c.name),
         description = coalesce(p_description, c.description),
         sla_target  = coalesce(p_sla_target, c.sla_target)
   where c.slug = p_slug
     and c.environment = p_environment
  returning c.* into v_row;

  if not found then
    raise exception 'publish_component: componente %/% nao existe', p_slug, p_environment;
  end if;

  return v_row;
end $fn$;

create or replace function unpublish_component(
  p_slug        text,
  p_environment text default 'producao'
) returns components
language plpgsql as $fn$
declare
  v_row components;
begin
  update components c set published = false
   where c.slug = p_slug and c.environment = p_environment
  returning c.* into v_row;

  if not found then
    raise exception 'unpublish_component: componente %/% nao existe', p_slug, p_environment;
  end if;

  return v_row;
end $fn$;

-- ---------------------------------------------------------------------
-- 9. merge_components -- conserta a descoberta que errou
--
-- Caso tipico: o mesmo servico entrou duas vezes com nomes diferentes
-- (o alarme de CloudWatch usa "api-tarefa-megas-producao", o do Beanstalk
-- usa "Api-Tarefa-Megas-env"). Repontua incidentes, sinais e apelidos para
-- o destino e apaga a origem.
--
-- Cuidado tratado: se ORIGEM e DESTINO tem incidente ABERTO com o mesmo
-- fingerprint, mover cru violaria incidents_open_uq. Os dois sao fundidos --
-- vale o started_at mais antigo (o inicio real da queda), o last_seen_at
-- mais recente e a soma das ocorrencias.
-- ---------------------------------------------------------------------
create or replace function merge_components(
  p_origem_slug   text,
  p_origem_env    text,
  p_destino_slug  text,
  p_destino_env   text default 'producao'
) returns table (
  incidentes_movidos int,
  incidentes_fundidos int,
  apelidos_movidos   int,
  sinais_movidos     int
)
language plpgsql as $fn$
declare
  v_origem  bigint;
  v_destino bigint;
  v_fundidos int := 0;
  v_movidos  int := 0;
  v_apelidos int := 0;
  v_sinais   int := 0;
begin
  select id into v_origem
    from components where slug = p_origem_slug and environment = p_origem_env;
  select id into v_destino
    from components where slug = p_destino_slug and environment = p_destino_env;

  if v_origem is null then
    raise exception 'merge_components: origem %/% nao existe', p_origem_slug, p_origem_env;
  end if;
  if v_destino is null then
    raise exception 'merge_components: destino %/% nao existe', p_destino_slug, p_destino_env;
  end if;
  if v_origem = v_destino then
    raise exception 'merge_components: origem e destino sao o mesmo componente';
  end if;

  -- Trava os dois componentes SEMPRE em ordem crescente de id -- duas fusoes
  -- simultaneas em sentidos opostos (A->B e B->A) travariam uma na outra.
  -- Namespace 2 = "componente"; a ingestao pega a mesma trava depois de
  -- resolver o componente (ver ingest_function.sql), entao um merge em curso
  -- segura o alarme que chegar no meio.
  perform pg_advisory_xact_lock(2, least(v_origem, v_destino)::int);
  perform pg_advisory_xact_lock(2, greatest(v_origem, v_destino)::int);

  -- 9.1 abertos que colidem: funde no do destino
  with colisoes as (
    select o.id as id_origem, d.id as id_destino,
           least(o.started_at, d.started_at)       as inicio,
           greatest(o.last_seen_at, d.last_seen_at) as visto,
           greatest(o.impact, d.impact)            as impacto,
           o.occurrences + d.occurrences           as ocorrencias
      from incidents o
      join incidents d
        on d.component_id = v_destino
       and d.fingerprint  = o.fingerprint
       and d.resolved_at is null
     where o.component_id = v_origem
       and o.resolved_at is null
  ),
  atualiza as (
    update incidents d
       set started_at   = c.inicio,
           last_seen_at = c.visto,
           impact       = c.impacto,
           occurrences  = c.ocorrencias
      from colisoes c
     where d.id = c.id_destino
    returning c.id_origem
  ),
  remove as (
    delete from incidents where id in (select id_origem from atualiza)
    returning 1
  )
  select count(*) into v_fundidos from remove;

  -- 9.2 o resto migra direto
  with m as (
    update incidents set component_id = v_destino where component_id = v_origem returning 1
  ) select count(*) into v_movidos from m;

  with m as (
    update component_aliases set component_id = v_destino where component_id = v_origem returning 1
  ) select count(*) into v_apelidos from m;

  with m as (
    update monitor_signals set component_id = v_destino where component_id = v_origem returning 1
  ) select count(*) into v_sinais from m;

  -- 9.3 o slug da origem vira apelido do destino: o proximo alarme com o
  --     nome antigo cai no lugar certo em vez de recriar o componente.
  insert into component_aliases (alias, component_id)
  values (normalize_alias(p_origem_slug), v_destino)
  on conflict (alias) do update set component_id = excluded.component_id;

  delete from components where id = v_origem;

  perform refresh_component_status(v_destino);

  return query select v_movidos, v_fundidos, v_apelidos, v_sinais;
end $fn$;
