# Carregamento de fontes e recuperação de falhas

O registro de `@font-face` mantém as faces que já entraram no atlas vivas durante a sessão: o ImGui guarda ponteiros para os arquivos. A correção não libera esses arquivos durante a navegação.

## Comportamento

- O orçamento passou de 12 para 32 faces prontas ou em download. Entradas Failed não consomem esse orçamento e são reutilizadas quando nunca entraram no atlas.
- Faces prontas e downloads em andamento continuam idempotentes por família/peso/itálico, inclusive quando o orçamento está cheio.
- Falhas de rede e HTTP 408, 429 ou 5xx têm nova tentativa automática no poll. São no máximo três tentativas por entrada/URL, com intervalo mínimo de dois segundos entre inícios.
- Falhas de dados inválidos, arquivo vazio, ausência de glifos ou HTTP permanente não entram no retry automático. Um novo scan (por exemplo, recarregar a página) pode tentar a mesma URL novamente, respeitando o mesmo intervalo e limite.
- Trocar a URL de uma combinação que falhou inicia uma nova contagem e reutiliza a entrada. Uma face pronta continua sendo reutilizada, conforme o comportamento anterior.
- A thread de registro usa o mesmo mutex dos workers para evitar realocar o vetor enquanto um download publica o resultado.

## Diagnóstico

Erros saem em stderr com `[FONT]`, incluindo família, peso, itálico, tentativa, motivo, status HTTP, tamanho e URL. Motivos: Network, Http, Empty, Decode, No_Glyphs, Thread; descarte por orçamento: atlas-limit. URLs longas são limitadas e fontes data: não imprimem o conteúdo base64.

Com `-define:FONTPROBE=true`, o diagnóstico também informa mudanças de seleção: variante solicitada e variante efetivamente escolhida. Isso evita perder o resultado quando as primeiras consultas ocorreram antes do download.

## Verificação

    C:/Odin/dist/odin.exe test src/ui -define:ODIN_TEST_THREADS=1
    powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-font-loading.ps1 -Browser ./browser.exe

Os testes de unidade cobrem retry com intervalo e limite, URL corrigida, aproveitamento da vaga de uma falha, saturação com faces vivas e seleção das três variantes.

O script renderiza Arial regular, negrito e itálico por `@font-face` e compara cada variante com o mesmo arquivo declarado isoladamente. Usa arquivos de Arial instalados no Windows; não usa rede. São seis verificações: conteúdo visível e correspondência de pixels para cada estilo, com tolerância de dois níveis de cinza para amostragem do atlas.

## Limites

O teto continua sendo por sessão: após 32 faces vivas distintas, novas faces podem cair no fallback e o log registra a causa. Não houve remoção de faces já usadas pelo atlas, pois exigiria reconstruir e religar todos os ponteiros de fontes e layouts.

Esta correção não força texto normal a usar uma face normal ausente e não altera a seleção de estilo quando só uma variante está disponível.

## Work Sans do animate.style (10/11/2026): timeout de rede e fonte variável

O timeout que a seção acima atribuía ao ambiente **era nosso**, e reproduzia sempre. Eram dois defeitos, um atrás do outro.

**1. Requisições simultâneas ao mesmo host travavam 10 s (`src/net/net.odin`).** Com UA de navegador, o Google Fonts serve a Work Sans como **uma** fonte variável em woff2: as `@font-face` de 400 e 700 apontam para a **mesma URL**. As duas faces baixavam ao mesmo tempo, e o `PIPEWAIT` fazia o 2º handle esperar a conexão do 1º, que pertence ao `easy_perform` de outra thread. Ninguém acordava esse handle até o `CONNECTTIMEOUT` de 10 s. Medido com uma página de 2 faces na mesma URL + 30 imagens do wikimedia, 3 rodadas por variante: com `PIPEWAIT`, 1 falha por rodada travada em 10 001 ms; sem `PIPEWAIT`, sem compartilhar conexões, ou sem os dois: 0 falhas, 0 respostas 429 e maior requisição < 510 ms. Ficou a variante que só tira o `PIPEWAIT` (preserva o reuso de conexão sequencial). A sonda `-define:NETPROBE=true` imprime tempo e resultado de cada fetch.

Além disso, o registro de fontes passou a fazer **um download por URL**: a 2ª face com a mesma URL espera a 1ª (`waiting_on`) e empresta os bytes decodificados (`raw`, `raw_borrowed`). A falha do download compartilhado propaga para quem espera, inclusive a re-tentativa.

**2. O 700 da fonte variável saía igual ao 400 (`src/varfont`).** O stb_truetype não lê variação: desenhava a instância padrão para todos os pesos. O pacote novo `src/varfont` instancia o eixo `wght` (normalização + `avar`, deltas do `gvar` com IUP, pontos fantasmas → `hmtx`) e regrava `glyf`/`loca`/`hmtx`. Cada face recebe a instância no seu peso.

