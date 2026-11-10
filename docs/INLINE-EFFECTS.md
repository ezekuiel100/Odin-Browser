# Efeitos e posicionamento inline

A reprodução da quebra em animate.style identificou que spans comuns eram
achatados em palavras sem preservar opacity, visibility e position. O parser
produzia os estilos corretos; a perda ocorria na construção das caixas.

## Correções

- Palavras preservam visibility sem remover o espaço ocupado na linha. Um
  descendente pode voltar a visibility:visible sem reexibir o fundo do ancestral.
  Marcadores, rótulos e conteúdo gerado também conservam a visibilidade.
- Escopos de opacidade permanecem ligados aos fragmentos, inclusive depois de
  quebra de palavra. O compositing ocorre por grupo e suporta grupos aninhados,
  átomos inline e filhos absolutos sobrepostos. O span continua quebrando linha.
- Absolute/fixed deixam o fluxo textual inclusive quando aninhados em spans.
  Caixas anônimas que contêm somente esses descendentes são preservadas.
- A passada de absolutos visita inline-blocks/botões em suas coordenadas locais.
  A pintura restaura essa origem também para fixed, mantendo a referência ao viewport.
- Spans relativos vazios conservam uma âncora para os filhos absolutos, sem
  converter spans com texto em blocos indivisíveis.
- Wrappers de bloco sem conteúdo em fluxo conservam suas margens e a posição
  estática dos filhos absolutos, mesmo quando aninhados em um inline.
- As consultas de estilos no passeio inline usam ponteiros para evitar copiar
  repetidamente Computed na pilha durante a recursão.

## Verificação

- src/ui/inline_effects_test.odin: herança/reativação de visibility, opacidade
  aninhada, quebra de linha com fonte sintética, absolutos e fixed dentro de botões.
- tests/paint/inline-effects.html e tools/check-inline-effects.ps1: dez asserções
  de pixels, incluindo os defeitos reproduzidos e controles. Integrado em paint-check.ps1.
- A reprodução original fica em _local/scratch/animate-tooltip-probe.html e a
  investigação inicial em _local/reports/animate-investigation.md.

Resultados em 10/11/2026:

- UI: 862/862; CSS: 175/175.
- Pintura: 108/108, incluindo as dez asserções de inline-effects.
- Geometria: 19/19 goldens, sem atualizar referências.
- WPT css-position: antes 8 PASS / 4 FAIL; depois 9 PASS / 3 FAIL / 0 ERROR.
  O teste position-absolute-in-inline-margin-top passou; não há novos nomes
  falhando. Permanecem position-absolute-center-001, position-absolute-center-002
  e position-absolute-fit-content.
- O gate geral de pintura/geometria rodou no build de desenvolvimento com a
  mesma implementação; o build otimizado final passou novamente nos dez casos
  novos e nos doze WPT de posicionamento. O WPT completo não foi executado.
- browser.exe foi atualizado com o build otimizado, SHA256
  49A1DA2C38EDAC4679D6AA8786EEC891513D827FD3668D394DF44E947FEE9290.
  Backup: _local/builds/browser_before_inline_fix_20261110_072743.exe.

## Limites

Não foi possível baixar o style.css efetivo do site neste ambiente. A correção
foi validada em reproduções locais; a largura da coluna lateral da página real
continua sem diagnóstico confirmado. Esta alteração não implementa toda a
fragmentação de caixas inline, containing blocks formados por inlines relativos,
nem timelines de animação/transição específicas desses novos escopos de pintura.

## Melhorias posteriores: controles e conteúdo gerado

- O passeio inline usa o peso e o estilo de fonte calculados, inclusive os valores
  normal que desligam negrito e itálico herdados. As tags strong/b não forçam
  novamente negrito depois da cascata.
- ::before/::after herdam visibility, peso, família de webfont e atributos de texto.
  Um pseudo pode reativar sua própria visibility explicitamente.
- Pseudos de inlines achatados conservam caixas quando possuem dimensões,
  posicionamento ou efeitos gráficos. Pseudos textuais usam sua própria fonte e cor.
- Regressões: src/ui/inline_controls_test.odin e tests/paint/inline-controls.html;
  tools/check-inline-controls.ps1 integrado no gate de pintura.

Validação: UI 864/864; pintura 109/109 (inclui o grupo novo de sete casos);
layout-golden 19/19, sem atualizar referências. O executável anterior falha em
3/7 casos novos; o novo passa em 7/7. O build otimizado passou novamente nos
sete casos novos e nos dez de inline-effects; a imagem foi inspecionada.
Não houve alterações posteriores ao código usado no gate completo.

Executável atual: browser.exe, SHA256
B2162147DEE5E873787E0F2753DCF452CFEAC7E0AA9AB53A9BFA6B884F5B24FA.
Backup desta rodada: _local/builds/browser_before_controls_20261110.exe.

O CSS efetivo do site segue indisponível neste ambiente. Esses são defeitos
confirmados do motor e corrigidos em reproduções locais; não demonstram que
todos os botões de copiar ou o espaçamento da página real estejam resolvidos.
A seleção de face da webfont e a largura da coluna real continuam sem causa
confirmada; esta rodada não altera o algoritmo de matching de fontes.
