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

Esta etapa não implementa todo o algoritmo intrínseco de flex/grid. A atualização abaixo amplia mínimos automáticos, funções intrínsecas de trilhas, transferência por aspect-ratio e flex column com wrap. Spans mistos, porcentagens cíclicas, baseline e modos de escrita continuam parciais.

## Precisão de flex/grid — 10/11/2026

- Flex em coluna coleta várias colunas pelo tamanho hipotético externo (base limitada por min/max, mais margens e row-gap). Cada coluna resolve grow/shrink separadamente. Altura indefinida mantém uma coluna; zero é uma altura definida.
- `column-reverse` e `row-reverse` preservam a coleta das linhas na ordem modificada por `order`, invertendo o posicionamento dentro de cada linha. `wrap-reverse` também inverte o eixo cruzado.
- `align-content` distingue stretch de distribuição de espaço, inclusive em um container com wrap que coletou somente uma linha. Linhas row usam row-gap; colunas usam column-gap. Um row-gap explicitamente zero não herda column-gap.
- Flex-basis em coluna respeita a conversão de content-box para border-box.
- O mínimo automático e a base automática de flex row consideram o tamanho transferido de uma altura definida por aspect-ratio, incluindo altura percentual resolvível, padding/borda e box-sizing. A largura definida limita o mínimo automático.
- Trilhas guardam separadamente as funções intrínsecas mínima e máxima. `min-content`, `max-content`, `minmax()` e `fit-content(length/percentage)` deixam de compartilhar uma única aproximação Auto no dimensionamento de colunas.
- Uma trilha `1fr` preserva o mínimo automático de um item que ocupa só ela, tanto em colunas quanto em linhas de altura definida. `minmax(0,1fr)`, min-size explícito e overflow rolável permitem o encolhimento. Um span cruzando trilhas flexíveis não ganha indevidamente o mínimo automático de um item de span 1.
- Medições intrínsecas de coluna também distinguem min-content, mínimo zero e o teto de fit-content em pixels.

### Regressões permanentes

`src/ui/flexgrid_precision_test.odin` contém 34 cenários sem dependência de fontes. `tests/layout/flexgrid-precision.html` exercita os mesmos cenários no executável e possui golden próprio.

A expectativa antiga de `m135_trilha_fixa_nao_cede_espaco` foi corrigida: uma trilha max-content de 500px ao lado de uma trilha fixa de 400px preserva os 500px e transborda. Aceitar ~179px codificava a aproximação antiga. O teste sintético de tipografia passou a inicializar row-gap explicitamente, mantendo sua asserção de espaçamento.

No golden `flex-anon-nowrap`, somente o item anônimo do grid com nowrap muda de 60px para 92px: a trilha preserva o mínimo do texto indivisível e transborda o container de 60px. A linha de controle com quebra permitida mantém 60px. A alteração da referência foi revisada por medida, sem regenerar os demais goldens.

Comparação dos executáveis: 79/79 medidas esperadas no novo; 63 medidas incorretas no anterior. Os registros locais ficam em `_local/flexgrid/`.

Portões desta atualização: `test.ps1` passou nos oito pacotes (175 CSS, 925 UI, 1873 JS, 81 HTML, 4 rede, 20 Brotli, 10 WOFF2 e 8 varfont). Pintura: 111/111. Goldens: 20/20 no `browser.exe` instalado, também conferido nas 79 medidas da fixture. WPT selecionado A/B: flex 12/12 e grid 28/30 nos dois executáveis; os dois casos de grid mantêm exatamente os mesmos nomes e diffs (5050 e 644 pixels). O WPT completo não foi repetido.

### Limites restantes

Não é uma implementação integral dos algoritmos das especificações. Continuam pendentes baseline de flex/grid, escrita vertical/ortogonal, distribuição completa de contribuições de spans mistos, resolução de ciclos percentuais e o algoritmo completo de crescimento por limites de trilha. A redução de trilhas não flexíveis ainda usa a distribuição proporcional histórica, agora respeitando os pisos calculados. A transferência por aspect-ratio foi ampliada no eixo principal de flex row; flex column e alguns casos de conteúdo/replaced ainda usam as medições anteriores. O dimensionamento intrínseco com porcentagens continua parcial. Não houve medição de desempenho ou de sites reais nesta etapa.

## Referências

- [Flexbox: determinação do tamanho principal](https://www.w3.org/TR/css-flexbox-1/#main-sizing)
- [Flexbox: resolução dos comprimentos flexíveis](https://www.w3.org/TR/css-flexbox-1/#resolve-flexible-lengths)
- [Grid: expansão de trilhas flexíveis](https://www.w3.org/TR/css-grid-2/#algo-flex-tracks)
- [Grid: cálculo da fração](https://www.w3.org/TR/css-grid-2/#algo-find-fr-size)
