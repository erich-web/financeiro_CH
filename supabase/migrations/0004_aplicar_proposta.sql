-- =====================================================================
-- Migração 0004: aplicação de propostas
--
-- Publicar uma proposta precisa ser atômico. Corrigir um número de um
-- fechamento publicado significa rebaixar a versão vigente e inserir a
-- nova — se isso acontecer em dois passos pelo navegador e o segundo
-- falhar, o período fica sem versão publicada, ou com duas. O corpo de
-- uma função roda em transação única, então os dois passos acontecem
-- juntos ou nenhum acontece.
--
-- A função é SECURITY INVOKER de propósito: roda com os privilégios de
-- quem chamou, e a RLS continua valendo. Quem não é diretoria não lê a
-- proposta, e sem ler não aplica.
--
-- Nada de SQL dinâmico. As colunas alteráveis de cada tabela estão
-- escritas uma por uma: é mais verboso e impede que uma proposta mal
-- formada alcance coluna que ninguém pretendia expor.
-- =====================================================================

create or replace function aplicar_proposta(p_proposta uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  pr        record;
  d         jsonb;          -- diff -> 'depois'
  tabela    text;
  v_id      uuid;
  f         record;
  novo      jsonb;
  nova_ver  integer;
  k         text;
  v         jsonb;
  resultado jsonb;
begin
  select * into pr from propostas where id = p_proposta;

  if pr.id is null then
    raise exception 'Proposta não encontrada — ou você não tem acesso a ela.';
  end if;
  if pr.estado <> 'proposta' then
    raise exception 'Proposta já foi % em %.', pr.estado, to_char(pr.decidido_em, 'DD/MM/YYYY HH24:MI');
  end if;

  tabela := pr.diff ->> 'tabela';
  v_id   := nullif(pr.diff ->> 'id', '')::uuid;
  d      := coalesce(pr.diff -> 'depois', '{}'::jsonb);

  if d = '{}'::jsonb then
    raise exception 'Proposta sem nenhuma alteração.';
  end if;

  -- -------------------------------------------------------------------
  -- Demonstrações: nunca edita o publicado, gera versão nova
  -- -------------------------------------------------------------------
  if tabela = 'fechamento_dados' then
    select * into f from fechamentos
    where estado = 'publicado'
      and (pr.diff ->> 'periodo' is null or periodo = pr.diff ->> 'periodo')
    order by periodo desc, versao desc limit 1;

    if f.id is null then
      raise exception 'Não há fechamento publicado para corrigir.';
    end if;

    novo := f.dados;
    for k, v in select key, value from jsonb_each(d) loop
      if k = '' or k like '%..%' then
        raise exception 'Caminho inválido na proposta: "%"', k;
      end if;
      novo := jsonb_set(novo, string_to_array(k, '.'), v, true);
    end loop;

    select coalesce(max(versao), 0) + 1 into nova_ver
    from fechamentos where periodo = f.periodo;

    -- Rebaixa a vigente antes de inserir: o índice único só admite um
    -- fechamento publicado por período.
    update fechamentos set estado = 'aprovado' where id = f.id;

    insert into fechamentos
      (periodo, versao, estado, dados, observacao, criado_por, publicado_por, publicado_em, parecer_conselho)
    values
      (f.periodo, nova_ver, 'publicado', novo,
       'Correção pelo assistente: ' || coalesce(pr.resumo, '(sem resumo)'),
       pr.autor_id, pessoa_atual(), now(), f.parecer_conselho);

    resultado := jsonb_build_object(
      'tabela', tabela, 'periodo', f.periodo,
      'versao_anterior', f.versao, 'versao_nova', nova_ver,
      'campos', (select count(*) from jsonb_each(d))
    );

  -- -------------------------------------------------------------------
  -- Pendências
  -- -------------------------------------------------------------------
  elsif tabela = 'pendencias' then
    if v_id is null then
      insert into pendencias (titulo, descricao, dono_id, prazo, estado, periodo, valor, origem, criado_por)
      values (
        coalesce(d ->> 'titulo', '(sem título)'),
        d ->> 'descricao',
        nullif(d ->> 'dono_id', '')::uuid,
        nullif(d ->> 'prazo', '')::date,
        coalesce(nullif(d ->> 'estado', '')::pendencia_estado, 'aberta'),
        nullif(d ->> 'periodo', ''),
        nullif(d ->> 'valor', '')::numeric,
        'assistente',
        pr.autor_id
      ) returning id into v_id;
    else
      update pendencias set
        titulo        = coalesce(d ->> 'titulo', titulo),
        descricao     = coalesce(d ->> 'descricao', descricao),
        dono_id       = coalesce(nullif(d ->> 'dono_id', '')::uuid, dono_id),
        prazo         = coalesce(nullif(d ->> 'prazo', '')::date, prazo),
        estado        = coalesce(nullif(d ->> 'estado', '')::pendencia_estado, estado),
        valor         = coalesce(nullif(d ->> 'valor', '')::numeric, valor),
        resolucao     = coalesce(d ->> 'resolucao', resolucao),
        resolvido_por = case when (d ->> 'estado') = 'resolvida' then pessoa_atual() else resolvido_por end,
        resolvido_em  = case when (d ->> 'estado') = 'resolvida' then now() else resolvido_em end
      where id = v_id;

      if not found then raise exception 'Pendência % não encontrada.', v_id; end if;
    end if;
    resultado := jsonb_build_object('tabela', tabela, 'id', v_id);

  -- -------------------------------------------------------------------
  -- Matérias
  -- -------------------------------------------------------------------
  elsif tabela = 'materias' then
    if v_id is null then
      insert into materias (titulo, descricao, clausula, quorum_exigido, estado, prazo, criado_por)
      values (
        coalesce(d ->> 'titulo', '(sem título)'),
        d ->> 'descricao',
        d ->> 'clausula',
        coalesce(
          nullif(d ->> 'quorum_exigido', '')::numeric,
          (select fracao from quoruns_acordo where clausula = d ->> 'clausula'),
          0.500001
        ),
        coalesce(nullif(d ->> 'estado', '')::materia_estado, 'rascunho'),
        nullif(d ->> 'prazo', '')::timestamptz,
        pr.autor_id
      ) returning id into v_id;
    else
      update materias set
        titulo      = coalesce(d ->> 'titulo', titulo),
        descricao   = coalesce(d ->> 'descricao', descricao),
        clausula    = coalesce(d ->> 'clausula', clausula),
        estado      = coalesce(nullif(d ->> 'estado', '')::materia_estado, estado),
        prazo       = coalesce(nullif(d ->> 'prazo', '')::timestamptz, prazo),
        abertura    = case when (d ->> 'estado') = 'em_votacao' and abertura is null
                           then now() else abertura end
      where id = v_id;

      if not found then raise exception 'Matéria % não encontrada.', v_id; end if;
    end if;
    resultado := jsonb_build_object('tabela', tabela, 'id', v_id);

  -- -------------------------------------------------------------------
  -- Documentos
  -- -------------------------------------------------------------------
  elsif tabela = 'documentos' then
    if v_id is null then
      insert into documentos (nome, tipo, periodo, url_externa, descricao, enviado_por)
      values (
        coalesce(d ->> 'nome', '(sem nome)'),
        d ->> 'tipo',
        nullif(d ->> 'periodo', ''),
        d ->> 'url_externa',
        d ->> 'descricao',
        pr.autor_id
      ) returning id into v_id;
    else
      update documentos set
        nome        = coalesce(d ->> 'nome', nome),
        tipo        = coalesce(d ->> 'tipo', tipo),
        periodo     = coalesce(nullif(d ->> 'periodo', ''), periodo),
        url_externa = coalesce(d ->> 'url_externa', url_externa),
        descricao   = coalesce(d ->> 'descricao', descricao)
      where id = v_id;

      if not found then raise exception 'Documento % não encontrado.', v_id; end if;
    end if;
    resultado := jsonb_build_object('tabela', tabela, 'id', v_id);

  else
    raise exception 'Alvo não suportado: "%". Esperado fechamento_dados, pendencias, materias ou documentos.', tabela;
  end if;

  -- -------------------------------------------------------------------
  update propostas set
    estado = 'aprovada', decidido_por = pessoa_atual(), decidido_em = now()
  where id = p_proposta;

  insert into versoes_painel (rotulo, snapshot, proposta_id, publicado_por, vigente)
  values (coalesce(pr.resumo, 'Alteração pelo assistente'),
          jsonb_build_object('diff', pr.diff, 'resultado', resultado),
          p_proposta, pessoa_atual(), false);

  return resultado;
end $$;

comment on function aplicar_proposta(uuid) is
  'Aplica uma proposta do assistente em transação única. Correção de '
  'fechamento publicado gera versão nova em vez de editar a antiga.';

-- ---------------------------------------------------------------------
-- Descartar é só marcar — nada é escrito no painel.
-- ---------------------------------------------------------------------
create or replace function descartar_proposta(p_proposta uuid, p_motivo text default null)
returns void
language plpgsql security invoker set search_path = public
as $$
begin
  update propostas set
    estado = 'descartada', motivo = p_motivo,
    decidido_por = pessoa_atual(), decidido_em = now()
  where id = p_proposta and estado = 'proposta';

  if not found then
    raise exception 'Proposta não encontrada ou já decidida.';
  end if;
end $$;
