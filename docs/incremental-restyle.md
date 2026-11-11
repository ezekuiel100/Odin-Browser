# Restyle incremental

`restyle_tab` compara snapshots locais do DOM e marca a subarvore alterada e
seus ancestrais. A cascata percorre os ancestrais para reconstruir o contexto de
heranca e variaveis; os demais ramos reutilizam os estilos computados. A deteccao
continua lendo o estado atual, inclusive escritas diretas em atributos.

Mudancas de fundo, opacidade e cursor podem atualizar caixas existentes. Outras
propriedades, texto inline sem caixa propria e mudancas estruturais reconstroem
a arvore de caixas. Zoom, viewport, tema e folhas novas invalidam tudo.
Seletores relacionais entre ramos, contadores e container queries usam o caminho
completo por seguranca. Container queries tambem invalidam sem mudanca no DOM.

Ainda ha trabalho O(n): deteccao, copia das entradas reutilizadas e atualizacao
das caixas. O loop de desenho ainda chama `layout_box` por frame; esta mudanca
reduz a cascata e a reconstrucao das caixas, sem cachear a geometria por frame.

## Validacao

`./test.ps1` executa todos os pacotes. As regressoes em
`src/ui/style_invalidation_test.odin` cobrem classes, atributos, variaveis,
pintura, estilos com recursos proprios, fallback relacional e estrutural.

Benchmark sintetico opcional, sem limite de tempo usado como assercao:

```powershell
C:/Odin/dist/odin.exe test src/ui -o:speed -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=incremental_style_benchmark -define:BENCH_RESTYLE=true
```

Medicao local em 2026-11-11, 2.003 nos, alternando uma classe em 20 restyles por
modo: caminho completo 34,200 ms/restyle e 2.003 cascatas; incremental 16,986 ms
e 5 cascatas (2,01x). Mede apenas `restyle_tab`, sem pintura ou layout geometrico.
O caso sintetico nao representa um benchmark de navegacao em paginas reais.
