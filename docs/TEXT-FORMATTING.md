# Quebra e formatação de texto

## Mudanças

- `white-space` distingue `normal`, `nowrap`, `pre`, `pre-wrap`, `pre-line` e `break-spaces`, inclusive na serialização de `getComputedStyle`.
- O padrão de `<pre>` vem do estilo UA e pode ser sobrescrito por `white-space:normal` do autor.
- `pre` preserva espaços e quebras explícitas sem quebrar automaticamente entre palavras, spans e átomos inline. `pre-wrap` preserva os espaços e permite quebra; seus espaços finais não entram no alinhamento nem no max-content. `pre-line` colapsa espaços e mantém as quebras explícitas.
- `break-spaces` mantém espaços finais nas medidas e permite quebra depois de cada espaço. O primeiro espaço continua ligado à palavra anterior.
- Linhas vazias usam font-size/line-height do contexto em vez de uma altura fixa de 18px. Uma quebra final não cria uma linha vazia adicional.
- `word-break:break-all` usa o espaço restante da linha antes de dividir a palavra. `overflow-wrap:break-word` e `anywhere` primeiro tentam mover a palavra inteira; a quebra de emergência acontece quando ela não cabe sozinha.
- `anywhere` e `break-all` reduzem o min-content; `break-word` mantém a largura intrínseca da palavra inteira. `nowrap` impede essas quebras.
- Fragmentos gerados pelo layout são recompostos antes de outra medição ou disposição. Encolher e ampliar o container não deixa cortes permanentes, e os links e paddings dos fragmentos são preservados.
- Cortes de palavras e reticências preservam acentos combinantes nos blocos cobertos, seletores de variação, modificadores de emoji, sequências ZWJ e pares de indicadores regionais.
- As gramáticas das propriedades de texto cobertas também são usadas na validação de declarações e nas consultas de suporte.

## Validação

`src/ui/text_formatting_test.odin` acrescenta 12 testes, com fonte sintética de avanço conhecido, verificando geometria e redimensionamento. Os testes existentes que aceitavam aproximações para pre-wrap/pre-line passaram a exigir os modos distintos.

`tests/layout/text-formatting.html` exercita 12 cenários com o executável e tem um golden permanente. A versão anterior falha nos casos de pre, pre-wrap, pre-line, break-spaces, anywhere/min-content e pre-wrap/max-content. As medidas de fonte desse golden são internas; a fonte sintética dos testes de unidade permite verificar a distribuição sem depender do atlas.

Resultados da rodada final:

- 839 testes UI, 175 CSS, 81 HTML, 4 rede, 20 Brotli e 10 WOFF2 passaram.
- 19 goldens de layout e 87 verificações de pintura passaram, preservando todas as referências existentes.
- Comparação A/B de 14 WPT de css-text, css-text-decor e css-inline: 10 passes, as mesmas 4 falhas por nome e zero erros de execução. Falhas: empty-span-size-002, text-stroke-width-subpixel, text-combine-emphasis e text-decoration-color.
- JavaScript: os 1873 testes mantiveram as mesmas 63 falhas; os pontos de falha foram comparados por nome com o registro anterior.

A ampliação da suíte expôs uma falha de alocador em `url_http_segue_normal`: o teste inseria uma imagem num cache global criado por outro teste. Ele agora isola e libera seu próprio cache. O resumo WPT também foi corrigido para contar arrays de resultados: no PowerShell 5.1, um único resultado era uma hashtable e `.Count` devolvia o número de campos, imprimindo quatro falhas para um único caso.

## Limites

Não implementa um algoritmo completo de quebra Unicode (UAX #14), segmentação de grafemas (UAX #29), bidi ou shaping de escritas complexas. Quebras entre trechos com estilos distintos ainda usam o modelo de itens existente. Hifenização automática, soft hyphen, regras linguísticas CJK e tab stops reais continuam pendentes; tabs preservados continuam expandidos para uma quantidade fixa de espaços. `word-break:break-word` mantém a representação legada compartilhada com overflow-wrap.

## Referência

[CSS Text Module Level 3](https://www.w3.org/TR/css-text-3/): white-space, overflow-wrap, word-break e processamento de espaços.