# Validação de valores e consultas de suporte

O parser consulta a gramática compartilhada em src/ui/css_values.odin antes de armazenar cada declaração. Um valor inválido não entra na cascata, mesmo quando aparece em outra regra ou com !important. No mesmo bloco, uma declaração normal também não substitui uma anterior marcada !important.

CSS.supports() e @supports usam a mesma validação e, com a UI carregada, o mesmo avaliador de condições. Sintaxe malformada resulta em false; funções desconhecidas de general-enclosed também resultam em false. and e or exigem agrupamento para serem combinados, e not só pode preceder uma condição simples. O fallback histórico de declaração sem parênteses do CSS.supports() foi preservado.

## Gramáticas cobertas

- Dimensões, flex-basis, offsets, margin/inset e padding: unidades, cardinalidade, auto/none conforme a propriedade, limites negativos e comprimentos sem unidade.
- gap e aliases: um ou dois valores, normal, comprimentos e porcentagens.
- Números de flex-grow/shrink, opacity (incluindo porcentagem), inteiros de order/z-index/column-count e aspect-ratio.
- Cores pelos parsers de cor existentes; border-width/style/color e seus longhands.
- Palavras-chave de display, position, overflow, box-sizing, flex-direction/wrap, visibility, float/clear, isolation, object-fit, border-collapse, table-layout, font-style/kerning, direction e scroll-behavior.
- Balanceamento de grupos e strings, com tratamento de escapes.

Referências var() malformadas são rejeitadas no parse. Referências sintaticamente válidas e attr() aguardam substituição. A cascata substitui var() antes de separar pares lógicos e componentes de shorthand; um resultado inválido conserva sua prioridade como unset, sem reativar um candidato anterior. Os setters style.prop e style.setProperty preservam a declaração anterior quando recebem valores inválidos das gramáticas cobertas. Remover com string vazia continua funcionando.

A detecção também rejeita recursos reconhecidos mas inertes: touch-action, hyphens, font-feature/variation-settings, scroll-snap, perspective e transform-style. writing-mode anuncia horizontal-tb, vertical-rl e vertical-lr; a cobertura e os limites estão em [WRITING-MODES.md](WRITING-MODES.md).

## Validação adicional por famílias

`src/ui/css_value_families.odin` amplia a mesma entrada compartilhada, antes do fallback:

- Bordas, lados, outline e column-rule: até um componente de largura, estilo e cor, em qualquer ordem; duplicatas e componentes desconhecidos invalidam o shorthand inteiro.
- border-radius e raios por canto: cardinalidade, valores não negativos e separação horizontal/vertical por barra apenas no shorthand; border-spacing e outline-offset distinguem comprimentos de porcentagens.
- flex, flex-flow, alinhamento e place-*: ordem e quantidade de componentes, palavras compostas baseline/safe/unsafe e restrições de cada longhand.
- columns/column-width, font-size, vertical-align, medidas de scroll-margin/padding e decoração de texto: palavras-chave, cardinalidade e restrições de sinal/unidade.
- Longhands de duração, atraso, iterações, direção, preenchimento, execução e timing de animações/transições: listas sem itens vazios, segundos/milissegundos, limites numéricos, cubic-bezier e steps.
- Palavras-chave de caption-side, empty-cells, resize, user-select, pointer-events, content-visibility e quebras de página/coluna.

Os testes em `src/ui/css_value_families_test.odin` cobrem consultas CSS/JS, descarte de duplicatas inválidas com `!important`, preservação pelo CSSOM e fallback na cascata entre regras. As famílias adicionais e a resolução de variáveis estão descritas abaixo. Não se deve interpretar `checked = false` como gramática validada; famílias não enumeradas conservam a política de fallback anterior.

## Valores e variáveis — 25/11/2026

A entrada compartilhada agora inclui:

- `box-shadow` e `text-shadow`: quantidade e sequência de comprimentos, blur não negativo, cor única, inset apenas em box-shadow e listas sem camadas vazias.
- `transform`, `translate`, `rotate` e `scale`: funções conhecidas, aridade, números, ângulos e restrição de porcentagens no eixo Z. Rotate conserva as duas ordens de ângulo/eixo já aceitas pelo motor.
- `animation` e `transition`: distribuição dos componentes, duração inicial não negativa, no máximo dois tempos, nomes e listas; os longhands de nome/propriedade usam a mesma validação.
- `background` e seus longhands: imagens, camadas, cor apenas na última camada, posição/tamanho separados por barra e limites de repeat, attachment e caixas. URLs e strings não são interpretadas como unidades ou funções CSS.
- `font` e `font-family`: componentes opcionais sem duplicação, tamanho obrigatório, line-height opcional, famílias citadas e listas sem itens vazios.
- Grid: linhas/áreas de posicionamento, tracks, minmax, fit-content, repeat, fluxo, grid-template e áreas nomeadas retangulares. Repetição automática exige tamanhos fixos.
- Dimensões e espaçamentos lógicos, aliases de fornecedor e tipos de expressões matemáticas: soma de número com comprimento, multiplicação de dois comprimentos e divisão por comprimento são rejeitadas. `line-height:calc(1.75 / 1.125)` continua válido como número.

