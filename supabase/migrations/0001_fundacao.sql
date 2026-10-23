-- =====================================================================
-- Campos Hall Ltda — painel de governança
-- Migração 0001: fundação
--
-- Duas decisões de modelagem que valem explicação:
--
-- 1. Quotista e pessoa são coisas diferentes. Nove dos onze quotistas do
--    Campos Hall são pessoas jurídicas, e uma mesma pessoa pode
--    representar mais de uma — a RPE Properties e a RPE Empreendimentos
--    são duas quotistas distintas com o mesmo representante. Quem loga é
--    pessoa; quem tem participação e vota é quotista. Juntar os dois numa
--    tabela só faria o representante de duas quotistas votar com o peso
--    de uma.
--
-- 2. As entidades de governança são normalizadas, porque precisam de
--    consulta e de RLS linha a linha. As demonstrações financeiras ficam
--    como jsonb versionado por fechamento, porque são lidas inteiras,
--    publicadas como bloco único e precisam de histórico imutável.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------
create type papel_tipo as enum (
  'conselho_fiscal',  -- emite parecer sobre o fechamento
  'diretoria',        -- opera o painel, propõe fechamento
  'admin'             -- administra cadastro e acessos
);
-- Observação: não existe papel 'socio'. Ser sócio não é papel atribuído,
-- é consequência de representar alguma quotista — ver pessoa_socio.

create type fechamento_estado as enum (
  'rascunho', 'em_conferencia', 'parecer_conselho', 'aprovado', 'publicado'
);

create type pendencia_estado   as enum ('aberta','em_andamento','resolvida','cancelada');
create type materia_estado     as enum ('rascunho','em_votacao','aprovada','rejeitada','cancelada');
create type voto_tipo          as enum ('favor','contra','abstencao');
create type voto_via           as enum ('painel','email_antecipado','presencial','procuracao');
create type proposta_estado    as enum ('proposta','aprovada','descartada');

-- ---------------------------------------------------------------------
-- Quotistas
--
-- participacao é fração do capital integralizado, de 0 a 1. O acordo de
-- sócios mede quórum em percentual de capital, não em contagem de quotas,
-- e no Campos Hall as duas medidas não coincidem: há quotista com uma
-- quota que integralizou mais que outra com uma quota.
-- ---------------------------------------------------------------------
create table socios (
  id            uuid primary key default gen_random_uuid(),
  nome          text    not null,
  quotas        integer not null default 0 check (quotas >= 0),
  capital       numeric(14,2) not null default 0 check (capital >= 0),
  participacao  numeric(12,9) not null default 0
                  check (participacao >= 0 and participacao <= 1),
  integralizado boolean not null default true,
  ativo         boolean not null default true,
  observacao    text,
  criado_em     timestamptz not null default now()
);

create unique index socios_nome_uniq on socios (lower(nome));
create index socios_ativo_idx on socios (ativo) where ativo;

-- ---------------------------------------------------------------------
-- Pessoas — quem loga
--
-- O e-mail é a chave de ligação com auth.users. O link mágico cria o
-- usuário para qualquer e-mail que o receba, mas sem linha aqui ele não
-- lê nada: é esta tabela, e não o provedor de autenticação, que autoriza.
-- ---------------------------------------------------------------------
create table pessoas (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  email      text not null,
  telefone   text,
  ativo      boolean not null default true,
  observacao text,
  criado_em  timestamptz not null default now()
);

create unique index pessoas_email_uniq on pessoas (lower(email));

-- Quem representa quem. Uma pessoa pode representar várias quotistas e
-- uma quotista pode ter mais de um representante.
create table pessoa_socio (
  pessoa_id uuid not null references pessoas(id) on delete cascade,
  socio_id  uuid not null references socios(id)  on delete cascade,
  primary key (pessoa_id, socio_id)
);

create table pessoa_papeis (
  pessoa_id uuid not null references pessoas(id) on delete cascade,
  papel     papel_tipo not null,
  primary key (pessoa_id, papel)
);

-- Soma das participações das quotistas ativas. Guarda de sanidade: se não
-- fechar em 1, a apuração de quórum está sobre base incompleta, e o painel
-- precisa dizer isso em vez de apresentar um percentual errado com
-- aparência de certo.
create or replace function capital_total()
returns numeric language sql stable set search_path = public
as $$ select coalesce(sum(participacao), 0) from socios where ativo $$;

