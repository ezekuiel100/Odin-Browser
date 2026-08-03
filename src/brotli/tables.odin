package brotli

// GERADO por tools/brotli-tables.py a partir do texto da RFC 7932.
// NAO EDITAR A MAO. A RFC publica o CRC-32 de cada uma destas tabelas
// (apendices A e B, secao 7.1) e brotli_test.odin os reconfere, entao
// um valor trocado aqui derruba o teste em vez de corromper a saida.
//
// @(rodata) e nao `::`: uma CONSTANTE de Odin nao tem endereco e por isso
// nao pode ser indexada por valor de RUNTIME (`Cannot index a constant`),
// que e como todas estas sao usadas. O @(rodata) da o endereco sem abrir
// mao da imutabilidade (mesmo tratamento de NDBITS em brotli.odin).

// As 121 transformacoes de palavra do dicionario (apendice B).
@(rodata)
TRANSFORMS := [121]Transform{
    {"", .Identity, ""}, // 0
    {"", .Identity, " "}, // 1
    {" ", .Identity, " "}, // 2
    {"", .OmitFirst1, ""}, // 3
    {"", .FermentFirst, " "}, // 4
    {"", .Identity, " the "}, // 5
    {" ", .Identity, ""}, // 6
    {"s ", .Identity, " "}, // 7
    {"", .Identity, " of "}, // 8
    {"", .FermentFirst, ""}, // 9
    {"", .Identity, " and "}, // 10
    {"", .OmitFirst2, ""}, // 11
    {"", .OmitLast1, ""}, // 12
    {", ", .Identity, " "}, // 13
    {"", .Identity, ", "}, // 14
    {" ", .FermentFirst, " "}, // 15
    {"", .Identity, " in "}, // 16
    {"", .Identity, " to "}, // 17
    {"e ", .Identity, " "}, // 18
    {"", .Identity, "\""}, // 19
    {"", .Identity, "."}, // 20
    {"", .Identity, "\">"}, // 21
    {"", .Identity, "\n"}, // 22
    {"", .OmitLast3, ""}, // 23
    {"", .Identity, "]"}, // 24
    {"", .Identity, " for "}, // 25
    {"", .OmitFirst3, ""}, // 26
    {"", .OmitLast2, ""}, // 27
    {"", .Identity, " a "}, // 28
    {"", .Identity, " that "}, // 29
    {" ", .FermentFirst, ""}, // 30
    {"", .Identity, ". "}, // 31
    {".", .Identity, ""}, // 32
    {" ", .Identity, ", "}, // 33
    {"", .OmitFirst4, ""}, // 34
    {"", .Identity, " with "}, // 35
    {"", .Identity, "'"}, // 36
    {"", .Identity, " from "}, // 37
    {"", .Identity, " by "}, // 38
    {"", .OmitFirst5, ""}, // 39
    {"", .OmitFirst6, ""}, // 40
    {" the ", .Identity, ""}, // 41
    {"", .OmitLast4, ""}, // 42
    {"", .Identity, ". The "}, // 43
    {"", .FermentAll, ""}, // 44
    {"", .Identity, " on "}, // 45
    {"", .Identity, " as "}, // 46
    {"", .Identity, " is "}, // 47
    {"", .OmitLast7, ""}, // 48
    {"", .OmitLast1, "ing "}, // 49
    {"", .Identity, "\n\t"}, // 50
    {"", .Identity, ":"}, // 51
    {" ", .Identity, ". "}, // 52
    {"", .Identity, "ed "}, // 53
    {"", .OmitFirst9, ""}, // 54
    {"", .OmitFirst7, ""}, // 55
    {"", .OmitLast6, ""}, // 56
    {"", .Identity, "("}, // 57
    {"", .FermentFirst, ", "}, // 58
    {"", .OmitLast8, ""}, // 59
    {"", .Identity, " at "}, // 60
    {"", .Identity, "ly "}, // 61
    {" the ", .Identity, " of "}, // 62
    {"", .OmitLast5, ""}, // 63
    {"", .OmitLast9, ""}, // 64
    {" ", .FermentFirst, ", "}, // 65
    {"", .FermentFirst, "\""}, // 66
    {".", .Identity, "("}, // 67
    {"", .FermentAll, " "}, // 68
    {"", .FermentFirst, "\">"}, // 69
    {"", .Identity, "=\""}, // 70
    {" ", .Identity, "."}, // 71
    {".com/", .Identity, ""}, // 72
    {" the ", .Identity, " of the "}, // 73
    {"", .FermentFirst, "'"}, // 74
    {"", .Identity, ". This "}, // 75
    {"", .Identity, ","}, // 76
    {".", .Identity, " "}, // 77
    {"", .FermentFirst, "("}, // 78
    {"", .FermentFirst, "."}, // 79
    {"", .Identity, " not "}, // 80
    {" ", .Identity, "=\""}, // 81
    {"", .Identity, "er "}, // 82
    {" ", .FermentAll, " "}, // 83
    {"", .Identity, "al "}, // 84
    {" ", .FermentAll, ""}, // 85
    {"", .Identity, "='"}, // 86
    {"", .FermentAll, "\""}, // 87
    {"", .FermentFirst, ". "}, // 88
    {" ", .Identity, "("}, // 89
    {"", .Identity, "ful "}, // 90
    {" ", .FermentFirst, ". "}, // 91
    {"", .Identity, "ive "}, // 92
    {"", .Identity, "less "}, // 93
    {"", .FermentAll, "'"}, // 94
    {"", .Identity, "est "}, // 95
    {" ", .FermentFirst, "."}, // 96
    {"", .FermentAll, "\">"}, // 97
    {" ", .Identity, "='"}, // 98
    {"", .FermentFirst, ","}, // 99
    {"", .Identity, "ize "}, // 100
    {"", .FermentAll, "."}, // 101
    {"\xc2\xa0", .Identity, ""}, // 102
    {" ", .Identity, ","}, // 103
    {"", .FermentFirst, "=\""}, // 104
    {"", .FermentAll, "=\""}, // 105
    {"", .Identity, "ous "}, // 106
    {"", .FermentAll, ", "}, // 107
    {"", .FermentFirst, "='"}, // 108
    {" ", .FermentFirst, ","}, // 109
    {" ", .FermentAll, "=\""}, // 110
    {" ", .FermentAll, ", "}, // 111
    {"", .FermentAll, ","}, // 112
    {"", .FermentAll, "("}, // 113
    {"", .FermentAll, ". "}, // 114
    {" ", .FermentAll, "."}, // 115
    {"", .FermentAll, "='"}, // 116
    {" ", .FermentAll, ". "}, // 117
    {" ", .FermentFirst, "=\""}, // 118
    {" ", .FermentAll, "='"}, // 119
    {" ", .FermentFirst, "='"}, // 120
}

// Tabelas de ID de contexto para os modos UTF8 e Signed (secao 7.1).
@(rodata)
LUT0 := [256]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 0, 0, 4, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    8, 12, 16, 12, 12, 20, 12, 16, 24, 28, 12, 12, 32, 12, 36, 12,
    44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 32, 32, 24, 40, 28, 12,
    12, 48, 52, 52, 52, 48, 52, 52, 52, 48, 52, 52, 52, 52, 52, 48,
    52, 52, 52, 52, 52, 48, 52, 52, 52, 52, 52, 24, 12, 28, 12, 12,
    12, 56, 60, 60, 60, 56, 60, 60, 60, 56, 60, 60, 60, 60, 60, 56,
    60, 60, 60, 60, 60, 56, 60, 60, 60, 60, 60, 24, 12, 28, 12, 0,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
    2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3,
    2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3,
    2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3,
    2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3,
}

@(rodata)
LUT1 := [256]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1,
    1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1,
    1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 1, 1, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
}

@(rodata)
LUT2 := [256]u8{
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7,
}

