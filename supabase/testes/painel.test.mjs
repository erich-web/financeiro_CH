/* =====================================================================
   Testes do painel no navegador (jsdom)

   Roda contra o index.html de verdade, o mesmo que vai para o ar — não
   contra uma cópia de teste. Os CDNs são trocados por stubs e o cliente
   do Supabase é falso, para o teste não depender de rede nem de backend.

       node supabase/testes/painel.test.mjs
   ===================================================================== */

import { readFileSync } from 'node:fs';
import { JSDOM, VirtualConsole } from 'jsdom';

/* Testa a prévia quando existe, senão o index.html publicado. É o mesmo
   arquivo que vai para o ar — não uma cópia feita para o teste passar. */
import { existsSync } from 'node:fs';
const PREVIA = new URL('../../build/index.preview.html', import.meta.url);
const PUBLICADO = new URL('../../index.html', import.meta.url);
const ARQUIVO = existsSync(PREVIA) ? PREVIA : PUBLICADO;
const html = readFileSync(ARQUIVO, 'utf-8');
console.log('arquivo em teste: ' + (ARQUIVO === PREVIA ? 'build/index.preview.html' : 'index.html'));

let falhas = 0, passes = 0;
const ok = (cond, msg) => {
  if (cond) { passes++; console.log('     ok: ' + msg); }
  else { falhas++; console.log('  FALHA: ' + msg); }
};
const secao = t => console.log('\n-- ' + t);

/* ---------------------------------------------------------------------
   Dados que o cliente falso devolve
   --------------------------------------------------------------------- */
const FECHAMENTO = {
  periodo: '2026-09', versao: 1, publicado_em: '2026-10-06T15:00:00Z',
  dados: {
    meta: {
      competencia: 'Setembro de 2026', competencia_curta: 'set/2026',
      competencia_contabil: 'Agosto de 2026',
      periodo: 'janeiro a setembro de 2026', inicio_caixa: '2025-07',
      inicio_dre: '2026-01', fim: '2026-09', caixa_total: 1287877.15,
      caixa_aplicado: 1160716.89, caixa_data: '30/09/2026',
      balanco_data: '31/08/2026', gerado_em: '06/10/2026',
      fonte_contabil: 'Pasta de teste', fonte_caixa: 'Fluxo de teste',
      resumo_visao: 'Resumo de teste.', balanco_sub: 'Balanço de teste.',
      receber_hint: 'Recebíveis de teste', nota_dre: 'Nota de teste.',
      pagar_mes: 'outubro', pagar_n: 32, pagar_note: 'Contas de teste.',
    },
    dre: {
      months: ['Jan', 'Fev'], chaves: ['2026-01', '2026-02'],
      receita_bruta: [100, 200], deducoes: [-1, -2], receita_liquida: [99, 198],
      custos_eventos: [-10, -20], margem_contrib: [89, 178],
      pessoal: [-5, -5], comercial: [-5, -5], ocupacao: [-5, -5], admin: [-5, -5],
      ebitda: [69, 158], depreciacao: [-1, -1], rec_fin: [0, 0], desp_fin: [0, 0],
      outros: [0, 0], lair: [68, 157], ir_csll: [0, 0], resultado: [68, 157],
      detalhe: {
        custos:    { eventos: [-6, -12], feiras: [-4, -8] },
        comercial: { publicidade: [-3, -3], redes: [-2, -2] },
        ocupacao:  { utilidades: [-3, -3], limpeza: [-2, -2] },
      },
    },
    mix: {
      chaves: ['2026-01', '2026-02'],
      locacao: [60, 120], patrocinio: [10, 20], comissionamento: [15, 30],
      recup_energia: [5, 10], eventos: [8, 16], nao_tributavel: [2, 4],
    },
    balanco: { disponibilidades: 127160.26, aplicacoes: 1160716.89 },
    receber: [], pagar: [], caixa_detalhe: [], serie_caixa: [],
    alertas: [], recomendacoes: [], delibs: [], atas: [], deals: [], docs: [],
    estacionamento: {
      fonte: 'https://exemplo', titulo_fonte: 'Planilha', atualizado: '20/10/2026',
      operador: 'Operador Teste',
      meses: [{
        k: '2026-01', nome: 'Janeiro', base: 1000, devido: 500, pago: 300, saldo: 200,
        itens: [{ forn: 'Fornecedor', desc: 'Conta', venc: '10/01/2026', valor: 300, st: 'Pago', obs: '' }],
      }],
    },
  },
};

