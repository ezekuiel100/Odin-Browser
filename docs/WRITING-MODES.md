# Escrita vertical, bidi e shaping

## Implementação

- `writing-mode:horizontal-tb/vertical-rl/vertical-lr` é herdado. Texto inline forma colunas verticais, com progressão dos blocos à direita ou à esquerda, dimensões físicas e redimensionamento. Blocos filhos também são posicionados no eixo de bloco vertical.
- `text-orientation:mixed/upright/sideways` controla os glifos. Mixed consulta a propriedade Unicode Vertical_Orientation pelo ICU, separa clusters upright dos trechos sideways e gira os trechos latinos 90 graus no sentido horário. Inclui orientação por span.
- Propriedades lógicas de tamanho, margem, padding, insets, bordas, raios e overflow mapeiam os eixos e a direção. Os modos também participam da validação, CSS.supports e CSSOM.
- O ICU do Windows resolve níveis bidi sobre o texto lógico antes da quebra. Cada linha posiciona itens e separadores na ordem visual, mantendo DOM, strings e alvos de eventos na ordem lógica.
- `unicode-bidi:normal/embed/isolate/bidi-override/isolate-override/plaintext` usa controles Unicode nos limites dos escopos inline, sem inserir esses controles no DOM. Suporta até oito escopos aninhados por item.
- Uniscribe analisa texto de escritas complexas e CJK, escolhe fallback e fornece tanto o avanço quanto a rasterização. O raster transparente entra no pipeline de pintura com tint, clipping, transform e opacidade. O caminho latino comum continua usando o atlas.
- As fontes do atlas são registradas temporariamente no GDI. Recursos de análise são liberados por chamada; fontes registradas, pixels e texturas são liberados no reset e no encerramento. O cache limita-se a 256 entradas, 4 milhões de pixels ao todo e 2 milhões por entrada.

## Validação

`text_native_test.odin` verifica análise e pixels com árabe, hebraico, devanágari e tailandês usando fonte real; também compara o avanço usado no layout com o da análise nativa. Os testes bidi verificam ordem visual, níveis de números e preservação das strings.

`writing_modes_test.odin` cobre geometria vertical-rl/lr, múltiplas disposições em alturas diferentes, sideways, herança e eixos lógicos, direção RTL, modo via var(), blocos verticais, isolamento/override inline, orientação Unicode em palavras mistas e gramáticas CSS.

`tests/layout/writing-modes.html` é a fixture de layout e de inspeção visual, com CJK, latim vertical, árabe, hebraico e scripts indianos.

## Limites

Este suporte não representa conformidade completa com CSS Writing Modes ou UAX #9 em todos os contextos. A ordem visual é aplicada a itens do modelo inline atual; mudanças de nível dentro de um único item, neutralização final de linha, caret/seleção visual, shaping que cruza fronteiras de estilos e casos de quebra intra-palavra complexa ainda precisam de trabalho.

A classificação vertical segue Unicode, mas não seleciona todas as substituições OpenType vert/vrt2 de pontuação. `text-combine-upright`, ruby, ênfase e tipografia vertical avançada não foram acrescentados. Layout vertical em flex/grid/tabelas, floats, fragmentação e contextos ortogonais complexos ainda usa partes da infraestrutura física existente. As unidades vi/vb continuam relativas aos eixos horizontais do viewport.

O backend nativo é Windows (Uniscribe/GDI e ICU do sistema). Não acrescenta controle de features OpenType, eixos de fontes variáveis ou aplicação completa de letter-spacing aos clusters shaped. A seleção GDI por família pode diferir da seleção do atlas, especialmente para variantes de peso/estilo e webfonts com famílias duplicadas. Se análise, fonte ou limites de cache falharem, o texto volta ao atlas; o resultado pode perder shaping ou fallback.

Referências: [CSS Writing Modes 3](https://www.w3.org/TR/css-writing-modes-3/), [ICU bidi](https://unicode-org.github.io/icu/userguide/transforms/bidi.html), [Uniscribe](https://learn.microsoft.com/en-us/windows/win32/api/usp10/nf-usp10-scriptstringanalyse), [Unicode Vertical Orientation](https://unicode-org.github.io/icu-docs/apidoc/dev/icu4c/uchar_8h.html).

Verificações finais: 3.122 testes de pacote (944 UI e 178 CSS), 22/22 goldens sem regenerar referências existentes e 5/5 testes novos de pintura. O teste de fundo inline RTL falha no executável de desenvolvimento anterior à correção e passa na versão corrigida. Logs e imagens estão em `_local/writing/`; o executável otimizado desta rodada é `final3.exe`.

A suíte geral de pintura também passou: 111/111 com `final3.exe` (116 verificações somando as cinco novas). O binário foi instalado em `browser.exe`, com backup em `_local/writing/browser-before-install.exe`; SHA-256: `27DAD8E9B3FB851CD80881E6E4AEF3EA9A37C4A663DCC4E7F4E3F1888AF8D778`.
