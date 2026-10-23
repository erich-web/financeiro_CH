-- =====================================================================
-- Testes de governança
--
-- Rodam contra um Postgres local com os stubs de auth.jwt() e storage.
-- Importante: o dono da tabela passa por cima da RLS, então todo teste
-- de permissão roda com SET ROLE para um papel sem privilégio. Testar
-- como superusuário daria tudo verde sem provar nada.
-- =====================================================================

-- Papéis são do cluster, não do banco: criar só se ainda não existir, para
-- que os testes possam rodar de novo sem recriar o cluster.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'app_user') then
    create role app_user nologin;
  end if;
end $$;

grant usage on schema public to app_user;
grant select, insert, update, delete on all tables in schema public to app_user;
grant select on all sequences in schema public to app_user;
grant execute on all functions in schema public to app_user;
grant usage on schema storage to app_user;
grant select, insert, delete on storage.objects to app_user;

-- Pessoas de teste: um sócio comum, um conselheiro, um intruso.
insert into pessoas (nome, email) values
  ('Sócio Teste',      'socio@teste.com'),
  ('Conselheiro Teste','conselho@teste.com');

insert into pessoa_socio (pessoa_id, socio_id)
select p.id, s.id from pessoas p, socios s
where p.email = 'socio@teste.com' and s.nome = 'Hotel Toriba';

insert into pessoa_papeis (pessoa_id, papel)
select id, 'conselho_fiscal' from pessoas where email = 'conselho@teste.com';

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
\echo '-- 1. A soma das participações fecha em 1 exato'
do $$
declare t numeric := capital_total();
begin
  if t <> 1 then raise exception 'capital_total() = %, esperado 1', t; end if;
  raise notice 'ok: capital_total = %', t;
end $$;

-- ---------------------------------------------------------------------
\echo '-- 2. E-mail não cadastrado não lê nada'
set role app_user;
set teste.jwt = '{"email":"intruso@qualquer.com"}';
do $$
declare n int;
begin
  if e_autorizado() then raise exception 'intruso foi autorizado'; end if;
  select count(*) into n from socios;
  if n <> 0 then raise exception 'intruso leu % linhas de socios', n; end if;
  select count(*) into n from pessoas;
  if n <> 0 then raise exception 'intruso leu % linhas de pessoas', n; end if;
  raise notice 'ok: intruso não autorizado, zero linhas';
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 3. Erich representa duas quotistas e soma os dois pesos'
set role app_user;
set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
do $$
declare r record;
begin
  select * into r from v_eu;
  if r.nome is null then raise exception 'v_eu vazia para o Erich'; end if;
  if array_length(r.representa,1) <> 2 then
    raise exception 'representa % quotistas, esperado 2', array_length(r.representa,1);
  end if;
  if r.peso_total <> 0.166364042 then
    raise exception 'peso_total = %, esperado 0.166364042', r.peso_total;
  end if;
  if not r.e_diretoria or not r.e_admin then raise exception 'papéis não reconhecidos'; end if;
  if not r.base_completa then raise exception 'base_completa deveria ser true'; end if;
  raise notice 'ok: % representa % (peso %)', r.nome, r.representa, r.peso_total;
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 4. Fechamento em rascunho é invisível ao sócio e visível à diretoria'
insert into fechamentos (periodo, versao, estado, dados)
values ('2025-12', 1, 'rascunho', '{"teste":1}');

set role app_user;
set teste.jwt = '{"email":"socio@teste.com"}';
do $$
declare n int;
begin
  -- Só o período do teste: o banco já vem com o fechamento real de
  -- 2026-09 publicado, que o sócio enxerga por direito.
  select count(*) into n from fechamentos where periodo = '2025-12';
  if n <> 0 then raise exception 'sócio viu % fechamento(s) em rascunho', n; end if;
  raise notice 'ok: sócio não vê rascunho';
end $$;

do $$
declare n int;
begin
  select count(*) into n from fechamentos where estado = 'publicado';
  if n = 0 then raise exception 'sócio não vê nenhum fechamento publicado'; end if;
  raise notice 'ok: mas vê % período publicado', n;
