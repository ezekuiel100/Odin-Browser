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

Antes de iniciar dependências, a instanciação registra as chaves dos exports,
iça funções e inicializa `var` com `undefined`. Bindings de `let`, `const`,
classes e expressões `default` ficam na zona morta temporal (TDZ) até sua
declaração executar. Ler esses bindings por import, namespace ou `typeof`
lança `ReferenceError`, inclusive durante uma suspensão por `await`.
Imports e reexports mantêm o vínculo com o binding original.

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

MutationObserver agenda uma única microtask de notificação na primeira mutação
pendente. Essa microtask compartilha a FIFO de Promises, retomadas de `await`
e `queueMicrotask`. A entrega captura o conjunto de observadores pendentes na
ordem de sua primeira mutação e drena a fila de cada observador imediatamente
antes do callback. Mutações durante callbacks agendam outra notificação no fim
da FIFO; não há limite de quatro rodadas. `takeRecords` e `disconnect` esvaziam
records sem remover ou reposicionar a microtask já agendada.

## Limites atuais

- Não há espera bloqueante nem timeout artificial para `await`. Uma Promise
  nunca resolvida mantém sua execução suspensa até o descarte da VM.
- A engine continua tolerando `await` no topo de scripts clássicos como extensão.
  Isso não equivale a implementar todas as regras de sintaxe e ligação
  de módulos do ECMAScript, como resolução de ambiguidades de `export *`.
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
`src/js/js_module_ciclo_test.odin` cobre TDZ, funções e `var` em ciclos,
`default`, identidade de funções, reexports vivos e acesso durante `await`.
`src/js/js_m201_test.odin` cobre a FIFO compartilhada de MutationObserver,
entregas recursivas e desconexão durante a notificação.

```powershell
& C:\Odin\dist\odin.exe test src/js -define:ODIN_TEST_THREADS=1
```
