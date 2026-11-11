# Animacoes: tracks e translacao

Implementado em 10/11/2026, depois da rodada documentada em ANIMATION-FORMS.md.

Cada canal (opacity, color, background-color, rotacao, escala e translacao)
procura seus proprios keyframes. Uma mudanca de fundo em 50% nao interrompe mais
a interpolacao de opacity entre 0% e 100%. A curva do inicio desse intervalo
governa o canal, mesmo havendo outros keyframes no meio.

Extremos ausentes em 0%/100% usam o estilo computado base do elemento. Isso
permite animacoes com um unico keyframe, inclusive retorno ao estilo base.
Offsets repetidos usam a ultima declaracao do canal naquele offset.
Valores de opacity em keyframes agora resolvem var() antes da conversao.

Transform em keyframes anima translateX/Y e translate/translate3d no plano,
alem dos canais anteriores de rotacao e escala. Pixels e porcentagens ficam
separados durante a interpolacao; as porcentagens sao resolvidas contra o
border-box atual. Por exemplo, de 20px a 100% sobre uma caixa de 40px resulta
em 30px no meio do intervalo.

A translacao animada substitui a translacao base e desloca a subarvore na
pintura, sem alterar o fluxo. A ultima animacao com efeito em transform vence,
inclusive transform:none. A origem compartilhada com o sistema de empilhamento
mantem os recortes das entradas adiadas no mesmo sistema de coordenadas.
O filtro de opacidade zero nao elimina mais caixas com players, permitindo
animar opacity a partir de uma base transparente.

## Verificacao

- Sete testes novos em src/ui/animation_tracks_test.odin: tracks esparsos,
  endpoints implicitos, um unico stop, unidades mistas, identidade, curva por
  segmento, offsets repetidos, var() e origem do empilhamento.
- tools/animation-tracks-paint-check.ps1: dez assercoes deterministicas, usando
  animacoes pausadas com delay negativo. Inclui substituicao da base, identidade
  da ultima animacao, opacidade base zero, filhos e entrada no viewport.
- Logs e executavel validado em _local/animations.

## Limites

Este trabalho amplia os canais existentes; nao implementa toda a especificacao.
Permanecem oito stops por animacao, sem tracks dinamicos ilimitados.
Os endpoints implicitos usam o estilo base estatico; nao amostram o efeito
dinamico de uma animacao anterior na mesma propriedade. Timing em blocos
duplicados separados no mesmo offset ainda nao tem cascata completa.

Skew e matrizes nao sao interpolados; a composicao de listas de transform,
perspectiva, rotacao 3D interpolada e interacao com propriedades individuais
translate/rotate/scale continuam limitadas pelo modelo escalar existente.
A ordem rotate/translate em listas continua sendo uma limitacao estatica;
esta rodada nao modifica parse_transform nem adiciona decomposicao de matrizes.
Transicoes de translate e eventos transition* nao foram ampliados nesta rodada.
!important, getComputedStyle temporal, animationcancel, Web Animations e
scroll-driven animations continuam pendentes. Os limites anteriores de eventos
e pseudo-elementos em ANIMATION-FORMS.md continuam valendo.

Referencias consultadas:
[CSS Animations 1](https://www.w3.org/TR/css-animations-1/#keyframes) e
[CSS Transforms 1](https://www.w3.org/TR/css-transforms-1/#interpolation-of-transforms).

Resultados da rodada:
- test.ps1: 3.129 testes passaram (951 no pacote UI).
- layout-golden.ps1: 22 PASS, 0 FAIL, nenhum golden regenerado.
- animation-tracks-paint-check.ps1: 10 PASS, 0 FAIL.
- Executavel: _local/animations/final.exe.
- SHA256: 8C6BA02372233FFC2DDD022F7A2CCD6C077C4927C687F89B12F720D979323ABA.
- Logs: _local/animations/tests-final.log, golden-final.log e tracks-final.log.

- paint-check.ps1: 111 PASS, 0 FAIL; writing-paint-check.ps1: 5 PASS, 0 FAIL.
  Total de assercoes principais de pixels: 126, incluindo as dez novas.
- O browser.exe anterior falha no primeiro teste novo: pixel (70,20) branco
  em vez do verde esperado na posicao transladada. Log control.log.
- final.exe instalado em browser.exe; anterior preservado em
  _local/animations/browser-before-install.exe.
