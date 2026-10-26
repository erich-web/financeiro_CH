// =====================================================================
// Tradução dos erros da API da Anthropic
//
// O chat mostra este texto na gaveta. "A API respondeu 400" não diz se
// falta crédito, se a chave expirou ou se o limite de gasto chegou — e
// cada caso tem um conserto diferente, em um lugar diferente. Aqui cada
// recusa conhecida vira o que fazer e onde.
//
// Caso desconhecido não é engolido: volta a mensagem original da API,
// que é o que permite diagnosticar.
// =====================================================================

const CONSOLE = "platform.claude.com";

export function traduzErroApi(status: number, corpo: string): string {
  let tipo = "";
  let msg = "";
  let codigo = "";
  try {
    const j = JSON.parse(corpo);
    tipo = j?.error?.type ?? "";
    msg = j?.error?.message ?? "";
    codigo = j?.error?.details?.error_code ?? "";
  } catch {
    msg = corpo ?? "";
  }
  const m = msg.toLowerCase();

  if (status === 401 || tipo === "authentication_error") {
    return "A Anthropic recusou a chave do assistente: ela está errada, foi revogada ou expirou. " +
      `Gere outra em ${CONSOLE}/settings/keys e substitua o secret ANTHROPIC_API_KEY no Supabase.`;
  }
  if (m.includes("credit balance")) {
    return "A conta da Anthropic está sem créditos. " +
      `Compre créditos em ${CONSOLE}/settings/billing e tente de novo.`;
  }
  if (m.includes("specified workspace api usage limits")) {
    return "O limite mensal de gasto do workspace foi atingido. " +
      `Aumente em ${CONSOLE}/settings/workspaces ou espere o dia 1º.`;
  }
  if (m.includes("specified api usage limits")) {
    return "O limite mensal de gasto da conta da Anthropic foi atingido. " +
      `Aumente em ${CONSOLE}/settings/billing ou espere o dia 1º.`;
  }
  if (codigo === "enforced_spend_limit_reached") {
    return "A conta da Anthropic chegou ao teto mensal do seu nível de uso. " +
      "O acesso volta no dia 1º (UTC), ou antes se a Anthropic aumentar o teto.";
  }
  if (m.includes("anthropic-workspace-id") || m.includes("workspace id") || m.includes("workspace_id")) {
    return "A chave não está vinculada a um workspace. " +
      `Crie outra em ${CONSOLE}/settings/keys escolhendo o workspace do painel ` +
      "e substitua o secret ANTHROPIC_API_KEY no Supabase.";
  }
  if (status === 404 || tipo === "not_found_error") {
    return "O modelo configurado não está disponível para esta chave. " +
      "Se existir o secret ANTHROPIC_MODEL no Supabase, apague-o para voltar ao padrão." +
      (msg ? ` (${msg.slice(0, 200)})` : "");
  }
  if (status === 429 || tipo === "rate_limit_error") {
    return "Muitas perguntas em pouco tempo. Espere um minuto e tente de novo.";
  }
  if (status >= 500 || tipo === "overloaded_error" || tipo === "api_error") {
    return "A Anthropic está instável agora. Tente de novo em alguns minutos.";
  }
  return `A API da Anthropic recusou o pedido (${status})` +
    (msg ? `: ${msg.slice(0, 300)}` : ".");
}
