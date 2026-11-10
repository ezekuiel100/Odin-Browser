# Terceiros

O código sob `src/` e `main.odin` é original e está sob a licença [MIT](LICENSE).
Este arquivo lista o que **não** é nosso: as suítes de teste que estão
versionadas aqui dentro e as bibliotecas que o build consome de fora.

## Suítes de conformância versionadas neste repositório

Estão commitadas, e não baixadas na hora, por um motivo concreto: os scripts
`tools/fetch-wpt.ps1` e `tools/fetch-test262.ps1` puxam de `master`/`main`, sem
SHA fixa. Um `fetch` novo devolveria um corpus diferente, e a lista nomeada
`wpt-baseline-fails.txt` — que é a autoridade do portão de regressão — deixaria
de corresponder aos arquivos. Versionar o corpus é o que torna o portão
reproduzível.

| Diretório | Origem | Licença declarada pelo upstream |
|---|---|---|
| `tests/wpt/` | [web-platform-tests/wpt](https://github.com/web-platform-tests/wpt) — subconjunto curado de reftests auto-contidos | BSD 3-Clause |
| `tests/test262/` | [tc39/test262](https://github.com/tc39/test262) — harness + subconjunto das áreas implementadas | BSD 3-Clause |
| `tests/html5lib/` | [html5lib/html5lib-tests](https://github.com/html5lib/html5lib-tests), tree-construction, na SHA `9329e64` | MIT |
| `tests/html5lib-tokenizer/` | o mesmo repositório, pasta `tokenizer` | MIT |

Nenhum arquivo dessas suítes foi modificado. A curadoria (quais casos entram)
está inteira nos scripts `tools/fetch-*.ps1`.

## Dados gerados a partir de especificações

Não são cópias de código, mas de tabelas normativas — cada gerador confere os
invariantes/CRC que a própria spec publica e se recusa a escrever se divergir.

| Artefato | Gerado de | Gerador |
|---|---|---|
| `src/brotli/dict.bin`, tabelas de transformação e LUTs | [RFC 7932](https://www.rfc-editor.org/rfc/rfc7932.txt) (Brotli) | `tools/brotli-tables.py` |
| `src/woff2/*` — `W2_TRIPLET`, `W2_KNOWN_TAGS` | [WOFF2, W3C](https://www.w3.org/TR/WOFF2/) | `tools/woff2-tables.py` |
| `src/html/entities_gen.odin` | tabela de entidades do WHATWG HTML | `tools/gen-entities.ps1` |

`src/woff2/testdata/roboto.woff2` é a fonte **Roboto** (Google Fonts), sob
Apache License 2.0 — está aqui porque um teste afirma que ela declara 18 tabelas.

`src/varfont/testdata/worksans-*` é a fonte **Work Sans** (Google Fonts), sob a
SIL Open Font License 1.1 (texto em `src/varfont/testdata/OFL.txt`): a versão
VARIÁVEL em woff2 (o arquivo que o animate.style recebe) e as instâncias
estáticas de 400 e 700 que o próprio Google Fonts serve — estas são o oráculo
contra o qual o instanciador é testado.

## Dependências de build (não versionadas — ver [docs/BUILD.md](docs/BUILD.md))

| Dependência | Papel | Licença declarada pelo upstream |
|---|---|---|
| [Dear ImGui](https://github.com/ocornut/imgui) | camada de desenho imediato e a UI do chrome/DevTools | MIT |
| [zeozeozeo/odin-imgui](https://github.com/zeozeozeo/odin-imgui) | bindings de Odin para o ImGui | MIT |
| [SDL2](https://www.libsdl.org/) | janela, entrada e o `SDL_Renderer` | zlib |
| [libwebp](https://chromium.googlesource.com/webm/libwebp) | decodificação de WebP | BSD 3-Clause |
| libcurl (via `vendor:curl` do Odin) | HTTP/HTTPS, com o TLS nativo do Windows | curl (MIT/X derivada) |
| `vendor:stb` do Odin (`stb_image`, `stb_truetype`) | decodificação de imagem e métricas de fonte | MIT / domínio público |

As licenças acima são as que cada projeto declara publicamente; ao redistribuir
um binário deste navegador, confira os textos nos repositórios de origem — eles
são a fonte, esta tabela é só um índice.
