# Build

Hoje isto só compila e roda no **Windows x64**. Não é uma decisão de projeto, é
um fato: `main.odin` importa `core:sys/windows`, o link é contra `SDL2.lib`
compilada com MSVC, e o TLS vem do Schannel via libcurl. Portar é possível; ainda
não foi feito.

## Pré-requisitos

| | |
|---|---|
| [Odin](https://odin-lang.org/) | O compilador. Os caminhos nos scripts assumem `C:\Odin\dist\odin.exe`. |
| MSVC Build Tools 2022 | Só para recompilar a lib do ImGui (passo do `vendor/`). O `cl` e o `lib` precisam estar no PATH — o `vcvarsall.bat x64` resolve. |
| Python 3 | Só para os geradores de tabela de Brotli/WOFF2. |
| `curl.exe` | Já vem no Windows 10+; usado pelos geradores para buscar a spec. |

## 1. `vendor/` — as dependências que não estão versionadas

`vendor/` tem ~750 MB e não vai para o repositório. São três peças:

### 1.1 Bindings de Odin para o ImGui

```powershell
git clone https://github.com/zeozeozeo/odin-imgui vendor\imgui
cd vendor\imgui
git checkout c69ef75          # a SHA contra a qual este projeto foi escrito
python build.py               # baixa SDL2/GLFW/Vulkan-Headers e gera os bindings
```

O `build.py` do odin-imgui baixa as dependências de backend e produz
`imgui.odin`, `imgui_internal.odin`, `enabled.odin` e a
`imgui_windows_x64.lib`. Os backends que este projeto usa são o **SDL2** e o
**SDL_Renderer2** — confirme que ambos aparecem como `true` no `enabled.odin`
gerado.

### 1.2 O remendo que faz o backend SDL2 linkar

Os arquivos `imgui_impl_sdl2.cpp` e `imgui_impl_sdlrenderer2.cpp` do ImGui
exportam com *name mangling* de C++, e o Odin espera símbolos C. O remendo é
forçar `extern "C"` na inclusão e regravar os dois objetos dentro da `.lib`:

```powershell
copy tools\vendor\force_c_api.h    vendor\imgui\
copy tools\vendor\compile_sdl2.bat vendor\imgui\
cd vendor\imgui
.\compile_sdl2.bat
```

Depois disto, `git status` dentro de `vendor/imgui` mostra a
`imgui_windows_x64.lib` modificada. É o esperado — é justamente o passo.

### 1.3 libwebp

`vendor/webp/` precisa de `libwebp.lib` (x64, estática) e do `webp.odin` com as
declarações `foreign`. A lib sai do build padrão do
[libwebp](https://chromium.googlesource.com/webm/libwebp) com CMake/MSVC.

### 1.4 A DLL que o executável precisa em tempo de execução

```powershell
copy vendor\imgui\backend_deps\SDL2-bin\SDL2.dll .
```

Sem ela ao lado do `browser.exe`, o processo nem sobe. Ela é ignorada pelo git
(é binário de terceiro), então este passo é manual em cada máquina nova.

### O que o build realmente consome

Vale saber, se algum dia isto virar um pacote menor: dos 750 MB, o build só
precisa de ~11 MB — os `.odin` gerados, a `imgui_windows_x64.lib`, o diretório
`backend_deps/SDL2-bin/` (o `main.odin` faz `foreign import` direto da
`SDL2.lib` de lá) e a `libwebp.lib`. O resto é fonte de backend que o `build.py`
baixou e não usamos.

## 2. Artefatos gerados de Brotli e WOFF2

⚠️ **Sem estes quatro artefatos a árvore inteira não compila** — não só os
pacotes deles. `src/ui` importa `../brotli` e `../woff2`, então um arquivo
faltando ali derruba `odin build .` e `odin test src/ui` junto.

Eles são versionados neste repositório, então normalmente **você não precisa
fazer nada**. A receita fica registrada para quando a spec mudar ou para auditar
de onde os números vieram:

```powershell
curl.exe -sL https://www.w3.org/TR/WOFF2/               -o WOFF2.html
curl.exe -sL https://www.rfc-editor.org/rfc/rfc7932.txt -o rfc7932.txt
python tools\woff2-tables.py  WOFF2.html  src\woff2      # W2_TRIPLET, W2_KNOWN_TAGS
python tools\brotli-tables.py rfc7932.txt src\brotli     # dict.bin + TRANSFORMS/LUT0..2
python tools\brotli-vectors.py src\brotli\testdata rfc7932.txt <alguma-fonte.woff2>
```

Os dois primeiros conferem invariantes e CRC na geração (a RFC publica os cinco)
e se recusam a escrever se algo divergir.

## 3. Compilar

```powershell
$flags="C:\Odin\dist\vendor\sdl2\SDL2.lib /STACK:1073741824"
& C:\Odin\dist\odin.exe build . -out:browser.exe -o:speed "-extra-linker-flags:$flags"
```

ou `.\build.bat`, que faz o mesmo.

Duas flags que **não** são opcionais, e o porquê medido de cada uma:

**`/STACK:1073741824`** (1 GB) — o interpretador de JS é um *tree-walker*: cada
chamada de JavaScript vira vários frames nativos, e o React gasta muito por
chamada. A stack padrão de 1 MB do Windows estoura em ~85 níveis e **fecha o
navegador** com `0xC00000FD`. 256 MB não bastaram para SPAs reais; 1 GB sim.
Reserva é só espaço de endereço no x64 (commit preguiçoso), então é barata. Tem
de ir como **uma única string** junto do `.lib`.

**`-o:speed`** — o build de debug roda a ~2500 evals/s, 50-100× mais lento. Um
SPA React não termina de renderizar a tempo e a página fica **branca**: parece um
bug do motor e é só lentidão do build. Para depurar o motor (ver as mensagens do
React em modo DEV, por exemplo), compile à mão sem `-o:speed` — e saiba que está
medindo outra coisa.

## Armadilhas do ambiente

Estas custaram tempo real; estão aqui para não custarem de novo.

- **O Defender põe o `browser.exe` recém-compilado em quarentena**, às vezes no
  meio de uma rodada. Sintoma: `CommandNotFoundException`, ou o arquivo
  simplesmente some. Recompilar.
- **`browser.exe` rodando trava o link** do build seguinte (`LNK1104`). Feche
  antes. Se não houver processo nenhum, confira se o arquivo ainda existe — pode
  ser o Defender.
- **O hash do `browser.exe` não identifica o build.** O build do Odin não é
  byte-reproduzível, e já houve conteúdo mudando com o `mtime` intacto. O hash
  serve para detectar **troca durante uma rodada** (ler antes e depois); para
  afirmar "este é o binário com o meu conserto", use uma **sonda de
  comportamento** — uma fixture de cinco linhas que só passa com o conserto.
- **`build.bat` via `cmd /c` falha em alguns ambientes**; chame o `odin`
  diretamente.
