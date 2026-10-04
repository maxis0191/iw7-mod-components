# The caller retains and disposes an already identity-verified process handle.
function Invoke-IW7OwnedStop($Handle, [scriptblock]$Request, [int]$TimeoutMs) {
    if (!$Handle -or !$Request -or $TimeoutMs -lt 1) { throw 'Invalid owned-stop request.' }
    $requestError = $null
    try { & $Request } catch { $requestError = $_.Exception.Message }
    $forced = $false
    if (!$Handle.HasExited -and ($requestError -or !$Handle.WaitForExit($TimeoutMs))) {
        $forced = $true
        $Handle.Terminate(3758096385)
    }
    if (!$Handle.WaitForExit(5000)) { throw 'Owned process termination is not confirmed; cleanup remains pending.' }
    $code = $Handle.get_ExitCode()
    [pscustomobject]@{Code=$code;Kind=$(if ($forced -or $requestError) {'forced'} elseif ($code -eq 0) {'clean'} else {'crash'});RequestError=$requestError}
}
