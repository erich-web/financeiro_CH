-- =====================================================================
-- Migração 0007: a chave anônima fora de tudo
--
-- O Supabase concede SELECT, INSERT, UPDATE e DELETE a anon em toda
-- tabela nova do schema public, e deixa a proteção inteira por conta da
-- RLS. Para este painel, anon não tem o que fazer: nada é lido antes do
-- login, e depois do login o papel é authenticated.
--
-- Então anon perde tudo. A RLS continua sendo a regra; isto é a segunda
-- camada, para que uma política escrita com descuido no futuro não baste
-- para expor o fechamento a quem nem entrou.
-- =====================================================================

revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;

-- Funções nascem executáveis por PUBLIC, e anon herda de PUBLIC. Tirar só
-- de anon não adiantaria.
revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;

-- O que for criado daqui para frente já nasce sem anon.
alter default privileges in schema public revoke all on tables    from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from public, anon;
alter default privileges in schema public grant  execute on functions to authenticated;
