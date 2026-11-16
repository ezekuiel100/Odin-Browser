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
