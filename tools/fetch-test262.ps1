# Baixa o harness + um subconjunto CURADO do Test262 (suite oficial do ECMAScript,
# tc39/test262). A curadoria mira exatamente as areas que o nosso motor JS diz
# suportar (ver roadmap M1-M74): iteradores, Array/String/Object, Map/Set, Symbol,
# Proxy/Reflect, TypedArray, Date, JSON, etc. Areas nao suportadas (BigInt, modulos,
# async-generators) ficam de fora para o placar de PASS ser honesto.
#
# Uso:  .\tools\fetch-test262.ps1              (conjunto padrao)
#       .\tools\fetch-test262.ps1 -PerDir 40   (mais testes por pasta)
#
# Saida:
#   tests\test262\harness\*.js        (assert.js, sta.js, propertyHelper.js, ...)
#   tests\test262\test\<area>\*.js    (espelha o caminho do repo)

param(
    [int]$PerDir = 25
)

$ErrorActionPreference = "Stop"
$root    = Split-Path $PSScriptRoot -Parent
$outRoot = Join-Path $root "tests\test262"
$rawBase = "https://raw.githubusercontent.com/tc39/test262/main"
$apiBase = "https://api.github.com/repos/tc39/test262/contents"
$UA      = @{ "User-Agent" = "odin-browser-test262-fetch" }

# Pastas de test/ a amostrar (caminho no repo tc39/test262, sem o "test/" inicial).
# Escolhidas por casarem com features JA implementadas no motor.
$areas = @(
    "built-ins/Array/prototype/map",
    "built-ins/Array/prototype/filter",
    "built-ins/Array/prototype/reduce",
    "built-ins/Array/prototype/forEach",
    "built-ins/Array/prototype/Symbol.iterator",
    "built-ins/Array/from",
    "built-ins/Array/of",
    "built-ins/Object/defineProperty",
    "built-ins/Object/getOwnPropertyDescriptor",
    "built-ins/Object/keys",
    "built-ins/Object/assign",
    "built-ins/Object/entries",
    "built-ins/Map/prototype/set",
    "built-ins/Map/prototype/get",
    "built-ins/Map/prototype/forEach",
    "built-ins/Set/prototype/add",
    "built-ins/Set/prototype/forEach",
    "built-ins/Symbol/iterator",
    "built-ins/Reflect/get",
    "built-ins/Reflect/has",
    "built-ins/Reflect/ownKeys",
    "built-ins/Proxy/get",
    "built-ins/Proxy/set",
    "built-ins/Proxy/has",
    "built-ins/String/prototype/slice",
    "built-ins/String/prototype/split",
    "built-ins/String/prototype/replace",
    "built-ins/String/prototype/includes",
    "built-ins/JSON/parse",
    "built-ins/JSON/stringify",
    "built-ins/Number/prototype/toFixed",
    "built-ins/Math/max",
    "built-ins/Date/prototype/setFullYear",
    "built-ins/Date/prototype/getTime",
    "built-ins/TypedArray/prototype/set",
    "built-ins/TypedArrayConstructors/ctors/buffer-arg",
    "language/statements/for-of",
    "language/expressions/optional-chaining",
    "language/expressions/spread",
    "language/statements/class/definition"
)

# Features que o motor NAO suporta -> pula qualquer teste que as exija (frontmatter
# `features:`). Mantem o placar honesto (roadmap: gaps abertos M74).
$unsupportedFeatures = @(
    "BigInt", "async-iteration", "generators", "async-functions",
    "class-static-block", "new.target", "regexp-lookbehind",
    "regexp-match-indices", "regexp-named-groups", "regexp-unicode-property-escapes",
    "Array.prototype.flat", "SharedArrayBuffer", "Atomics", "Temporal",
    "tail-call-optimization", "IsHTMLDDA", "decorators", "import-assertions",
    "resizable-arraybuffer", "array-grouping", "Array.fromAsync"
)

$UAheaders = $UA

function Download-Raw($repoPath) {
    try {
        return (Invoke-WebRequest -Uri "$rawBase/$repoPath" -Headers $UAheaders -UseBasicParsing -TimeoutSec 30).Content
    } catch { return $null }
}

