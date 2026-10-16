#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Project = 'Consumer.csproj',
    [string]$NuGetConfig,
    [string]$ReportPath = 'audit.json'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectPath = (Resolve-Path -LiteralPath $Project).Path
$lockPath = Join-Path (Split-Path $projectPath -Parent) 'packages.lock.json'
if (-not (Test-Path -LiteralPath $lockPath)) {
    throw 'packages.lock.json fehlt. Einmal bewusst erzeugen, pruefen und einchecken.'
}
$restoreArguments = @('restore', $projectPath, '--locked-mode', '-p:NuGetAudit=true', '-p:NuGetAuditMode=all', '-p:WarningsAsErrors=NU1903%3BNU1904')
if ($NuGetConfig) { $restoreArguments += @('--configfile', (Resolve-Path -LiteralPath $NuGetConfig).Path) }
$before = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash
& dotnet @restoreArguments
if ($LASTEXITCODE -ne 0) { throw 'Restore oder Audit fehlgeschlagen.' }
if (((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash) -ne $before) {
    throw 'Locked Restore hat die Lockdatei veraendert.'
}
& dotnet build $projectPath --no-restore -m:1
if ($LASTEXITCODE -ne 0) { throw 'Build fehlgeschlagen.' }
$report = @(& dotnet package list --project $projectPath --vulnerable --include-transitive --no-restore --format json --output-version 1)
if ($LASTEXITCODE -ne 0) { throw 'Auditabfrage fehlgeschlagen.' }
$report | Set-Content -LiteralPath $ReportPath -Encoding utf8
Write-Host "CI-Pruefung erfolgreich. Bericht: $ReportPath"
