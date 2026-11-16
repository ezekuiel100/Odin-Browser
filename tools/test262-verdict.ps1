# Pure verdict predicate, also exercised by tests/test262-runner.ps1.
function Test-NegativeVerdict($negative, $threw, $name, $phase, $sourceIndex, $testIndex, $rec) {
    return $threw -and $name -ceq $negative.Type -and $phase -ceq $negative.Phase -and
                $sourceIndex -eq $testIndex -and $rec -eq 0 -and
                $negative.Phase -in @('parse', 'resolution', 'runtime') -and
                ($negative.Phase -ne 'parse' -or $name -ceq 'SyntaxError')
}
