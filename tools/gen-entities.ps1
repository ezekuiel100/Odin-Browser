# Gera src/html/entities_gen.odin a partir do entities.json oficial da WHATWG
# (https://html.spec.whatwg.org/entities.json). Emite o conjunto COMPLETO de
# referencias de caractere nomeadas do HTML5 terminadas em ';' (2125), ORDENADO
# por nome byte-wise (ordinal) para casar com o operador '<' de string do Odin
# na busca binaria de named_entity().
#
# Uso:  .\tools\gen-entities.ps1
# Reproduzivel: rode de novo quando a spec mudar.

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$out  = Join-Path $root "src\html\entities_gen.odin"
$url  = "https://html.spec.whatwg.org/entities.json"
$UA   = @{ "User-Agent" = "odin-browser-entities-gen" }

Write-Host "baixando $url ..." -ForegroundColor Cyan
$raw = (Invoke-WebRequest -Uri $url -Headers $UA -UseBasicParsing -TimeoutSec 60).Content

Add-Type -AssemblyName System.Web.Extensions
$js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$js.MaxJsonLength = [int]::MaxValue
$dict = $js.DeserializeObject($raw)

# TODAS as chaves (sem o '&' inicial; MANTEM o ';' final quando existe). O ';'
# faz parte da chave para o longest-match distinguir "&amp" (legado) de "&amp;".
$names = New-Object System.Collections.Generic.List[string]
foreach ($k in $dict.Keys) { $names.Add($k.Substring(1)) }
$arr = $names.ToArray()
[Array]::Sort($arr, [System.StringComparer]::Ordinal)   # byte-wise = '<' do Odin

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("package html")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("// GERADO por tools/gen-entities.ps1 -- NAO editar a mao.")
[void]$sb.AppendLine("// Conjunto COMPLETO de referencias de caractere nomeadas do HTML5 ($($arr.Count)),")
[void]$sb.AppendLine("// de https://html.spec.whatwg.org/entities.json. Inclui as formas COM e SEM ';'")
[void]$sb.AppendLine("// (o ';' faz parte da chave) p/ o longest-match de decode_entities distinguir")
[void]$sb.AppendLine("// '&amp' de '&amp;'. ORDENADO byte-wise p/ a busca binaria. b==0 => 1 codepoint.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("@(private)")
[void]$sb.AppendLine("Entity :: struct { name: string, a: rune, b: rune }")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("@(private)")
[void]$sb.AppendLine("entity_table := [?]Entity{")

$astral = 0; $two = 0
foreach ($name in $arr) {
    $cp = $dict["&$name"].codepoints
    $a = [int]$cp[0]
    $b = if ($cp.Count -ge 2) { [int]$cp[1] } else { 0 }
    if ($cp.Count -ge 2) { $two++ }
    if ($a -gt 0xFFFF -or $b -gt 0xFFFF) { $astral++ }
    # concatenacao explicita: um format-item '{N:X4}' colado a '}}' confunde o -f
    [void]$sb.AppendLine('    {"' + $name + '", 0x' + $a.ToString("X4") + ', 0x' + $b.ToString("X4") + '},')
}
[void]$sb.AppendLine("}")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("// Busca binaria (a tabela esta ordenada byte-wise). Devolve ate 2 runes.")
[void]$sb.AppendLine("@(private)")
[void]$sb.AppendLine("named_entity :: proc(name: string) -> (a: rune, b: rune, ok: bool) {")
[void]$sb.AppendLine("    lo, hi := 0, len(entity_table)")
[void]$sb.AppendLine("    for lo < hi {")
[void]$sb.AppendLine("        mid := (lo + hi) / 2")
[void]$sb.AppendLine("        e := entity_table[mid]")
[void]$sb.AppendLine("        if e.name == name do return e.a, e.b, true")
[void]$sb.AppendLine("        if e.name < name { lo = mid + 1 } else { hi = mid }")
[void]$sb.AppendLine("    }")
[void]$sb.AppendLine("    return 0, 0, false")
[void]$sb.AppendLine("}")

[System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("gerado {0}" -f $out) -ForegroundColor Green
Write-Host ("  {0} entidades ({1} de 2 codepoints, {2} com codepoint astral >U+FFFF)" -f $arr.Count, $two, $astral) -ForegroundColor DarkGray
Write-Host "  ATENCAO: sanitize_text descarta runes astral -> essas $astral ainda darao DIFF no tokenizer." -ForegroundColor DarkGray
