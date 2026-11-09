# Transforms 3D achatados

O motor não tem contexto de renderização 3D. Até aqui isso significava que cada
função 3D de `transform` era descartada sozinha dentro da lista:
`translate3d(-50%,-50%,0)` perdia o deslocamento, `translateZ(0)` nem marcava o
elemento como transformado, e o verso de um flip-card era pintado por cima da
frente.

## Modelo

Sem `perspective` a projeção é **ortográfica**: o que chega à tela é o bloco 2×2
superior-esquerdo do produto das matrizes 3D. O `parse_transform` acumula uma
matriz 3×3 na ordem da lista e projeta **no fim** — projetar função a função
erra (`rotateX(90deg) rotateX(-90deg)` é a identidade, mas o produto das duas
projeções é uma escala por zero).

| Função | Efeito na tela |
|---|---|
| `translate3d(x,y,z)` | `translate(x,y)` |
| `translateZ(z)`, `perspective(d)` | nenhum, mas o elemento conta como transformado (stacking context, containing block) |
| `scale3d(x,y,z)`, `scaleZ(z)` | `scale(x,y)`; `z` negativo vira a face |
| `rotateX(θ)`, `rotateY(θ)` | encolhe o eixo oposto por `cos θ` |
| `rotate3d(x,y,z,θ)` | Rodrigues; eixo puro cai no caso acima |
| `matrix3d(16)` | bloco 3×3 + translação da 4ª coluna, dividido por `m44` |

A propriedade individual `rotate` aceita as mesmas formas com eixo
(`rotate: y 180deg`, `rotate: 0 1 0 180deg`, eixo antes ou depois do ângulo).

Um giro só (`rotateY(180deg)`) continua nos campos escalares, que são os que a
transition anima. Quando a lista não cabe neles — `rotateY(180deg) rotate(30deg)`,
dois giros 3D seguidos — a pintura passa a usar a matriz. Essa conferência só
roda para listas com função 3D; as puramente 2D não mudaram.

## O lado

`rotateY(180deg)` e `scaleX(-1)` dão o mesmo 2×2; só o primeiro mostra o verso.
Esse bit (`xf_back`) sai do sinal de `cofator(3,3) / det` da matriz 3×3 — a
componente z da normal transformada, o mesmo critério do Chromium — e é o que
`backface-visibility: hidden` lê:

- a caixa com a face de trás voltada para o observador não é pintada nem recebe
  clique;
- com `transform-style: preserve-3d` no pai, o lado do pai compõe com o do filho
  **direto** (o cartão que gira no pai esconde a frente e mostra o verso
  desespelhado); sem ele o conteúdo é achatado e cada filho responde só por si;
- no `:hover` com transition, o lado troca quando a escala efetiva cruza o zero.

## Defeito vizinho consertado

O `transform` do `:hover` **acumulava** sobre o da base em vez de substituí-lo
(o estilo de hover nasce de uma cópia já transformada). `.x{transform:rotate(45deg)}
.x:hover{transform:rotate(45deg) scale(1.2)}` girava 90° no hover, e
`:hover{transform:none}` não desfazia nada. Agora o grupo
`transform`/`translate`/`rotate`/`scale` é reaplicado inteiro: do `:hover` o que
ele declarou, da base o que ele não tocou.

## Testes

- `src/ui/style_xform3d_test.odin`: 11 testes. Cada grafia 3D é pareada com o
  controle 2D que tem de pintar igual; o lado tem os pares giro × espelho.
- `tests/paint/transform-3d.html`, executada pelo `paint-check.ps1` duas vezes
  (mouse sobre o cartão de hover e fora dele): 15 asserções de pixel.

## Validação

Medido em 2026-11-09, binário novo × binário de controle buildado do commit
anterior (`4183834`).

- Unidade: `src/ui` 850/850, `src/css` 175/175. Quatro sabotagens (sem o cálculo
  do lado, sem a conferência campos × matriz, hover voltando a acumular, `in_p3d`
  não lido do pai) deixam os testes novos vermelhos.
- Pintura: 102/102 no novo; **90/102 no controle** — as 12 falhas são exatamente
  as asserções 3D (as 3 que passam nos dois são os controles 2D e a identidade).
- Golden de layout: 19/19 nos dois.
- WPT: 351 PASS / 130 FAIL / 0 ERRO nos dois, **diff nomeado vazio**. Nenhum
  conserto: os reftests de 3D da suíte dependem de perspectiva ou de contexto 3D.

⚠️ O `wpt-baseline-fails.txt` versionado (128 falhas) já não descreve o commit
anterior: `css-tables/absolute-tables-008/009/011` falham e
`css-borders/border-radius-greater-than-width` passa, nos dois binários. É deriva
anterior a esta mudança.

## Limites

- **Sem perspectiva.** `perspective()` e as props `perspective`/`perspective-origin`
  não encurtam nada; `@supports (perspective: …)` e
  `@supports (transform-style: preserve-3d)` continuam falsos, de propósito —
  quem testa suporte cai no fallback do autor.
- **Z depois de giro some.** `rotateY(90deg) translateZ(100px)` deveria deslocar
  100px na tela (carrossel, cubo). A translação deste motor não passa pela parte
  linear, nem em 2D (`rotate(90deg) translateX(100px)` anda em X).
- **Sem ordenação em profundidade.** Faces de um cubo são pintadas em ordem de
  documento.
- **`preserve-3d` só compõe o lado**, e só entre pai e filho direto, por paridade:
  dois giros de 100° em níveis diferentes contam como frente.
- O giro animado é uma escala linear, não `cos θ(t)`; e um giro vindo de
  `@keyframes` não troca o lado no meio do caminho.
- Elemento cuja pintura usa a matriz (skew, `matrix()`, listas que não cabem
  nos campos escalares) continua sem rotação/escala de `:hover`: a matriz é
  estática.

Referências: [CSS Transforms 2](https://www.w3.org/TR/css-transforms-2/).
