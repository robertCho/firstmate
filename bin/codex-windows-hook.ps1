param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('SessionStart', 'PreToolUse', 'Stop')]
    [string]$Event,
    [int]$Index = 0
)

$ErrorActionPreference = 'Stop'
$hookRoot = Split-Path $PSScriptRoot -Parent
$bashPath = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path -LiteralPath $bashPath)) {
    throw "Git Bash is missing: $bashPath"
}
$definitions = Get-Content -LiteralPath (Join-Path $hookRoot '.codex/hooks.json') -Raw | ConvertFrom-Json
$handlers = @($definitions.hooks.$Event | ForEach-Object { $_.hooks })
if ($Index -lt 0 -or $Index -ge $handlers.Count) { throw 'Invalid hook index' }
$command = $handlers[$Index].command
$prefix = "bash -lc '"
if (-not $command.StartsWith($prefix) -or -not $command.EndsWith("'")) {
    throw 'Expected the existing Firstmate Bash hook command'
}
$body = $command.Substring($prefix.Length, $command.Length - $prefix.Length - 1)

if ($Event -eq 'SessionStart') {
    # Keep the tracked registration checks, then hand the existing source router
    # to the first turn. The hook itself acquires no lock and starts no worker.
    $invoke = 'printf "%s" "$payload" | "$root/bin/fm-sessionstart-run.sh"'
    if (-not $body.EndsWith($invoke)) {
        throw 'Expected the existing Firstmate SessionStart invocation'
    }
    $handoff = @'
fm_windows_startup_handoff() {
    local fm_root fm_home fm_state source instruction
    fm_root=${FM_ROOT_OVERRIDE:-$root}
    fm_home=${FM_HOME:-$fm_root}
    fm_state=${FM_STATE_OVERRIDE:-$fm_home/state}
    . "$root/bin/fm-gate-refuse-lib.sh"
    . "$root/bin/fm-primary-scope-lib.sh"
    . "$root/bin/fm-hook-host-lib.sh"
    . "$root/bin/fm-operational-input.sh"
    fm_is_gate_agent "$fm_root" && return 0
    fm_primary_scope_matches "$fm_root" "$fm_state" || return 0
    fm_hook_payload_is_foreign_host "$payload" && return 0
    source=$(printf '%s' "$payload" | jq -r 'if type == "object" and (.source | type == "string") then .source else "startup" end' 2>/dev/null) || source=startup
    case "$source" in
        startup|new|clear|compact|resume|reload|fork) ;;
        *) source=startup ;;
    esac
    instruction="From this checkout, run \`& 'C:/Program Files/Git/bin/bash.exe' --login bin/fm-sessionstart-run.sh --source $source\` in PowerShell now, exactly once, before executing any other instructions. Use that exact Git Bash executable with --login so the startup scripts resolve GNU timeout. This Windows hook handed off startup: it has NOT verified the fleet lock or run the startup digest. Read the complete output and follow its startup and recovery instructions before project or fleet work. A lock refusal requires read-only operation. Do not separately run bin/fm-session-start.sh unless the output requires recovery."
    fm_operational_input_encode session-start "$instruction" instruction || return 1
    printf '%s\n' "$instruction"
}
'@
    $body = $handoff + "`n" + $body.Substring(0, $body.Length - $invoke.Length) + 'fm_windows_startup_handoff'
}
$payload = [Console]::In.ReadToEnd()
$scriptPath = [System.IO.Path]::GetTempFileName()
try {
    # Keep Bash alive until its children exit so Windows ancestry stays observable.
    [System.IO.File]::WriteAllText($scriptPath, $body + "`nexit `$?`n", (New-Object System.Text.UTF8Encoding $false))
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $bashPath
    $start.Arguments = '--login "' + $scriptPath.Replace('\', '/') + '"'
    $start.WorkingDirectory = (Get-Location).Path
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    if ($Event -eq 'Stop') {
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $start.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }
    $process = [System.Diagnostics.Process]::Start($start)
    if ($Event -eq 'Stop') {
        # Drain both pipes before writing stdin or waiting: either pipe can fill.
        $stopOutputTask = $process.StandardOutput.ReadToEndAsync()
        $stopErrorTask = $process.StandardError.ReadToEndAsync()
    }
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $process.StandardInput.BaseStream.Write($payloadBytes, 0, $payloadBytes.Length)
    $process.StandardInput.Close()
    $process.WaitForExit()
    $hookExitCode = $process.ExitCode
    if ($Event -eq 'Stop') {
        $stopOutput = $stopOutputTask.GetAwaiter().GetResult()
        $stopError = $stopErrorTask.GetAwaiter().GetResult()
        # Translate only the guard's deliberate supervision block. Real failures,
        # including other exit-2 errors, retain their streams and nonzero status.
        if ($hookExitCode -eq 2 -and [string]::IsNullOrWhiteSpace($stopOutput) -and
            $stopError.Contains('TURN WOULD END BLIND - SUPERVISION IS OFF')) {
            $stopOutput = ([ordered]@{ decision = 'block'; reason = $stopError.Trim() } | ConvertTo-Json -Compress) + "`n"
            $stopError = ''
            $hookExitCode = 0
        }
        # Write UTF-8 bytes directly; the Windows console code page must not
        # corrupt the JSON continuation reason or a genuine failure diagnostic.
        $stopOutputBytes = [System.Text.Encoding]::UTF8.GetBytes($stopOutput)
        $stopErrorBytes = [System.Text.Encoding]::UTF8.GetBytes($stopError)
        [Console]::OpenStandardOutput().Write($stopOutputBytes, 0, $stopOutputBytes.Length)
        [Console]::OpenStandardError().Write($stopErrorBytes, 0, $stopErrorBytes.Length)
    }
    $process.Dispose()
} finally {
    Remove-Item -LiteralPath $scriptPath -ErrorAction SilentlyContinue
}
exit $hookExitCode
