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

`test_svg_css_paint` (`src/ui`) falha **em rajadas**, inclusive com uma thread só.
Já houve sequências de 20/20 falhas e, minutos depois, verde duas vezes seguidas.
Foi reproduzido numa árvore com o código suspeito revertido, então **não é da
mudança que você está fazendo** — confirme nas duas árvores antes de investigar.
Sintoma: `len(g_svg_css) == 1` mas iterar o mapa não produz chave nenhuma.
Suspeita não confirmada: uso-depois-de-liberado de nó de DOM.
