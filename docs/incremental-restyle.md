# Restyle incremental

`restyle_tab` compara snapshots locais do DOM e marca a subarvore alterada e
seus ancestrais. A cascata percorre os ancestrais para reconstruir o contexto de
heranca e variaveis; os demais ramos reutilizam os estilos computados. A deteccao
continua lendo o estado atual, inclusive escritas diretas em atributos.

Mudancas de fundo, opacidade e cursor podem atualizar caixas existentes. Outras
propriedades, texto inline sem caixa propria e mudancas estruturais reconstroem
os ramos afetados, reaproveitando subarvores intactas quando suas dependencias
permitem. Zoom, viewport, tema, fontes e folhas novas ainda reconstroem tudo.
Seletores relacionais com :has() comparam snapshots de casamento para invalidar
os sujeitos afetados e seus descendentes. Contadores continuam no caminho completo.
Container queries permitem invalidacao incremental quando suas medidas
estao estaveis; medidas novas ou alteradas invalidam mesmo sem mudanca no DOM.

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

## Invalidacao de container queries por medidas

A presenca de @container na folha nao forca mais a cascata completa por si so.
Cada aba guarda um fingerprint das dimensoes consultaveis dos seus conteineres,
incluindo a diferenca entre tamanho ainda desconhecido e tamanho ja medido.
Medidas iguais permitem o plano incremental normal. A primeira resolucao e
mudancas nos eixos consultaveis continuam usando Full_CQ; viewport, zoom, fontes e folhas
novas preservam suas invalidacoes completas. Medidas de outros documentos nao
entram no fingerprint da aba.

Uma mutacao em um irmao pode mudar a largura do conteiner sem mudar seus
atributos. O layout mede as dimensoes e as passadas seguintes resolvem novamente o
estilo ate estabilizar. O diagnostico --diagnose realiza o mesmo ciclo da interface.
Os testes comparam os estilos com uma cascata completa, incluindo containers
nomeados, mudanca de container-type/name, texto, insercao/remocao de filhos,
primeira medicao, limpeza das medidas e redimensionamento causado por irmaos.

A ampliacao de 26/11/2026 inclui altura, mudancas de fracao de pixel e selecao
conforme os eixos contidos. Uma mudanca apenas na altura de um container
inline-size horizontal nao exige Full_CQ. Sem container elegivel/medido a consulta
nao aplica a regra, sem usar o viewport como substituto. Consultas aninhadas podem
exigir mais de duas passadas; o ciclo tem teto de 32 e compara medidas finais,
ignorando os tamanhos provisorios do flex/grid. Detalhes e testes estao em
[CONTAINER-QUERIES.md](CONTAINER-QUERIES.md).

Medicao sintetica local em 2026-11-22, 700 ramos intactos e uma classe alternada
em um alvo: cascata 29,7 -> 3,1 ms/restyle; build_layout 6,9 -> 0,4 ms/restyle.
O caminho incremental recalculou 132 de 46.464 entradas acumuladas (0,3%).
A versao anterior fez 22 restyles, a nova 23, incluindo a passada de medicao.
Esses tempos incluem instrumentacao e nao sao um percentual de ganho no Reddit.
Arquivos locais: `_local/cq-invalidation-bench.html`,
`_local/cq-invalidation-before.log` e `_local/cq-invalidation-after.log`.

Na carga do Reddit observada, os 10 restyles foram classificados como Full_Env=1,
Full_Structure=5 e Full_Cross_Sel=4. A cascata completa ainda e necessaria pelos
seletores relacionais: remover o gatilho incondicional de CQ nao elimina esses
fallbacks. Conteudo e mutacoes variam entre cargas; a medicao nao e controlada.

## Invalidacao relacional de :has()

Cada aba ret?m os seletores que contem :has(), inclusive dentro de :not(),
:is(), :where() e filtros de :nth-child. Antes do planejamento, a UI carimba os
escopos de shadow DOM e registra o conjunto exato de pares (no, seletor) que
casam. O plano normal cuida de atributos, texto e estrutura; diferencas entre o
snapshot antigo e o novo marcam tambem os sujeitos relacionais e suas subarvores.
Ancestrais desses sujeitos continuam participando para reconstruir a heranca.
Sujeitos encaixados sao agrupados pela raiz mais alta, evitando marcar a mesma
subarvore varias vezes. Ponteiros removidos sao usados apenas como chaves.

Folhas novas e navegacao descartam os snapshots. Uma aba recebida do worker
sem snapshot ainda usa uma primeira cascata completa para estabelecer a base.
Contadores, fontes, ambiente e medidas de container queries preservam seus
fallbacks. A deteccao relacional ainda percorre o DOM e reavalia os seletores
relacionais; nao ha indice de dependencias por mutacao nesta etapa.

O parser tambem passa a preservar argumentos cujo alvo e apenas :has() dentro
de :not/:is/:where. Antes eles eram considerados nao avaliaveis e descartados,
por exemplo em `.card:not(:has(>.on))`. Os testes conferem esse parsing, a
cascata completa e a geometria em sequencias com descendentes, irmaos,
heranca, grupos funcionais, texto, insercao/remocao, movimentos e troca de folhas.

