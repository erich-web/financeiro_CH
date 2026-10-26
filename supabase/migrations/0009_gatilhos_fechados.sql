-- =====================================================================
-- Migração 0009: funções de gatilho fora da API
--
-- O alerta de segurança do Supabase apontou sete funções SECURITY DEFINER
-- executáveis por quem está logado. Cinco são de identidade (pessoa_atual,
-- e_autorizado, tem_papel, socios_representados, e_socio): respondem só
-- sobre quem pergunta e precisam continuar executáveis, porque as
-- políticas de RLS as chamam no contexto do usuário.
--
-- As duas de gatilho não têm motivo para isso. O Postgres confere o
-- privilégio de EXECUTE quando o gatilho é criado, não quando dispara —
-- então tirar o EXECUTE não muda nada no funcionamento e tira as duas da
-- superfície exposta pela API.
-- =====================================================================

revoke execute on function public.fixar_peso_voto()     from authenticated, public;
revoke execute on function public.registrar_auditoria() from authenticated, public;
