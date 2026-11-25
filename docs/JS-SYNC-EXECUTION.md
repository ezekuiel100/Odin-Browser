# Chamadas síncronas com frames explícitos — 2026-11-25

Chamadas entre funções JavaScript comuns passam pelo trampoline de
`continuation.odin`. `sync_execution.odin` registra entrada, parâmetros, corpo
e saída da função sem empilhar uma invocação nativa de `call_function` por nível.
Chamadas recursivas, métodos, templates marcados e construtores ordinários
compartilham os frames de operandos do chamador. Retornos e exceções passam pelos
handlers existentes, incluindo conclusões preservadas por `finally`.

Parâmetros padrão e padrões de desestruturação também usam esse executor.
`Function.prototype.call`, `apply` e cadeias de funções ligadas por `bind`
são encaminhados ao mesmo trampoline quando o alvo final é uma função síncrona
comum. O encaminhamento reconhece a identidade dos built-ins; métodos próprios
com esses nomes seguem seu comportamento normal. Os argumentos de `apply` são
copiados antes de executar o alvo, como no caminho nativo existente.

`Error.stack` usa frames de chamada com endereços estáveis no heap, separados do
array de operandos que pode realocar. A saída restaura fonte, posição e frame
do chamador e recicla ambientes apenas quando não houve escape de referências.
O armazenamento ocioso é limitado: até 1.024 frames de operandos e 1.024 registros
de chamada. Uma recursão profunda não deixa seu array inteiro retido entre tarefas.
Funções sem chamadas internas podem executar seu corpo diretamente no avaliador
existente, mantendo o registro de chamada e seu tratamento de saída.

## Validação

Passaram **2.340 testes de JS** e **3.778 no gate completo** (`./test.ps1`).
`odin check .` e a verificação do pacote com `JSPROF` e `MEMBERPROBE` também passaram.
Os onze testes novos em `src/js/js_sync_execution_test.odin` cobrem:

- 3.000 níveis de recursão não terminal, métodos mutuamente recursivos e `this`;
- `call`/`apply`/`bind` e chamadas em defaults/padrões de parâmetros;
- propagação de exceções, execução de `finally` e substituição de retornos;
- construtores recursivos e preservação de `new.target`;
- ordem dos argumentos e reentrada por callbacks nativos;
- closures e `arguments` preservados após coleta;
- limite lógico de chamadas, restauração do estado e reutilização da VM;
- chamadas profundas antes/depois de `await` e dentro de geradores.

Os onze testes também passam com `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.

Na mesma amostra completa do Test262, upstream
`2a1ade303f72d3de80565c921d685222405c32ce`, foram comparadas **21.056 variantes**
de 10.848 arquivos. Resultado bruto: **12.229 → 12.242 PASS**,
**8.445 → 8.432 FAIL**, **42 ERROR** e **340 SKIP**.

Houve 16 transições FAIL→PASS e três PASS→FAIL. As três quedas são testes de
`name` em `Array.prototype.toLocaleString`, `Object.prototype.toLocaleString`
e `Date.prototype.toUTCString`. Seis reexecuções por build confirmaram que esses
testes oscilam entre PASS e FAIL nos dois executáveis. Excluindo esses casos
instáveis, foram **16 FAIL→PASS e nenhuma regressão**. Os dois testes de
`TypedArray.copyWithin` com coerção/detach ainda podem abortar nativamente;
reexecuções confirmam que não foram corrigidos por esta mudança.

O [resumo](../tests/test262-measurements/summary-sync-20261125.json) registra
hashes, transições e reexecuções. Os relatórios completos
[anterior](../tests/test262-measurements/sync-before-20261125.json.gz) e
[novo](../tests/test262-measurements/sync-20261125.json.gz) mantêm cada variante.
O runner retorna 1 enquanto houver falhas conhecidas; estes números não são
um percentual de conformidade de uma edição do ECMAScript.

## Medição reproduzível

`tools/sync-bench` compara um controle do commit
`190cac74fc3884b930d83e1c03ca0084e69b2a4e` com esta implementação. Ambos usam o
mesmo fonte do benchmark e `-o:speed`. O cenário `recursion` faz uma soma após
cada chamada recursiva; amostra um endereço local nativo na primeira e na última
chamada. `nativeStackGrowthBytes` é a distância entre esses endereços, não a
memória privada do processo nem o tamanho total da stack.

```powershell
C:/Odin/dist/odin.exe build tools/sync-bench -o:speed -out:_local/builds/sync-bench.exe
./_local/builds/sync-bench.exe recursion 3000
./_local/builds/sync-bench.exe calls 100000
```

O cenário `calls` mede 100.000 chamadas rasas de uma função de soma. Os dois
cenários são microbenchmarks: não medem renderização nem desempenho de sites.

Medianas de sete processos novos por build, alternando a ordem de execução:

| Cenário | Antes | Depois |
|---|---:|---:|
| Recursão de 3.000 níveis, reserva padrão de 1 MiB | RangeError | conclui |
| Crescimento nativo entre as amostras, reserva de 1 GiB | 57.888.000 bytes | 0 bytes |
| Tempo da recursão com reserva de 1 GiB | 31,904 ms | 13,262 ms |
| Tempo de 100.000 chamadas rasas, reserva padrão | 59,371 ms | 69,327 ms |

A recursão medida usou cerca de 55,2 MiB a menos de crescimento de pilha e
terminou em menos tempo. Na carga rasa houve **aproximadamente 17% de custo
extra**. Portanto, a melhoria principal é a independência entre profundidade
de chamadas JS e pilha nativa; não há ganho universal de velocidade. O zero
na tabela significa ausência de crescimento entre as duas amostras, não uma
execução sem qualquer stack nativa.

Dados brutos, hashes e reservas de stack lidas dos executáveis PE estão em
[sync-benchmark-20261125.json](../tests/test262-measurements/sync-benchmark-20261125.json).

## Limites

O interpretador continua percorrendo a AST. Subárvores sem chamadas, código de
`eval`, inicializadores de classe e callbacks invocados por built-ins, getters,
coerções e proxies ainda podem usar/reentrar pela pilha nativa. As guardas de
stack e a reserva do build continuam necessárias. O teto lógico de 10.000
chamadas permanece para limitar recursão infinita no heap.

O GC continua coletando nos pontos seguros do host. Ter frames explícitos para
chamadas não torna temporários dos built-ins rastreáveis nem habilita coleta no
meio de uma tarefa síncrona. As regras de microtasks e suspensão permanecem as
de [JS-CONTINUATIONS.md](JS-CONTINUATIONS.md).
