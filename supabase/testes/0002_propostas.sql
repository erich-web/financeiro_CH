-- =====================================================================
-- Testes da aplicação de propostas
-- Depende de 0001_governanca.sql ter rodado (cria app_user e as pessoas).
-- =====================================================================

\set ON_ERROR_STOP on

-- Um fechamento publicado de referência, com um número para corrigir.
insert into fechamentos (periodo, versao, estado, dados)
values ('2026-10', 1, 'publicado', '{"meta":{"caixa_total":1287877.15,"competencia":"Setembro de 2026"},"alertas":["um"]}');

-- ---------------------------------------------------------------------
\echo '-- 1. Correção de fechamento publicado gera versão nova'
set role app_user;
set teste.jwt = '{"email":"erich@gruporpe.com.br"}';

insert into propostas (autor_id, pedido, resumo, alvo, diff)
select pessoa_atual(),
       'O caixa de setembro era 1.290.000, não 1.287.877',
       'Corrige o caixa total de setembro',
       'fechamento',
       jsonb_build_object(
         'tabela','fechamento_dados','periodo','2026-10',
         'antes', jsonb_build_object('meta.caixa_total', 1287877.15),
         'depois', jsonb_build_object('meta.caixa_total', 1290000)
       );

do $$
declare r jsonb; pid uuid;
begin
  select id into pid from propostas where estado='proposta' order by criado_em desc limit 1;
  r := aplicar_proposta(pid);
  raise notice 'ok: % v% -> v% (% campo)', r->>'periodo', r->>'versao_anterior', r->>'versao_nova', r->>'campos';
end $$;
reset role;

do $$
declare n int; v numeric; comp text; al jsonb;
begin
  select count(*) into n from fechamentos where periodo='2026-10' and estado='publicado';
  if n <> 1 then raise exception 'FALHA: % fechamentos publicados em 2026-10', n; end if;

  select (dados->'meta'->>'caixa_total')::numeric,
         dados->'meta'->>'competencia', dados->'alertas'
    into v, comp, al
  from fechamentos where periodo='2026-10' and estado='publicado';

  if v <> 1290000 then raise exception 'FALHA: caixa gravado %, esperado 1290000', v; end if;
  if comp <> 'Setembro de 2026' then raise exception 'FALHA: perdeu campo vizinho (competencia = %)', comp; end if;
  if al::text <> '["um"]' then raise exception 'FALHA: perdeu alertas (%)', al; end if;

  raise notice 'ok: 1 publicado, caixa %, vizinhos preservados', v;
end $$;

do $$
declare e text;
begin
  select estado into e from fechamentos where periodo='2026-10' and versao=1;
  if e <> 'aprovado' then raise exception 'FALHA: v1 ficou como %, esperado aprovado', e; end if;
  raise notice 'ok: versão anterior rebaixada para %', e;
end $$;

-- ---------------------------------------------------------------------
\echo '-- 2. A mesma proposta não se aplica duas vezes'
set role app_user;
set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
do $$
declare pid uuid;
begin
  select id into pid from propostas where estado='aprovada' order by decidido_em desc limit 1;
  begin
    perform aplicar_proposta(pid);
    raise exception 'FALHA: aplicou duas vezes';
  exception when others then
    if sqlerrm like '%já foi%' then raise notice 'ok: recusado — %', left(sqlerrm,45);
    else raise; end if;
  end;
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 3. Quem não é diretoria não vê nem aplica proposta'

-- Cenário montado como dono da tabela: um fechamento de novembro e uma
-- proposta da diretoria que mexeria nele.
insert into fechamentos (periodo, versao, estado, dados)
  values ('2026-11', 1, 'publicado', '{"meta":{"caixa_total":1}}');

insert into propostas (autor_id, pedido, resumo, alvo, diff)
select p.id, 'teste', 'Mexe no caixa de novembro', 'fechamento',
       jsonb_build_object('tabela','fechamento_dados','periodo','2026-11',
                          'antes', jsonb_build_object('meta.caixa_total', 1),
                          'depois', jsonb_build_object('meta.caixa_total', 999))
from pessoas p where p.email = 'erich@gruporpe.com.br'
returning id as pid \gset

-- O id vai por tabela temporária porque o psql não interpola variável
-- dentro de bloco $$. Simula o pior caso: alguém que descobriu o
-- identificador por fora e tenta aplicar direto.
create temp table alvo_teste as select :'pid'::uuid as pid;
grant select on alvo_teste to app_user;

set role app_user;
set teste.jwt = '{"email":"socio@teste.com"}';

do $$
declare n int;
begin
  select count(*) into n from propostas;
  if n <> 0 then raise exception 'FALHA: sócio viu % proposta(s)', n; end if;
  raise notice 'ok: sócio vê zero propostas';
end $$;

do $$
declare alvo uuid;
begin
  select pid into alvo from alvo_teste;
  begin
    perform aplicar_proposta(alvo);
    raise exception 'FALHA: sócio aplicou proposta';
  exception when others then
    if sqlerrm like 'FALHA%' then raise; end if;
    raise notice 'ok: recusado — %', left(sqlerrm, 52);
  end;
end $$;
reset role;

do $$
declare v numeric;
begin
  select (dados->'meta'->>'caixa_total')::numeric into v
  from fechamentos where periodo='2026-11' and estado='publicado';
  if v <> 1 then raise exception 'FALHA: caixa de novembro mudou para %', v; end if;
  raise notice 'ok: novembro intacto (caixa %)', v;