const QUADRO = [
  { nome: 'FRK Empreendimentos e Participações', quotas: 2, capital: 525000, participacao: 0.166364044, integralizado: true, observacao: null, ativo: true },
  { nome: 'Hotel Toriba', quotas: 1, capital: 262500, participacao: 0.083182021, integralizado: true, observacao: null, ativo: true },
  { nome: 'RAMFEJ Engenharia', quotas: 1, capital: 262500, participacao: 0.083182021, integralizado: false, observacao: 'Pendente – chamada abr/mai', ativo: true },
];

const TABELAS = {
  v_fechamento_vigente: [FECHAMENTO],
  v_pendencias: [],
  v_materias: [],
  comentarios: [],
  v_socios: QUADRO,
  quoruns_acordo: [{ clausula: '5.6.2', fracao: 0.75, rotulo: 'Setenta e cinco por cento' }],
  documentos: [],
  propostas: [],
};

/* Encadeamento preguiçoso: todo método devolve o próprio objeto, e o
   objeto é aguardável. Imita o formato do supabase-js sem a biblioteca. */
function consulta(linhas) {
  const alvo = {
    _linhas: linhas,
    select() { return alvo; }, order() { return alvo; }, limit() { return alvo; },
    eq() { return alvo; }, in() { return alvo; }, insert(v) { alvo._ins = v; return alvo; },
    update(v) { alvo._upd = v; return alvo; },
    single() { return Promise.resolve({ data: alvo._linhas[0] ?? null, error: null }); },
    maybeSingle() { return Promise.resolve({ data: alvo._linhas[0] ?? null, error: null }); },
    then(res, rej) { return Promise.resolve({ data: alvo._linhas, error: null }).then(res, rej); },
  };
  return alvo;
}

function clienteFalso({ sessao, eu, invoke } = {}) {
  const chamadas = { otp: [], rpc: [], invoke: [] };
  return {
    chamadas,
    from(t) { return consulta(t === 'v_eu' ? (eu ? [eu] : []) : (TABELAS[t] ?? [])); },
    rpc(nome, args) { chamadas.rpc.push([nome, args]); return Promise.resolve({ data: {}, error: null }); },
    functions: {
      invoke(nome, opt) {
        chamadas.invoke.push([nome, opt]);
        return Promise.resolve(invoke ? invoke(opt) : { data: { resposta: 'ok', propostas: [] }, error: null });
      },
    },
    auth: {
      getSession() { return Promise.resolve({ data: { session: sessao ?? null } }); },
      getUser() { return Promise.resolve({ data: { user: sessao?.user ?? { email: 'ninguem@teste.com' } } }); },
      signInWithOtp(a) { chamadas.otp.push(a); return Promise.resolve({ error: null }); },
      signOut() { return Promise.resolve({}); },
    },
  };
}

/* ---------------------------------------------------------------------
   Montagem do documento
   --------------------------------------------------------------------- */
const STUBS = `
<script>
  // Chart.defaults é acessado em profundidade na carga; um Proxy que cria
  // ramos sob demanda evita listar cada chave usada.
  const fundo = () => new Proxy({}, {
    get: (o, k) => (k in o ? o[k] : (o[k] = fundo())),
    set: (o, k, v) => { o[k] = v; return true; },
  });
  window.__charts = [];
  window.Chart = class { constructor(el, cfg) { window.__charts.push(cfg); } destroy() {} };
  window.Chart.defaults = fundo();
  window.feather = { replace() {} };
  window.tailwind = {};   // o head faz tailwind.config = {...}
  window.__cfgSupabase = null;
  window.supabase = { createClient: (u, k, o) => { window.__cfgSupabase = { u, k, o }; return window.__cliente; } };
</script>`;

