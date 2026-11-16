# Execução assíncrona de JavaScript

Funções `async` e geradores `async function*` usam a máquina de corrotinas de
`src/js/generator.odin`. Cada corpo mantém sua pilha em uma thread, com troca
de controle por semáforos: somente uma thread executa JavaScript por vez.

Programas com `await` ou `for await` de topo também usam essa máquina, mantendo
o ambiente global ou de módulo original. `vm_exec` e `vm_run` devolvem uma
Promise de conclusão quando o programa suspende; código sem suspensão mantém
seu valor de conclusão síncrono. O checkpoint pode concluir a Promise antes
de `vm_run` retornar, mas timers só avançam pelo event loop do hospedeiro.

Cada módulo possui uma Promise de avaliação. `import()` só entrega seu
namespace depois da conclusão do corpo; imports estáticos e reexports aguardam
as dependências. Todas as dependências estáticas diretas começam antes de o
importador aguardar qualquer uma delas. Ciclos estáticos usam o namespace
parcial dos ancestrais; uma rejeição da avaliação rejeita os importadores.

`await_value` suspende a corrotina sem bombear timers ou aguardar a rede. O
driver registra uma reação na Promise aguardada e devolve o controle ao
chamador. A reação retoma o corpo no checkpoint de microtasks; rejeições são
injetadas como exceções no ponto do `await`.

O mesmo caminho atende `await`, `for await`, valores emitidos por geradores
assíncronos e delegação com `yield*`. Cada gerador assíncrono mantém uma fila
FIFO de pedidos `next`, `return` e `throw`. Um pedido permanece pendente durante
os awaits internos e só termina quando o corpo emite um valor, retorna ou lança.
O fechamento de um `for await` aguarda o método `return` do iterador, inclusive
quando o corpo sai por exceção.

Promises nativas recebem a reação de retomada diretamente, evitando um job de
adoção extra que alteraria a ordem com `queueMicrotask`. Para thenables, o getter
`then` é lido imediatamente e a chamada ao método é enfileirada como microtask.

## Limites atuais

- Não há espera bloqueante nem timeout artificial para `await`. Uma Promise
  nunca resolvida mantém sua execução suspensa até o descarte da VM.
- A engine continua tolerando `await` no topo de scripts clássicos como extensão.
  Isso não equivale a implementar todas as regras de sintaxe e instanciação
  de módulos do ECMAScript, incluindo a TDZ de exports em ciclos.
- Cada corrotina suspensa conserva uma thread e uma pilha nativas. Não há
  paralelismo de JavaScript; muitos corpos pendentes ainda consomem recursos.
- O event loop do hospedeiro continua responsável por avançar timers e rede e
  executar checkpoints. Suspender não faz uma Promise pendente resolver sozinha.

## Validação

`src/js/js_async_suspend_test.odin` cobre resolução posterior à chamada, FIFO de
microtasks, thenables, rejeições, pedidos concorrentes ao gerador, timers,
fechamento assíncrono, delegação e descarte de corrotinas pendentes.
`src/js/js_top_await_test.odin` cobre suspensão de programas, timers controlados
pelo hospedeiro, grafo de módulos, dependências irmãs, ciclos, reexports,
rejeições e retomada por scripts posteriores sem timeout.

```powershell
& C:\Odin\dist\odin.exe test src/js -define:ODIN_TEST_THREADS=1
```
