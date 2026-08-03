// Repro do modulo que importa a SI MESMO -- a forma que todo bundle rspack/webpack
// emite (o modulo le o proprio namespace para achar a tabela de ids).
//
// Dois defeitos medidos em 2026-07-28, os dois visiveis so por HTTP:
//   1. o corpo do modulo e AVALIADO DUAS VEZES (script inline/classico roda 1x)
//   2. na 1a avaliacao o namespace vem VAZIO (Object.keys(self) == [])
//
// Saida esperada quando estiver CORRIGIDO: uma unica linha MODPROBE, com ns ok.
export var TABELA = { k: 1 };
import * as self from './probe_module_a.js';
export function ler() {
  if (self.TABELA) { return 'ns ok: ' + JSON.stringify(self.TABELA); }
  return 'ns VAZIO (self.TABELA undefined)';
}
console.log('MODPROBE eval self-import: ' + ler());
console.log('MODPROBE chaves do ns: [' + Object.keys(self).join(',') + ']');
