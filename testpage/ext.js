// Script EXTERNO carregado via <script src="ext.js">.
// Usa a global `antes` (definida pelo inline ANTERIOR) e define `depois`
// (usada pelo inline SEGUINTE) — prova a ordem de execução.
document.getElementById('alvo').textContent = 'carregado de ext.js (antes=' + antes + ')';
document.getElementById('alvo').classList.add('ok');
var depois = 'B';
