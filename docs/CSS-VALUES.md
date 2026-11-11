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

Declarações com var()/attr() aguardam substituição. Após resolver var(), um shorthand inválido é descartado inteiro, sem reativar um candidato anterior. Os setters style.prop e style.setProperty preservam a declaração anterior quando recebem valores inválidos das gramáticas cobertas. Remover com string vazia continua funcionando.

A detecção também rejeita recursos reconhecidos mas inertes: touch-action, hyphens, font-feature/variation-settings, scroll-snap, perspective e transform-style. writing-mode anuncia horizontal-tb, vertical-rl e vertical-lr; a cobertura e os limites estão em [WRITING-MODES.md](WRITING-MODES.md).

## Limites

Comentários e escapes de nomes agora passam pela mesma normalização em declarações, consultas e validação CSSOM. Strings preservam comentários literais e aspas escapadas; comentários entre números e unidades não podem formar um token novo. Escapes de pontuação permanecem escapados para não virarem delimitadores. Isso ainda não substitui um tokenizer CSS completo.

A cobertura adicional inclui font-weight, line-height, letter-spacing, word-spacing, text-overflow e backface-visibility. CSSOM usa o parser compartilhado ao ler declarações e atribuir cssText; setProperty valida valores e prioridade, getPropertyPriority expõe important e removeProperty retorna o valor removido. A serialização de cssText ainda não preserva a ordem original das declarações.

A cobertura ainda não é uma implementação completa das gramáticas CSS. As famílias não enumeradas conservam seus parsers e o juiz de efeito legado para duplicatas; valores desconhecidos nessas famílias ainda podem gerar falsos positivos. Funções matemáticas e cores delegam aos parsers existentes e conservam suas aproximações. CSSStyleDeclaration ainda tem limitações de serialização e ordem; a tokenização de comentários e escapes permanece parcial, conforme descrito acima. A etapa de validação e consultas está descrita em [CSS-SELECTORS.md](CSS-SELECTORS.md). O pacote JS isolado, sem UI, mantém seu fallback sintático.

## Referências e testes

- [CSS Conditional Rules: definição de suporte](https://www.w3.org/TR/css-conditional-3/#support-definition)
- [CSS Syntax: declarações](https://www.w3.org/TR/css-syntax-3/#consume-declaration)
- src/ui/css_values_test.odin: tabelas positivas/negativas, cascata, variáveis, CSSOM e concordância das consultas.
- Suítes completas de UI/CSS/JS e layout-golden.ps1.