As regras ficam em `css_value_effects.odin`, `css_value_font.odin`, `css_value_grid.odin` e `css_value_math.odin`. Parser, CSS.supports(), @supports e setters CSSOM passam pela mesma entrada.

### Resolução de var()

`src/css/variables.odin` centraliza sintaxe e substituição por tokens. Strings, escapes, vírgulas internas e identificadores como myvar() permanecem opacos. O nome da função ignora caixa; nomes de custom properties conservam caixa. O primeiro argumento exige um nome -- válido; fallbacks podem conter outras referências e podem ser vazios.

Cada ambiente local calcula o grafo de dependências, incluindo referências em fallbacks não utilizados. Todos os membros de um ciclo recebem um marcador garantido-inválido, distinto do valor vazio válido. Uma propriedade dependente pode usar seu próprio fallback; ausência sem fallback invalida o valor inteiro. O ambiente herdado já contém valores computados: redefinir uma variável no filho não altera referências resolvidas no pai nem recupera um valor inválido herdado.

As substituições preservam limites de tokens: `--n:12; width:var(--n)px` não pode criar um token 12px. Valores computados são limitados a 1 MiB e a profundidade de resolução a 256, evitando expansão exponencial e estouro da pilha. O memo por ambiente herdado e declarações locais permanece ativo; ambientes compartilhados são imutáveis. Os defaults de @property inherits:false entram antes da resolução das dependências locais.

Resolver antes da expansão também elimina a degradação anterior das bordas com var() na competição por átomo. Invalidar um shorthand preserva a prioridade sobre longhands inferiores; flex-flow propaga esse reset aos seus dois componentes. Consultas aceitam uma referência var() bem formada mesmo quando o fallback contém uma unidade ainda não implementada: a decisão depende da substituição efetivamente utilizada.

Esta etapa amplia as gramáticas implementadas, sem afirmar conformidade integral com todas as gramáticas CSS. Permanecem os parsers legados nas famílias não enumeradas, incluindo filter, border-image e os shorthands grid/mask; cálculos de domínios adicionais, recursos novos de animação e sintaxe completa de subgrid continuam limitados pelos avaliadores existentes. @property ainda não valida integralmente o descritor syntax nem implementa todo o registro tipado; attr()/env(), animation-taint e aplicação geral de CSS-wide contra defaults UA não foram completados nesta etapa. Também permanecem os limites de componentes omitidos, rollback entre shorthand/longhand e serialização CSSOM descritos abaixo.

Regressões: quatro testes em `src/css/variables_test.odin`, seis em `src/ui/css_variables_test.odin`, três em `src/ui/css_value_effects_test.odin`, um em `src/ui/css_value_grid_test.odin` e `tests/layout/variables-values.html`.

Validação: os oito pacotes de `test.ps1` passaram (3.805 testes: 194 CSS, 1.144 UI, 2.342 JS, 81 HTML, 6 rede, 20 Brotli, 10 WOFF2 e 8 varfont). Os quatro testes novos do pacote CSS passaram com `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`. O build otimizado passou nos 28 goldens de layout e nas 111 verificações principais de pintura, incluindo as suítes auxiliares. A fixture nova demonstra diferenças contra o controle c09ec4f em herança, ciclos, invalidação integral, pares lógicos e fallback de cálculo. WPT css-variables comparado por nome: controle 10 PASS / 2 FAIL / 0 ERROR, nova versão 12 PASS / 0 FAIL / 0 ERROR. As duas transições são variable-declaration-11 e variable-declaration-12, ambas com diff de 952 para zero pixels; nenhuma regressão. O WPT completo não foi repetido.

## Limites

Comentários e escapes de nomes agora passam pela mesma normalização em declarações, consultas e validação CSSOM. Strings preservam comentários literais e aspas escapadas; comentários entre números e unidades não podem formar um token novo. Escapes de pontuação permanecem escapados para não virarem delimitadores. Isso ainda não substitui um tokenizer CSS completo.

