# Testes e portões

Um motor de navegador quebra em silêncio: a caixa continua sendo desenhada, só
que 40 px à esquerda. Por isso aqui há vários portões, cada um cego para o que o
outro enxerga.

| Portão | Comando | O que pega | O que **não** pega |
|---|---|---|---|
| Unidade | `.\test.ps1` | Lógica de 7 pacotes. É o gate oficial. | Qualquer coisa que só apareça na página inteira. |
| Reftests do WPT | `.\wpt-reftest.ps1` | Conformidade de layout/CSS contra referências da spec. | Métrica de texto — ele compara o nosso render com a **nossa própria** referência, e o erro cancela dos dois lados. |
| Golden de layout | `.\layout-golden.ps1` | Regressão de geometria, com precisão de nome e número. | Caixa no lugar certo e **não pintada**. |
| Pintura | `.\paint-check.ps1` | Exatamente o ponto cego acima: afirma regiões visíveis/esmaecidas/recortadas. | Aparência fina; nada aqui depende de fonte ou antialiasing. |
| Geometria incremental | `.\geometry-check.ps1` | Geometria e PNGs de 16 estados com fontes reais contra reconstruções completas independentes; exige hits e mudanças visuais. | Conformidade integral de CSS ou desempenho de sites reais. |
| Test262 | `.\test262.ps1` | Conformidade da linguagem JavaScript. | Tudo que é DOM/host. |
| html5lib | `.\html5lib-test.ps1`, `.\html5lib-tokenizer.ps1` | Conformidade do parser de HTML. | — |
| Oráculo visual | `.\oracle-diff.ps1` | Distância até o **Chrome** em sites reais. É o único que enxerga métrica de fonte. | Nada é automático: o número é ruidoso, ver abaixo. |

## `wpt-baseline-fails.txt` é a autoridade, não o placar

O arquivo lista, **por nome**, os testes do WPT que se sabe falharem hoje. Ele é
versionado de propósito: `353/128` é um placar agregado, e placar agregado **não
prova ausência de regressão** — dá para consertar dois e quebrar dois e o número
não se mexe. O que vale é o diff nomeado contra essa lista.

⚠️ O arquivo é UTF-8 **com BOM** e CRLF. Não o "normalize": já aconteceu de um
passo intermediário reencodar um dos lados e o diff acusar 132 consertos que eram
só ausência de medição.

## A/B entre binários

Todos os portões aceitam `-Browser <exe>`:

```powershell
.\wpt-reftest.ps1  -Browser .\browser_antes.exe
.\layout-golden.ps1 -Browser .\browser_antes.exe
.\paint-check.ps1  -Browser .\browser_antes.exe
```

Rode a mesma suíte nos dois binários e diffe as **duas listas nomeadas entre
si**. Comparar contra o baseline gravado só atribui corretamente quando nada mais
mudou na árvore desde que ele foi gerado.

## Antes de acreditar num número

Cada linha abaixo custou pelo menos uma conclusão errada.

- **Suíte que termina sem imprimir `TOTAL:` é rodada inválida**, não resultado
  ruim. Já saiu lista com 26 FAILs em vez de 132, parecendo "106 testes
  consertados" — era o script morrendo no meio.
- **Site real deriva entre rodadas.** O mesmo binário mediu 18,8 e 23,4 no mesmo
  site; a wikipedia é bimodal. Sem repetição, o `oracle-diff` produz ganhos
  imaginários — aconteceu três vezes num dia só. Use `tools\ab-paint.ps1` com
  `-RuidoRep` ≥ 3, e compare a variação **intra**-binário com a **entre**
  binários antes de chamar qualquer diferença de efeito.
- **`--imgdiff` chega a errar a direção.** Um conserto que muda a quebra de linha
  faz a média punir o render *mais* correto. Quando houver dúvida,
  `getComputedStyle` do Chrome é um oráculo mais forte que o pixel.
- **Um teste que não pode falhar não vale nada.** Prove por sabotagem: reverta o
  conserto e veja o teste ficar vermelho. Um controle de golden escrito com o
  piso errado passou nos dois binários e não provava coisa nenhuma.
- **Contenção de recursos vira ERRO fantasma.** Não rode duas suítes que abram
  janela ao mesmo tempo. `--js262` e `--parsetree` são texto puro e podem
  conviver.
