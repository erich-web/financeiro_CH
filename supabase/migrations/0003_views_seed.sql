-- =====================================================================
-- Migração 0003: visões de apoio e carga inicial
-- =====================================================================

-- security_invoker: a visão roda com os privilégios de quem consulta, e a
-- RLS das tabelas por baixo vale. Sem isso, a visão roda como o dono e
-- devolve tudo a qualquer um — inclusive à chave anônima. Ver o teste
-- 0005_vazamento.sql, que provou o vazamento antes desta correção.

-- ---------------------------------------------------------------------
-- Quem sou eu
-- Primeira chamada do painel depois do login. Decide o que a tela mostra,
-- inclusive se o botão do chat aparece. A decisão de exibir é conforto;
-- a de permitir é da RLS, que não depende desta visão.
-- ---------------------------------------------------------------------
create or replace view v_eu with (security_invoker = true) as
select
  p.id, p.nome, p.email,
  coalesce(array_agg(distinct pp.papel) filter (where pp.papel is not null), '{}') as papeis,
  tem_papel('diretoria')      as e_diretoria,
  tem_papel('conselho_fiscal') as e_conselho,
  tem_papel('admin')          as e_admin,
  e_socio()                   as e_socio,
  coalesce((select array_agg(s.nome order by s.nome)
            from socios s where s.id in (select socios_representados())), '{}') as representa,
  coalesce((select sum(s.participacao)
            from socios s where s.id in (select socios_representados())), 0) as peso_total,
  capital_total() as capital_total,
  abs(capital_total() - 1) < 0.000001 as base_completa
from pessoas p
left join pessoa_papeis pp on pp.pessoa_id = p.id
where p.id = pessoa_atual()
group by p.id, p.nome, p.email;

-- ---------------------------------------------------------------------
-- Quadro societário com representantes
-- ---------------------------------------------------------------------
create or replace view v_socios with (security_invoker = true) as
select
  s.id, s.nome, s.quotas, s.capital, s.participacao, s.integralizado, s.ativo,
  s.observacao,
  coalesce((select array_agg(p.nome order by p.nome)
            from pessoa_socio ps join pessoas p on p.id = ps.pessoa_id
            where ps.socio_id = s.id and p.ativo), '{}') as representantes
from socios s;

-- ---------------------------------------------------------------------
-- Fechamento vigente de cada período
-- ---------------------------------------------------------------------
create or replace view v_fechamento_vigente with (security_invoker = true) as
select distinct on (periodo)
  id, periodo, versao, estado, dados, publicado_em, parecer_conselho
from fechamentos
where estado = 'publicado'
order by periodo desc, versao desc;

-- ---------------------------------------------------------------------
-- Matérias com apuração já calculada
-- ---------------------------------------------------------------------
create or replace view v_materias with (security_invoker = true) as
select m.*, q.rotulo as quorum_rotulo,
       a.favor, a.contra, a.abstencao, a.nao_votou,
       a.atingido, a.capital, a.base_completa
from materias m
left join quoruns_acordo q on q.clausula = m.clausula
left join lateral apurar_materia(m.id) a on true;

-- ---------------------------------------------------------------------
-- Pendências com nome do dono
-- ---------------------------------------------------------------------
create or replace view v_pendencias with (security_invoker = true) as
select pe.*, p.nome as dono_nome, r.nome as resolvido_nome
from pendencias pe
left join pessoas p on p.id = pe.dono_id
left join pessoas r on r.id = pe.resolvido_por;

-- =====================================================================
-- Carga inicial — quadro societário
--
-- Participação calculada sobre o capital integralizado de cada quotista,
-- porque o acordo mede quórum em percentual de capital. Soma exata: 1.
-- O resíduo de arredondamento de 1e-9 foi atribuído ao maior quotista;
-- sem isso a soma daria 0,999999999 e unanimidade seria inalcançável.
--
-- Duas divergências entre quota e capital, anotadas para conferência
-- contra o Anexo I do contrato social:
--   Tarundu      1 quota, R$ 270.834 — acima do valor de uma quota
--   Fábio/Cesar  1 quota, R$ 259.896 — abaixo do valor de uma quota
-- Se o Anexo I disser outra coisa, é ele que vale: corrigir aqui.
-- =====================================================================
insert into socios (nome, quotas, capital, participacao, integralizado, observacao) values
  ('FRK Empreendimentos e Participações', 2, 525000, 0.166364044, true, null),
  ('JRCL Empreendimentos Imobiliários', 1, 262500, 0.083182021, true, null),
  ('Luiz de Oliveira Rozette Filho', 1, 262500, 0.083182021, true, null),
  ('RPE Properties Gestão de Ativos', 1, 262500, 0.083182021, true, null),
  ('RPE Empreendimentos e Participações', 1, 262500, 0.083182021, true, null),
  ('Guimarães Confiance Administrativo', 1, 262500, 0.083182021, true, null),
  ('XRBM Empreendimentos e Participações', 1, 262500, 0.083182021, true, null),
  ('Hotel Toriba', 1, 262500, 0.083182021, true, null),
  ('Tarundu Empreendimentos Comerciais', 1, 270834, 0.085822932, true, null),
  ('Fábio Izar / Cesar Augusto F. dos Santos', 1, 259896, 0.082356856, true, null),
  ('RAMFEJ Engenharia', 1, 262500, 0.083182021, false, 'Pendente – chamada abr/mai')
on conflict (lower(nome)) do nothing;

-- =====================================================================
-- Carga inicial — pessoas
--
-- Só o Erich entra agora, porque é o único e-mail conhecido. Sem linha em
-- pessoas, o e-mail recebe o link mágico, entra e não lê nada: é assim que
-- o painel fica fechado mesmo antes do cadastro completo.
--
-- A ligação dele com RPE Properties e RPE Empreendimentos é inferência
-- minha, pelas duas serem empresas do Grupo RPE. Confirmar.
-- =====================================================================
insert into pessoas (nome, email, observacao) values
  ('Erich Progin', 'erich@gruporpe.com.br', 'Representação a confirmar')
on conflict (lower(email)) do nothing;

insert into pessoa_papeis (pessoa_id, papel)
select p.id, v.papel
from pessoas p
cross join (values ('diretoria'::papel_tipo), ('admin'::papel_tipo)) v(papel)
where lower(p.email) = 'erich@gruporpe.com.br'
on conflict do nothing;

insert into pessoa_socio (pessoa_id, socio_id)
select p.id, s.id
from pessoas p, socios s
where lower(p.email) = 'erich@gruporpe.com.br'
  and s.nome in ('RPE Properties Gestão de Ativos', 'RPE Empreendimentos e Participações')
on conflict do nothing;

-- ---------------------------------------------------------------------
-- Modelo para os demais — completar com os e-mails e rodar
--
-- O Arthur precisa de 'diretoria'. Ele é quotista, mas quem opera o painel
-- é o diretor: os dois ficam separados para que a auditoria registre em
-- qual condição ele agiu. Ser sócio vem de pessoa_socio, não de papel.
--
-- insert into pessoas (nome, email) values ('Arthur <sobrenome>', '<email>');
--
-- insert into pessoa_papeis (pessoa_id, papel)
-- select id, 'diretoria' from pessoas where lower(email) = '<email>';
--
-- insert into pessoa_socio (pessoa_id, socio_id)
-- select p.id, s.id from pessoas p, socios s
-- where lower(p.email) = '<email>' and s.nome = '<quotista que ele representa>';
-- ---------------------------------------------------------------------