A cobertura adicional inclui font-weight, line-height, letter-spacing, word-spacing, text-overflow e backface-visibility. CSSOM usa o parser compartilhado ao ler declarações e atribuir cssText; setProperty valida valores e prioridade, getPropertyPriority expõe important e removeProperty retorna o valor removido. A serialização mantém a ordem das declarações válidas vencedoras, inclusive depois de alterações por setters.

A cobertura ainda não é uma implementação completa das gramáticas CSS. As famílias não enumeradas conservam seus parsers e o juiz de efeito legado para duplicatas; valores desconhecidos nessas famílias ainda podem gerar falsos positivos. Funções matemáticas e cores delegam aos parsers existentes e conservam suas aproximações. CSSStyleDeclaration ainda não representa todas as expansões e serializações de shorthand da especificação. A etapa de validação e consultas está descrita em [CSS-SELECTORS.md](CSS-SELECTORS.md). O pacote JS isolado, sem UI, mantém seu fallback sintático.

## Ordem de declarações e nesting — 25/11/2026

`parse_decls` pode devolver as posições das declarações válidas vencedoras junto com o mapa de valores. Duplicatas rejeitadas e declarações normais que perdem para uma anterior `!important` não alteram a posição do vencedor. As strings desse índice pertencem ao mapa; a regra libera apenas a lista de posições, além do mapa e suas strings.

A cascata compara a posição da regra e depois a posição da declaração. Aliases, propriedades lógicas e componentes de borda mantêm essa origem ao competir com propriedades físicas e shorthands. A competição também abrange as famílias de shorthand existentes, incluindo font, flex, columns, place-*, fundos, animações e transições. `all` descarta declarações de prioridade inferior antes da expansão, respeitando suas exclusões.

Declarações intercaladas com regras ou condições aninhadas geram trechos separados, na ordem do fonte e com os mesmos seletores/condições/camadas do pai. Trechos diretos mantêm a especificidade individual dos seletores-pai. Referências estáticas explícitas ou implícitas ao pai nas regras aninhadas agrupam listas e seletores complexos com a semântica de `:is()`. Pais com estados dinâmicos mantêm a expansão e o roteamento anteriores: a especificidade máxima de listas e o agrupamento de pais complexos nesses casos continuam limitados pelo matching funcional de estados. Ampersands em strings ou identificadores escapados permanecem literais.

Esta etapa não completa a expansão de todos os shorthands: permanecem os limites anteriores de componentes omitidos, herança de palavras-chave CSS-wide e rollback entre shorthand/longhand com `revert-layer`. As consultas de container e os estados dinâmicos continuam com a cobertura anterior.

Regressões: `src/css/declaration_order_test.odin`, `src/ui/declaration_order_test.odin`, `src/js/js_declaration_order_test.odin` e `tests/layout/cascade-declaration-order.html`.

Validação: `test.ps1` passou nos oito pacotes (3.791 testes: 190 CSS, 1.134 UI, 2.342 JS, 81 HTML, 6 rede, 20 Brotli, 10 WOFF2 e 8 varfont). Os quatro testes novos do parser também passaram com `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`. O build otimizado passou nos 27 goldens de layout e nas 111 verificações principais de pintura, incluindo as suítes auxiliares do portão. WPT selecionado `css-cascade`, comparado por nome com o `browser.exe` anterior: 6 PASS / 6 FAIL / 0 ERROR nos dois executáveis, sem transições. O diff de `all-prop-001` caiu de 6.655 para 981 pixels, ainda acima do orçamento de 480. O WPT completo não foi repetido.

## Container queries

A revisão de 26/11/2026 está em [CONTAINER-QUERIES.md](CONTAINER-QUERIES.md): seleção por tamanho medido, eixos, condições booleanas/listas, consultas aninhadas e invalidação.

## Referências e testes

- [CSS Conditional Rules: definição de suporte](https://www.w3.org/TR/css-conditional-3/#support-definition)
- [CSS Syntax: declarações](https://www.w3.org/TR/css-syntax-3/#consume-declaration)
- [CSS Variables: ciclos e substituição](https://www.w3.org/TR/css-variables-1/#cycles)
- [CSS Nesting: declarações intercaladas](https://www.w3.org/TR/css-nesting-1/#nested-declarations-rule)
- src/ui/css_values_test.odin: tabelas positivas/negativas, cascata, variáveis, CSSOM e concordância das consultas.
- Suítes completas de UI/CSS/JS e layout-golden.ps1.
