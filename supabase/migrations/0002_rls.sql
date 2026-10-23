-- =====================================================================
-- Migração 0002: controle de acesso (RLS)
--
-- Princípio: tudo negado por padrão. RLS ligada sem política permissiva
-- significa nenhuma linha. Cada permissão abaixo é explícita.
--
-- Quem é quem vem do e-mail do token, cruzado com a tabela pessoas. O
-- provedor de autenticação entrega link mágico a qualquer e-mail que o
-- solicite; é esta camada que decide se ele lê algo. E-mail sem linha em
-- pessoas entra e não vê nada.
-- =====================================================================

alter table socios          enable row level security;
alter table pessoas         enable row level security;
alter table pessoa_socio    enable row level security;
alter table pessoa_papeis   enable row level security;
alter table fechamentos     enable row level security;
alter table pendencias      enable row level security;
alter table comentarios     enable row level security;
alter table materias        enable row level security;
alter table votos           enable row level security;
alter table quoruns_acordo  enable row level security;
alter table documentos      enable row level security;
alter table propostas       enable row level security;
alter table versoes_painel  enable row level security;
alter table auditoria       enable row level security;

-- ---------------------------------------------------------------------
-- Cadastro
-- Todo autorizado vê o quadro societário inteiro: sem isso não há como
-- conferir se o quórum de uma matéria foi apurado sobre a base certa.
-- Alterar o cadastro é de admin — é ele que define quem entra.
-- ---------------------------------------------------------------------
create policy socios_leitura on socios for select using (e_autorizado());
create policy socios_admin   on socios for all
  using (tem_papel('admin')) with check (tem_papel('admin'));

create policy pessoas_leitura on pessoas for select using (e_autorizado());
create policy pessoas_admin   on pessoas for all
  using (tem_papel('admin')) with check (tem_papel('admin'));

create policy ps_leitura on pessoa_socio for select using (e_autorizado());
create policy ps_admin   on pessoa_socio for all
  using (tem_papel('admin')) with check (tem_papel('admin'));

create policy pp_leitura on pessoa_papeis for select using (e_autorizado());
create policy pp_admin   on pessoa_papeis for all
  using (tem_papel('admin')) with check (tem_papel('admin'));

-- ---------------------------------------------------------------------
-- Fechamentos
-- O sócio vê o publicado. Rascunho e conferência são da diretoria e do
-- conselho. É a regra de nenhum número chegar ao sócio sem conferência,
-- escrita no banco em vez de confiada à disciplina de quem opera.
-- ---------------------------------------------------------------------
create policy fechamentos_publicado on fechamentos
  for select using (e_autorizado() and estado = 'publicado');

create policy fechamentos_internos on fechamentos
  for select using (tem_papel('diretoria') or tem_papel('conselho_fiscal') or tem_papel('admin'));

create policy fechamentos_cria on fechamentos
  for insert with check (tem_papel('diretoria') or tem_papel('admin'));

create policy fechamentos_edita on fechamentos
  for update using (tem_papel('diretoria') or tem_papel('admin') or tem_papel('conselho_fiscal'));

-- ---------------------------------------------------------------------
-- Pendências — todos veem, diretoria administra, dono move a sua
-- ---------------------------------------------------------------------
create policy pendencias_leitura on pendencias for select using (e_autorizado());

create policy pendencias_diretoria on pendencias for all
  using (tem_papel('diretoria') or tem_papel('admin'))
  with check (tem_papel('diretoria') or tem_papel('admin'));

create policy pendencias_dono on pendencias for update
  using (dono_id = pessoa_atual()) with check (dono_id = pessoa_atual());

-- ---------------------------------------------------------------------
-- Comentários — qualquer autorizado lê e escreve, só em nome próprio
-- ---------------------------------------------------------------------
create policy comentarios_leitura on comentarios for select using (e_autorizado());

create policy comentarios_insere on comentarios for insert
  with check (autor_id = pessoa_atual());

create policy comentarios_proprio on comentarios for update
  using (autor_id = pessoa_atual()) with check (autor_id = pessoa_atual());

create policy comentarios_apaga on comentarios for delete
  using (autor_id = pessoa_atual() or tem_papel('admin'));

create policy comentarios_resolve on comentarios for update
  using (tem_papel('diretoria') or tem_papel('admin'));

-- ---------------------------------------------------------------------
-- Matérias e votos
-- Voto nominal e aberto, como manda o acordo: todos leem todos os votos.
-- Cada um insere voto apenas pelas quotistas que representa, e só
-- enquanto a matéria está em votação. Não há política de update: voto
-- dado não se altera.
-- ---------------------------------------------------------------------
create policy materias_leitura on materias
  for select using (e_autorizado() and estado <> 'rascunho');

