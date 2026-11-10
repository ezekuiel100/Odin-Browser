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

Esta correção não força texto normal a usar uma face normal ausente e não altera a seleção de estilo quando só uma variante está disponível. A indisponibilidade específica da Work Sans em animate.style ainda precisa ser confirmada numa sessão com acesso ao site/Google Fonts; o ambiente da investigação retornou falha de conexão/timeout.
## Resultado desta atualização

- UI: 869 testes passaram.
- Fontes: 6 verificações visuais passaram.
- Pintura: 109 casos passaram.
- Layout: 19 casos passaram.
- Executável otimizado instalado como browser.exe.
- SHA-256: 30047B990C58ED5C31A7C7EFA0C72F3D3BBC7DC3A0EE7CCF2F633F33348BA655.
- Backup: _local/builds/browser_before_fonts_20261110_092141.exe.

O navegador que já estava aberto continua usando a versão anterior. Fechar e abrir browser.exe aplica a atualização.