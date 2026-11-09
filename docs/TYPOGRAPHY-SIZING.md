# Tipografia e tamanhos intrínsecos

Implementação de 2026-11-09.

## Alterações

- `font-kerning: auto | normal | none` participa da herança, do reset por
  `font:`, do CSSOM, da medição, do corte de palavras e da pintura. `auto` usa
  os pares disponíveis em todos os tamanhos.
- O leitor GPOS interpreta PairPos 1/2 e ExtensionPos 9, inclusive coverage e
  classes por faixas. Coleta apenas a feature `kern`, deduplicando lookups.
  Isso permite ler o kerning da Segoe UI, que o stb não aplicava.
- A pintura preserva as posições fracionárias relativas dos caracteres.
  O espaço usado na largura intrínseca agora vem da mesma fonte usada no fluxo.
  Reconstruir o atlas invalida os caches de métricas.
- `width:min-content` usa contribuições mínimas em vez de max-content.
  `width:fit-content` limita max-content ao disponível, com piso em min-content.
  Grid e flex de coluna respeitam essas larguras; o grid mede a altura após
  resolver a largura do item, evitando sobreposição entre linhas.
- Absolutos respeitam margens fixas e uma única margem `auto`. O cálculo de
  shrink-to-fit considera os insets e preserva o conteúdo indivisível.

## Verificação

`typography_sizing_test.odin` exercita estilos, fontes reais no atlas, medidas,
grid/flex e posicionamento. `typography_gpos_test.odin` cobre pares, classes,
extensões, features não aplicáveis e truncamento de dados.

`paint-check.ps1` compara a largura da tinta com a largura do fundo calculada
por `max-content`, com kerning ligado/desligado e com `letter-spacing`.
O par comprova que medida e pintura aplicam o mesmo ajuste.

Página para inspeção: [typography-sizing.html](../tests/manual/typography-sizing.html).

Resultados desta rodada:

| Verificação | Resultado |
|---|---|
| Unidade CSS | 175/175 |
| Unidade UI, incluindo novas regressões | 789/789 |
| Golden de layout | 17/17, sem atualizar referências |
| Pintura | 77/77, incluindo quatro novas asserções de kerning |
| WPT selecionado: grid, sizing e position | Mesmas falhas nomeadas antes/depois, sem erros |

A suíte geral também foi executada: HTML, rede, Brotli e WOFF2 passaram, mas
o pacote JavaScript apresentou 63 falhas, inclusive em execução com uma thread.
Esse pacote e suas dependências não foram alterados por esta mudança. A rodada
WPT completa foi interrompida; somente a comparação selecionada foi concluída.

## Limites

O suporte é de kerning horizontal por XAdvance, sem shaping completo de scripts,
ligaturas, variações de fonte ou seleção de linguagem em GPOS. As propriedades
`font-feature-settings`, `font-variation-settings` e `font-optical-sizing`
continuam inertes. `fit-content()` como função de largura não foi acrescentada.
Fragmentação de múltiplas colunas e contextos de empilhamento ainda têm as
aproximações anteriores.

Referências: [CSS Sizing 3](https://www.w3.org/TR/css-sizing-3/),
[CSS Fonts 4](https://www.w3.org/TR/css-fonts-4/#font-kerning-prop),
[OpenType GPOS](https://learn.microsoft.com/en-us/typography/opentype/spec/gpos).
