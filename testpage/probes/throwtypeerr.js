var r = 'NO_THROW';
try { null.x; r = 'IMPOSSIVEL'; } catch(e){ r = 'SYNTAX_OK'; }
console.log(r);