- Oráculo: as instâncias **estáticas** que o próprio Google Fonts serve (sem UA, um TTF por peso). A nossa instância de 700 bate **exatamente** (avanço e bbox de toda letra ASCII) com o TTF estático de 700, e a de 400 com o de 400. Controle: a instância padrão comparada ao 700 diverge em mais da metade das letras. Sabotagem do IUP derruba o teste (bbox do `[`).
- `font-weight: 100 900` (faixa) agora guarda as duas pontas. A face de faixa entra instanciada no 400 trazido para dentro dela; um peso pedido dentro da faixa gera, sob demanda, uma instância **derivada** (sem novo download), que vence assim que entra no atlas.
- No animate.style, "Documentation", o título e os cabeçalhos da lista saem em negrito e terminam no mesmo x que no Edge.

**Limites desta parte:**

- ~~O estilo computado guarda o peso em 3 degraus~~ — consertado em seguida, ver "Peso numérico" abaixo.
- Só o eixo `wght`, só contornos TrueType (CFF2 cai na instância padrão, com `[FONT] ... variation=Unsupported`), sem `HVAR`/`MVAR`.
- Cada instância ocupa uma vaga no teto de 32 faces.

**Portões (10/11):** `test.ps1` com todos os pacotes verdes (`src/varfont` entrou na lista: 8 testes; `src/ui` 876; `src/css` 175), paint-check 109/109, layout-golden 19/19, `tools/check-font-loading.ps1` 6/6. WPT: 352/129/0 (481). O diff nomeado contra `wpt-baseline-fails.txt` acusa 3 `css-tables/absolute-tables-*` a mais e 2 a menos. O `browser.exe` do HEAD sem esta mudança dá **as mesmas falhas por nome** nas três categorias, então é deriva anterior da lista (sem atualização desde o primeiro commit), não efeito desta mudança. Sabotagens provadas: IUP desligado (bbox do `[`), derivação desligada, guarda de bytes compartilhados desligada (`panic: Bad free` no teste nomeado).

### Peso numérico: 300 e 900 de verdade (10/11/2026)

O peso morria antes de chegar à @font-face: `Font_Weight` era `enum {Regular, Semi, Bold}`, e o `l_pick_font` só pedia 400/600/700. Numa face `font-weight: 100 900`, o 300 saía igual ao 400 e o 900 igual ao 700.

- `Font_Weight` agora é o **número** do CSS (`distinct u16`, 1..1000). ⚠️ O zero-value significa `normal`: leia sempre por `fw_css(w)` (0 → 400), nunca o campo cru.
- A quantização ficou só onde é necessária: `fw_class(w)` escolhe a face **embutida** (Segoe UI 400/600/700: ≤500 → regular, ≤600 → semibold, acima → negrito, a mesma regra de antes). A @font-face recebe o número inteiro, e a variável deriva a instância exata (300, 900, 450…).
- Junto vieram:
  - qualquer `<number>` em [1,1000] (`450`, `1000`); antes só as centenas eram aceitas;
  - `bolder`/`lighter` **relativos ao pai**, pela tabela do Fonts 4. Antes `bolder` valia 700 fixo e `lighter` era ignorado. O h1..h6 refaz o relativo contra o pai no `compute_node`, porque o UA já pôs 700 no próprio heading;
  - `getComputedStyle().fontWeight` devolve o número computado.
- Medido (fixture com Work Sans `100 900`, linhas em 300/400/700/900):

  | | tinta 300/400 | tinta 900/700 | borda direita (px), 300/400/700/900 |
  |---|---|---|---|
  | Edge | 0,649 | 1,262 | 372/387/391/394 |
  | nós | 0,650 | 1,256 | 373/389/392/394 |
  | antes | 1,000 | 1,000 | 389/389/392/392 |

  As linhas de 400 e 700 não mudaram entre os binários (controle).
- Testes:
  - `font_weight_test.odin` reescrito para afirmar números, faixa, inválidos, classe da face embutida e bolder/lighter, incluindo o heading.
  - `test_var_l_pick_font_entrega_300_e_900_a_face_de_faixa` cobre o elo layout → @font-face. Sabotagem (quantizar o `css_w` de novo) reprova: só sai a instância de 700.
- Portões: `test.ps1` todo verde (`src/ui` 880), paint-check 109/109, layout-golden 19/19. WPT 352/129/0 com **as mesmas 129 falhas por nome** do binário anterior.
- Continua aberto: a face embutida não tem light/black. `font-weight: 300` sem @font-face segue em Segoe UI regular. O Chrome usaria a Segoe UI Light, mas ela custa ~4 MB de atlas.

## Resultado desta atualização (09–10/11, commit d3017dc)

- UI: 869 testes passaram.
- Fontes: 6 verificações visuais passaram.
- Pintura: 109 casos passaram.
- Layout: 19 casos passaram.
- Executável otimizado instalado como browser.exe.
- SHA-256: 30047B990C58ED5C31A7C7EFA0C72F3D3BBC7DC3A0EE7CCF2F633F33348BA655.
- Backup: _local/builds/browser_before_fonts_20261110_092141.exe.

O navegador que já estava aberto continua usando a versão anterior. Fechar e abrir browser.exe aplica a atualização.