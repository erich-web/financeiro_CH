-- =====================================================================
-- Migração 0006: visões para as telas de pendência, comentário e voto
--
-- Aditiva: não altera nada de 0001 a 0005.
-- =====================================================================

-- ---------------------------------------------------------------------
-- v_eu passa a trazer os ids das quotistas representadas, não só os
-- nomes. A tela de votação precisa de id para montar um botão por
-- quotista — com nome não dá para votar.
-- Recriada em vez de substituída: "create or replace view" exige as mesmas
-- colunas na mesma ordem, e representa_ids entra no meio. Nada depende de
-- v_eu além do painel, então derrubar e refazer é seguro.
-- ---------------------------------------------------------------------
drop view if exists v_eu;

create view v_eu as
select
  p.id, p.nome, p.email,
  coalesce(array_agg(distinct pp.papel) filter (where pp.papel is not null), '{}') as papeis,
  tem_papel('diretoria')       as e_diretoria,
  tem_papel('conselho_fiscal') as e_conselho,
  tem_papel('admin')           as e_admin,
  e_socio()                    as e_socio,
  coalesce((select array_agg(s.nome order by s.nome)
            from socios s where s.id in (select socios_representados())), '{}') as representa,
  coalesce((select array_agg(s.id order by s.nome)
            from socios s where s.id in (select socios_representados())), '{}') as representa_ids,
  coalesce((select sum(s.participacao)
            from socios s where s.id in (select socios_representados())), 0) as peso_total,
  capital_total() as capital_total,
  abs(capital_total() - 1) < 0.000001 as base_completa
from pessoas p
left join pessoa_papeis pp on pp.pessoa_id = p.id
where p.id = pessoa_atual()
group by p.id, p.nome, p.email;

-- ---------------------------------------------------------------------
-- Votos com nome de quem votou e por qual quotista. Voto é nominal e
-- aberto no acordo, então todo autorizado lê — e é o que permite ao
-- sócio conferir a apuração em vez de acreditar nela.
-- ---------------------------------------------------------------------
create or replace view v_votos as
select
  v.id, v.materia_id, v.socio_id, v.pessoa_id,
  v.voto, v.via, v.peso, v.justificativa, v.criado_em,
  s.nome as socio_nome,
  p.nome as pessoa_nome
from votos v
join socios s on s.id = v.socio_id
left join pessoas p on p.id = v.pessoa_id;

-- ---------------------------------------------------------------------
-- Comentários com o nome do autor já resolvido, para a tela não precisar
-- de um segundo join a cada linha.
-- ---------------------------------------------------------------------
create or replace view v_comentarios as
select
  c.id, c.autor_id, c.ancora_aba, c.ancora_item, c.periodo,
  c.texto, c.pai_id, c.resolvido, c.criado_em, c.editado_em,
  p.nome as autor_nome,
  p.id = pessoa_atual() as meu
from comentarios c
join pessoas p on p.id = c.autor_id;
