#!/usr/bin/env bash
# =====================================================================
# Roda a bateria inteira: banco e painel.
#
#     bash supabase/testar.sh
#
# Sobe um Postgres próprio num diretório temporário, aplica as migrações,
# roda os testes de SQL e depois os de navegador. Não toca em projeto
# nenhum do Supabase e não precisa de rede.
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
PGDIR="${PGDIR:-/tmp/pgch}"
PORTA="${PORTA:-5599}"
USUARIO=ch
BANCO=camposhall

cd "$RAIZ"

if [ ! -x "$PGBIN/initdb" ]; then
  echo "erro: não achei o Postgres em $PGBIN (defina PGBIN)" >&2
  exit 1
fi

# Executa como usuário comum: o initdb recusa rodar como root.
COMO=""
if [ "$(id -u)" = "0" ]; then COMO="su claude -c"; fi
rodar() { if [ -n "$COMO" ]; then su claude -c "$1"; else bash -c "$1"; fi; }

# ---------------------------------------------------------------------
if ! "$PGBIN/pg_isready" -h "$PGDIR" -p "$PORTA" >/dev/null 2>&1; then
  echo "== subindo Postgres em $PGDIR =="
  rm -rf "$PGDIR"; mkdir -p "$PGDIR"
  [ -n "$COMO" ] && chown -R claude:claude "$PGDIR"
  rodar "$PGBIN/initdb -D $PGDIR/data -U $USUARIO --auth=trust -E UTF8 --locale=C" >/dev/null
  rodar "$PGBIN/pg_ctl -D $PGDIR/data -l $PGDIR/log.txt -o '-k $PGDIR -p $PORTA -c listen_addresses=' start" >/dev/null
  sleep 2
fi

# Migrações: notices caladas, senão o "create ... if not exists" enche a tela.
psql_() { rodar "PGOPTIONS='--client-min-messages=warning' $PGBIN/psql -h $PGDIR -p $PORTA -U $USUARIO -d $BANCO -v ON_ERROR_STOP=1 $*"; }

# Testes: notices visíveis — é nelas que vêm os valores apurados, e um
# teste que só diz "passou" sem mostrar o número não prova grande coisa.
psql_teste() { rodar "$PGBIN/psql -h $PGDIR -p $PORTA -U $USUARIO -d $BANCO -v ON_ERROR_STOP=1 $*"; }

# ---------------------------------------------------------------------
echo "== banco limpo =="
rodar "$PGBIN/psql -h $PGDIR -p $PORTA -U $USUARIO -d postgres -q \
  -c 'drop database if exists $BANCO' -c 'create database $BANCO'" >/dev/null

# Stubs do que o Supabase fornece e o Postgres puro não tem.
#
# Os papéis anon e authenticated, e os privilégios padrão, imitam o que o
# Supabase faz em todo projeto: qualquer tabela ou visão criada no schema
# public nasce com SELECT, INSERT, UPDATE e DELETE concedidos a anon e a
# authenticated. A proteção fica inteira por conta da RLS — e é por isso
# que o teste precisa reproduzir essas concessões, senão um vazamento que
# existe no Supabase passa despercebido aqui.
cat > "$PGDIR/stubs.sql" <<'SQL'
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables    to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;

create schema if not exists auth;
create schema if not exists storage;
grant usage on schema auth to anon, authenticated;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('teste.jwt', true), ''), '{}')::jsonb
$$;
create table storage.buckets (id text primary key, name text, public boolean default false);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id), name text
);
alter table storage.objects enable row level security;
SQL
[ -n "$COMO" ] && chown claude:claude "$PGDIR/stubs.sql"

echo "== migrações =="
psql_ "-q -f $PGDIR/stubs.sql" >/dev/null
for f in supabase/migrations/*.sql; do
  printf '   %s\n' "$(basename "$f")"
  psql_ "-q -f $RAIZ/$f" >/dev/null
done

# ---------------------------------------------------------------------
falhou=0
for t in supabase/testes/*.sql; do
  # 0003 confere a carga, que vem da migração 0005 — e a 0005 não entra no
  # Git porque carrega números do Campos Hall e este repositório é público.
  if [ "$(basename "$t")" = "0003_carga.sql" ] && \
     [ ! -f supabase/migrations/0005_carga_fechamento.sql ]; then
    echo
    echo "== 0003_carga.sql (pulado) =="
    echo "   a migração 0005 não está presente: ela é gerada localmente e"
    echo "   não vai para o repositório, que é público."
    continue
  fi
  echo
  echo "== $(basename "$t") =="
  if ! psql_teste "-f $RAIZ/$t" 2>&1 \
       | grep -aE "NOTICE|^-- |=====|ERROR" \
       | sed 's/^psql:[^ ]*: //;s/^NOTICE:  /     /'; then
    falhou=1
  fi
done

# ---------------------------------------------------------------------
echo
echo "== painel (jsdom) =="
if [ ! -d node_modules/jsdom ]; then
  echo "   instalando jsdom…"
  npm install --no-save --no-fund --no-audit --silent jsdom@25.0.1
fi
python3 build/montar.py >/dev/null
node supabase/testes/painel.test.mjs || falhou=1

echo
echo "== chat: CORS e erros da API =="
node --experimental-strip-types --no-warnings supabase/testes/chat.test.mjs || falhou=1

echo
if [ "$falhou" = "0" ]; then echo "===== tudo verde ====="; else echo "===== houve falha ====="; fi
exit "$falhou"
