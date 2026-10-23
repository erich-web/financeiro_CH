# Painel do Campos Hall — backend

O painel deixou de ser um arquivo com os números dentro. Agora é uma casca
que exige login e lê tudo do banco. Esta pasta tem o banco inteiro escrito
como código, mais a função que atende o chat da diretoria.

## O que mudou no painel

Antes, `index.html` carregava um objeto `DATA` com DRE, balanço, caixa,
recebíveis e quadro societário. Qualquer pessoa com o link baixava o
arquivo e tinha os números. Colocar uma tela de login na frente disso não
resolveria nada — os dados continuariam no arquivo.

Agora o arquivo não tem número nenhum. Ele pede o e-mail, manda um link,
e só depois busca os dados. E-mail que não esteja na tabela `pessoas`
entra e não lê uma linha.

## Este repositório é público

`github.com/erich-web/financeiro_CH` é público — é o que faz o GitHub
Pages servir o painel de graça. Consequência: **nada com número do Campos
Hall entra em commit.** O `.gitignore` barra:

- `build/data_atual.json` — o payload extraído do painel antigo
- `supabase/migrations/0005_carga_fechamento.sql` — a carga do fechamento
- `build/index.preview.html` — a prévia montada, que embute a prévia dos dados

A 0005 é gerada localmente a partir do painel em produção e aplicada à
mão. Ela não precisa viver no Git: é operação de uma vez só.

Vale saber que o `index.html` que está no ar hoje carrega o objeto `DATA`
com DRE, balanço, caixa e recebíveis — e está neste repositório público,
além de no histórico de commits. Trocar o arquivo resolve o futuro, não o
passado: quem quiser o histórico ainda o acha. Ver "O que ainda falta".

## Estrutura

    migrations/
      0001_fundacao.sql          tabelas, tipos, funções de identidade, auditoria
      0002_rls.sql               políticas de acesso e integridade do voto
      0003_views_seed.sql        visões de apoio e quadro societário
      0004_aplicar_proposta.sql  aplicação atômica de proposta do chat
      0005_carga_fechamento.sql  o painel de hoje, migrado para o banco
      0006_views_telas.sql       visões das telas de pendência, voto e comentário
    functions/chat/index.ts      Edge Function do assistente
    testes/                      46 testes de SQL e 100 de navegador
    testar.sh                    roda tudo, sem rede e sem tocar em projeto real

## Decisões que valem saber

**Quotista e pessoa são tabelas diferentes.** Nove dos onze quotistas são
pessoas jurídicas, e um mesmo representante pode responder por mais de uma
— RPE Properties e RPE Empreendimentos têm o mesmo. Numa tabela só, o voto
desse representante valeria metade do que vale.

**Quórum é percentual de capital, não contagem de quotas.** É o que o
acordo de 26.09.2025 diz, e no Campos Hall as duas medidas divergem: há
quotista com uma quota que integralizou R$ 270.834 e outra com uma quota
que integralizou R$ 259.896. As participações saem do capital
integralizado e somam 1 exato.

**O peso do voto nunca vem do cliente.** Um trigger sobrescreve com a
participação registrada. Sem isso, qualquer sócio mandaria peso 1 pela API
e aprovaria matéria sozinho — é o teste 7 de `0001_governanca.sql`.

**As demonstrações ficam como jsonb versionado, não normalizadas em
linhas.** São lidas inteiras, publicadas como bloco único e precisam de
histórico imutável. Normalizar o DRE não traria ganho de consulta e
quebraria todo o código de gráficos que já funciona.

**Fechamento publicado é imutável.** Correção gera versão nova do mesmo
período; a anterior fica no histórico. É o que permite ao sócio confiar
que o número visto na reunião continua lá.

**A auditoria é legível por qualquer sócio, de propósito.** Quando uma
pessoa opera o painel inteiro, o registro só controla alguma coisa se os
outros puderem ler. Não existe política de escrita: as linhas entram por
trigger, e ninguém forja nem apaga pela API.

## Rodar os testes

    bash supabase/testar.sh

Sobe um Postgres próprio em `/tmp/pgch`, aplica as migrações, roda os
testes de SQL e depois os de navegador em jsdom. Não precisa de rede nem
de projeto no Supabase.

Os testes de permissão rodam com `SET ROLE app_user`, sem privilégio.
Rodar como dono da tabela passa por cima da RLS e daria tudo verde sem
provar nada.

## Aplicar num projeto novo

1. Criar o projeto no Supabase, região `sa-east-1`.

2. Aplicar as migrações em ordem, de 0001 a 0005.

3. Cadastrar as pessoas. O quadro societário já vem na 0003; o que falta
   são os e-mails e quem representa quem:

   ```sql
   insert into pessoas (nome, email) values ('Arthur <sobrenome>', '<email>');

   insert into pessoa_papeis (pessoa_id, papel)
   select id, 'diretoria' from pessoas where lower(email) = '<email>';

   insert into pessoa_socio (pessoa_id, socio_id)
   select p.id, s.id from pessoas p, socios s
   where lower(p.email) = '<email>' and s.nome = '<quotista>';
   ```

   Sem isso, o e-mail recebe o link, entra e não vê nada — que é o
   comportamento correto, não uma falha.

4. Conferir a representação do Erich. A 0003 liga ele a RPE Properties e
   RPE Empreendimentos por inferência, pelas duas serem do Grupo RPE.

5. Publicar a função e guardar a chave como secret:

   ```
   supabase secrets set ANTHROPIC_API_KEY=...
   supabase functions deploy chat
   ```

   A chave vive só aqui. Enquanto não existir, o painel funciona inteiro
   e a gaveta do chat avisa que o assistente está fora.

6. Montar o `index.html` com as credenciais do projeto:

   ```
   echo '{"url":"https://xxx.supabase.co","anon":"eyJ..."}' > build/cfg.json
   python3 build/montar.py build/cfg.json
   ```

   A URL e a chave anônima são públicas por natureza — ficam no navegador
   de quem abre o painel. O que protege os dados é a RLS, não o sigilo
   delas. `build/cfg.json` fica fora do Git só para o arquivo montado não
   divergir sem alguém perceber.

7. No painel do Supabase, em Authentication → URL Configuration, apontar
   o site para `https://erich-web.github.io/financeiro_CH/`, senão o link
   mágico volta para o lugar errado.

## O que ainda falta

- **Decidir o que fazer com o histórico público.** O `DATA` com os números
  está nos commits deste repositório. Três caminhos: tornar o repositório
  privado e hospedar o painel em outro lugar (a casca não tem dado, então
  hospedagem pública dela é inofensiva); reescrever o histórico e forçar o
  push; ou apagar e recriar o repositório com o mesmo nome, mantendo a URL
  do Pages. O terceiro é o mais completo e o mais simples.
- Os e-mails dos onze sócios e de quem representa cada quotista.
- Conferir contra o Anexo I as duas divergências entre quota e capital
  (Tarundu e Fábio/Cesar).
- O painel ainda mostra quatro conselheiros fiscais; a cláusula 6.12 fala
  de três efetivos mais suplentes.
- Fluxo visual de fechamento mensal: hoje a diretoria muda o estado por
  SQL ou pelo assistente, não por uma tela.
- Resumo mensal por e-mail aos sócios quando um fechamento é publicado.
- Rastreabilidade de cada número até a página do documento de origem.
