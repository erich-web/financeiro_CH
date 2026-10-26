// =====================================================================
// O que o Claude precisa saber para achar o número certo
//
// Na primeira conversa real, a pergunta "qual o caixa de agosto?" voltou
// sem resposta: o Claude procurou um fechamento com periodo 2026-08, que
// não existe. O único fechamento era o de 2026-09 — e o saldo de agosto
// estava dentro dele, na série mensal de caixa.
//
// O periodo de um fechamento é a competência do fechamento, não o mês de
// cada número. Este arquivo diz isso ao Claude de três jeitos: no mapa
// dos dados que vai nas instruções, na lista dos fechamentos que existem
// e, se mesmo assim ele pedir um período que não há, na resposta da
// própria ferramenta.
// =====================================================================

export type LinhaFechamento = { periodo: string; versao: number; estado: string };

export function resumoFechamentos(linhas: LinhaFechamento[]): string {
  if (!linhas.length) return "nenhum";
  return linhas.map((l) => `${l.periodo} v${l.versao} (${l.estado})`).join("; ");
}

export function avisoSemFechamento(periodo: string, linhas: LinhaFechamento[]): string {
  return `Não existe fechamento com periodo ${periodo}. Fechamentos cadastrados: ` +
    `${resumoFechamentos(linhas)}. O periodo é a competência do fechamento, não o mês ` +
    "do dado: cada fechamento traz o histórico mensal dentro de dados (serie_caixa, " +
    "uma linha por mês; dre.chaves, os meses da DRE). Chame ler_dados sem periodo para " +
    "ler o mais recente e procure o mês lá dentro.";
}

export const MAPA_DADOS = `Como os dados estão organizados:

- Cada fechamento é o retrato completo do painel na data em que foi fechado. O periodo dele é a competência do fechamento, não o mês de cada número: o histórico mensal inteiro vem dentro de "dados".
- Pergunta sobre um mês: leia o fechamento mais recente (ler_dados sem periodo) e procure o mês lá dentro. Mês sem ano é o mais recente que tenha dado. Use periodo só para ler um fechamento específico, por exemplo para comparar versões.
- Se o fechamento lido estiver em rascunho, avise que os números ainda não foram publicados.
- Dentro de "dados":
  · meta: competência, datas de referência (caixa_data, balanco_data), caixa_total, resumo e notas.
  · serie_caixa: uma linha por mês (k = AAAA-MM) desde o início do caixa. saldo é o saldo no fim do mês; os outros campos são as entradas e saídas do mês por categoria.
  · dre: chaves traz os meses (AAAA-MM) e months os rótulos. Cada linha (receita_bruta, deducoes, receita_liquida, custos_eventos, margem_contrib, pessoal, ocupacao, comercial, admin, outros, ebitda, depreciacao, rec_fin, desp_fin, lair, ir_csll, resultado) é uma lista na mesma ordem de chaves: dre.resultado.7 é o oitavo mês de chaves. dre.detalhe abre custos, ocupação e comercial.
  · balanco: posição patrimonial na data meta.balanco_data.
  · caixa_detalhe: onde está o dinheiro, [conta, saldo], na data meta.caixa_data.
  · pagar: contas a pagar, [descrição, valor]. receber: carteira, [cliente, vencimento, valor, dias em atraso].
  · deals (eventos em negociação), mix (receita por tipo), estacionamento, alertas, recomendacoes, delibs (pontos para deliberar), atas, docs.
- Ao citar um número, diga a que data ele se refere e de onde saiu (por exemplo: saldo no fim de agosto/2026, série de caixa do fechamento 2026-09).`;
