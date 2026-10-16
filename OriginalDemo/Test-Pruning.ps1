#requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$IncludeMultiTarget,
    [switch]$AuditReport
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$demoRoot = $PSScriptRoot
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$runRoot = Join-Path $demoRoot "artifacts/$runId"
$oldEnvironment = @{}
foreach ($name in @('NUGET_PACKAGES', 'NUGET_HTTP_CACHE_PATH', 'DOTNET_CLI_HOME', 'DOTNET_NOLOGO', 'DOTNET_CLI_TELEMETRY_OPTOUT')) {
    $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Invoke-DotNet {
    param([string[]]$Arguments, [string]$LogPath)
    Write-Host ('dotnet ' + ($Arguments -join ' '))
    $lines = @(& dotnet @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $result = ($lines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($LogPath) { $result | Set-Content -LiteralPath $LogPath -Encoding utf8 }
    Write-Host $result
    if ($exitCode -ne 0) { throw "dotnet exited with code ${exitCode}: $($Arguments -join ' ')" }
    return $result
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Get-PackageKeys {
    param([hashtable]$Assets)
    return @($Assets.libraries.Keys | Where-Object { $Assets.libraries[$_].type -eq 'package' } | Sort-Object)
}

try {
    Push-Location $demoRoot
    $null = Get-Command dotnet -ErrorAction Stop
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $env:DOTNET_CLI_HOME = Join-Path $runRoot '.dotnet-home'
    $env:DOTNET_NOLOGO = '1'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:NUGET_PACKAGES = Join-Path $runRoot 'producer-packages'
    $env:NUGET_HTTP_CACHE_PATH = Join-Path $runRoot 'producer-http-cache'
    $sdk = (Invoke-DotNet -Arguments @('--version')).Trim()
    $requiredSdk = (Get-Content (Join-Path $demoRoot 'global.json') -Raw | ConvertFrom-Json).sdk.version
    Assert-True ($sdk -eq $requiredSdk) "Expected SDK $requiredSdk, found $sdk."
    [void](Invoke-DotNet -Arguments @('--info') -LogPath (Join-Path $runRoot 'dotnet-info.txt'))

    $feed = Join-Path $runRoot 'feed'
    New-Item -ItemType Directory -Path $feed -Force | Out-Null
    $configPath = Join-Path $runRoot 'NuGet.Config'
    $escapedFeed = [System.Security.SecurityElement]::Escape($feed)
    @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="demo-local" value="$escapedFeed" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <clear />
    <packageSource key="demo-local"><package pattern="PruningDemo.*" /></packageSource>
    <packageSource key="nuget.org"><package pattern="*" /></packageSource>
  </packageSourceMapping>
</configuration>
"@ | Set-Content -LiteralPath $configPath -Encoding utf8

    $producer = Join-Path $runRoot 'Bridge'
    Copy-Item -LiteralPath (Join-Path $demoRoot 'Bridge') -Destination $producer -Recurse
    $producerProject = Join-Path $producer 'Bridge.csproj'
    [void](Invoke-DotNet -Arguments @('restore', $producerProject, '--configfile', $configPath) -LogPath (Join-Path $runRoot 'producer-restore.log'))
    [void](Invoke-DotNet -Arguments @('build', $producerProject, '-c', 'Release', '--no-restore') -LogPath (Join-Path $runRoot 'producer-build.log'))
    [void](Invoke-DotNet -Arguments @('pack', $producerProject, '-c', 'Release', '--no-build', '--no-restore', '-o', $feed) -LogPath (Join-Path $runRoot 'producer-pack.log'))

    $summary = [System.Collections.Generic.List[object]]::new()
    $scenarioList = @(
        @{ Name = 'off'; Pruning = 'false'; Direct = 'false' },
        @{ Name = 'on'; Pruning = 'true'; Direct = 'false' },
        @{ Name = 'direct-on'; Pruning = 'true'; Direct = 'true' }
    )
    foreach ($scenario in $scenarioList) {
        $caseRoot = Join-Path $runRoot $scenario.Name
        $consumer = Join-Path $caseRoot 'Consumer'
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $demoRoot 'Consumer') -Destination $consumer -Recurse
        $env:NUGET_PACKAGES = Join-Path $caseRoot 'packages'
        $env:NUGET_HTTP_CACHE_PATH = Join-Path $caseRoot 'http-cache'
        @"
<Project>
  <PropertyGroup>
    <RestoreEnablePackagePruning>$($scenario.Pruning)</RestoreEnablePackagePruning>
    <DirectJsonReference>$($scenario.Direct)</DirectJsonReference>
    <NuGetAuditMode>all</NuGetAuditMode>
  </PropertyGroup>
</Project>
"@ | Set-Content -LiteralPath (Join-Path $caseRoot 'Directory.Build.props') -Encoding utf8

        $project = Join-Path $consumer 'Consumer.csproj'
        [void](Invoke-DotNet -Arguments @('restore', $project, '--configfile', $configPath, '--force-evaluate', '--verbosity', 'normal') -LogPath (Join-Path $caseRoot 'restore.log'))
        $assetsPath = Join-Path $consumer 'obj/project.assets.json'
        $lockPath = Join-Path $consumer 'packages.lock.json'
        Copy-Item $assetsPath (Join-Path $caseRoot 'project.assets.json')
        Copy-Item $lockPath (Join-Path $caseRoot 'packages.lock.json')
        $assets = Get-Content -LiteralPath $assetsPath -Raw | ConvertFrom-Json -AsHashtable
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -AsHashtable
        $packageKeys = @(Get-PackageKeys $assets)
        $packageKeys | Set-Content (Join-Path $caseRoot 'packages.txt') -Encoding utf8
        $hasJson = $packageKeys -contains 'System.Text.Json/8.0.5'
        $expectedJson = $scenario.Name -ne 'on'
        Assert-True ($hasJson -eq $expectedJson) "$($scenario.Name): unexpected System.Text.Json package presence."
        Assert-True ($packageKeys -contains 'PruningDemo.Bridge/1.0.0') 'Bridge must remain in the graph.'
        $lockHasJson = $lock.dependencies['net10.0'].ContainsKey('System.Text.Json')
        Assert-True ($lockHasJson -eq $expectedJson) "$($scenario.Name): unexpected JSON entry in lock file."
        $cacheHasJson = Test-Path (Join-Path $env:NUGET_PACKAGES 'system.text.json/8.0.5')
        Assert-True ($cacheHasJson -eq $expectedJson) "$($scenario.Name): unexpected JSON download in isolated cache."
        if ($scenario.Name -eq 'direct-on') {
            $jsonTarget = $assets.targets['net10.0']['System.Text.Json/8.0.5']
            $actualAssets = @($jsonTarget.compile.Keys) + @($jsonTarget.runtime.Keys)
            Assert-True (@($actualAssets | Where-Object { -not $_.EndsWith('/_._') }).Count -eq 0) 'Direct JSON reference must expose no compile/runtime assets.'
            $warningCodes = @($assets.logs | ForEach-Object { $_.code })
            Assert-True ($warningCodes -contains 'NU1510') 'Direct reference must raise NU1510.'
        }
        [void](Invoke-DotNet -Arguments @('build', $project, '-c', 'Release', '--no-restore') -LogPath (Join-Path $caseRoot 'build.log'))
        if ($scenario.Name -eq 'direct-on') {
            $packed = Join-Path $caseRoot 'packed'
            [void](Invoke-DotNet -Arguments @('pack', $project, '-c', 'Release', '--no-build', '--no-restore', '-p:IsPackable=true', '-p:PackageId=PruningDemo.Consumer', '-p:Version=1.0.0', '-o', $packed) -LogPath (Join-Path $caseRoot 'pack.log'))
            $archive = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $packed 'PruningDemo.Consumer.1.0.0.nupkg'))
            try {
                $entry = @($archive.Entries | Where-Object { $_.FullName.EndsWith('.nuspec') })[0]
                $reader = [System.IO.StreamReader]::new($entry.Open())
                try { $nuspec = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $nuspec | Set-Content (Join-Path $caseRoot 'consumer.nuspec') -Encoding utf8
                Assert-True (-not $nuspec.Contains('id="System.Text.Json"')) 'Direct JSON reference must not flow into package dependencies.'
                Assert-True ($nuspec.Contains('id="PruningDemo.Bridge"')) 'Bridge dependency must remain in packed consumer.'
            }
            finally { $archive.Dispose() }
        }
        $runText = Invoke-DotNet -Arguments @('run', '--project', $project, '-c', 'Release', '--no-build', '--no-restore') -LogPath (Join-Path $caseRoot 'run.log')
        Assert-True ($runText.Contains('{"message":"Pruning funktioniert"}')) 'Expected JSON output is missing.'
        [void](Invoke-DotNet -Arguments @('package', 'list', '--project', $project, '--include-transitive', '--no-restore') -LogPath (Join-Path $caseRoot 'package-list.txt'))
        [void](Invoke-DotNet -Arguments @('package', 'list', '--project', $project, '--include-transitive', '--no-restore', '--format', 'json') -LogPath (Join-Path $caseRoot 'package-list.json'))
        $before = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash
        [void](Invoke-DotNet -Arguments @('restore', $project, '--configfile', $configPath, '--locked-mode') -LogPath (Join-Path $caseRoot 'locked-restore.log'))
        Assert-True (((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash) -eq $before) 'Locked restore must not modify lock file.'
        if ($AuditReport) {
            [void](Invoke-DotNet -Arguments @('package', 'list', '--project', $project, '--vulnerable', '--include-transitive', '--no-restore', '--format', 'json') -LogPath (Join-Path $caseRoot 'audit-report.json'))
        }
        $summary.Add([ordered]@{ scenario = $scenario.Name; packages = $packageKeys; packageCount = $packageKeys.Count; jsonDownloaded = $cacheHasJson; build = 'passed'; run = 'passed'; lockedRestore = 'passed' })
    }

    $offKeys = @(Get-Content (Join-Path $runRoot 'off/packages.txt'))
    $onKeys = @(Get-Content (Join-Path $runRoot 'on/packages.txt'))
    Compare-Object $offKeys $onKeys | Format-Table -AutoSize | Out-String | Set-Content (Join-Path $runRoot 'package-diff.txt') -Encoding utf8
    Compare-Object (Get-Content (Join-Path $runRoot 'off/packages.lock.json')) (Get-Content (Join-Path $runRoot 'on/packages.lock.json')) |
        Format-Table -Wrap -AutoSize | Out-String -Width 180 | Set-Content (Join-Path $runRoot 'lock-line-diff.txt') -Encoding utf8

    if ($IncludeMultiTarget) {
        $caseRoot = Join-Path $runRoot 'multi-target'
        Copy-Item -LiteralPath (Join-Path $demoRoot 'MultiTarget') -Destination $caseRoot -Recurse
        $env:NUGET_PACKAGES = Join-Path $caseRoot 'packages'
        $env:NUGET_HTTP_CACHE_PATH = Join-Path $caseRoot 'http-cache'
        $project = Join-Path $caseRoot 'MultiTarget.csproj'
        [void](Invoke-DotNet -Arguments @('restore', $project, '--configfile', $configPath, '--force-evaluate') -LogPath (Join-Path $caseRoot 'restore.log'))
        $assets = Get-Content (Join-Path $caseRoot 'obj/project.assets.json') -Raw | ConvertFrom-Json -AsHashtable
        $modern = $assets.targets['net10.0']['System.Text.Json/8.0.5']
        $standardKey = @($assets.targets.Keys | Where-Object { $_ -match '(?i)standard' })[0]
        $standard = $assets.targets[$standardKey]['System.Text.Json/8.0.5']
        Assert-True (@($modern.compile.Keys | Where-Object { $_.EndsWith('.dll') }).Count -eq 0) 'Multi-target net10.0 must exclude the direct JSON package assets.'
        Assert-True (@($standard.compile.Keys | Where-Object { $_.EndsWith('.dll') }).Count -gt 0) 'netstandard2.0 must retain JSON package assets.'
        $codes = if ($assets.ContainsKey('logs')) { @($assets.logs | ForEach-Object { $_.code }) } else { @() }
        Assert-True ($codes -notcontains 'NU1510') 'NU1510 must not suggest removal while netstandard2.0 needs the package.'
        [void](Invoke-DotNet -Arguments @('build', $project, '-c', 'Release', '--no-restore', '-m:1') -LogPath (Join-Path $caseRoot 'build.log'))
        $summary.Add([ordered]@{ scenario = 'multi-target'; frameworks = @('net10.0', 'netstandard2.0'); build = 'passed'; net10JsonAssets = 'none'; netstandardJsonAssets = 'retained'; nu1510 = 'absent' })
    }
    [ordered]@{ completedAtUtc = [DateTime]::UtcNow.ToString('o'); sdk = $sdk; powershell = $PSVersionTable.PSVersion.ToString(); platform = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription; results = $summary } |
        ConvertTo-Json -Depth 12 | Set-Content (Join-Path $runRoot 'summary.json') -Encoding utf8
    Write-Host "All requested checks passed. Evidence: $runRoot"
}
finally {
    Pop-Location
    foreach ($entry in $oldEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
}