function montar(cliente, { placeholders = false } = {}) {
  // Remove os CDNs: o teste não deve depender de rede.
  let doc = html.replace(/<script src="https:\/\/[^"]+"><\/script>/g, '');

  // Credenciais de mentira, salvo quando o teste é justamente sobre a
  // falta delas. Sem isso iniciarPainel() cai na tela de erro e troca o
  // conteúdo do portão, e os testes de login não teriam onde digitar.
  if (!placeholders) {
    doc = doc.replace('__SUPABASE_URL__', 'https://teste.supabase.co')
             .replace('__SUPABASE_ANON_KEY__', 'chave-de-teste');
  }
  // Os stubs entram logo após <head>: o próprio head já usa tailwind.config
  // e Chart.defaults, então definir depois seria tarde.
  doc = doc.replace(/<head([^>]*)>/i, (m, a) => `<head${a}>` + STUBS);

  // Erro de script e falha de seção são coisas diferentes: a segunda é
  // tratada pelo painel de propósito e não deve reprovar o teste.
  const vc = new VirtualConsole();
  const erros = [], rendersQuebrados = [];
  vc.on('jsdomError', e => erros.push(e.message));
  vc.on('error', (...a) => {
    const m = a.map(String).join(' ');
    (m.includes('[painel] falhou') ? rendersQuebrados : erros).push(m);
  });

  const dom = new JSDOM(doc, {
    runScripts: 'dangerously',
    url: 'https://erich-web.github.io/financeiro_CH/',
    pretendToBeVisual: true,
    virtualConsole: vc,
    beforeParse(w) { w.__cliente = cliente; },
  });
  return { dom, w: dom.window, erros, rendersQuebrados };
}

const esperar = (ms = 60) => new Promise(r => setTimeout(r, ms));

/* DB, EU e sb são declarados com `let` no topo de scripts clássicos, e
   isso cria binding no escopo léxico global — que não é window. Só se
   alcança por eval dentro da própria janela. */
const val = (w, expr) => w.eval(expr);

/* =====================================================================
   1. O arquivo não carrega número nenhum
   ===================================================================== */
secao('1. O arquivo servido não contém dados financeiros');
ok(!html.includes('const DATA'), 'o objeto DATA não está no arquivo');
ok(!html.includes('1287877.15'), 'o saldo de caixa não aparece no fonte');
ok(!html.includes('3348867'), 'a receita acumulada não aparece no fonte');
ok(!html.includes('FRK Empreendimentos'), 'o quadro societário não aparece no fonte');
ok(!/sk-ant|ANTHROPIC_API_KEY/.test(html), 'nenhuma referência a chave de API');
ok(html.includes('let DB = null'), 'DB começa vazio');

/* =====================================================================
   2. Sem sessão, o portão fica de pé
   ===================================================================== */
secao('2. Sem sessão, o portão cobre o painel');
{
  const { w, erros } = montar(clienteFalso({ sessao: null }));
  await esperar();

  const gate = w.document.getElementById('gate');
  ok(gate && !gate.classList.contains('hidden'), 'o portão está visível');
  ok(!w.document.getElementById('gate-form').classList.contains('hidden'), 'pede o e-mail');
  ok(val(w, 'DB') === null, 'DB continua vazio');
  ok(w.__charts.length === 0, 'nenhum gráfico foi desenhado');
  ok(w.document.getElementById('chat-fab').classList.contains('hidden'), 'o botão do chat não aparece');
  ok(erros.length === 0, 'sem erro de script' + (erros.length ? ': ' + erros[0] : ''));
}

/* =====================================================================
   3. O formulário pede o link mágico
   ===================================================================== */
