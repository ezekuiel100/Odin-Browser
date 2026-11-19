$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/test262-verdict.ps1')
$parse = @{ Phase = 'parse'; Type = 'SyntaxError' }
$runtime = @{ Phase = 'runtime'; Type = 'TypeError' }
$cases = @(
    @($parse, $true, 'SyntaxError', 'parse', 2, 2, 0, $true),
    @($parse, $true, 'TypeError', 'parse', 2, 2, 0, $false),
    @($parse, $true, 'SyntaxError', 'runtime', 2, 2, 0, $false),
    @($parse, $false, '', '', -1, 2, 1, $false),
    @($parse, $true, 'SyntaxError', 'parse', 0, 2, 0, $false),
    @($parse, $true, 'SyntaxError', 'parse', 2, 2, 1, $false),
    @($runtime, $true, 'TypeError', 'runtime', 2, 2, 0, $true),
    @($runtime, $true, 'TypeError', '', -1, 2, 0, $false),
    @($runtime, $true, 'SyntaxError', 'runtime', 2, 2, 0, $false)
)
foreach ($c in $cases) {
    $actual = Test-NegativeVerdict $c[0] $c[1] $c[2] $c[3] $c[4] $c[5] $c[6]
    if ($actual -ne $c[7]) { throw "Unexpected verdict: $c" }
}
Write-Host "$($cases.Count) verdict regression cases passed"

# Get-Negative: the `negative:` block as Test262 writes it (indented keys, more
# keys after it). Expected @(Phase, Type), or $null for "no negative block".
$nl = "`n"
$negCases = @(
    @(("description: x" + $nl + "negative:" + $nl + "  phase: parse" + $nl + "  type: SyntaxError" + $nl + "info: |" + $nl + "    Foo : Bar" + $nl), @('parse', 'SyntaxError')),
    @(("negative:" + $nl + "  type: TypeError" + $nl + "  phase: runtime" + $nl + "flags: [onlyStrict]" + $nl), @('runtime', 'TypeError')),
    @(("flags: [raw]" + $nl + "negative:" + $nl + "  phase: resolution" + $nl + "  type: SyntaxError" + $nl), @('resolution', 'SyntaxError')),
    @(("negative:" + $nl + "  phase: parse" + $nl + "  type: SyntaxError"), @('parse', 'SyntaxError')),
    @(("negative:`r`n  phase: parse`r`n  type: SyntaxError`r`nflags: [x]`r`n"), @('parse', 'SyntaxError')),
    @(("negative:" + $nl + "  phase: parse" + $nl + "info: |" + $nl + "  type: Wrong" + $nl), @('parse', '')),
    @(("description: no negative here" + $nl + "info: |" + $nl + "  negative: phase" + $nl), $null)
)
foreach ($c in $negCases) {
    $got = Get-Negative $c[0]
    if ($null -eq $c[1]) {
        if ($null -ne $got) { throw "Get-Negative should be null for: $($c[0])" }
        continue
    }
    if ($null -eq $got -or $got.Phase -cne $c[1][0] -or $got.Type -cne $c[1][1]) {
        throw "Get-Negative: want $($c[1] -join '/'), got $($got.Phase)/$($got.Type) for: $($c[0])"
    }
}
Write-Host "$($negCases.Count) negative-frontmatter cases passed"
