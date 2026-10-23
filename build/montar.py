#!/usr/bin/env python3
"""
Monta o index.html a partir das partes.

    python3 build/montar.py                  # prévia em build/index.preview.html
    python3 build/montar.py build/cfg.json   # index.html, pronto para publicar

cfg.json: {"url": "https://xxx.supabase.co", "anon": "eyJ..."}

Sem credenciais a montagem NÃO sobrescreve o index.html. O painel que está
no ar funciona; trocá-lo por uma casca que não sabe a qual banco falar
deixaria os sócios sem nada. A prévia serve para teste.

A URL e a chave anônima são públicas por natureza — ficam no navegador de
quem abre o painel. O que protege os dados é a RLS, não o sigilo delas.
"""
import json
import re
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
B = RAIZ / 'build'

SUPABASE_CDN = (
    '<script src="https://cdn.jsdelivr.net/npm/@supabase/'
    'supabase-js@2.45.4/dist/umd/supabase.js"></script>'
)


def ler(nome: str) -> str:
    return (B / nome).read_text(encoding='utf-8')


def main() -> int:
    cfg = {'url': '__SUPABASE_URL__', 'anon': '__SUPABASE_ANON_KEY__'}
    if len(sys.argv) > 1:
        cfg.update(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8')))
        if not cfg['url'].startswith('https://'):
            print('erro: url do projeto precisa começar com https://', file=sys.stderr)
            return 1

    head = ler('head.html')

    # supabase-js entra junto aos outros CDNs, antes de qualquer script nosso
    alvo = '<script src="https://cdnjs.cloudflare.com/ajax/libs/feather-icons/4.29.0/feather.min.js"></script>'
    if alvo not in head:
        print('erro: não achei o CDN do feather no head para ancorar o supabase-js', file=sys.stderr)
        return 1
    if 'supabase-js' not in head:
        head = head.replace(alvo, alvo + '\n' + SUPABASE_CDN)

    api = ler('api.html')
    for chave, valor in (('__SUPABASE_URL__', cfg['url']), ('__SUPABASE_ANON_KEY__', cfg['anon'])):
        api = api.replace(chave, valor)

    saida = '\n'.join([
        head, ler('gate.html'), api,
        ler('governanca.html'), ler('chat.html'), ler('tail.html'),
    ])

    # Conferências que já custaram tempo quando falharam calado
    erros = []
    if 'const DATA' in saida:
        erros.append('o objeto DATA ainda está no arquivo — os números vazariam para quem não logou')
    if saida.count('<script>const DB') or 'let DB = null' not in saida:
        erros.append('a declaração de DB não ficou como esperado')
    if 'iniciarPainel()' not in saida:
        erros.append('o boot não chama iniciarPainel()')
    if 'ANTHROPIC_API_KEY' in saida:
        erros.append('referência à chave da Anthropic no arquivo do navegador')
    if saida.count('</html>') != 1:
        erros.append('o arquivo tem %d fechamentos de html' % saida.count('</html>'))
    if erros:
        for e in erros:
            print('erro: ' + e, file=sys.stderr)
        return 1

    conectado = not cfg['url'].startswith('__')
    destino = (RAIZ / 'index.html') if conectado else (B / 'index.preview.html')
    destino.write_text(saida, encoding='utf-8')

    print(f"{destino.relative_to(RAIZ)}: {len(saida):,} bytes".replace(',', '.'))
    print('projeto: ' + (cfg['url'] if conectado else 'nenhum — prévia só para teste'))
    if not conectado:
        print('index.html intacto: sem banco para apontar, substituí-lo tiraria')
        print('o painel do ar sem pôr nada no lugar.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