secao('3. O formulário dispara o link mágico');
{
  const cli = clienteFalso({ sessao: null });
  const { w } = montar(cli);
  await esperar();

  w.document.getElementById('gate-email').value = '  Erich@GrupoRPE.com.BR  ';
  w.document.getElementById('gate-form').dispatchEvent(new w.Event('submit', { cancelable: true, bubbles: true }));
  await esperar();

  ok(cli.chamadas.otp.length === 1, 'pediu o link uma vez');
  ok(cli.chamadas.otp[0]?.email === 'erich@gruporpe.com.br', 'normalizou o e-mail (minúsculas, sem espaço)');
  ok(!w.document.getElementById('gate-enviado').classList.contains('hidden'), 'mostra a tela de link enviado');
  ok(w.document.getElementById('gate-destino').textContent.includes('erich@'), 'mostra para onde foi');
}

/* =====================================================================
   4. E-mail com sessão mas fora do cadastro não entra
   ===================================================================== */
secao('4. E-mail não cadastrado é barrado');
{
  const { w } = montar(clienteFalso({
    sessao: { user: { email: 'estranho@fora.com' } },
    eu: null,
  }));
  await esperar();

  ok(!w.document.getElementById('gate').classList.contains('hidden'), 'o portão não abriu');
  ok(!w.document.getElementById('gate-negado').classList.contains('hidden'), 'mostra "não cadastrado"');
  ok(w.document.getElementById('gate-negado-email').textContent === 'estranho@fora.com', 'diz qual e-mail');
  ok(val(w, 'DB') === null, 'não carregou dado nenhum');
}

/* =====================================================================
   5. Diretoria entra, painel desenha, chat aparece
   ===================================================================== */
secao('5. Diretoria entra e vê o painel com o chat');
{
  const EU_DIR = {
    id: 'p1', nome: 'Erich Progin', email: 'erich@gruporpe.com.br',
    papeis: ['admin', 'diretoria'], e_diretoria: true, e_conselho: false,
    e_admin: true, e_socio: true,
    representa: ['RPE Empreendimentos e Participações', 'RPE Properties Gestão de Ativos'],
    peso_total: 0.166364042, capital_total: 1, base_completa: true,
  };
  const cli = clienteFalso({ sessao: { user: { email: EU_DIR.email } }, eu: EU_DIR });
  const { w, erros, rendersQuebrados } = montar(cli);
  await esperar(150);

  ok(w.document.getElementById('gate').classList.contains('hidden'), 'o portão saiu da frente');
  ok(val(w, 'DB') !== null, 'DB foi preenchido');
  ok(val(w, 'DB && DB.meta && DB.meta.caixa_total') === 1287877.15, 'o caixa veio do banco');
  ok(w.__charts.length > 0, `desenhou ${w.__charts.length} gráficos`);

  const fab = w.document.getElementById('chat-fab');
  ok(!fab.classList.contains('hidden'), 'o botão do chat aparece para a diretoria');

  const chip = w.document.getElementById('eu-chip');
  ok(!!chip, 'o chip de identificação entrou na barra lateral');
  ok(chip?.textContent.includes('Erich'), 'mostra o nome');
  ok(chip?.textContent.includes('Administrador'), 'mostra o papel');
  ok(chip?.textContent.includes('2 quotistas'), 'diz que representa duas quotistas');

  // o quadro societário tem de vir da tabela, não do payload
  ok(val(w, 'DB && DB.socios ? DB.socios.length : 0') === 3, 'quadro societário montado pela tabela');
  ok(val(w, 'DB.socios[0][0]') === 'FRK Empreendimentos e Participações', 'primeiro quotista correto');
  ok(val(w, 'DB.socios[2][3]') === 'Pendente – chamada abr/mai', 'quotista não integralizado marcado');

  ok(erros.length === 0, 'sem erro de script' + (erros.length ? ': ' + erros[0] : ''));
  ok(rendersQuebrados.length === 0,
     'todas as seções desenharam' + (rendersQuebrados.length ? ': ' + rendersQuebrados[0].slice(0, 400) : ''));
}

/* =====================================================================
   6. Sócio comum entra sem o chat
   ===================================================================== */
