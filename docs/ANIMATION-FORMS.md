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

Limites: apenas a primeira animacao da lista e aplicada. Os canais continuam
restritos a opacidade, cores, rotacao e escala; nao ha animacao de layout.
Duracao zero ainda nao produz efeitos de preenchimento. O relogio pertence a
caixa de layout: reconstruir a caixa reinicia a animacao. Nao ha timeline Web
Animations nem eventos animationstart/iteration/end nesta implementacao.
