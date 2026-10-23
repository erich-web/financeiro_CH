-- =====================================================================
-- Testes de vazamento
--
-- Os testes anteriores provam que cada pessoa vê o que deve. Estes provam
-- o outro lado: que quem não deve ver não vê nada, por nenhum caminho —
-- tabela, visão ou chave anônima.
--
-- Existem porque uma visão no Postgres roda, por padrão, com os
-- privilégios do dono, e não de quem consulta. Sem security_invoker, uma
-- visão sobre tabela protegida por RLS devolve tudo a qualquer um. Os
-- testes de tabela não pegavam isso, porque nunca consultavam as visões
-- pelo lado negativo.
-- =====================================================================

\set ON_ERROR_STOP on

-- Uma matéria em rascunho, para provar que o sócio não a enxerga.
insert into materias (titulo, clausula, quorum_exigido, estado)
values ('Rascunho que só a diretoria vê', '5.5', 0.500001, 'rascunho');

-- E uma proposta aberta da diretoria.
insert into propostas (autor_id, pedido, resumo, alvo, diff)
select id, 'teste', 'Proposta interna', 'fechamento',
       '{"tabela":"fechamento_dados","antes":{},"depois":{"meta.x":1}}'::jsonb
from pessoas where email = 'erich@gruporpe.com.br';

-- ---------------------------------------------------------------------
\echo '-- 1. Intruso logado com e-mail fora do cadastro não lê visão nenhuma'
set role app_user;
set teste.jwt = '{"email":"intruso@qualquer.com"}';
do $$
declare v text; n bigint; vazou text[] := '{}';
begin
  foreach v in array array[
    'v_eu','v_socios','v_fechamento_vigente','v_materias',
    'v_pendencias','v_votos','v_comentarios'
  ] loop
    execute format('select count(*) from %I', v) into n;
    if n > 0 then vazou := vazou || (v || ': ' || n); end if;
  end loop;
  if coalesce(array_length(vazou, 1), 0) > 0 then
    raise exception 'FALHA: intruso leu linhas em %', array_to_string(vazou, ', ');
  end if;
  raise notice 'ok: zero linhas nas 7 visões';
end $$;

\echo '-- 2. Intruso não lê tabela nenhuma'
do $$
declare t text; n bigint; vazou text[] := '{}';
begin
  foreach t in array array[
    'socios','pessoas','pessoa_socio','pessoa_papeis','fechamentos',
    'pendencias','comentarios','materias','votos','quoruns_acordo',
    'documentos','propostas','versoes_painel','auditoria'
  ] loop
    execute format('select count(*) from %I', t) into n;
    if n > 0 then vazou := vazou || (t || ': ' || n); end if;
  end loop;
  if coalesce(array_length(vazou, 1), 0) > 0 then
    raise exception 'FALHA: intruso leu linhas em %', array_to_string(vazou, ', ');
  end if;
  raise notice 'ok: zero linhas nas 14 tabelas';
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 3. A chave anônima, sem login, não lê nada'
set role anon;
reset teste.jwt;
do $$
declare o text; n bigint; vazou text[] := '{}'; negados int := 0;
begin
  foreach o in array array[
    'v_eu','v_socios','v_fechamento_vigente','v_materias','v_pendencias',
    'v_votos','v_comentarios','socios','pessoas','fechamentos','pendencias',
    'comentarios','materias','votos','documentos','propostas','auditoria'
  ] loop
    begin
      execute format('select count(*) from %I', o) into n;
      if n > 0 then vazou := vazou || (o || ': ' || n); end if;
    exception when insufficient_privilege then
      negados := negados + 1;   -- sem permissão nenhuma também serve
    end;
  end loop;
  if coalesce(array_length(vazou, 1), 0) > 0 then
    raise exception 'FALHA: anônimo leu linhas em %', array_to_string(vazou, ', ');
  end if;
  raise notice 'ok: anônimo não leu nada (% objetos negados de saída, o resto vazio)', negados;
end $$;

do $$
declare f text; executou text[] := '{}';
begin
  foreach f in array array[
    'select aplicar_proposta(gen_random_uuid())',
    'select descartar_proposta(gen_random_uuid())',
    'select capital_total()',
    'select * from apurar_materia(gen_random_uuid())'
  ] loop
    begin
      execute f;
      executou := executou || f;
    exception
      when insufficient_privilege then null;   -- o esperado
      when others then executou := executou || (f || ' [' || sqlerrm || ']');
    end;
  end loop;
  if coalesce(array_length(executou, 1), 0) > 0 then
    raise exception 'FALHA: anônimo executou %', array_to_string(executou, '; ');
  end if;
  raise notice 'ok: anônimo não executa nenhuma função do painel';
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 4. O sócio não vê rascunho nem proposta, nem pela visão'
set role app_user;
set teste.jwt = '{"email":"socio@teste.com"}';
do $$
declare n bigint;
begin
  select count(*) into n from v_materias where estado = 'rascunho';
  if n > 0 then raise exception 'FALHA: sócio viu % matéria(s) em rascunho pela visão', n; end if;

  select count(*) into n from propostas;
  if n > 0 then raise exception 'FALHA: sócio viu % proposta(s)', n; end if;

  select count(*) into n from v_materias;
  if n = 0 then raise exception 'FALHA: sócio não vê nem as matérias em votação'; end if;

  raise notice 'ok: % matérias visíveis, nenhuma em rascunho, nenhuma proposta', n;
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 5. A diretoria continua vendo o rascunho'
set role app_user;
set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
do $$
declare n bigint;
begin
  select count(*) into n from v_materias where estado = 'rascunho';
  if n = 0 then raise exception 'FALHA: a correção escondeu o rascunho da própria diretoria'; end if;
  raise notice 'ok: diretoria vê % rascunho(s)', n;
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 6. Nenhuma visão roda com privilégio do dono'
do $$
declare r record; inseguras text[] := '{}';
begin
  for r in
    select c.relname
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'
      and not coalesce(
        (select bool_or(o = 'security_invoker=true' or o = 'security_invoker=on')
         from unnest(c.reloptions) o), false)
  loop
    inseguras := inseguras || r.relname::text;
  end loop;
  if coalesce(array_length(inseguras, 1), 0) > 0 then
    raise exception 'FALHA: visões sem security_invoker: %', array_to_string(inseguras, ', ');
  end if;
  raise notice 'ok: todas as visões do schema public são security_invoker';
end $$;

\echo ''
\echo '===== testes de vazamento passaram ====='
