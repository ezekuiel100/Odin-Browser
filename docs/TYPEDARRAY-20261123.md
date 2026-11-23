# TypedArray, DataView e ArrayBuffer — 2026-11-23

Implementados BigInt64Array, BigUint64Array e Float16Array, os acessores correspondentes de DataView, ArrayBuffer redimensionável, resize, transfer e transferToFixedLength. As operações com BigInt preservam os 64 bits sem conversão para Number. Float16 arredonda diretamente de binary64 com empates para o par. Views fixas recuperam seu tamanho após o buffer crescer; views de comprimento automático acompanham o buffer. Transferência destaca as views antigas.

Comparação das mesmas 2.951 variantes do baseline de 2026-11-22, upstream `2a1ade303f72d3de80565c921d685222405c32ce`, seleção de dez arquivos por diretório. Manifest SHA-256 `6e20cdce7ed5ebb46a3d44c51d1100cdc1ec78fa32ab90f074788faed47d623c`. A variante annexB que contém TypedArray no nome é excluída desta contagem.

| Família | FAIL antes | FAIL depois | PASS depois | ERROR depois | SKIP depois |
|---|---:|---:|---:|---:|---:|
| TypedArray | 1035 | 617 | 683 | 0 | 0 |
| TypedArrayConstructors | 561 | 317 | 532 | 0 | 34 |
| DataView | 292 | 46 | 462 | 0 | 0 |
| ArrayBuffer | 220 | 80 | 180 | 0 | 0 |

Total: **2.108 → 1060 FAIL**, 1048 variantes corrigidas, sem regressões de PASS. Ainda há falhas de conformidade; isto não significa suporte completo dessas famílias. O baseline geral não foi substituído e a suíte inteira não foi medida novamente.

Validação: **2.303 testes unitários de JS passaram**, incluindo onze novos testes; `odin check .` passou. Testes novos cobrem precisão BigInt, coerções e mistura de tipos, métodos, arredondamento Float16, endianness, limites, resize durante callbacks, recuperação de views, subclasses, transferência e detach.

Resultados por variante, alterações e hash do executável estão em [typedarray-20261123.json.gz](../tests/test262-measurements/typedarray-20261123.json.gz).

Reprodução no Windows (com a seleção expandida correspondente ao manifesto acima):

```powershell
C:/Odin/dist/odin.exe test src/js
C:/Odin/dist/odin.exe check .
C:/Odin/dist/odin.exe build tools/js262 -out:_local/builds/typedarray.exe -o:speed '-extra-linker-flags:/STACK:1073741824'
foreach ($family in @('TypedArray', 'ArrayBuffer', 'DataView')) {
    python tools/test262-run.py --suite _local/test262-expanded-10 --browser _local/builds/typedarray.exe --filter "built-ins/$family" --timeout 5 --jobs 4 --report "_local/reports/$family.json"
}
```