- **Um `browser.exe` pendurado de uma rodada anterior** segura o diretório de
  saída e derruba a rodada nova em cascata. Confira `browser.exe` zumbi pelo
  `CreationDate` antes de culpar o render.

## Flake conhecido

Nenhum, neste momento.

`test_svg_css_paint` **foi** o flake (rajadas inclusive a 1 thread: `len(g_svg_css)==1`
e a iteração do mapa vazia). Causa: mapa global chaveado por `^Node`, alocado com o
`context.allocator` do teste — o runner troca o tracking allocator a cada `@(test)`,
o rehash/clear usava o alocador errado e o header (`len`) dessincronizava dos
buckets. M246 moveu o dado para `Computed.svg_css` (dono = `free_styles`); o
portão é `test_svg_css_dono_e_o_computed` (50 passadas + free_styles pai/filho).

## Test262: cobertura e comparação por teste

`tools/fetch-test262.ps1` baixa um snapshot oficial, fixa o SHA do upstream e
preserva harness, fixtures e dependências. Não exclui features ausentes no motor.
A amostragem escolhe até `-PerDir` testes em **cada** diretório, ordenados pelo
SHA256 do caminho; `-PerDir 0` seleciona todos. O manifest separa os testes que
serão executados dos arquivos presentes apenas como dependências. As áreas padrão
são `language`, `built-ins` e `annexB`; `intl402` e `staging` ficam fora desta
medição. O upstream também inclui testes de propostas: consulte `byFeature`,
sem interpretar o agregado como percentual de uma edição do ECMAScript.

```powershell
# Reproduzir a seleção ampliada; escolha um diretório novo se já existir.
.\tools\fetch-test262.ps1 -Revision 2a1ade303f72d3de80565c921d685222405c32ce -PerDir 10 -OutDir _local/test262-expanded-10
.\test262.ps1 -Suite _local/test262-expanded-10 -TimeoutSec 5 -Report _local/reports/test262-expanded.json
```

Requer Python 3.10+ e PyYAML (`python -m pip install -r
tools/test262-requirements.txt`). Sem `-Browser`, o comando compila um executável
isolado de `tools/js262` em `_local/builds/test262.exe`, usando o código atual;
não substitui `browser.exe`. `-Browser <exe>` permite repetir uma medição com um
binário arquivado. Sem `-Suite`, prefere `_local/test262-expanded/manifest.json`
quando presente e usa o conjunto legado `tests/test262` como fallback.

O runner executa variantes normal/estrita, respeita `raw`/`noStrict`/`onlyStrict`
e executa módulos uma vez, com seu goal e URL originais. Imports usam arquivos
locais; harness e includes executam no escopo global. Testes assíncronos exigem
uma única chamada a `$DONE`; conclusão ausente, `$DONE(error)`, chamada duplicada
e exceções reportadas em callbacks não passam silenciosamente. Cada variante
tem um processo/VM novo, com prazo externo; os watchdogs de tempo/iterações do
navegador ficam desligados para não produzirem `RangeError` que satisfaça um
negativo por acidente.

Negativos exigem tipo, fase e origem no teste. `phase=parse` só identifica a
rejeição do próprio fonte antes de executar; erro em fixture importada não pode
aprovar esse negativo. O host ainda não identifica separadamente a fase de
linkagem `resolution`, portanto não reclassifica um erro de runtime para aprová-la.
`$262.createRealm`, agentes/CanBlock, GC explícito, IsHTMLDDA e ModuleSource são
limites do host: testes que os exigem ficam em **SKIP com motivo**, separados de
FAIL de linguagem. Ausência de includes também aparece como SKIP.

O relatório JSON contém cada teste/variante, erro, duração, revisão da suíte,
hash do executável, parâmetros e agregados por área, feature, modo e async. O
JSONL ao lado registra progresso, mas uma rodada sem JSON final e `TOTAL:` é
incompleta. A comparação recusa conjuntos/revisões diferentes:

```powershell
.\test262.ps1 -Suite _local/test262-expanded-10 -TimeoutSec 5 -Baseline _local/reports/antes.json -Report _local/reports/depois.json
# O relatório "changes" lista transições por nome e variante, inclusive SKIPs.
```

Regressões do host/coletor/veredito:

```powershell
python -m unittest discover -s tests -p test262_measurement_test.py -v
powershell -File tests/test262-runner.ps1
```

Os 170/299 antigos são históricos. Resultados do conjunto legado, da seleção
ampliada e de hosts diferentes não devem ser comparados só pelo total de PASS.

