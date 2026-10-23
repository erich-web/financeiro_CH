-- =====================================================================
-- Testes das visões das telas de governança (migração 0006)
-- Depende de 0001_governanca.sql, que cria app_user, as pessoas e os votos.
-- =====================================================================

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
\echo '-- 1. v_eu traz os ids das quotistas, não só os nomes'
set role app_user;
set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
do $$
declare r record; n_nomes int; n_ids int;
begin
  select * into r from v_eu;
  n_nomes := array_length(r.representa, 1);
  n_ids   := array_length(r.representa_ids, 1);

  if n_ids is distinct from n_nomes then
    raise exception 'FALHA: % nomes contra % ids', n_nomes, n_ids;
  end if;
  if n_ids <> 2 then raise exception 'FALHA: % ids, esperado 2', n_ids; end if;

  -- os ids têm de apontar para as quotistas cujos nomes a visão devolveu
  if exists (
    select 1 from unnest(r.representa_ids) i
    where (select nome from socios where id = i) <> all (r.representa)
  ) then
    raise exception 'FALHA: id devolvido não corresponde a nenhum dos nomes';
  end if;

  raise notice 'ok: % ids casando com % nomes', n_ids, n_nomes;
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 2. Sem quota, representa_ids volta vazio e não nulo'
set role app_user;
set teste.jwt = '{"email":"conselho@teste.com"}';
do $$
declare r record;
begin
  select * into r from v_eu;
  if r.representa_ids is null then
    raise exception 'FALHA: representa_ids nulo quebraria a tela de voto';
  end if;
  if coalesce(array_length(r.representa_ids, 1), 0) <> 0 then
    raise exception 'FALHA: conselheiro sem quota tem % ids', array_length(r.representa_ids, 1);
  end if;
  if r.e_socio then raise exception 'FALHA: conselheiro marcado como sócio'; end if;
  raise notice 'ok: conselheiro sem quota, lista vazia';
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 3. v_votos nomeia a quotista e quem exerceu o voto'
set role app_user;
set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
do $$
declare r record;
begin
  select * into r from v_votos
  where socio_nome = 'RPE Properties Gestão de Ativos' limit 1;

  if r.id is null then raise exception 'FALHA: voto da RPE Properties não apareceu'; end if;
  if r.pessoa_nome <> 'Erich Progin' then
    raise exception 'FALHA: pessoa_nome = %', coalesce(r.pessoa_nome, '(nulo)');
  end if;
  if r.peso <> 0.083182021 then raise exception 'FALHA: peso %', r.peso; end if;
  raise notice 'ok: % votou por % com peso %', r.pessoa_nome, r.socio_nome, r.peso;
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 4. Voto é nominal e aberto: todo sócio lê todos'
set role app_user;
set teste.jwt = '{"email":"socio@teste.com"}';
do $$
declare n int; meus int;
begin
  select count(*) into n from v_votos;
  select count(*) into meus from v_votos
  where socio_id in (select socios_representados());

  if n = 0 then raise exception 'FALHA: sócio não lê voto nenhum'; end if;
  if n <= meus then
    raise exception 'FALHA: sócio lê % votos e % são dele — não vê os dos outros', n, meus;
  end if;
  raise notice 'ok: sócio lê % votos, sendo % dele', n, meus;
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 5. v_comentarios marca o que é meu'
set role app_user;
set teste.jwt = '{"email":"socio@teste.com"}';
do $$
declare r record;
begin
  select * into r from v_comentarios where ancora_aba = 'dre' limit 1;
  if r.id is null then raise exception 'FALHA: comentário do DRE não apareceu'; end if;
  if r.autor_nome <> 'Sócio Teste' then raise exception 'FALHA: autor %', r.autor_nome; end if;
  if not r.meu then raise exception 'FALHA: o próprio comentário não foi marcado como meu'; end if;
  raise notice 'ok: comentário de % marcado como meu', r.autor_nome;
end $$;

set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
do $$
declare r record;
begin
  select * into r from v_comentarios where ancora_aba = 'dre' limit 1;
  if r.id is null then raise exception 'FALHA: outro autorizado não lê o comentário'; end if;
  if r.meu then raise exception 'FALHA: comentário de terceiro marcado como meu'; end if;
  raise notice 'ok: para outra pessoa, o mesmo comentário não é "meu"';
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 6. Pendência criada pelo painel respeita o dono'
set role app_user;
set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
do $$
declare pid uuid; dono uuid; nome text;
begin
  insert into pendencias (titulo, dono_id, prazo, origem, criado_por)
  select 'Conferir rateio de energia',
         (select id from pessoas where email = 'socio@teste.com'),
         current_date + 7, 'painel', pessoa_atual()
  returning id into pid;

  select dono_id into dono from pendencias where id = pid;
  select dono_nome into nome from v_pendencias where id = pid;

  if nome <> 'Sócio Teste' then raise exception 'FALHA: dono_nome = %', coalesce(nome,'(nulo)'); end if;
  raise notice 'ok: pendência com dono % resolvido pela visão', nome;
end $$;
reset role;

-- O dono move a própria pendência mesmo sem ser diretoria.
set role app_user;
set teste.jwt = '{"email":"socio@teste.com"}';
do $$
declare n int;
begin
  update pendencias set estado = 'em_andamento'
  where titulo = 'Conferir rateio de energia';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FALHA: dono não conseguiu mover a própria (% linhas)', n; end if;
  raise notice 'ok: o dono move a própria pendência';
end $$;
reset role;

-- Mas não a de outro.
set role app_user;
set teste.jwt = '{"email":"conselho@teste.com"}';
do $$
declare n int;
begin
  update pendencias set estado = 'resolvida'
  where titulo = 'Conferir rateio de energia';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FALHA: terceiro alterou pendência alheia (% linhas)', n; end if;
  raise notice 'ok: terceiro sem papel não altera pendência alheia';
end $$;
reset role;

\echo ''
\echo '===== testes das visões de tela passaram ====='
