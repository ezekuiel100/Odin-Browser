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

## Metadados de folhas e lotes de fontes

As dependencias de seletores e a presenca de container queries ficam em cache
por aba, junto das regras. A varredura de @font-face tambem ocorre apenas na
entrada de uma folha, inclusive quando as regras chegam prontas do worker.
`tab_drop_rules` invalida esses metadados; mudancas no CSSOM seguem esse caminho.

No navegador interativo, fontes prontas e novos tamanhos nativos compartilham
um lote de atlas. Se ainda houver downloads, o lote aguarda ate 50 ms a partir
da primeira fonte pronta, sem bloquear a thread. Ao terminar o ultimo download,
o lote pode sair antes do prazo. O rebuild continua invalidando estilos e layout
para preservar as metricas. Renderizacao offline continua promovendo imediatamente.
Isso reduz rebuilds quando os downloads chegam proximos; nao reduz o custo de
um rebuild isolado nem elimina os fallbacks completos de :has/container queries.
Ainda nao ha medicao comparativa desta alteracao no Reddit.

## Filtro de valores de atributos nos ancestrais

O filtro de ancestrais tambem registra pares nome/valor para seletores de
igualdade exata, como `[data-shadow-scope="42"] .item`. Antes, qualquer ancestral
com `data-shadow-scope` passava pelo filtro, mesmo com outro valor, e o matcher
precisava percorrer a cadeia para rejeitar a regra. Operadores parciais e
seletores com flag `i` continuam usando apenas o nome do atributo. Colisoes de
hash apenas deixam candidatos extras passarem; o matcher completo continua
sendo a autoridade sobre o casamento.

A medicao do Reddit em 2026-11-22 encontrou 20 restyles: um `Full_Env` e 19
`Full_CQ`. O filtro torna a cascata mais seletiva, mas nao elimina o fallback
completo de container queries. Os testes cobrem valores distintos, igualdade
sem diferenciar maiusculas, valor vazio, prefixos e combinadores de irmaos.

Em uma rodada sequencial com a versao final e a mesma pagina sintetica local
(24 componentes, 24 itens por componente e 64 regras por componente), foram
22 restyles por versao. O perfil da cascata caiu de 58,7 para 27,2 ms/restyle
(2,16x). Esses tempos incluem instrumentacao e nao representam aceleracao de
navegacao do Reddit. Arquivos locais da medicao: `_local/scoped-style-bench.html`,
`_local/scoped-before-final.log` e `_local/scoped-final.log`.

Na ultima carga real do Reddit, a versao final registrou 19 restyles (18 Full_CQ,
1 Full_Env), 497,6 ms de cascata e 618,4 ms de build_layout por restyle. A carga
anterior registrou 20 restyles, 760,7 ms e 675,9 ms, respectivamente. Conteudo,
rede e mutacoes diferem entre cargas; esses numeros sao observacoes, nao uma
comparacao controlada nem prova de um percentual de ganho no Reddit. Relatorios:
`_local/reddit-css-before.log` e `_local/reddit-css-final.log`.