Em teste sintetico local de 700 cards, com 22 restyles por versao, o tempo TOTAL
de restyle (incluindo a comparacao relacional) caiu de 1.049 para 134 ms
(47,7 -> 6,1 ms/chamada, cerca de 7,8x). O caminho incremental recalculou
147 de 58.989 entradas acumuladas, cerca de 0,25%. Tempos incluem instrumentacao;
nao sao um percentual de ganho no Reddit. Arquivos locais:
`_local/has-invalidation-bench.html`, `_local/has-before.log`, `_local/has-final.log`.

Na carga real observada, 21 restyles foram classificados como Incremental=20 e
Full_Env=1. As chamadas incrementais recalcularam 54.435 de 103.376 nos acumulados
(52,7%). A reconstrucao global das caixas permaneceu cara (688,9 ms/chamada
nessa carga) e segue sendo um gargalo. Conteudo e mutacoes diferem entre cargas,
portanto a medicao real nao e uma comparacao controlada de tempo total.

Validacao com STYLECHECK=true: na execucao real do Reddit, 21 rodadas fizeram
101.815 comparacoes de estilos com a cascata completa, sem divergencias,
entradas ausentes ou entradas excedentes. O sintetico tambem passou pelo
oraculo. Logs locais: `_local/reddit-has-oracle.log` e
`_local/has-oracle-bench.log`. Suites: 1.116 testes de UI e 186 de CSS passaram.

## Reaproveitamento durante a construcao das caixas

Restyles incrementais podem transferir subarvores de caixas intactas para a
nova raiz. O indice aponta para os slots donos da arvore antiga: ao transferir
uma caixa, o slot e zerado e as entradas dos descendentes sao retiradas do
indice. A liberacao da arvore antiga nao libera os ramos transferidos. O estado
de scroll e os players de animacao desses ramos permanecem nas mesmas caixas;
os ramos reconstruidos seguem os mecanismos existentes de restauracao.

O indice verifica tanto nos DOM quanto a proveniencia de texto inline.
Ponteiros de nos removidos servem apenas como chaves. Imagens e marcadores de
lista nao sao reaproveitados diretamente, pois podem consultar irmaos fora da
sua subarvore. Um ramo shadow e reconstruido quando seu host esta sujo: slots
podem projetar nos de luz fora da ancestralidade DOM do proprio slot.

Caixas absolutas/fixas e ambos os caminhos de posse afetados pelo icamento
continuam sendo reconstruidos. O passe de posicionamento pode mover essas
caixas para outros pais e guardar ancoras externas; reter esses ramos produziria
caixas ausentes/duplicadas ou referencias a ancestrais antigos. Nos representados
por varias caixas e a raiz tambem seguem o caminho completo de construcao.

As caixas possuem copias das listas de transformacao, inclusive hover e stops
aninhados de animacao. Elas nao dependem da vida util do Computed que as criou.
Os testes liberam os estilos antes de avaliar a geometria/animacao e usam um
rastreador de memoria para tornar liberacoes duplicadas uma falha do teste.

Isso reduz a CONSTRUCAO da arvore. O calculo de posicoes e tamanhos continua
cobrindo o documento todo apos uma reconstrucao; ainda nao ha layout geometrico
parcial por subarvore. O perfil UIPROF informa caixas e subarvores transferidas.

O define LAYOUTCHECK=true habilita um oraculo opcional que constroi uma arvore
completa independente dos mesmos estilos e compara caixas anonimas, estrutura,
geometria e fragmentos inline. Na execucao do Reddit validada, foram 16 rodadas,
12.386 caixas comparadas e zero divergencias. Os testes de UI passaram (1.122),
e seis estados de uma fixture com flex, inline-block, absolutos e pseudo-elementos
produziram pixels identicos entre reaproveitamento e reconstrucao completa.
Logs/probe locais: `_local/reddit-layout-oracle-3.log`,
`_local/layout-reuse-complete-tests.log` e `_local/layout_reuse_probe/main.odin`.

Medicao final sintetica (700 ramos estaveis, 22 restyles): a fase de construcao
caiu de 10,6 para 2,3 ms/chamada (cerca de 4,6x), e o tempo total de restyle de
366 para 194 ms. Foram transferidas 44.100 caixas em 14.700 subarvores acumuladas.
Os tempos incluem instrumentacao. Arquivos locais: `_local/layout-before.log`
e `_local/layout-final-bench.log`.

Na ultima carga real do Reddit, 27 restyles transferiram 9.243 caixas em 1.567
subarvores acumuladas. A fase de construcao ainda custou 779,5 ms/chamada nessa
carga. Conteudo, mutacoes e carga da maquina variam; nao ha ganho de tempo total
comprovado no Reddit a partir dessas cargas distintas. A melhoria controlada
e a validacao de geometria nao eliminam os caminhos conservadores nem o custo
do calculo global de posicoes. Log local: `_local/reddit-layout-final.log`.