function List-Dir($repoPath) {
    try {
        return Invoke-RestMethod -Uri "$apiBase/$repoPath" -Headers $UAheaders -TimeoutSec 30
    } catch {
        Write-Host "  listagem falhou ($repoPath): $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

# Extrai o bloco de frontmatter /*--- ... ---*/ (YAML simplificado).
function Get-Frontmatter($js) {
    $m = [regex]::Match($js, '/\*---(.*?)---\*/', 'Singleline')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

# Le uma lista YAML inline [a, b] OU em bloco (- a) de uma chave. Devolve string[].
function Get-YamlList($fm, $key) {
    $out = @()
    $inline = [regex]::Match($fm, "(?m)^\s*$key\s*:\s*\[(.*?)\]")
    if ($inline.Success) {
        foreach ($p in ($inline.Groups[1].Value -split ',')) {
            $t = $p.Trim(); if ($t) { $out += $t }
        }
        return $out
    }
    # forma em bloco: "flags:\n  - a\n  - b"
    $block = [regex]::Match($fm, "(?ms)^\s*$key\s*:\s*\n((?:\s*-\s*.*\n?)+)")
    if ($block.Success) {
        foreach ($line in ($block.Groups[1].Value -split "`n")) {
            $lm = [regex]::Match($line, '^\s*-\s*(.+?)\s*$')
            if ($lm.Success) { $out += $lm.Groups[1].Value.Trim() }
        }
    }
    return $out
}

New-Item -ItemType Directory -Force -Path $outRoot | Out-Null

# --- 1) harness completo (todos os .js de harness/) ---
Write-Host "`n=== harness ===" -ForegroundColor Cyan
$harnessDir = Join-Path $outRoot "harness"
New-Item -ItemType Directory -Force -Path $harnessDir | Out-Null
$hcount = 0
foreach ($f in (List-Dir "harness")) {
    if ($f.type -ne 'file' -or $f.name -notmatch '\.js$') { continue }
    $c = Download-Raw "harness/$($f.name)"
    if ($c) {
        [System.IO.File]::WriteAllText((Join-Path $harnessDir $f.name), $c)
        $hcount++
    }
}
Write-Host "  $hcount arquivos de harness" -ForegroundColor Green

# --- 2) testes curados ---
$totalKept = 0; $totalSkip = 0
foreach ($area in $areas) {
    Write-Host "`n=== $area ===" -ForegroundColor Cyan
    $listing = List-Dir "test/$area"
    $files = $listing | Where-Object {
        $_.type -eq 'file' -and $_.name -match '\.js$' -and $_.name -notmatch '_FIXTURE\.js$'
    }
    $kept = 0
    foreach ($c in $files) {
        if ($kept -ge $PerDir) { break }
        $js = Download-Raw "test/$area/$($c.name)"
        if (-not $js) { continue }

        $fm = Get-Frontmatter $js
        if ($fm) {
            $flags    = Get-YamlList $fm 'flags'
            $features = Get-YamlList $fm 'features'
            # pula o que o runner nao sabe conduzir / o motor nao suporta
            if ($flags -contains 'module' -or $flags -contains 'async' -or $flags -contains 'CanBlockIsFalse' -or $flags -contains 'CanBlockIsTrue') { $totalSkip++; continue }
            $blocked = $false
            foreach ($ft in $features) { if ($unsupportedFeatures -contains $ft) { $blocked = $true; break } }
            if ($blocked) { $totalSkip++; continue }
        }

        $dest = Join-Path $outRoot ("test/$area/$($c.name)" -replace '/','\')
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        [System.IO.File]::WriteAllText($dest, $js)
        $kept++; $totalKept++
    }
    Write-Host "  + $kept testes" -ForegroundColor Green
}

Write-Host ("`nTotal: {0} testes ({1} pulados por flag/feature) em {2}" -f $totalKept, $totalSkip, $outRoot) -ForegroundColor Cyan
Write-Host "Rode:  .\test262.ps1" -ForegroundColor Cyan