-- ---------------------------------------------------------------------
-- Identidade — base de todas as políticas de RLS
-- ---------------------------------------------------------------------
create or replace function pessoa_atual()
returns uuid language sql stable security definer set search_path = public
as $$
  select p.id from pessoas p
  where lower(p.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    and p.ativo
  limit 1
$$;

create or replace function e_autorizado()
returns boolean language sql stable security definer set search_path = public
as $$ select pessoa_atual() is not null $$;

create or replace function tem_papel(p papel_tipo)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from pessoa_papeis pp
    where pp.pessoa_id = pessoa_atual() and pp.papel = p
  )
$$;

-- Quotistas que a pessoa logada representa. Define por quem ela pode votar.
create or replace function socios_representados()
returns setof uuid language sql stable security definer set search_path = public
as $$
  select ps.socio_id from pessoa_socio ps
  join socios s on s.id = ps.socio_id and s.ativo
  where ps.pessoa_id = pessoa_atual()
$$;

create or replace function e_socio()
returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from socios_representados()) $$;

-- ---------------------------------------------------------------------
-- Fechamentos mensais
--
-- Fechamento publicado nunca é alterado: correção gera nova versão do
-- mesmo período. É o que permite ao sócio confiar que o número visto na
-- reunião continua lá.
-- ---------------------------------------------------------------------
create table fechamentos (
  id             uuid primary key default gen_random_uuid(),
  periodo        text not null check (periodo ~ '^\d{4}-\d{2}$'),
  versao         integer not null default 1 check (versao >= 1),
  estado         fechamento_estado not null default 'rascunho',
  dados          jsonb not null default '{}'::jsonb,
  observacao     text,
  criado_por     uuid references pessoas(id),
  criado_em      timestamptz not null default now(),
  publicado_por  uuid references pessoas(id),
  publicado_em   timestamptz,
  parecer_conselho text,
  parecer_por    uuid references pessoas(id),
  parecer_em     timestamptz,
  unique (periodo, versao)
);

create index fechamentos_periodo_idx on fechamentos (periodo desc, versao desc);
create unique index fechamentos_publicado_uniq
  on fechamentos (periodo) where estado = 'publicado';

create or replace function fechamento_imutavel()
returns trigger language plpgsql set search_path = public as $$
begin
  if old.estado = 'publicado' and new.dados is distinct from old.dados then
    raise exception
      'Fechamento % v% já publicado: os números não podem ser alterados. Crie nova versão do período.',
      old.periodo, old.versao;
  end if;
  return new;
end $$;

create trigger fechamentos_imutavel before update on fechamentos
  for each row execute function fechamento_imutavel();

-- ---------------------------------------------------------------------
-- Pendências
-- ---------------------------------------------------------------------
create table pendencias (
  id            uuid primary key default gen_random_uuid(),
  titulo        text not null,
  descricao     text,
  dono_id       uuid references pessoas(id),
  prazo         date,
  estado        pendencia_estado not null default 'aberta',
  origem        text,
  periodo       text check (periodo is null or periodo ~ '^\d{4}-\d{2}$'),
  valor         numeric(14,2),
  criado_por    uuid references pessoas(id),
  criado_em     timestamptz not null default now(),
  resolvido_por uuid references pessoas(id),
  resolvido_em  timestamptz,
  resolucao     text
);

create index pendencias_estado_idx on pendencias (estado, prazo);
create index pendencias_dono_idx on pendencias (dono_id) where estado in ('aberta','em_andamento');

-- ---------------------------------------------------------------------
-- Comentários, ancorados em qualquer item do painel
-- ---------------------------------------------------------------------
create table comentarios (
  id          uuid primary key default gen_random_uuid(),
  autor_id    uuid not null references pessoas(id),
  -- Âncora solta de propósito: o painel evolui e o comentário não pode
  -- quebrar junto.
  ancora_aba  text not null,
  ancora_item text,
  periodo     text check (periodo is null or periodo ~ '^\d{4}-\d{2}$'),
  texto       text not null check (length(trim(texto)) > 0),
  pai_id      uuid references comentarios(id) on delete cascade,
  resolvido   boolean not null default false,
  criado_em   timestamptz not null default now(),
  editado_em  timestamptz
);

