# Restyle incremental

`restyle_tab` compara snapshots locais do DOM e marca a subarvore alterada e
seus ancestrais. A cascata percorre os ancestrais para reconstruir o contexto de
heranca e variaveis; os demais ramos reutilizam os estilos computados. A deteccao
continua lendo o estado atual, inclusive escritas diretas em atributos.

Mudancas de fundo, opacidade e cursor podem atualizar caixas existentes. Outras
propriedades, texto inline sem caixa propria e mudancas estruturais reconstroem
a arvore de caixas. Zoom, viewport, tema e folhas novas invalidam tudo.
Seletores relacionais entre ramos, contadores e container queries usam o caminho
completo por seguranca. Container queries tambem invalidam sem mudanca no DOM.

As entradas intactas permanecem no mesmo mapa: apenas os valores substituidos
sao copiados para um snapshot temporario e liberados depois de atualizar as
caixas. A deteccao ainda percorre o DOM e a atualizacao de pintura percorre caixas.

A geometria do root tem cache compartilhado pelo loop de desenho e pelo flush
sincrono do CSSOM. Frames intactos e alteracoes apenas de pintura pulam
`layout_box` e `layout_absolutes`. Nova arvore, largura/altura do viewport e
entregas de imagens invalidam o cache; fontes novas ja provocam restyle completo.
Zoom, tema e viewport tambem passam pelo restyle no loop de desenho.
Scroll e animacoes visuais continuam sendo aplicados na pintura. Havendo
entradas no mapa de resize manual, a geometria e recalculada conservadoramente.
O cache cobre o documento inteiro; ainda nao ha layout parcial por subarvore.

## Validacao

`./test.ps1` executa todos os pacotes. As regressoes em
`src/ui/style_invalidation_test.odin` cobrem classes, atributos, variaveis,
pintura, estilos com recursos proprios, fallback relacional e estrutural.
Ha comparacao incremental/completa de propriedades computadas e geometria em
uma sequencia de mutacoes, incluindo flex e elementos absolutos, e verificacao
dos motivos de invalidacao do cache. Nao ha comparacao de pixels nessa suite.

Benchmark sintetico opcional, sem limite de tempo usado como assercao:

```powershell
C:/Odin/dist/odin.exe test src/ui -o:speed -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=incremental_style_benchmark -define:BENCH_RESTYLE=true
```

Medicao local em 2026-11-11, 2.003 nos, alternando uma classe em 20 restyles por
modo: caminho completo 34,200 ms/restyle e 2.003 cascatas; incremental 16,986 ms
e 5 cascatas (2,01x). Mede apenas `restyle_tab`, sem pintura ou layout geometrico.
O caso sintetico nao representa um benchmark de navegacao em paginas reais.

Depois da atualizacao in-place (mesma maquina e comando), nova observacao:
completo 39,677 ms/restyle; incremental 1,362 ms, 5 cascatas (29,13x).
As rodadas variam; os numeros nao medem o cache de geometria nem paginas reais.
