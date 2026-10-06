function Convert-IW7IsolatedVoiceSource {
    param([Parameter(Mandatory)][string]$Source)
    $pch=[regex]::Matches($Source,'(?m)^#include <std_include\.hpp>\r?$')
    if ($pch.Count -ne 1 -or $pch[0].Index -ne 0 -or $Source -match '(?m)^\s*#\s*define\s+IW7_PARIS_ISOLATED_VOICE_CAPTURE\b') { throw 'Exact single leading PCH include and untransformed voice source required.' }
    $end=$pch[0].Length
    if ($end -ge $Source.Length -or $Source[$end] -ne "`n") { throw 'PCH include must end with a newline.' }
    $end++
    $Source.Substring(0,$end)+"#define IW7_PARIS_ISOLATED_VOICE_CAPTURE 1`n"+$Source.Substring($end)
}