create index comentarios_ancora_idx on comentarios (ancora_aba, ancora_item);

-- ---------------------------------------------------------------------
-- Matérias e votos
-- ---------------------------------------------------------------------
create table materias (
  id              uuid primary key default gen_random_uuid(),
  titulo          text not null,
  descricao       text,
  clausula        text,
  quorum_exigido  numeric(12,9) not null check (quorum_exigido > 0 and quorum_exigido <= 1),
  estado          materia_estado not null default 'rascunho',
  abertura        timestamptz,
  prazo           timestamptz,
  criado_por      uuid references pessoas(id),
  criado_em       timestamptz not null default now(),
  encerrado_em    timestamptz,
  resultado       text,
  ata_url         text
);

create index materias_estado_idx on materias (estado, prazo);

-- Um voto por quotista. O representante de duas quotistas vota duas vezes,
-- uma por cada, e cada voto carrega o peso daquela quotista.
create table votos (
  id            uuid primary key default gen_random_uuid(),
  materia_id    uuid not null references materias(id) on delete cascade,
  socio_id      uuid not null references socios(id),
  pessoa_id     uuid references pessoas(id),   -- quem exerceu o voto
  voto          voto_tipo not null,
  via           voto_via not null default 'painel',
  -- Participação congelada no momento do voto: mudança futura no quadro
  -- societário não reescreve apuração passada.
  peso          numeric(12,9) not null,
  justificativa text,
  criado_em     timestamptz not null default now(),
  unique (materia_id, socio_id)
);

create index votos_materia_idx on votos (materia_id);

-- Catálogo dos quóruns, direto do acordo de 26.09.2025. Alimenta o seletor
-- do painel para que ninguém precise lembrar qual cláusula rege o quê.
create table quoruns_acordo (
  clausula text primary key,
  fracao   numeric(12,9) not null,
  rotulo   text not null,
  materias text not null
);

insert into quoruns_acordo (clausula, fracao, rotulo, materias) values
  ('5.5',   0.500001, 'Maioria absoluta',
   'Locação a terceiros; alteração do orçamento acima de 30% por rubrica; instalação do conselho fiscal; remuneração de diretores; política contábil; auditoria independente'),
  ('5.6.1', 0.666667, 'Dois terços',
   'Aumento de capital até R$ 2,5 milhões; orçamento anual e plano de negócios; venda de ativo relevante'),
  ('5.6.2', 0.750000, 'Setenta e cinco por cento',
   'Bens imóveis; bens móveis acima de R$ 300 mil em 12 meses; órgãos de administração; participação em outras sociedades; alteração do contrato social; empréstimos e financiamentos; recuperação judicial'),
  ('5.6.3', 0.900000, 'Noventa por cento',
   'Aumento de capital acima de R$ 2,5 milhões; empréstimo a terceiros; gravame sobre quotas; garantias; litígio acima de R$ 1 milhão'),
  ('5.6.4', 1.000000, 'Unanimidade',
   'Aumento de capital igual ou superior a 50% do capital social vigente');

-- Apuração. Cláusula 5.7: voto em desacordo não é computado. Cláusula 5.8:
-- vincula ausente e vencido. Cláusula 5.2.3: voto antecipado por e-mail
-- conta como presente, e é o que a via 'email_antecipado' registra.
create or replace function apurar_materia(p_materia uuid)
returns table (
  favor numeric, contra numeric, abstencao numeric, nao_votou numeric,
  exigido numeric, atingido boolean, capital numeric, base_completa boolean
)
language sql stable set search_path = public as $$
  with m as (select quorum_exigido from materias where id = p_materia),
       v as (
         select
           coalesce(sum(peso) filter (where voto = 'favor'), 0)     as favor,
           coalesce(sum(peso) filter (where voto = 'contra'), 0)    as contra,
           coalesce(sum(peso) filter (where voto = 'abstencao'), 0) as abstencao
         from votos where materia_id = p_materia
       )
  select
    v.favor, v.contra, v.abstencao,
    greatest(capital_total() - v.favor - v.contra - v.abstencao, 0),
    m.quorum_exigido,
    -- Tolerância de 5e-9: as participações são frações arredondadas em nove
    -- casas, e sem isso um quórum de unanimidade ficaria inalcançável por
    -- resíduo de arredondamento.
    v.favor >= m.quorum_exigido - 0.000000005,
    capital_total(),
    abs(capital_total() - 1) < 0.000001
  from m, v