create policy materias_internas on materias
  for select using (tem_papel('diretoria') or tem_papel('admin'));

create policy materias_diretoria on materias for all
  using (tem_papel('diretoria') or tem_papel('admin'))
  with check (tem_papel('diretoria') or tem_papel('admin'));

create policy votos_leitura on votos for select using (e_autorizado());

create policy votos_proprio on votos for insert with check (
  socio_id in (select socios_representados())
  and exists (
    select 1 from materias m
    where m.id = materia_id
      and m.estado = 'em_votacao'
      and (m.prazo is null or m.prazo > now())
  )
);

-- A diretoria registra voto recebido por e-mail antecipado (cláusula
-- 5.2.3), presencialmente ou por procuração, em nome de quem votou.
create policy votos_diretoria on votos for insert with check (
  (tem_papel('diretoria') or tem_papel('admin'))
  and via in ('email_antecipado','presencial','procuracao')
);

create policy quoruns_leitura on quoruns_acordo for select using (e_autorizado());

-- ---------------------------------------------------------------------
-- Documentos
-- ---------------------------------------------------------------------
create policy documentos_leitura on documentos for select using (e_autorizado());

create policy documentos_diretoria on documentos for all
  using (tem_papel('diretoria') or tem_papel('admin'))
  with check (tem_papel('diretoria') or tem_papel('admin'));

-- ---------------------------------------------------------------------
-- Propostas e versões — fora da diretoria ninguém precisa ver proposta
-- em aberto. As versões publicadas, sim: é o histórico do painel.
-- ---------------------------------------------------------------------
create policy propostas_diretoria on propostas for all
  using (tem_papel('diretoria') or tem_papel('admin'))
  with check (tem_papel('diretoria') or tem_papel('admin'));

create policy versoes_leitura on versoes_painel for select using (e_autorizado());

create policy versoes_diretoria on versoes_painel for all
  using (tem_papel('diretoria') or tem_papel('admin'))
  with check (tem_papel('diretoria') or tem_papel('admin'));

-- ---------------------------------------------------------------------
-- Auditoria
-- Legível por qualquer autorizado, de propósito: quando uma pessoa opera
-- o painel inteiro, o registro só controla alguma coisa se os outros
-- puderem ler. Não existe política de escrita — as linhas entram pelo
-- trigger, que roda como definer e passa por cima da RLS. Ninguém
-- escreve, edita ou apaga auditoria pela API.
-- ---------------------------------------------------------------------
create policy auditoria_leitura on auditoria for select using (e_autorizado());

-- =====================================================================
-- Integridade do voto
--
-- O peso não pode vir do cliente: qualquer um mandaria peso 1 e aprovaria
-- matéria sozinho. O trigger sobrescreve com a participação registrada da
-- quotista e congela o valor na linha, e confere que quem vota pelo painel
-- realmente representa aquela quotista — a RLS já barra, mas uma regra
-- desta importância merece as duas camadas.
-- =====================================================================
create or replace function fixar_peso_voto()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_part numeric; v_nome text;
begin
  if new.via = 'painel' then
    if new.socio_id not in (select socios_representados()) then
      raise exception 'Voto recusado: você não representa essa quotista.';
    end if;
    new.pessoa_id := pessoa_atual();
  else
    new.pessoa_id := coalesce(new.pessoa_id, pessoa_atual());
  end if;

  select participacao, nome into v_part, v_nome
  from socios where id = new.socio_id and ativo;

  if v_part is null then
    raise exception 'Voto recusado: quotista não encontrada ou inativa.';
  end if;
  if v_part = 0 then
    raise exception 'Voto recusado: participação de % não cadastrada.', v_nome;
  end if;

  new.peso := v_part;
  return new;
end $$;

create trigger votos_fixar_peso before insert on votos
  for each row execute function fixar_peso_voto();

-- =====================================================================
-- Bucket de documentos
-- =====================================================================
insert into storage.buckets (id, name, public)
values ('documentos', 'documentos', false)
on conflict (id) do nothing;

create policy docs_leitura on storage.objects for select
  using (bucket_id = 'documentos' and e_autorizado());

create policy docs_envia on storage.objects for insert
  with check (bucket_id = 'documentos' and (tem_papel('diretoria') or tem_papel('admin')));

create policy docs_remove on storage.objects for delete
  using (bucket_id = 'documentos' and (tem_papel('diretoria') or tem_papel('admin')));
