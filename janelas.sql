-- =====================================================================
--  janelas.sql  ·  Auxiliares para os horarios de maquina reduzida
--  Executar DEPOIS de api.sql.
--
--  A TABELA e a funcao janelas_do_periodo() vivem em schema.sql, junto de
--  downtime_seconds() -- que depende delas. Definir a mesma funcao em dois
--  arquivos ja causou regressao aqui: rodar api.sql depois de janelas.sql
--  desfazia o desconto e o uptime subia sozinho, sem erro nenhum.
--
--  Aqui ficam so as conveniencias de cadastro e leitura.
-- =====================================================================

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