$$;

-- ---------------------------------------------------------------------
-- Documentos
-- ---------------------------------------------------------------------
create table documentos (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,
  tipo         text,
  periodo      text check (periodo is null or periodo ~ '^\d{4}-\d{2}$'),
  storage_path text,
  url_externa  text,
  tamanho      bigint,
  enviado_por  uuid references pessoas(id),
  enviado_em   timestamptz not null default now(),
  descricao    text
);

create index documentos_periodo_idx on documentos (periodo desc, enviado_em desc);

-- ---------------------------------------------------------------------
-- Propostas — nada entra no painel sem passar por aqui
-- ---------------------------------------------------------------------
create table propostas (
  id           uuid primary key default gen_random_uuid(),
  autor_id     uuid not null references pessoas(id),
  pedido       text not null,
  resumo       text,
  alvo         text not null,
  diff         jsonb not null,
  estado       proposta_estado not null default 'proposta',
  criado_em    timestamptz not null default now(),
  decidido_por uuid references pessoas(id),
  decidido_em  timestamptz,
  motivo       text
);

create index propostas_estado_idx on propostas (estado, criado_em desc);

create table versoes_painel (
  id            uuid primary key default gen_random_uuid(),
  rotulo        text not null,
  snapshot      jsonb not null,
  proposta_id   uuid references propostas(id),
  publicado_por uuid references pessoas(id),
  publicado_em  timestamptz not null default now(),
  vigente       boolean not null default false
);

create unique index versoes_vigente_uniq on versoes_painel (vigente) where vigente;

-- ---------------------------------------------------------------------
-- Auditoria — o controle que sobra quando uma pessoa opera tudo
-- ---------------------------------------------------------------------
create table auditoria (
  id          bigserial primary key,
  pessoa_id   uuid references pessoas(id),
  ator_email  text,
  acao        text not null,
  entidade    text not null,
  entidade_id text,
  antes       jsonb,
  depois      jsonb,
  criado_em   timestamptz not null default now()
);

create index auditoria_entidade_idx on auditoria (entidade, entidade_id, criado_em desc);
create index auditoria_pessoa_idx on auditoria (pessoa_id, criado_em desc);

create or replace function registrar_auditoria()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_antes jsonb; v_depois jsonb;
begin
  if tg_op = 'DELETE' then v_antes := to_jsonb(old);
  elsif tg_op = 'INSERT' then v_depois := to_jsonb(new);
  else v_antes := to_jsonb(old); v_depois := to_jsonb(new);
  end if;

  insert into auditoria (pessoa_id, ator_email, acao, entidade, entidade_id, antes, depois)
  values (
    pessoa_atual(),
    coalesce(auth.jwt() ->> 'email', 'sistema'),
    tg_op, tg_table_name,
    coalesce((v_depois ->> 'id'), (v_antes ->> 'id')),
    v_antes, v_depois
  );
  return coalesce(new, old);
end $$;

create trigger aud_fechamentos   after insert or update or delete on fechamentos   for each row execute function registrar_auditoria();
create trigger aud_pendencias    after insert or update or delete on pendencias    for each row execute function registrar_auditoria();
create trigger aud_materias      after insert or update or delete on materias      for each row execute function registrar_auditoria();
create trigger aud_votos         after insert or update or delete on votos         for each row execute function registrar_auditoria();
create trigger aud_socios        after insert or update or delete on socios        for each row execute function registrar_auditoria();
create trigger aud_pessoas       after insert or update or delete on pessoas       for each row execute function registrar_auditoria();
create trigger aud_pessoa_socio  after insert or update or delete on pessoa_socio  for each row execute function registrar_auditoria();
create trigger aud_pessoa_papeis after insert or update or delete on pessoa_papeis for each row execute function registrar_auditoria();
create trigger aud_propostas     after insert or update or delete on propostas     for each row execute function registrar_auditoria();
create trigger aud_documentos    after insert or update or delete on documentos    for each row execute function registrar_auditoria();
