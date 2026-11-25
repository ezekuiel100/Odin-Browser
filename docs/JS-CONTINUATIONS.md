# Frames de execução e corrotinas — 2026-11-24

`await`, `yield`, `yield*`, `for await` e a avaliação suspensa de módulos usam
frames explícitos no heap. O corpo executa na thread que chama ou retoma a
corrotina. Não há uma thread, semáforos ou uma pilha nativa por execução pendente.

O trampoline em `src/js/continuation.odin` guarda escopos, operandos já
avaliados, receptores de chamadas, referências de atribuição, iteradores e
conclusões estacionadas por `finally`. Subárvores que não suspendem reutilizam
`eval` e os built-ins existentes. Um cache por VM classifica a sintaxe sem
reescrever a AST compartilhada entre chamadas.

O coletor percorre esses frames nos pontos seguros do host. A lista de
corrotinas é um índice de alocações; as raízes são os iteradores alcançáveis e
os holders das reações de Promise. Corrotinas inalcançáveis podem ser liberadas
durante uma suspensão. Concluir ou descartar libera os frames e os argumentos
sem executar `catch` ou `finally` como efeito da coleta.

A FIFO de microtasks continua a mesma. Rejeições entram no ponto do `await`,
`return` e `throw` desenrolam os handlers salvos, e o fechamento de um iterador
assíncrono pode suspender preservando a conclusão original. A retomada também
preserva o contexto de módulo e os frames usados por `Error.stack`.

## Medição

O benchmark `tools/continuation-bench` cria operações que guardam um objeto
local e aguardam a mesma Promise. Acrescenta 6.000 objetos descartáveis, tenta
coletar enquanto as operações estão pendentes, resolve a Promise e verifica
o número de conclusões e a soma dos resultados. A contagem de threads e a
memória privada vêm do processo Windows, incluindo as pilhas fora do heap Odin.

O controle foi compilado do commit `3c76987` em uma cópia isolada dos fontes,
com o mesmo benchmark e as mesmas flags de otimização. Os resultados e os
hashes ficam nos arquivos de medição associados a esta rodada.

Medianas de três processos novos por build, com 1.000 operações pendentes:

| Medida | Antes | Depois |
|---|---:|---:|
| Threads antes da carga | 4 | 4 |
| Threads durante a espera | 1.004 | 4 |
| Memória privada durante a espera | 67,7 MiB | 17,8 MiB |
| Iniciar e suspender as operações | 79,126 ms | 5,213 ms |
| Retomar e concluir | 41,295 ms | 1,655 ms |
| GC durante a espera | adiado | executado |

As 1.000 operações concluíram com a soma esperada em todas as execuções. Os
dados brutos estão em [continuations-benchmark-20261124.json](../tests/test262-measurements/continuations-benchmark-20261124.json).

```powershell
C:/Odin/dist/odin.exe build tools/continuation-bench -o:speed -out:_local/builds/continuation-bench.exe '-extra-linker-flags:/STACK:1073741824'
./_local/builds/continuation-bench.exe 1000
./_local/builds/continuation-bench.exe 3000
```

Essa carga mede custo de suspensão e retomada. Não mede desempenho de sites,
renderização ou chamadas síncronas em geral.

## Validação e limites

Os testes de `src/js/js_continuation_test.odin` incluem GC com referências e
operandos intermediários vivos, chamadas com getters e `this`, desestruturação,
closures por iteração, `finally`, fechamento e delegação de iteradores, fila de
pedidos de gerador assíncrono, contexto do host e 3.000 funções pendentes. Um
teste com WeakMap verifica que iteradores concluídos deixam de reter seus locais.

```powershell
./test.ps1
C:/Odin/dist/odin.exe check .
```

Passaram **2.329 testes de JS**, incluindo 18 regressões novas, e **3.767 testes
no gate completo**. `odin check .` também passou.

O navegador completo foi compilado com otimização em
`_local/builds/browser_continuations.exe`. Um smoke test nesse executável
validou retomada de `await` e `return` atravessando um `finally` com `yield`,
com veredito `__262__ status=pass rec=0`.

Na união de três seleções do Test262, sem contar variantes repetidas, foram
comparadas **1.871 variantes de 1.092 arquivos** do upstream
`2a1ade303f72d3de80565c921d685222405c32ce`. A seleção reúne as features
generators/async-functions/async-iteration/top-level-await, todos os testes de
módulo da amostra e caminhos que contêm async ou generator.

Resultado: **1.169 → 1.209 PASS**, **647 → 607 FAIL**, **2 ERROR** e **53 SKIP**.
Foram **40 FAIL→PASS e zero regressões**. Os dois ERROR são timeouts já
existentes em `Array/fromAsync/asyncitems-arraylike-too-long.js`, nas variantes
normal e estrita. Ainda há 607 falhas nessa seleção; a suíte inteira não foi
reexecutada e o baseline geral não foi substituído.

O [resumo](../tests/test262-measurements/summary-continuations-20261124.json)
registra contagens e hashes; os resultados
[anteriores](../tests/test262-measurements/continuations-before-20261124.json.gz)
e [novos](../tests/test262-measurements/continuations-20261124.json.gz) preservam
cada variante e seu veredito.

Para reproduzir a seleção a partir de uma cópia completa da amostra fixada:

```powershell
./tools/fetch-test262.ps1 -Revision 2a1ade303f72d3de80565c921d685222405c32ce -PerDir 10 -OutDir _local/test262-continuations
Copy-Item tests/test262-measurements/manifest-continuations-20261124.json _local/test262-continuations/manifest.json
C:/Odin/dist/odin.exe build tools/js262 -o:speed -out:_local/builds/js262-continuations.exe '-extra-linker-flags:/STACK:1073741824'
python tools/test262-run.py --suite _local/test262-continuations --browser _local/builds/js262-continuations.exe --timeout 5 --jobs 4 --baseline tests/test262-measurements/continuations-before-20261124.json.gz --report _local/reports/continuations-recheck.json
```

O runner retorna 1 enquanto houver FAIL ou ERROR conhecidos. A comparação
relevante para esta mudança é a lista de transições por nome e variante.

Na entrega de 24/11 a execução síncrona ainda era recursiva. A extensão de
25/11 em `sync_execution.odin` passa chamadas entre funções JS para o mesmo
trampoline, incluindo retornos, exceções, parâmetros padrão e `call`/`apply`/`bind`.
Subárvores sem chamadas e reentradas por código nativo ainda usam o avaliador
existente. A reserva de stack e suas guardas continuam necessárias. O GC mantém
seus pontos seguros no host; isso não é uma VM de bytecode nem um JIT.
Detalhes e medição da extensão: [JS-SYNC-EXECUTION.md](JS-SYNC-EXECUTION.md).
