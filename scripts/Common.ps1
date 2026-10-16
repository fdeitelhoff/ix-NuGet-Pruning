Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-DemoDotNet {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$LogPath)
    Write-Host ('dotnet ' + ($Arguments -join ' '))
    $lines = @(& dotnet @Arguments 2>&1)
    $code = $LASTEXITCODE
    $result = ($lines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($LogPath) { $result | Set-Content -LiteralPath $LogPath -Encoding utf8 }
    Write-Host $result
    if ($code -ne 0) { throw "dotnet exited with code ${code}: $($Arguments -join ' ')" }
    return $result
}

function Assert-Demo {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Pruefung fehlgeschlagen: $Message" }
}

function Assert-DemoSdk {
    param([string]$Root)
    $null = Get-Command dotnet -ErrorAction Stop
    $actual = (Invoke-DemoDotNet -Arguments @('--version')).Trim()
    $required = (Get-Content -LiteralPath (Join-Path $Root 'global.json') -Raw | ConvertFrom-Json).sdk.version
    Assert-Demo ($actual -eq $required) "SDK $required erforderlich, ausgewaehlt: $actual."
    return $actual
}
