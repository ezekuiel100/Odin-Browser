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


## Precisão adicional — 11/11/2026

Esta etapa corrige quatro casos concretos sobre o suporte parcial existente:

- Grid reconstrói os grupos de primeira/última baseline depois de resolver as dimensões finais dos itens. Uma altura percentual numa linha definida já não usa a baseline da medição com altura auto. O posicionamento final translada a subárvore sem executar novamente o layout.
- A medição intrínseca de Grid acumula aumentos planejados para spans de mesmo comprimento, incluindo spans que combinam trilhas fixas e auto. As contribuições deixam de depender da ordem dos itens no DOM; a distribuição de frações também usa as bases anteriores ao grupo.
- Flex com largura intrínseca trata column-gap percentual cíclico como zero; a medição intrínseca não reaproveita o gap percentual resolvido por um layout anterior. Largura definida continua resolvendo o percentual normalmente.
- O min-content físico de conteúdo inline vertical usa a extensão de bloco vertical, com a mesma altura disponível e conversão de border-box usadas na medição max-content. Isso preserva o mínimo automático em Flex e Grid para filhos ortogonais com altura definida.

Cobertura: sete testes novos em `src/ui/flexgrid_precision_test.odin`, incluindo ordem invertida dos spans, primeira/última baseline, controle percentual definido e vertical-lr com padding/border-box. Os quatro primeiros reproduziram falhas antes da correção. A fixture `tests/layout/flexgrid-next.html` cobre os sete cenários no executável; o golden foi conferido pelas dimensões e posições esperadas. Nenhum golden existente foi alterado.

Validação: UI 1036/1036; 23/23 goldens de layout, incluindo a fixture nova. CSS 182/182; HTML 81/81; rede 4/4; Brotli 20/20; WOFF2 10/10; varfont 8/8. Na execução conjunta, JS teve uma falha em `cssom_shared_token_boundaries`, de alterações concorrentes no tokenizer/CSS.supports, fora deste patch. O executável de validação foi gerado em `_local/flexgrid_precision_next.exe`, sem substituir `browser.exe`.

WPT Grid selecionado: 28/30, sem erros; as falhas foram `grid-with-orthogonal-child-within-flexbox` (5050 pixels) e `stretch-grid-item-text-input-overflow` (644 pixels), os mesmos casos e diffs registrados anteriormente.

Os algoritmos completos continuam parciais: escrita vertical dos próprios containers Flex/Grid, propagação da altura disponível a descendentes ortogonais sem altura própria, ciclos percentuais gerais, distribuição de spans entre funções intrínsecas diferentes e crescimento integral por limites de trilha ainda exigem trabalho. Esta etapa não altera a expectativa do WPT ortogonal histórico nem mede desempenho/sites reais.

## Precisão de dimensionamento e margens — 26/11/2026

Esta atualização substitui a redução proporcional histórica das trilhas não flexíveis pelo crescimento a partir das bases, com incrementos iguais e congelamento nos limites de crescimento. Colunas e linhas compartilham essa etapa e só depois resolvem a fração comum de `fr`. Por exemplo, em 240px, `minmax(20px,60px) minmax(80px,300px)` resulta em 60px e 180px. Trilhas de máximo `auto` esticam com `justify-content`/`align-content:normal` ou `stretch`; máximos `min-content`, `max-content` e `fit-content()` preservam seus limites. `place-content` também atualiza essa distinção. Linhas `fr` em altura indefinida consideram contribuições de itens com span mesmo quando o mínimo é zero.

Flex pondera `flex-shrink` pela base **interna**, excluindo padding e bordas; a base externa continua participando do cálculo do espaço livre. O piso de padding/borda só limita os tamanhos hipotéticos e finais, preservando bases internas negativas permitidas por `box-sizing:border-box`. Fatores fracionários e congelamento por min/max continuam funcionando. Porcentagens de padding/margem são resolvidas contra a largura do container antes da medição das bases. Colunas medem a altura natural na largura disponível depois das margens cruzadas.

Margens `auto` funcionam nos dois eixos de Flex e Grid. Em Flex column, o espaço principal é dividido por margem e por coluna coletada, inclusive em `column-reverse`. Margens cruzadas automáticas impedem stretch e participação em grupos de baseline; em overflow mantêm o início acessível. Grid calcula stretch e alinhamento pela margin-box, incluindo margens percentuais resolvidas contra a área do item, sem duplicar a centralização de bloco.

O stretch cruzado de Flex pode reduzir uma caixa até a altura da linha, respeitando min/max e padding/borda. Filhos que dependem da altura final refazem a disposição: flex/grid aninhados, percentuais, imagens, scroll e containers de consulta. Quando a linha já tem altura definida, essa altura é passada na primeira medição, evitando duas chamadas recursivas por nível. Uma regressão com 20 níveis verifica o limite de chamadas.

`src/ui/layout_flexgrid_accuracy_test.odin` contém 26 testes com dimensões independentes de fontes. Os 12 casos iniciais falharam antes das correções. `tests/layout/flexgrid-sizing.html` reúne 27 cenários, incluindo controles e as duas direções de coluna; dois reftests locais com referências de retângulos verificam a pintura.

Duas expectativas antigas foram corrigidas: no teste de áreas implícitas, trilhas auto de conteúdo 60px e 40px num container de 200px ganham 50px cada com alinhamento normal; o segundo item começa em 110px e mantém sua largura própria de 40px. No golden da navbar, só os quatro itens com `min-width:0` mudam: o encolhimento passa a preservar o padding e ponderar o texto pela base interna. Os casos com mínimo automático e nowrap mantêm suas medidas.

Validação: 3.845 testes do projeto passaram (197 CSS, 1.181 UI, 2.342 JS, 81 HTML, 6 rede, 20 Brotli, 10 WOFF2 e 8 varfont); a suíte de UI foi repetida após a última alteração. Os 30 goldens de layout e 111 verificações de pintura passaram. Os dois novos reftests têm diferença zero; no binário anterior falham com 7,10% e 25,50%. A comparação independente com Edge conferiu 376 medidas de 94 caixas nas 27 cenas, sem divergência além do arredondamento do dump (tolerância de 0,51px); o binário anterior divergia em 114 medidas.

WPT selecionado A/B: Flex 12/12 e Grid 28/30, sem erros nos dois executáveis. A comparação por nome e diferença de pixels preservou exatamente as duas falhas: `grid-with-orthogonal-child-within-flexbox` (5050px) e `stretch-grid-item-text-input-overflow` (852px). O WPT completo não foi executado. Logs e comparações ficam em `_local/fga-*`; o binário anterior foi preservado em `_local/builds/browser-before-flexgrid-20261126.exe`.

O algoritmo completo de contribuições intrínsecas e spans mistos, mínimos automáticos de coluna com conteúdo/replaced, ciclos percentuais gerais, baseline e escrita vertical/ortogonal continuam parciais. Esta etapa não mede sites reais e não representa conformidade integral de Flex/Grid.

Referências: [Flex: comprimentos flexíveis](https://www.w3.org/TR/css-flexbox-1/#resolve-flexible-lengths), [Flex: dimensões cruzadas](https://www.w3.org/TR/css-flexbox-1/#cross-sizing), [Flex: margens cruzadas](https://www.w3.org/TR/css-flexbox-1/#cross-margins), [Grid: maximização das trilhas](https://www.w3.org/TR/css-grid-2/#algo-grow-tracks), [Grid: stretch de auto](https://www.w3.org/TR/css-grid-2/#algo-stretch), [Grid: margens automáticas](https://www.w3.org/TR/css-grid-2/#auto-margins).
