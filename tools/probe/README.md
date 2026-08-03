# Sonda de capacidade do motor JS

Mede **o que a engine entrega para o código que um site real escreve**, feature a
feature. Complementa as outras suítes em vez de repeti-las:

| suíte | mede |
|---|---|
| Test262 (`test262.ps1`) | conformidade da linguagem contra a spec — e boa parte do FAIL lá é metadata pedante, não bug |
| WPT (`wpt-reftest.ps1`) | layout/CSS |
| **esta** | se a API que a página chama devolve o que ela espera |

## Por que ela existe

O achado que justifica o formato (auditoria de 2026-07-28): **o grosso do que falta
não lança TypeError — é stub que devolve valor neutro.** À época: `getComputedStyle`
devolvia `""` para tudo, `getBoundingClientRect` devolvia zero, e os três observers
nunca disparavam. A página não quebra: ela fica **errada em silêncio**, e nem
`js_uncaught` nem o console acusam. (Os três primeiros foram fechados —
`getComputedStyle` no M199, geometria no M200, MutationObserver no M201. Resize e
Intersection Observer continuam stub.)

Por isso cada teste **exercita a API e confere o resultado**. Sonda por
`typeof x === 'function'` marca os quatro stubs acima como OK — foi exatamente o erro
da auditoria anterior (2026-07-20), que deu MutationObserver/IntersectionObserver/
ResizeObserver/getComputedStyle como prontos.

## Rodar

```
.\tools\probe\probe.ps1                  # lang + dom + módulo, e diff vs baseline
.\tools\probe\probe.ps1 -Only lang       # só a linguagem (rápido, sem janela)
.\tools\probe\probe.ps1 -Dump            # valores CRUS (diagnóstico, não placar)
.\tools\probe\probe.ps1 -ShowOk          # lista também o que passou
.\tools\probe\probe.ps1 -Browser x.exe   # apontar para OUTRO binário (A/B)
.\tools\probe\probe.ps1 -WriteBaseline   # regravar baseline.txt
```

## Arquivos

| arquivo | o que é |
|---|---|
| `probe_lang.js` | placar da linguagem (258 checagens), roda por `--js262` — sem janela, sem RAM de render |
| `probe_dom.html` | placar do DOM/web (145 checagens), roda por `--render`. Tem duas seções: as síncronas (momento do script de carga) e a **`pos-layout`**, que repete num `setTimeout` o que só faz sentido depois do 1º layout — ou, no caso do MutationObserver, o que só chega na TAREFA seguinte |
| `probe_lang_dump.js` | diagnóstico: imprime o **valor cru** em vez de OK/BAD |
| `probe_dom_dump.html` | idem, e nas **3 fases** (parse / `setTimeout` / `rAF`) |
| `probe_module*.{html,js}` | repro do módulo que se auto-importa — **precisa de HTTP** |
| `baseline.txt` | o conjunto **nomeado** de gaps de hoje (105); é a autoridade do diff |
| `probe_now.txt` | o conjunto da última rodada (gerado; comparar com o baseline) |
| `out/` | PNG e stdout/stderr crus de cada invocação (gerado) |

## O veredito é o DIFF, não o placar

Não existe "tudo verde" aqui — **o placar É o inventário de gaps**. O que serve de
gate é o diff por NOME contra `baseline.txt`, mesma disciplina do
`wpt-baseline-fails.txt`: o script sai **1** se aparecer gap novo, e lista os
consertados quando some algum. Ao fechar um marco que mexeu no motor, rode e leia o
diff; se ele acusar consertos que você fez de propósito, regrave com
`-WriteBaseline`.

Placar de 2026-07-28: **298 OK / 94 BAD / 11 FAIL** (de 403), módulo em GAP.
Histórico curto: 282/387 antes do `getComputedStyle` real (M199) → 287/395 depois
dele → 294/400 com a geometria (M200) → 298/403 com o MutationObserver (M201). A
seção `pos-layout` está **16/16** — fechada.

## Cinco armadilhas já pagas

1. **`-Only lang` não faz diff.** Cobre só parte do conjunto nomeado; o script avisa
   e pula, em vez de acusar 57 "consertos" que são só ausência de medição.
2. **O repro de módulo só funciona por HTTP.** De `file://` o `<script src>` externo
   não carrega (só inline roda) e o teste dá falso-negativo silencioso. O
   `-Only module` sobe um `python -m http.server` e derruba no fim; sem python, ele
   diz SKIP em vez de fingir PASS.
3. **Medição de layout precisa das 3 fases.** Ler `getBoundingClientRect` só durante
   o parse não distingue "o layout ainda não rodou" de "é sempre 0" — hoje é sempre
   0, e isso só ficou provado medindo também em `setTimeout` e `rAF`.
4. **Uma sonda que mede só o momento da CARGA não vê melhora nenhuma.** Quando o
   `getComputedStyle` passou a devolver valor real, o placar não se moveu: todos os
   checks liam durante o parse, a única janela que continua vazia (os scripts de
   carga rodam antes do 1º `compute_styles`). Foi por isso que nasceu a seção
   `pos-layout` — sem ela a sonda diria "nada mudou" sobre uma mudança grande.
5. **API de entrega ASSÍNCRONA não se confere na mesma tarefa.** O check
   `MutationObserver dispara` mutava e lia `n > 0` na linha seguinte — isso dá
   `records=0` **até no Chrome**, porque a entrega é no fim do microtask
   checkpoint. Ou seja: a sonda acusaria BAD contra qualquer motor, inclusive um
   correto, e o "conserto" apareceria como falso-positivo. Agora a mutação é feita
   no script de CARGA e a conferência no `setTimeout` — uma tarefa depois; o que dá
   para checar dentro da tarefa (`takeRecords`, que é síncrono por spec) tem check
   próprio. **Antes de escrever um check, pergunte em que tarefa a resposta chega.**
