# Layout intrínseco e casos de flex/grid

## Alterações

- Flex com flex-basis:auto usa o conteúdo (ou a largura definida), mesmo quando flex-grow é positivo. O shorthand flex:1 continua com base zero.
- flex-wrap coleta itens pelo tamanho hipotético externo: base limitada por min/max, mais margens. Isso evita tanto juntar itens que deveriam quebrar quanto separar itens que cabem após max-width.
- Quando a soma dos fatores grow/shrink é menor que um, somente a fração solicitada do espaço livre inicial é distribuída. O congelamento por min/max mantém essa referência; shrink continua ponderado pela base.
- A largura max-content de uma linha flex conta gaps somente entre itens em fluxo.
- Colunas e linhas fr em eixos definidos compartilham um resolvedor com congelamento: trilhas no piso são descontadas antes de recalcular a fração das demais. Fatores cuja soma é menor que um deixam espaço livre.
- A largura max-content de grids respeita uma fração comum para as colunas fr. Itens com span descontam gaps e trilhas não flexíveis antes de resolver as frações, inclusive quando já existem contribuições de outros itens.

## Cobertura

src/ui/layout_intrinsic_flexgrid_test.odin contém 19 regressões/controles com dimensões conhecidas, sem dependência de fontes. O helper executa parser HTML/CSS, estilos computados, construção de caixas e layout; valida dimensões e posições, liberando os recursos da fixture.

tests/layout/intrinsic-flexgrid.html reúne os mesmos cenários para o executável real e para o harness de goldens. Os registros da comparação com o executável anterior ficam em _local/intrinsic/.

## Validação

- UI: 818/818 testes; CSS: 175/175.
- 17 goldens existentes passaram sem alterar referências; uma nova fixture cobre os 19 cenários.
- No dump do executável real: 45/45 medidas esperadas. O executável anterior errava 28 dessas medidas.
- Pintura: 87/87 verificações do harness (inclui os 24 casos de stacking).
- WPT selecionado: flex 12/12 e grid 28/30, antes e depois, sem erros. As duas falhas mantêm os mesmos diffs: grid-with-orthogonal-child-within-flexbox (5050 pixels) e stretch-grid-item-text-input-overflow (644 pixels).

## Limites

Esta etapa não implementa todo o algoritmo intrínseco de flex/grid. Permanecem aproximados os mínimos automáticos de tracks de grid, a distinção entre funções intrínsecas de minmax/fit-content, alguns spans mistos, porcentagens cíclicas, tamanhos transferidos por aspect-ratio, baseline e modos de escrita. Flex column com wrap também continua fora deste conjunto de correções.

## Referências

- [Flexbox: determinação do tamanho principal](https://www.w3.org/TR/css-flexbox-1/#main-sizing)
- [Flexbox: resolução dos comprimentos flexíveis](https://www.w3.org/TR/css-flexbox-1/#resolve-flexible-lengths)
- [Grid: expansão de trilhas flexíveis](https://www.w3.org/TR/css-grid-2/#algo-flex-tracks)
- [Grid: cálculo da fração](https://www.w3.org/TR/css-grid-2/#algo-find-fr-size)