Baseline ampliado de **2026-11-22** (commit `98cd35e`): **10.848 arquivos /
21.056 variantes** em 1.482 diretórios, selecionados de 48.803 testes candidatos —
a MESMA seleção (mesmo manifest) de 2026-11-21. Resultado: **10.089 PASS / 10.565
FAIL / 62 ERROR / 340 SKIP**. Inclui 163 variantes de módulos e 916 variantes async
(categorias que podem se sobrepor). Os ERROR são 46 timeouts de 5 s e 16 abortos
nativos; os SKIP são 197 createRealm, 70 IsHTMLDDA, 52 agentes, 11 ModuleSource e
10 CanBlock.

Contra a linha de base de 2026-11-21 (8.971 PASS / 11.679 FAIL / 66 ERROR): 1.117
FAIL→PASS, 4 ERROR→PASS e 3 PASS→FAIL. Os 3 são dois testes que dependem da ORDEM
de chaves e oscilam também no binário de controle
(`built-ins/Reflect/getOwnPropertyDescriptor/symbol-property.js` e
`language/computed-property-names/class/method/generator.js`), não regressões.
Outro caso conhecido: `built-ins/decodeURI/S15.1.3.1_A2.5_T1.js` roda em 4,2–5,5 s e
estoura o timeout de 5 s conforme a carga da máquina — um ERROR dele não indica
mudança. A verificação dos casos com carriage return (feita em 2026-11-21) não foi
repetida nesta rodada; a seleção é a mesma.

O [resumo versionado](../tests/test262-measurements/summary-20261122.json) aponta
para o manifest exato e os resultados completos comprimidos; o de
[2026-11-21](../tests/test262-measurements/summary-20261121.json) fica como
histórico. Para comparar a próxima rodada com esta linha de base:

```powershell
.\test262.ps1 -Suite _local/test262-expanded-10 -TimeoutSec 5 -Baseline tests/test262-measurements/baseline-20261122.json.gz -Report _local/reports/test262-depois.json
```

`-Baseline` registra transições em `changes`; o comando continua saindo com código
1 quando houver qualquer FAIL ou ERROR, inclusive os já conhecidos.

## Erros de sintaxe precoces (parser)

`browser.exe --jsparse [m:|s:]arq.js ...` só PARSEIA (não executa) e imprime
`OK <arq>` ou `ERR <arq> <linha>:<col> <mensagem>` por arquivo (`m:` = goal Module,
`s:` = strict). É a ferramenta para medir o parser em lote, nas duas direções:

- **falso positivo** (JS válido rejeitado): rode sobre bundles reais (React, Vue,
  TypeScript, Babel, pdf.js, three.js...). Tem de dar **zero** — um SyntaxError
  indevido mata o script INTEIRO da página.
- **acerto**: os negativos `phase: parse` de `test/language` do Test262.

O parser não recupera mais de sintaxe inválida: todo problema de parse rejeita o
fonte com SyntaxError (mensagens no formato do V8). Em teste (`odin test`), um
SyntaxError em JS que o teste julgava válido entra em pânico
(`check_parse_recoveries`); com `-define:PARSEFAIL_LOG=true` ele só registra
`[PARSEFAIL]`, para listar todos os casos numa rodada só.

## Carregamento paralelo e primeira pintura

`python tools/check-page-loading.py --browser .\browser.exe` abre um servidor
local com respostas atrasadas e verifica downloads simultâneos, ordem de
execução dos scripts, uma única transferência por URL de CSS e pintura antes
do fim do JavaScript. Não depende de sites externos. `--baseline <exe-antigo>`
também mede o executável anterior; logs e tempos ficam em
`_local/reports/page-loading/`. Os tempos incluem inicialização do processo;
`first_content_ms` e `load_complete_ms` começam na navegação.

Os testes normais de `src/ui` cobrem a transferência da prévia, seu DOM
independente, imports reutilizados, navegações substituídas e abas fechadas.
Para exercitar também a pintura pelo caminho da interface, rode em um processo
separado (o atlas real interfere com as fontes sintéticas de outros testes):

```powershell
& C:\Odin\dist\odin.exe test src/ui -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false -define:PAGE_PREVIEW_INTEGRATION_TEST=true -define:ODIN_TEST_NAMES=page_preview_paints_in_real_ui_while_script_is_busy
```
