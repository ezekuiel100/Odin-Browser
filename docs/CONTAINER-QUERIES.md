# Container queries — 26/11/2026

As consultas de tamanho agora usam a content-box medida de um ancestral elegível. Não há fallback para o viewport: sem container, sem nome correspondente ou antes da primeira medição, a consulta não aplica sua regra. O próprio elemento não pode ser o container da sua consulta. A escolha do ancestral mais próximo ocorre antes de avaliar a condição; uma condição falsa não permite tentar um ancestral mais distante.

## Condições e seleção

`src/css/container_queries.odin` analisa uma árvore de condições própria para @container, independente de @media. A representação retida por Rule possui suas strings e nós; free_rules libera ambos. Os antigos campos cq_min/cq_max continuam como resumo de diagnóstico, sem decidir o matching.

- width, height, inline-size, block-size, aspect-ratio e orientation.
- Formas min-/max-, igualdade, comparações estritas e inclusivas e intervalos com dois limites, em ambas as direções.
- not, and, or e agrupamento. Misturar and/or sem agrupamento é inválido.
- Listas separadas por vírgula: cada alternativa escolhe seu próprio container. Blocos @container aninhados conservam todas as condições externas, com seus próprios nomes e alternativas. Condições @media continuam independentes.
- Recursos desconhecidos mantêm o valor lógico desconhecido, inclusive sob not. Uma alternativa conhecida verdadeira pode satisfazer or; condições malformadas não ativam regras.

container-name aceita uma lista de identificadores e conserva caixa; Card e card são nomes distintos. container-type distingue normal, inline-size e size. O shorthand container reseta os componentes omitidos e compete com seus longhands na ordem da cascata. Consultas CSS/JS e setters usam a validação compartilhada dessas propriedades.

inline-size permite consultar somente o eixo inline do container: largura em horizontal-tb, altura em vertical-rl/vertical-lr. size permite os dois eixos. A seleção verifica todos os eixos exigidos pela condição antes de escolher o ancestral. block-size, aspect-ratio e orientation não são habilitados por um container que só contenha o eixo inline necessário parcialmente. Containers display:none/contents não fornecem uma caixa de tamanho elegível.

Comprimentos das condições usam os avaliadores existentes. em/ex/lh usam a fonte/entrelinha do container selecionado; rem usa a raiz. Comparações estritas não deslocam os limites com epsilon, e mudanças de frações de pixel não são descartadas.

## Medição, contenção e invalidação

`src/ui/container_queries.odin` mantém largura, altura e medidas usadas por thread. Ausência de medida é distinta de tamanho zero. Os mapas persistentes usam o heap, evitando ponteiros para arenas de frames ou alocadores temporários dos testes.

O layout publica as duas dimensões após aplicar width/height, min/max, borda, padding e dimensões impostas por flex/grid. Consultas usam a área de conteúdo; borda e padding não são somados à medida. A contribuição intrínseca de conteúdo é ignorada nos eixos contidos; size não deixa filhos definirem uma altura auto. contain-intrinsic-width/height fornecem a reserva nos eixos correspondentes.

O fingerprint da aba inclui presença e dimensões consultáveis. Alterar altura de um container size invalida consultas sem exigir mutação no DOM. Alterar somente o eixo block de um container inline-size não força a cascata completa. Dimensões estáveis conservam o planejamento incremental anterior; medidas de outros documentos não participam do fingerprint.

Uma consulta externa pode mudar largura, tipo ou nome de um container interno. A resolução alterna estilo/layout até estabilizar, em vez de supor que duas passadas sempre bastam. Medidas provisórias de flex/grid não causam reconstrução repetida quando a medida final é a mesma. O teto defensivo é de 32 passadas. A interface, --diagnose, --render e --dumplayout realizam a resolução; os rebuilds do render após timers e cliques também a realizam. --dumplayout conserva as regras até terminar as medições.

## Testes e limites

Regressões novas: três testes do parser em `src/css/container_queries_test.odin`, dez testes de estilo/layout em `src/ui/container_queries_test.odin` e um teste adicional de invalidação em `src/ui/style_invalidation_structure_test.odin`. Os três testes do parser passam com ODIN_TEST_FAIL_ON_BAD_MEMORY=true, incluindo a sobrevivência das strings após reciclar a arena temporária.

`tests/layout/container-queries.html` verifica nomes/listas, altura, escrita vertical, content-box, consultas aninhadas dependentes e um elemento sem container. O reftest `tests/reftest/container-size-queries.html` compara a pintura com caixas explicitamente verdes. reftest.ps1 aceita -Browser e -Filter para comparar o mesmo caso nos dois binários.

O caso público `css/css-conditional/container-queries/multiple-conditions-001.html` e sua referência foram copiados sem modificações do WPT em 26/11/2026. Ambos são autocontidos e o teste declara domínio público. O diretório local está em `tests/wpt/css/css-conditional/container-queries`.

Validação final: os oito pacotes de test.ps1 passaram, totalizando 3.819 testes (197 CSS, 1.155 UI, 2.342 JS, 81 HTML, 6 rede, 20 Brotli, 10 WOFF2 e 8 varfont). O build otimizado passou nos 29 goldens de layout e nas 111 verificações principais de pintura, incluindo as suítes auxiliares. Nenhum golden anterior foi alterado. O WPT selecionado passou de FAIL com 6.489 pixels diferentes para PASS com zero; o reftest local passou de 5% para zero. As comparações usaram o browser.exe anterior da etapa de valores como controle. Este resultado cobre um caso WPT selecionado, não a suíte completa de container queries ou o WPT completo.

Esta etapa cobre consultas de tamanho. style(), estados de scroll, unidades cqw/cqh/cqi/cqb/cqmin/cqmax e APIs CSSContainerRule/matchContainer não foram implementados. A resolução de comprimentos conserva as unidades e funções disponíveis nos avaliadores existentes. Outros efeitos de contenção de layout/estilo, substituições de nomes escapados complexos, elementos substituídos e todos os casos especiais de layout ainda não representam conformidade integral com CSS Containment. O parser limita a profundidade de condições a 64; árvores de dependência que excedam o teto de estabilização também permanecem limitadas.

## Referências

- [CSS Conditional Rules 5: regra @container](https://drafts.csswg.org/css-conditional-5/#container-rule)
- [CSS Conditional Rules 5: consultas de tamanho](https://drafts.csswg.org/css-conditional-5/#size-container)
- [WPT: multiple-conditions-001](https://github.com/web-platform-tests/wpt/blob/master/css/css-conditional/container-queries/multiple-conditions-001.html)