secao('6. Sócio entra, mas sem o chat');
{
  const EU_SOCIO = {
    id: 'p2', nome: 'Luiz de Oliveira Rozette Filho', email: 'luiz@teste.com',
    papeis: [], e_diretoria: false, e_conselho: false, e_admin: false, e_socio: true,
    representa: ['Hotel Toriba'], peso_total: 0.083182021,
    capital_total: 1, base_completa: true,
  };
  const { w } = montar(clienteFalso({ sessao: { user: { email: EU_SOCIO.email } }, eu: EU_SOCIO }));
  await esperar(150);

  ok(w.document.getElementById('gate').classList.contains('hidden'), 'o portão abriu');
  ok(val(w, 'DB') !== null, 'o painel carregou');
  ok(w.document.getElementById('chat-fab').classList.contains('hidden'), 'o chat não aparece para o sócio');
  ok(w.document.getElementById('eu-chip')?.textContent.includes('Sócio'), 'o chip diz Sócio');
  ok(w.document.getElementById('eu-chip')?.textContent.includes('Hotel Toriba'), 'nomeia a quotista que ele representa');
}

/* =====================================================================
   7. Base de capital incompleta avisa na cara
   ===================================================================== */
secao('7. Base de capital incompleta gera aviso');
{
  const EU = {
    id: 'p3', nome: 'Teste', email: 't@t.com', papeis: ['diretoria'],
    e_diretoria: true, e_conselho: false, e_admin: false, e_socio: false,
    representa: [], peso_total: 0, capital_total: 0.8318, base_completa: false,
  };
  const { w } = montar(clienteFalso({ sessao: { user: { email: EU.email } }, eu: EU }));
  await esperar(150);

  const txt = w.document.body.textContent;
  ok(txt.includes('Base de capital incompleta'), 'o aviso aparece');
  ok(txt.includes('83,18%'), 'diz quanto soma de fato');
}

/* =====================================================================
   8. Projeto não configurado falha dizendo o que falta
   ===================================================================== */
secao('8. Sem credenciais, o painel diz o que falta');
{
  const temPlaceholder = html.includes('__SUPABASE_URL__');
  ok(temPlaceholder, 'o build sem credenciais deixa o placeholder');
  if (temPlaceholder) {
    const { w } = montar(clienteFalso({ sessao: null }), { placeholders: true });
    await esperar();
    const txt = w.document.getElementById('gate').textContent;
    ok(txt.includes('não conectado ao banco'), 'avisa que não está conectado');
    ok(w.__cfgSupabase === null, 'não tentou criar cliente com placeholder');
  }
}

/* =====================================================================
   9. Uma seção quebrada não derruba o painel
   ===================================================================== */
secao('9. Seção quebrada degrada sozinha');
{
  // Fechamento com o bloco do estacionamento corrompido de propósito.
  // mix: null é defeito de formato que nenhuma guarda razoável conserta —
  // justo o caso em que a seção deve cair sozinha.
  const ruim = JSON.parse(JSON.stringify(FECHAMENTO));
  ruim.dados.mix = null;
  TABELAS.v_fechamento_vigente = [ruim];

  const EU = {
    id: 'p4', nome: 'Teste', email: 't@t.com', papeis: ['diretoria'],
    e_diretoria: true, e_conselho: false, e_admin: false, e_socio: false,
    representa: [], peso_total: 0, capital_total: 1, base_completa: true,
  };
  const { w } = montar(clienteFalso({ sessao: { user: { email: EU.email } }, eu: EU }));
  await esperar(150);

  ok(w.document.getElementById('gate').classList.contains('hidden'), 'o painel abriu mesmo assim');
  ok(val(w, 'DB') !== null, 'os dados carregaram');
  const aviso = w.document.getElementById('aviso-render');
  ok(!!aviso, 'o aviso de seção quebrada apareceu');
  ok(aviso?.textContent.includes('Visão geral'), 'nomeia a seção que falhou');
  ok(w.__charts.length > 0, 'as outras seções desenharam');

  TABELAS.v_fechamento_vigente = [FECHAMENTO];   // devolve o fixture
}

/* ===================================================================== */
console.log(`\n===== ${passes} passaram, ${falhas} falharam =====`);
process.exit(falhas ? 1 : 0);
