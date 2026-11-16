# Execução assíncrona de JavaScript

Funções `async` e geradores `async function*` usam a máquina de corrotinas de
`src/js/generator.odin`. Cada corpo mantém sua pilha em uma thread, com troca
de controle por semáforos: somente uma thread executa JavaScript por vez.

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

- `await` no topo, fora de uma corrotina, ainda usa
  `promise_await_blocking`, com pump aninhado e timeout de compatibilidade.
  A avaliação assíncrona do grafo de módulos ES ainda precisa de uma mudança
  própria no carregador; esta implementação não resolve top-level await.
- Cada corrotina suspensa conserva uma thread e uma pilha nativas. Não há
  paralelismo de JavaScript; muitos corpos pendentes ainda consomem recursos.
- O event loop do hospedeiro continua responsável por avançar timers e rede e
  executar checkpoints. Suspender não faz uma Promise pendente resolver sozinha.

## Validação

`src/js/js_async_suspend_test.odin` cobre resolução posterior à chamada, FIFO de
microtasks, thenables, rejeições, pedidos concorrentes ao gerador, timers,
fechamento assíncrono, delegação e descarte de corrotinas pendentes.

```powershell
& C:\Odin\dist\odin.exe test src/js -define:ODIN_TEST_THREADS=1
```