end $$;

set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
do $$
declare n int;
begin
  select count(*) into n from fechamentos where periodo = '2025-12';
  if n <> 1 then raise exception 'diretoria viu % fechamentos, esperado 1', n; end if;
  raise notice 'ok: diretoria vê rascunho';
end $$;

set teste.jwt = '{"email":"conselho@teste.com"}';
do $$
declare n int;
begin
  select count(*) into n from fechamentos where periodo = '2025-12';
  if n <> 1 then raise exception 'conselho viu % fechamentos, esperado 1', n; end if;
  raise notice 'ok: conselho fiscal vê rascunho';
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 5. Fechamento publicado não pode ter os números alterados'
update fechamentos set estado = 'publicado' where periodo = '2025-12';
do $$
begin
  begin
    update fechamentos set dados = '{"teste":2}' where periodo = '2025-12';
    raise exception 'FALHA: alterou dados de fechamento publicado';
  exception when others then
    if sqlerrm like '%já publicado%' then
      raise notice 'ok: recusado — %', left(sqlerrm, 60);
    else raise; end if;
  end;
end $$;

-- Mas trocar o parecer do conselho continua possível.
update fechamentos set parecer_conselho = 'Favorável' where periodo = '2025-12';
\echo '   ok: parecer ainda editável'

-- ---------------------------------------------------------------------
\echo '-- 6. Matéria a 75%: os votos do Erich não bastam'
insert into materias (titulo, clausula, quorum_exigido, estado, abertura)
select 'Compra de imóvel vizinho', '5.6.2', fracao, 'em_votacao', now()
from quoruns_acordo where clausula = '5.6.2';

set role app_user;
set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
insert into votos (materia_id, socio_id, voto)
select m.id, s.id, 'favor'
from materias m, socios s
where m.clausula = '5.6.2' and s.nome in ('RPE Properties Gestão de Ativos','RPE Empreendimentos e Participações');
reset role;

do $$
declare a record;
begin
  select * into a from apurar_materia((select id from materias where clausula='5.6.2'));
  if a.favor <> 0.166364042 then raise exception 'favor = %, esperado 0.166364042', a.favor; end if;
  if a.atingido then raise exception 'FALHA: 16,6%% atingiu quórum de 75%%'; end if;
  raise notice 'ok: favor %, exigido %, atingido %', a.favor, a.exigido, a.atingido;
end $$;

-- ---------------------------------------------------------------------
\echo '-- 7. O peso do voto não pode vir do cliente'
set role app_user;
set teste.jwt = '{"email":"socio@teste.com"}';
insert into votos (materia_id, socio_id, voto, peso)
select m.id, s.id, 'favor', 1.0
from materias m, socios s
where m.clausula = '5.6.2' and s.nome = 'Hotel Toriba';
reset role;

do $$
declare p numeric;
begin
  select peso into p from votos v join socios s on s.id = v.socio_id
  where s.nome = 'Hotel Toriba';
  if p <> 0.083182021 then
    raise exception 'FALHA: peso forjado passou — gravou %', p;
  end if;
  raise notice 'ok: peso 1.0 enviado pelo cliente foi sobrescrito por %', p;
end $$;

