# Contextos de empilhamento

A pintura agora reúne os elementos posicionados e os contextos descendentes no
contexto ancestral mais próximo, em vez de ordenar somente os filhos imediatos.
O fundo e a borda do contexto vêm antes dos contextos negativos; o fluxo vem
depois deles; posicionados auto/zero e contextos positivos vêm por último.
Empates conservam a ordem da árvore, modificada por order em flex e grid.

z-index:auto e z-index:0 têm representações diferentes no estilo computado,
na caixa e no CSSOM. Zero explícito cria uma barreira em elementos posicionados
e itens flex/grid; auto permite que os contextos descendentes participem do
contexto ancestral. Um inteiro em um bloco estático comum não cria contexto.

Os gatilhos incluem fixed/sticky, opacidade menor que um, transformações,
filtros, backdrop-filter, blend, isolation, clip-path, máscaras implementadas,
will-change relevante e contenção de layout/pintura. A pintura também consulta
hover e transições em andamento. Animações de opacidade e transformações
mantêm um contexto; animações somente de cor não o criam.

Os elementos promovidos para a ordem do contexto conservam os offsets relativos
e os recortes retangulares de seus ancestrais. O içamento geométrico de absolutos
não pode atravessar barreiras de empilhamento. Fixed acompanha uma cadeia de
barreiras separada, porque seu bloco contenedor pode ser o viewport enquanto
um ancestral posicionado já estabelece o bloco contenedor de absolute.

A composição em grupo abrange caixas com conteúdo inline, além dos filhos
em bloco. A ordenação por z-index é estável e usa merge sort.

## Verificação

- src/ui/stacking_test.odin: auto/zero, CSSOM, herança explícita, gatilhos,
  promoção de descendentes, offsets e barreiras de contexto.
- tests/paint/stacking-contexts.html: 24 casos sem dependência de fonte.
- tools/check-stacking.ps1: verifica as cores nas sobreposições, sozinho ou
  chamado por paint-check.ps1. Aceita -Browser para comparação entre binários.
- Registros locais _local/stacking/stack_wpt_before_*.txt e
  _local/stacking/wpt_final_*.txt: comparação WPT
  selecionada por categoria e por nome de falha.

## Resultado desta alteração

- UI: 799/799; CSS: 175/175.
- Pintura: 86 verificações existentes e os 24 casos novos passaram.
- Golden de layout: 17/17, sem atualizar referências.
- WPT selecionado: 82 PASS / 14 FAIL / 0 ERROR em 96 testes. As listas de falhas
  de position, transforms, compositing, overflow, flexbox, grid e will-change
  são idênticas às do binário anterior.
- O executável principal foi atualizado; browser_pre_stacking_20261109.exe
  preserva o executável que estava no diretório antes da atualização.

## Limites

Isto não implementa todo o Apêndice E: a divisão fina entre fundos de blocos,
floats e conteúdo de cada linha continua no caminho de fluxo existente.
O recorte arredondado de overflow continua aproximado por máscaras de cantos,
inclusive quando o conteúdo é emitido em outra fase. Máscaras de imagem e os
modos de blend continuam limitados ao suporte anterior. Há orçamento de 24
layers por frame; excedê-lo ainda usa a composição aproximada existente.
As limitações de animações, transformações 3D e hit-testing transformado não
foram ampliadas por esta mudança. A construção de caixas para absolutos em
alguns contextos inline continua parcial; a ordenação não cria caixas ausentes.

Referências:
- [CSS 2.2, Appendix E](https://www.w3.org/TR/CSS22/zindex.html)
- [CSS Positioned Layout: Painting Order](https://www.w3.org/TR/css-position-3/#painting-order)
- [Flex Item Z-Ordering](https://www.w3.org/TR/css-flexbox-1/#painting)
