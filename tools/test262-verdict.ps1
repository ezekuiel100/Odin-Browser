# Pure helpers of the Test262 runner, also exercised by tests/test262-runner.ps1.

# negative: { phase: parse|resolution|runtime, type: TypeError }
# Reads the block LINE BY LINE: the indented lines right below `negative:`.
# The old regex, `(?:\s+\w+\s*:\s*\S+\s*\n?)+`, ended each repetition with `\s*`,
# which ate the NEXT line's indentation; the 2nd repetition then failed and only
# `phase:` was captured -- every negative test became an ERROR with no `type`.
function Get-Negative($fm) {
    $blk = [regex]::Match($fm, '(?m)^negative[ \t]*:[ \t]*\r?\n((?:[ \t]+\S[^\r\n]*(?:\r?\n|$))+)')
    if (-not $blk.Success) { return $null }
    $body  = $blk.Groups[1].Value
    $phase = [regex]::Match($body, '(?m)^[ \t]+phase[ \t]*:[ \t]*(\S+)')
    $type  = [regex]::Match($body, '(?m)^[ \t]+type[ \t]*:[ \t]*(\S+)')
    return @{
        Phase = if ($phase.Success) { $phase.Groups[1].Value } else { "" }
        Type  = if ($type.Success)  { $type.Groups[1].Value }  else { "" }
    }
}

# Pure verdict predicate.
function Test-NegativeVerdict($negative, $threw, $name, $phase, $sourceIndex, $testIndex, $rec) {
    return $threw -and $name -ceq $negative.Type -and $phase -ceq $negative.Phase -and
                $sourceIndex -eq $testIndex -and $rec -eq 0 -and
                $negative.Phase -in @('parse', 'resolution', 'runtime') -and
                ($negative.Phase -ne 'parse' -or $name -ceq 'SyntaxError')
}