-- ---------------------------------------------------------------------
\echo '-- 8. Não se vota por quotista que não se representa'
set role app_user;
set teste.jwt = '{"email":"socio@teste.com"}';
do $$
begin
  begin
    insert into votos (materia_id, socio_id, voto)
    select m.id, s.id, 'favor' from materias m, socios s
    where m.clausula = '5.6.2' and s.nome = 'Hotel Toriba';
    raise exception 'FALHA: votou duas vezes pela mesma quotista';
  exception when unique_violation then
    raise notice 'ok: voto duplicado recusado';
  end;

  begin
    insert into votos (materia_id, socio_id, voto)
    select m.id, s.id, 'favor' from materias m, socios s
    where m.clausula = '5.6.2' and s.nome = 'Tarundu Empreendimentos Comerciais';
    raise exception 'FALHA: votou por quotista que não representa';
  exception when insufficient_privilege or others then
    if sqlerrm like '%não representa%' or sqlerrm like '%row-level security%' then
      raise notice 'ok: recusado — %', left(sqlerrm, 50);
    else raise; end if;
  end;
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 9. Voto dado não se altera'
set role app_user;
set teste.jwt = '{"email":"socio@teste.com"}';
do $$
declare n int;
begin
  update votos set voto = 'contra'
  where socio_id = (select id from socios where nome = 'Hotel Toriba');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FALHA: alterou % voto(s)', n; end if;
  raise notice 'ok: update de voto não afeta linha nenhuma';
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 10. Unanimidade é alcançável'
insert into materias (titulo, clausula, quorum_exigido, estado, abertura)
select 'Aumento de capital de 50%', '5.6.4', fracao, 'em_votacao', now()
from quoruns_acordo where clausula = '5.6.4';

insert into votos (materia_id, socio_id, voto, via, peso)
select (select id from materias where clausula='5.6.4'), id, 'favor', 'presencial', 0
from socios where ativo;

do $$
declare a record;
begin
  select * into a from apurar_materia((select id from materias where clausula='5.6.4'));
  if a.favor <> 1 then raise exception 'favor = %, esperado 1', a.favor; end if;
  if not a.atingido then
    raise exception 'FALHA: 100%% do capital não atingiu unanimidade (favor %, exigido %)', a.favor, a.exigido;
  end if;
  raise notice 'ok: favor %, unanimidade atingida', a.favor;
end $$;

-- ---------------------------------------------------------------------
\echo '-- 11. Participação zero impede voto'
insert into socios (nome, quotas, capital, participacao) values ('Quotista Sem Anexo', 1, 0, 0);
do $$
begin
  begin
    insert into votos (materia_id, socio_id, voto, via)
    select (select id from materias where clausula='5.6.2'),
           (select id from socios where nome='Quotista Sem Anexo'), 'favor', 'presencial';
    raise exception 'FALHA: aceitou voto de quotista com participação zero';
  exception when others then
    if sqlerrm like '%não cadastrada%' then raise notice 'ok: recusado — %', left(sqlerrm,60);
    else raise; end if;
  end;
end $$;
delete from socios where nome = 'Quotista Sem Anexo';

-- ---------------------------------------------------------------------
\echo '-- 12. Auditoria registra e ninguém consegue forjar linha'
do $$
declare n int;
begin
  select count(*) into n from auditoria where entidade = 'votos';
  if n = 0 then raise exception 'nenhum voto auditado'; end if;
  raise notice 'ok: % linhas de auditoria em votos', n;
end $$;

set role app_user;
set teste.jwt = '{"email":"erich@gruporpe.com.br"}';
do $$
begin
  begin
    insert into auditoria (acao, entidade, ator_email)
    values ('INSERT','socios','forjado@teste.com');
    raise exception 'FALHA: forjou linha de auditoria';
  exception when insufficient_privilege then
    raise notice 'ok: insert direto em auditoria recusado';
  end;
end $$;
reset role;

-- ---------------------------------------------------------------------
\echo '-- 13. Comentário só em nome próprio'
set role app_user;
set teste.jwt = '{"email":"socio@teste.com"}';
do $$
begin
  insert into comentarios (autor_id, ancora_aba, texto)
  values (pessoa_atual(), 'dre', 'Por que a depreciação pulou em fevereiro?');
  raise notice 'ok: comentário próprio aceito';

  begin
    insert into comentarios (autor_id, ancora_aba, texto)
    values ((select id from pessoas where email='erich@gruporpe.com.br'), 'dre', 'forjado');
    raise exception 'FALHA: comentou em nome de outro';
  exception when insufficient_privilege then
    raise notice 'ok: comentário em nome de terceiro recusado';
  end;
end $$;
reset role;

\echo ''
\echo '===== todos os testes passaram ====='
