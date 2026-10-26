// Confere a função do chat no que dá para conferir sem a Anthropic:
// os cabeçalhos CORS e a tradução dos erros que a gaveta mostra.
// Roda com: node --experimental-strip-types supabase/testes/chat.test.mjs
import { readFileSync } from 'node:fs';
import { traduzErroApi } from '../functions/chat/erros.ts';

let total = 0, falhas = 0;
function confere(nome, ok) {
  total++;
  if (ok) console.log('   ok    ' + nome);
  else { falhas++; console.log('   FALHA ' + nome); }
}
// O supabase-js 2.45.4 manda estes quatro em todo functions.invoke. Se o
// preflight não liberar algum, o navegador barra a chamada antes de ela
// chegar à função — e nenhum teste em jsdom percebe.
const fonte = readFileSync(new URL('../functions/chat/index.ts', import.meta.url), 'utf8');
const permitidos = (fonte.match(/"Access-Control-Allow-Headers":\s*"([^"]+)"/)?.[1] || '')
  .split(',').map(h => h.trim().toLowerCase());
for (const h of ['authorization', 'x-client-info', 'apikey', 'content-type']) {
  confere(`CORS libera ${h}`, permitidos.includes(h));
}

const corpo = (type, message, extra = {}) =>
  JSON.stringify({ type: 'error', error: { type, message, ...extra }, request_id: 'req_x' });

confere('chave errada, revogada ou expirada',
  /recusou a chave/.test(traduzErroApi(401, corpo('authentication_error', 'invalid x-api-key'))));

confere('conta sem créditos',
  /sem créditos/.test(traduzErroApi(400, corpo('invalid_request_error',
    'Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits.'))));

confere('limite de gasto do workspace',
  /workspace foi atingido/.test(traduzErroApi(400, corpo('invalid_request_error',
    'You have reached your specified workspace API usage limits. You will regain access on 2026-11-01 at 00:00 UTC.'))));

confere('limite de gasto da conta',
  /conta da Anthropic foi atingido/.test(traduzErroApi(400, corpo('invalid_request_error',
    'You have reached your specified API usage limits. You will regain access on 2026-11-01 at 00:00 UTC.'))));

confere('teto mensal do nível (429 com error_code)',
  /teto mensal/.test(traduzErroApi(429, corpo('rate_limit_error',
    'You have reached your API usage limits: ...', { details: { error_code: 'enforced_spend_limit_reached' } }))));

confere('chave sem workspace',
  /não está vinculada a um workspace/.test(traduzErroApi(400, corpo('invalid_request_error',
    'The anthropic-workspace-id header is required for this API key.'))));

confere('modelo indisponível',
  /modelo configurado/.test(traduzErroApi(404, corpo('not_found_error', 'model: claude-xyz'))));

confere('excesso de pedidos por minuto',
  /Espere um minuto/.test(traduzErroApi(429, corpo('rate_limit_error',
    'Number of request tokens has exceeded your per-minute rate limit'))));

confere('Anthropic sobrecarregada',
  /instável/.test(traduzErroApi(529, corpo('overloaded_error', 'Overloaded'))));

confere('caso desconhecido devolve a mensagem original',
  /recusou o pedido \(400\): algo novo/.test(traduzErroApi(400, corpo('invalid_request_error', 'algo novo'))));

confere('corpo que não é JSON não derruba a tradução',
  /recusou o pedido \(400\): <html>/.test(traduzErroApi(400, '<html>bad</html>')));

console.log(`   ${total - falhas}/${total}`);
process.exit(falhas ? 1 : 0);
