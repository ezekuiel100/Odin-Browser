# Arquitetura

O caminho de uma página, do byte ao pixel:

```
URL ──► src/net ──► src/html ──► src/dom ──► src/css ──► src/ui/style ──► src/ui/layout ──► src/ui/render
       libcurl     tokenizer +   árvore de   folhas +     cascata →         árvore de          ImGui →
       (HTTP/2,    tree builder    nós       seletores    estilo computado   caixas            SDL_Renderer
        TLS nativo)                                                          (bloco/inline/
                                       ▲                                      flex/grid)
                                       │
                                    src/js  ◄── interpretador tree-walking + bindings de DOM
```

## Pacotes

| Pacote | O que faz |
|---|---|
| `src/net` | HTTP/HTTPS via libcurl com pool de conexões compartilhado entre workers, resolução de URL relativa, `file:`. Passa-se por Chrome no `User-Agent`, senão os CDNs com bot-detection servem página de bloqueio. |
| `src/html` | Tokenizador e construtor de árvore do HTML. Também a serialização usada pelo html5lib. |
| `src/dom` | A árvore de nós. Deliberadamente burra: quem dá semântica é `ui` e `js`. |
| `src/css` | Tokenizador e parser de CSS, seletores e **especificidade**, `@supports`, `@media`, `@font-face`. Não decide nada de layout — só entende o texto. |
| `src/ui/style.odin` | A **cascata**: casa seletores, ordena por origem/camada/`!important`/especificidade/ordem e produz o estilo computado. É onde vivem as regras de shorthand × longhand. |
| `src/ui/layout.odin` | A árvore de caixas: fluxo normal, inline, float, `position`, flexbox, grid, tabelas. |
| `src/ui/render.odin` | Pintura: fundos, bordas e raios, sombras, texto, `clip`/`overflow`, camadas com opacidade. |
| `src/ui/browser_ui.odin` | O chrome do navegador (abas, barra de endereço), o atlas de fontes e os **DevTools** (F12). |
| `src/ui/headless.odin` | Todos os modos de linha de comando — é o que as suítes dirigem. |
| `src/js` | Motor JavaScript próprio: lexer, parser, AST e um interpretador **tree-walking**. Inclui `Promise`/microtasks, geradores, `Proxy`/`Reflect`, `BigInt`, regex, `Intl` parcial, módulos ES, e os bindings de DOM/CSSOM/canvas/observers. |
| `src/brotli`, `src/woff2` | Decodificadores próprios, escritos para as webfonts: WOFF2 remonta o SFNT, e o corpo dele é Brotli. |

## A regra de dependência que sustenta tudo

```
ui ──► js ──► html ──► dom
 └───► css, net, brotli, woff2
```

**`src/js` não pode importar `src/ui`.** A ponte de volta (o JS precisa perguntar
geometria e estilo computado ao motor de layout) é feita por ponteiros de função
registrados em `src/ui/computed_om.odin`, não por import.

Isso não é purismo: é o que permite `odin test src/js` compilar **só** o pacote
JS, sem tocar em ImGui nem SDL — o teste mais rodado do projeto, e o único que se
pode rodar com segurança enquanto outra coisa mexe no CSS.

⚠️ E é por isso que um artefato faltando em `src/brotli`/`src/woff2` derruba a
árvore **inteira**: `src/ui` importa os dois. Ver [BUILD.md](BUILD.md).

## Duas armadilhas que valem saber antes de mexer

**Há dois caminhos de parsing de HTML.** O caminho principal e de spec fica em
`treebuild.odin`: `parse_document` produz a árvore medida pelo html5lib,
`parse_render` aplica somente a preparação visual e é usado pela navegação e
pelos modos de renderização, e `parse_fragment` atende `innerHTML` e
`insertAdjacentHTML`. O parser simplificado de `parser.odin` é legado, conserva
helpers compartilhados e permanece disponível para comparação explícita pelo
modo `--parsetree-legacy`.

**O estado global de pacote + o runner paralelo de testes do Odin = flake.** O
`odin test` monta 16 páginas ao mesmo tempo; qualquer global mutável em `src/ui`
é compartilhado entre elas. A solução adotada é `thread_local`
(`src/ui/computed_om.odin`), e o `test.ps1` roda `src/ui` e `src/css` com
`-define:ODIN_TEST_THREADS=1` porque essas duas ainda têm estado global de
verdade. Um comentário do tipo "isto roda numa thread só" é o sinal de que
ninguém pensou no runner.

## Sondas compiladas condicionalmente

Investigação neste projeto é feita instrumentando o funil comum, não teorizando
sobre a raiz. O padrão custa zero quando desligado:

```odin
when #config(NOME_PROBE, false) { fmt.eprintfln("[TAG] ...") }
```

```powershell
odin build . -define:NOME_PROBE=true ...
```

A que mais rendeu é a **sonda de cascata**, que imprime, por nó alvo, toda regra
que casou e não casou (com especificidade, camada, `!important` e ordem), o
vencedor por propriedade e o que o desempate apagou:

```powershell
odin build . -define:CASCADEPROBE=true -define:CASCADE_ALVO=<trecho de id/class> -define:CASCADE_PROP=<trecho da prop> ...
```

Sonda esquecida no código já aconteceu — remova depois de usar.
