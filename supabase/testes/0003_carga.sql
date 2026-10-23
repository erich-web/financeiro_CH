-- =====================================================================
-- Testes da carga do fechamento
--
-- Confere que os números chegaram ao banco iguais aos que o painel
-- mostrava, e que o sócio só vê o que foi publicado.
-- =====================================================================

\set ON_ERROR_STOP on

\echo '-- 1. O fechamento entrou e está publicado'
do $$
declare e text; v int;
begin
  select estado, versao into e, v from fechamentos where periodo = '2026-09';
  if e is null then raise exception 'FALHA: fechamento 2026-09 não existe'; end if;
  if e <> 'publicado' then raise exception 'FALHA: estado %', e; end if;
  raise notice 'ok: 2026-09 v% %', v, e;
end $$;

\echo '-- 2. Os números batem com o painel que está no ar'
do $$
declare d jsonb; caixa numeric; receita numeric; ago numeric; n int;
begin
  select dados into d from fechamentos where periodo = '2026-09';

  caixa := (d -> 'meta' ->> 'caixa_total')::numeric;
  if caixa <> 1287877.15 then
    raise exception 'FALHA: caixa %, esperado 1287877.15', caixa;
  end if;

  select sum(x::numeric) into receita
  from jsonb_array_elements_text(d -> 'dre' -> 'receita_bruta') x;
  if round(receita, 2) <> 3348867.90 then
    raise exception 'FALHA: receita acumulada %, esperado 3348867.90', receita;
  end if;

  ago := (d -> 'dre' -> 'resultado' ->> 7)::numeric;
  if ago <> 57505.82 then
    raise exception 'FALHA: resultado de agosto %, esperado 57505.82', ago;
  end if;

  if d -> 'estacionamento' is null then raise exception 'FALHA: estacionamento não veio'; end if;
  if d -> 'socios' is not null then
    raise exception 'FALHA: quadro societário ficou duplicado no payload';
  end if;

  select count(*) into n from jsonb_array_elements(d -> 'receber');
  if n <> 19 then raise exception 'FALHA: % parcelas a receber, esperado 19', n; end if;

  raise notice 'ok: caixa %, receita %, agosto %, 19 parcelas', caixa, round(receita,2), ago;
end $$;

\echo '-- 3. O painel monta o quadro societário pela tabela, não pelo payload'
do $$
declare n int; soma numeric;
begin
  select count(*), sum(participacao) into n, soma from socios where ativo;
  if n <> 11 then raise exception 'FALHA: % quotistas, esperado 11', n; end if;
  if soma <> 1 then raise exception 'FALHA: participações somam %', soma; end if;
  raise notice 'ok: 11 quotistas, participações somam %', soma;
end $$;

\echo '-- 4. O sócio vê o fechamento publicado'
set role app_user;
set teste.jwt = '{"email":"socio@teste.com"}';
do $$
declare n int; caixa numeric;
begin
  select count(*) into n from v_fechamento_vigente;
  if n = 0 then raise exception 'FALHA: sócio não vê nenhum fechamento publicado'; end if;
  select (dados -> 'meta' ->> 'caixa_total')::numeric into caixa
  from v_fechamento_vigente where periodo = '2026-09';
  if caixa <> 1287877.15 then raise exception 'FALHA: sócio lê caixa %', caixa; end if;
  raise notice 'ok: sócio lê o caixa publicado (%)', caixa;
end $$;
reset role;

\echo ''
\echo '===== testes de carga passaram ====='
