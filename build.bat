@echo off
rem Comentarios em ASCII puro: acentos aqui quebram em alguns codepages do cmd.
set ODIN=C:\Odin\dist\odin.exe
set SDL2_LIB=C:\Odin\dist\vendor\sdl2\SDL2.lib
rem /STACK:1GB -- o interpretador JS e tree-walking (cada chamada JS = varios
rem frames nativos, e o React gasta MUITO por chamada). A stack padrao de 1MB do
rem Windows estoura em ~85 niveis e FECHA o navegador (0xC00000FD). Sites React
rem reais (tradebig) recursionam fundo com frames pesados: 256MB nao bastava, 1GB
rem sim. Reserva e so espaco de endereco (commit preguicoso), barata no x64. Vale
rem p/ a thread principal E as workers (CreateThread com stackSize=0 herda a
rem reserva do PE header). Alem disso ha a guarda por ponteiro (stack_guard.odin)
rem que converte overflow em RangeError capturavel. NAO builde sem /STACK.
rem
rem -o:speed -- OBRIGATORIO p/ sites reais. O interpretador de debug roda a
rem ~2500 evals/seg (50-100x mais lento); um SPA React (tradebig/ultra-photo) NAO
rem termina de renderizar a tempo e a pagina fica BRANCA -- parece um bug do motor
rem mas e so lentidao do build. Com -o:speed tradebig=11 caixas, ultra-photo=130.
rem Para depurar o MOTOR (mensagens do React DEV, etc.) builde a mao sem -o:speed.
%ODIN% build . -out:browser.exe -o:speed -extra-linker-flags:"%SDL2_LIB% /STACK:1073741824" %*
