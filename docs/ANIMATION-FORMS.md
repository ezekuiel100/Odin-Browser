# Animacoes e formularios

As animacoes usam o mesmo avaliador de curvas das transicoes: ease por padrao,
linear, cubic-bezier e steps. Funcoes com virgulas permanecem intactas no
shorthand. Uma curva declarada dentro do keyframe governa o intervalo seguinte.

Normal, reverse, alternate e alternate-reverse resolvem a direcao de cada ciclo.
Fill-mode controla o periodo anterior e posterior a animacao; sem fill, o estilo
original volta a valer. Iteracoes fracionarias conservam a posicao final correta.
Zero iteracoes deixa de ser interpretado como infinito. Nomes de keyframes
preservam maiusculas e minusculas. Play-state paused congela o relogio da caixa.

Campos input e textarea distinguem readonly de disabled. Readonly conserva a
cor do texto e permite foco e selecao, impedindo edicao. Disabled desabilita o
widget, incluindo foco e interacao. Valores sao preservados em ambos os casos.

Testes: animation_forms_test.odin exercita computacao, progresso e estados dos
controles; tests/paint/animation-forms.html testa pixels de animacoes pausadas
com delay negativo, sem depender do tempo real entre frames.

Listas de animation sao aplicadas integralmente. A lista de animation-name
determina a quantidade; os demais longhands repetem ciclicamente quando mais
curtos. Um item none ocupa sua posicao sem aplicar efeitos. Para a mesma
propriedade, a ultima animacao com efeito no instante amostrado prevalece.
Transform identidade tambem substitui rotacao/escala de uma animacao anterior.

Cada Box possui uma lista de players com copia dos keyframes e do nome.
O relogio avanca numa travessia anterior a pintura, mesmo em caixas fora do
viewport; nao depende do culling. Paused congela o tempo. Ao reestilizar, o
layout anterior permanece vivo ate a transferencia dos players para o novo:
mesmo no DOM e mesmo nome preservam o tempo, casando nomes duplicados da direita
para a esquerda. Remover animation-name ou display:none descarta o player; ao
reaparecer ele comeca de novo. Novos valores de duracao/delay/direcao/curva sao
amostrados com o tempo preservado.

animationstart, animationiteration e animationend sobem pelo DOM com
animationName, elapsedTime (segundos sem incluir delay) e pseudoElement vazio.
Sao eventos nao cancelaveis e herdam Event.prototype. Start com delay negativo
reporta o tempo saltado, limitado pela duracao ativa; nao inventa eventos de
iteracoes anteriores ao primeiro sample. O fim nao emite iteration adicional.
Duracao ou contagem zero produzem start/end e respeitam fill-mode, sem divisao
por zero. Os handlers rodam fora da pintura; mutacoes passam pelo fingerprint
e pelo rebuild normal. No headless, a entrega ocorre no inicio do frame seguinte.

Testes adicionais: src/ui/animation_runtime_test.odin cobre listas, longhands,
pausa, limites de eventos, delay negativo, duracao/contagem zero, nomes
duplicados e restyle com handler DOM. tests/paint/animation-lists.html verifica
combinacao de canais, precedencia, identidade e eventos que alteram o CSS.

Verificacao em 10/11/2026:
- src/ui: 858/858; src/css: 175/175; html 81, net 4, brotli 20, woff2 10 passam.
- src/js: 63 falhas em 1873, tambem no HEAD anterior; diff nomeado vazio
  entre os dois, ambos executados com uma thread.
- paint-check: 107/107 no novo. Na comparacao inicial, o controle anterior
  deu 102/106; suas quatro falhas eram as assercoes de animation-lists.
  O gate adicional de pausa por clique reproduziu a perda de progresso no
  --render anterior ao conserto (cor saltava de rosa para verde).
- layout-golden: 19/19.
- WPT css-animations: 4 PASS / 8 FAIL / 0 ERROR nos dois; diff nomeado vazio.
  Nao foi repetido o WPT completo nem medido site real.
- Sabotagens separadas no parser de listas, na restauracao e no ciclo de eventos
  fazem os testes correspondentes falharem.

Atualizacao posterior: [ANIMATION-TRACKS.md](ANIMATION-TRACKS.md) descreve
translacao animada, tracks independentes e endpoints implicitos implementados
depois dos resultados historicos acima.

Limites atuais: nao ha animacao de layout nem interpolacao completa de matrizes
e giros 3D. Continuam os oito stops por animacao. !important ainda nao suprime
o canal animado. Eventos em pseudo-elementos, animationcancel, construtor
AnimationEvent, timeline Web Animations, scroll-driven animations e mudancas de
fase por alteracao de delay/duracao depois de iniciado/finalizado nao estao
completos. O getComputedStyle continua expondo o estilo base, sem overlay temporal.

Referencia: [CSS Animations Level 1](https://www.w3.org/TR/css-animations-1/),
especialmente a ordem das listas, o casamento de nomes e os eventos.

Demonstracao manual: tests/paint/animation-live.html inicia cinco animacoes em
quatro quadrados sem rede, mostra eventos e permite pausar/continuar ou alterar
o DOM. Ela tambem cobre o rebuild do clique no headless, agora com transferencia
do relogio como no restyle interativo.
