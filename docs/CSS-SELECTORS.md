# Seletores, validação e consultas — 10/11/2026

A validação compartilhada em src/css/selector_validation.odin verifica listas, combinadores, identificadores, grupos, atributos e pseudo-classes reconhecidas. querySelector(), querySelectorAll(), matches() e closest() lançam SyntaxError para a sintaxe rejeitada. Nas folhas, o parser conserva estruturas recuperadas para diagnóstico, mas marca toda a lista inválida como incapaz de casar. :is() e :where() descartam membros inválidos da lista interna; listas vazias não casam.

O matcher preserva a interseção entre várias chamadas de :is()/:where() e a união dentro de cada chamada. Identificadores e valores de atributo decodificam escapes simples e hexadecimais CSS. Separação de listas e leitura de grupos respeitam aspas e escapes. Atributos aceitam comparação ASCII insensível com i e sensível com s; os operadores compartilham essa lógica.

:scope usa o elemento consultado, ou o primeiro elemento do documento. O escopo se propaga por combinadores e argumentos de :is()/:not(). closest() preserva o escopo do elemento original ao subir. matches() e closest() funcionam em elementos desconectados. Consultas não retornam pseudo-elementos gerados; listas retornam elementos em ordem de documento, sem duplicatas.

selector(...) passa pela mesma validação e pelo parser real; CSS.supports() e @supports conservam o avaliador compartilhado. O scanner de condições agora respeita strings com parênteses, palavras and/or e escapes. An+B rejeita formas como n1, 2 n+1 e n+1 2.

## Verificação

- src/css/selector_validation_test.odin: casos positivos/negativos, operadores e flags, escapes Unicode e grupos com delimitadores entre aspas.
- src/ui/selector_query_test.odin: consultas JS, SyntaxError, escopo, elementos desconectados, grupos múltiplos e aninhados, pseudo-elementos e regras inválidas.
- test.ps1: todos os oito pacotes passaram (3.102 testes).
- Build otimizado instalado em browser.exe, com cópia anterior em _local/selectors/browser-before-install.exe.
- layout-golden.ps1: 20 PASS, 0 FAIL, sem alterar goldens.
- paint-check.ps1: 111 PASS, 0 FAIL, incluindo as suítes auxiliares.

## Limites

Esta etapa não completa Selectors Level 4 nem todas as consultas CSS. Permanecem fora namespaces, An+B of S, todas as combinações de pseudo-classes estruturais repetidas, estados dinâmicos completos e propagação de :scope dentro de :has(). Algumas pseudo-classes conhecidas ainda conservam aproximações históricas. Comentários e nomes de pseudo-classes escapados não têm tokenização completa. As gramáticas de valores não foram ampliadas para todas as propriedades, e não houve expansão de media/container queries nesta etapa. O pacote JS isolado depende dos hooks instalados pela UI para validação e matching completos.

## Referências

- [Selectors Level 4: erros e listas](https://www.w3.org/TR/selectors-4/#invalid)
- [Selectors Level 4: atributos](https://www.w3.org/TR/selectors-4/#attribute-case)
- [DOM: consultas com escopo](https://dom.spec.whatwg.org/#scope-match-a-selectors-string)
