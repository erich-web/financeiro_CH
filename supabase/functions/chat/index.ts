// =====================================================================
// Edge Function: chat
//
// O chat do painel. Conversa com o Claude no servidor, porque a chave da
// API não pode existir no navegador: o painel é um arquivo que qualquer
// pessoa com o link baixa.
//
// Duas garantias, nesta ordem:
//
//  1. A função usa o token de quem chamou, nunca a service role key. Toda
//     leitura e escrita passa pela RLS. Se o Claude tentar algo que o
//     usuário não poderia fazer, o banco recusa — a permissão não depende
//     do que foi escrito no prompt.
//
//  2. Nenhuma ferramenta escreve no painel. A única escrita possível é
//     criar uma linha em `propostas`. Quem publica é uma pessoa, clicando.
// =====================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const API = "https://api.anthropic.com/v1/messages";
const MODELO = Deno.env.get("ANTHROPIC_MODEL") ?? "claude-sonnet-5-5";
const CHAVE = Deno.env.get("ANTHROPIC_API_KEY");
const MAX_VOLTAS = 8;

// Só o painel chama esta função. Se a hospedagem mudar de endereço, basta
// definir o secret ORIGEM_PERMITIDA com a origem nova.
const cors = {
  "Access-Control-Allow-Origin": Deno.env.get("ORIGEM_PERMITIDA") ?? "https://erich-web.github.io",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

// ---------------------------------------------------------------------
// Ferramentas oferecidas ao Claude
// ---------------------------------------------------------------------
const FERRAMENTAS = [
  {
    name: "ler_dados",
    description:
      "Lê o estado atual do painel. Use antes de propor qualquer mudança: " +
      "nunca proponha alteração de um número sem ter lido o valor que está lá.",
    input_schema: {
      type: "object",
      properties: {
        recurso: {
          type: "string",
          enum: ["fechamento", "pendencias", "socios", "materias", "documentos", "quoruns"],
        },
        periodo: {
          type: "string",
          description: "AAAA-MM. Só para fechamento e pendências.",
        },
      },
      required: ["recurso"],
    },
  },
  {
    name: "propor_mudanca",
    description:
      "Registra uma proposta de mudança para aprovação humana. É a única " +
      "forma de alterar o painel. A proposta não entra no ar: aparece como " +
      "prévia antes/depois para a pessoa publicar ou descartar. Chame uma " +
      "única vez por pedido, com a mudança completa.",
    input_schema: {
      type: "object",
      properties: {
        resumo: {
          type: "string",
          description: "Uma frase dizendo o que a mudança faz, em português.",
        },
        tabela: {
          type: "string",
          enum: ["fechamento_dados", "pendencias", "materias", "documentos"],
          description:
            "fechamento_dados para qualquer número ou texto das demonstrações " +
            "(DRE, balanço, caixa, alertas, recomendações, metadados). As outras " +
            "para as entidades de governança.",
        },
        id: {
          type: "string",
          description:
            "O id da linha a alterar. Omita para criar linha nova. Não se " +
            "aplica a fechamento_dados.",
        },
        periodo: {
          type: "string",
          description:
            "AAAA-MM do fechamento a corrigir. Só para fechamento_dados; " +
            "omitido, corrige o período publicado mais recente.",
        },
        antes: {
          type: "object",
          description:
            "Os valores que estão lá hoje, lidos com ler_dados — é o que a " +
            "pessoa confere para saber se você entendeu o pedido. Em " +
            "fechamento_dados, as chaves são caminhos pontuados dentro do " +
            "objeto de dados, por exemplo 'meta.caixa_total' ou 'dre.resultado.7'.",
        },
        depois: {
          type: "object",
          description:
            "Os valores novos, nas mesmas chaves de 'antes'. Inclua apenas o " +
            "que muda: campo que não aparece aqui fica como está.",
        },
      },
      required: ["resumo", "tabela", "antes", "depois"],
    },
  },
];

function instrucoes(eu: Record<string, unknown>, ctx: Record<string, unknown>) {
  return `Você é o assistente do painel de governança do Campos Hall Ltda, um centro de eventos em Campos do Jordão com 11 sócios e 12 quotas. Responde em português do Brasil.

Quem está falando com você: ${eu.nome} (${eu.email}), papéis: ${
    Array.isArray(eu.papeis) ? (eu.papeis as string[]).join(", ") : "—"
  }.
Onde ela está no painel agora: aba "${ctx.aba ?? "—"}", período "${ctx.periodo ?? "todo o histórico"}".

Como você trabalha:

- Leia antes de propor. Chame ler_dados e confira o valor atual. Propor mudança de um número sem ter visto o que está lá é como corrigir no escuro.
- Uma proposta por pedido, completa. Se o pedido envolve três campos, a proposta traz os três.
- Em "antes" vai o valor que está no banco hoje, não o que você imagina. É esse campo que a pessoa usa para conferir se você entendeu o pedido.
- Você não publica nada. Toda proposta espera clique humano. Diga isso quando a pessoa parecer esperar que já entrou no ar.
- Fechamento publicado é imutável. Correção de período publicado gera versão nova, nunca edição da antiga. Avise quando for o caso.
- Quórum é percentual de capital, não contagem de sócios, e segue as cláusulas do acordo de 26.09.2025. Consulte o recurso "quoruns" antes de afirmar qual se aplica.
- Se a soma das participações não fechar em 100%, diga: o Anexo I ainda não foi cadastrado e qualquer apuração de quórum está sobre base incompleta.
- Não invente número. Se o dado não está no painel e você não consegue derivá-lo do que leu, diga que falta e o que exatamente falta.
- Seja curto. Quem usa isso está no meio do fechamento.`;
}

// ---------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ erro: "Use POST." }, 405);

  if (!CHAVE) {
    return json(
      {
        erro:
          "A chave da API Anthropic não está configurada neste projeto. " +
          "Defina o secret ANTHROPIC_API_KEY para o chat funcionar.",
      },
      503,
    );
  }

  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ erro: "Sem sessão." }, 401);

  // Cliente com o token de quem chamou: a RLS vale para tudo o que vem a seguir.
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: auth } } },
  );

  const { data: eu, error: erroEu } = await db.from("v_eu").select("*").maybeSingle();
  if (erroEu || !eu) return json({ erro: "E-mail não autorizado neste painel." }, 403);
  if (!eu.e_diretoria && !eu.e_admin) {
    return json({ erro: "O chat está disponível para a diretoria." }, 403);
  }

  let corpo: { mensagem?: string; contexto?: Record<string, unknown>; historico?: unknown[] };
  try {
    corpo = await req.json();
  } catch {
    return json({ erro: "Corpo inválido." }, 400);
  }
  const mensagem = (corpo.mensagem ?? "").trim();
  if (!mensagem) return json({ erro: "Mensagem vazia." }, 400);

  const ctx = corpo.contexto ?? {};
  const mensagens: Array<Record<string, unknown>> = [
    ...((corpo.historico as Array<Record<string, unknown>>) ?? []).slice(-20),
    { role: "user", content: mensagem },
  ];

  const propostasCriadas: unknown[] = [];

  // -------------------------------------------------------------------
  async function executar(nome: string, entrada: Record<string, unknown>) {
    if (nome === "ler_dados") {
      const { recurso, periodo } = entrada as { recurso: string; periodo?: string };
      const mapa: Record<string, () => unknown> = {
        fechamento: () => {
          let q = db.from("fechamentos").select("id,periodo,versao,estado,dados,publicado_em");
          if (periodo) q = q.eq("periodo", periodo);
          return q.order("periodo", { ascending: false }).order("versao", { ascending: false }).limit(3);
        },
        pendencias: () => {
          let q = db.from("pendencias").select("*");
          if (periodo) q = q.eq("periodo", periodo);
          return q.order("prazo", { ascending: true, nullsFirst: false }).limit(100);
        },
        socios: () => db.from("v_socios").select("*").eq("ativo", true),
        materias: () => db.from("v_materias").select("*").order("criado_em", { ascending: false }).limit(50),
        documentos: () => db.from("documentos").select("*").order("enviado_em", { ascending: false }).limit(50),
        quoruns: () => db.from("quoruns_acordo").select("*").order("fracao"),
      };
      if (!mapa[recurso]) return { erro: `Recurso desconhecido: ${recurso}` };
      const { data, error } = (await mapa[recurso]()) as { data: unknown; error: unknown };
      if (error) return { erro: String((error as { message?: string }).message ?? error) };
      return { dados: data };
    }

    if (nome === "propor_mudanca") {
      const { resumo, tabela, id, periodo, antes, depois } = entrada as {
        resumo: string; tabela: string; id?: string; periodo?: string;
        antes: Record<string, unknown>; depois: Record<string, unknown>;
      };

      if (!depois || Object.keys(depois).length === 0) {
        return { erro: "A proposta não altera nada: 'depois' veio vazio." };
      }

      const { data, error } = await db
        .from("propostas")
        .insert({
          autor_id: eu.id,
          pedido: mensagem,
          resumo,
          alvo: tabela,
          diff: { tabela, id: id ?? null, periodo: periodo ?? null, antes, depois },
          estado: "proposta",
        })
        .select("id,resumo,alvo,diff,criado_em")
        .single();

      if (error) return { erro: String(error.message) };
      propostasCriadas.push(data);
      return {
        ok: true,
        proposta_id: data.id,
        aviso:
          "Proposta registrada e exibida como prévia. Nada mudou no painel: " +
          "aguarda a pessoa publicar ou descartar.",
      };
    }

    return { erro: `Ferramenta desconhecida: ${nome}` };
  }

  // -------------------------------------------------------------------
  let textoFinal = "";

  for (let volta = 0; volta < MAX_VOLTAS; volta++) {
    const resp = await fetch(API, {
      method: "POST",
      headers: {
        "x-api-key": CHAVE,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: MODELO,
        max_tokens: 4096,
        system: instrucoes(eu, ctx),
        tools: FERRAMENTAS,
        messages: mensagens,
      }),
    });

    if (!resp.ok) {
      const detalhe = await resp.text();
      console.error("Anthropic", resp.status, detalhe);
      return json(
        { erro: `A API respondeu ${resp.status}.`, detalhe: detalhe.slice(0, 500) },
        502,
      );
    }

    const r = await resp.json();
    mensagens.push({ role: "assistant", content: r.content });

    textoFinal = (r.content ?? [])
      .filter((b: { type: string }) => b.type === "text")
      .map((b: { text: string }) => b.text)
      .join("\n")
      .trim() || textoFinal;

    if (r.stop_reason !== "tool_use") break;

    const usos = (r.content ?? []).filter((b: { type: string }) => b.type === "tool_use");
    const resultados = [];
    for (const u of usos) {
      const saida = await executar(u.name, u.input ?? {});
      resultados.push({
        type: "tool_result",
        tool_use_id: u.id,
        content: JSON.stringify(saida).slice(0, 180_000),
        is_error: Boolean((saida as { erro?: string }).erro),
      });
    }
    mensagens.push({ role: "user", content: resultados });
  }

  return json({
    resposta: textoFinal || "Não consegui formular resposta.",
    propostas: propostasCriadas,
    historico: mensagens.slice(-20),
  });
});