end $$;

-- ---------------------------------------------------------------------
\echo '-- 4. Pendência: cria e depois resolve'
set role app_user;
set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
do $$
declare pid uuid; r jsonb; nova uuid; est text; quem uuid;
begin
  insert into propostas (autor_id, pedido, resumo, alvo, diff)
  values (pessoa_atual(), 'Abre pendência do DARF', 'Cria pendência do DARF de outubro', 'pendencia',
          jsonb_build_object('tabela','pendencias','antes','{}'::jsonb,
            'depois', jsonb_build_object(
              'titulo','DARF de IRPJ e CSLL','valor','182193.33',
              'prazo','2026-10-31','periodo','2026-10')))
  returning id into pid;

  r := aplicar_proposta(pid);
  nova := (r->>'id')::uuid;
  raise notice 'ok: pendência criada %', left(nova::text,8);

  insert into propostas (autor_id, pedido, resumo, alvo, diff)
  values (pessoa_atual(), 'DARF foi pago', 'Resolve a pendência do DARF', 'pendencia',
          jsonb_build_object('tabela','pendencias','id',nova,
            'antes', jsonb_build_object('estado','aberta'),
            'depois', jsonb_build_object('estado','resolvida','resolucao','Pago em 31/10')))
  returning id into pid;

  perform aplicar_proposta(pid);

  select estado, resolvido_por into est, quem from pendencias where id = nova;
  if est <> 'resolvida' then raise exception 'FALHA: estado %', est; end if;
  if quem is null then raise exception 'FALHA: resolvido_por vazio'; end if;
  raise notice 'ok: pendência resolvida, autor registrado';
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 5. Alvo desconhecido e caminho inválido são recusados'
set role app_user;
set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
do $$
declare pid uuid;
begin
  insert into propostas (autor_id, pedido, resumo, alvo, diff)
  values (pessoa_atual(), 'x', 'x', 'outro',
          jsonb_build_object('tabela','auditoria','antes','{}'::jsonb,
                             'depois', jsonb_build_object('acao','forjado')))
  returning id into pid;
  begin
    perform aplicar_proposta(pid);
    raise exception 'FALHA: alvo auditoria foi aceito';
  exception when others then
    if sqlerrm like '%não suportado%' then raise notice 'ok: recusado — %', left(sqlerrm,52);
    else raise; end if;
  end;

  insert into propostas (autor_id, pedido, resumo, alvo, diff)
  values (pessoa_atual(), 'x', 'x', 'fechamento',
          jsonb_build_object('tabela','fechamento_dados','antes','{}'::jsonb,
                             'depois', jsonb_build_object('meta..caixa', 1)))
  returning id into pid;
  begin
    perform aplicar_proposta(pid);
    raise exception 'FALHA: caminho com .. foi aceito';
  exception when others then
    if sqlerrm like '%inválido%' then raise notice 'ok: recusado — %', left(sqlerrm,52);
    else raise; end if;
  end;

  insert into propostas (autor_id, pedido, resumo, alvo, diff)
  values (pessoa_atual(), 'x', 'x', 'fechamento',
          jsonb_build_object('tabela','fechamento_dados','antes','{}'::jsonb,'depois','{}'::jsonb))
  returning id into pid;
  begin
    perform aplicar_proposta(pid);
    raise exception 'FALHA: proposta vazia foi aceita';
  exception when others then
    if sqlerrm like '%sem nenhuma altera%' then raise notice 'ok: recusado — %', left(sqlerrm,45);
    else raise; end if;
  end;
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 6. Descartar não escreve no painel'
set role app_user;
set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
do $$
declare pid uuid; antes numeric; depois numeric;
begin
  select (dados->'meta'->>'caixa_total')::numeric into antes
  from fechamentos where periodo='2026-10' and estado='publicado';

  insert into propostas (autor_id, pedido, resumo, alvo, diff)
  values (pessoa_atual(), 'muda o caixa', 'Muda o caixa para zero', 'fechamento',
          jsonb_build_object('tabela','fechamento_dados','periodo','2026-10',
            'antes', jsonb_build_object('meta.caixa_total', antes),
            'depois', jsonb_build_object('meta.caixa_total', 0)))
  returning id into pid;

  perform descartar_proposta(pid, 'Número conferido, estava certo');

  select (dados->'meta'->>'caixa_total')::numeric into depois
  from fechamentos where periodo='2026-10' and estado='publicado';

  if antes <> depois then raise exception 'FALHA: descarte alterou o caixa (% -> %)', antes, depois; end if;
  if (select estado from propostas where id=pid) <> 'descartada' then
    raise exception 'FALHA: proposta não ficou descartada';
  end if;
  raise notice 'ok: descartada, caixa segue em %', depois;
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 7. Toda aplicação deixa rastro'
do $$
declare n int; m int;
begin
  select count(*) into n from versoes_painel;
  if n < 3 then raise exception 'FALHA: só % versões registradas', n; end if;

  select count(*) into m from auditoria where entidade='propostas' and acao='UPDATE';
  if m = 0 then raise exception 'FALHA: decisões de proposta não auditadas'; end if;

  raise notice 'ok: % versões no histórico, % decisões auditadas', n, m;
end $$;

\echo ''
\echo '===== testes de proposta passaram ====='
