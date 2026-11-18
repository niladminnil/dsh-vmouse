# launch.ps1 -- portable launcher for the vmouse MCP server.
#
# DSH spawns this with system PowerShell (no absolute paths in the bundle patch),
# and it locates a Node.js executable to run server.mjs:
#   1. $env:DSH_VMOUSE_NODE (explicit override)
#   2. node.exe from PATH
#   3. the DSH host process's own executable, when the host is node.exe
#   4. Node bundled with DSH Desktop: <app>\resources\runtime\<arch>\primary-runtime\dependencies\node\bin\node.exe
#   5. a system-wide Node.js install
# If nothing is found it prints a diagnostic on stderr and exits nonzero; the MCP
# client then reports a startup failure instead of hanging.
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$server = Join-Path $here 'server.mjs'

$candidates = New-Object System.Collections.Generic.List[string]

function Add-Candidate([string]$path) {
    if ($path -and -not $candidates.Contains($path)) { $candidates.Add($path) }
}

if ($env:DSH_VMOUSE_NODE) { Add-Candidate $env:DSH_VMOUSE_NODE }

$cmdNode = Get-Command node -ErrorAction SilentlyContinue
if ($cmdNode -and $cmdNode.Source) { Add-Candidate $cmdNode.Source }

try {
    $self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    if ($self -and $self.ParentProcessId) {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($self.ParentProcessId)" -ErrorAction SilentlyContinue
        if ($parent) {
            if ($parent.ExecutablePath) {
                # Parent runs on the same bundled Node (e.g. a CLI-launched host).
                if ($parent.Name -eq 'node.exe') { Add-Candidate $parent.ExecutablePath }
                $dir = Split-Path $parent.ExecutablePath -Parent
                # DSH Desktop layout: <app>\resources\runtime\<arch>\primary-runtime\dependencies\node\bin\node.exe
                $runtime = Join-Path $dir 'resources\runtime'
                if (Test-Path $runtime) {
                    Get-ChildItem $runtime -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                        Add-Candidate (Join-Path $_.FullName 'primary-runtime\dependencies\node\bin\node.exe')
                        Add-Candidate (Join-Path $_.FullName 'node\bin\node.exe')
                    }
                }
                Add-Candidate (Join-Path $dir 'resources\node\node.exe')
                Add-Candidate (Join-Path $dir 'node.exe')
            }
        }
    }
} catch {
    # WMI may be unavailable under hardened policies; the other candidates still apply.
}

if ($env:ProgramFiles) { Add-Candidate (Join-Path $env:ProgramFiles 'nodejs\node.exe') }
if ($env:LOCALAPPDATA) { Add-Candidate (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe') }
if ($env:ProgramFiles) { Add-Candidate (Join-Path $env:ProgramFiles 'nodejs\node.exe') }

$node = $null
foreach ($path in $candidates) {
    if (Test-Path -LiteralPath $path) { $node = $path; break }
}

if (-not $node) {
    [Console]::Error.WriteLine('vmouse: cannot locate node.exe. Set DSH_VMOUSE_NODE to a Node.js executable, or install Node.js / re-run the DSH Desktop installer.')
    exit 1
}

& $node $server
exit $LASTEXITCODE
