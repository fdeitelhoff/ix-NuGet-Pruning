#requires -Version 7.2
[CmdletBinding()]
param([switch]$AuditReport)
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
$root = $PSScriptRoot
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$runRoot = Join-Path $root "artifacts/test-$runId"
$work = Join-Path $runRoot 'work'
New-Item -ItemType Directory -Path $work -Force | Out-Null
# Copy source inputs only: each test starts with fresh obj/bin and package caches.
foreach ($name in @('src', 'scripts', 'feed')) {
    $source = Join-Path $root $name
    foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
        if ($file.FullName -match '[\\/](bin|obj)[\\/]') { continue }
        $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName)
        $target = Join-Path $work $relative
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}
foreach ($name in @('global.json', 'NuGet.Config', 'Directory.Build.props', 'NuGetPruning.slnx')) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $work $name)
}
$oldEnvironment = @{}
foreach ($name in @('NUGET_HTTP_CACHE_PATH', 'DOTNET_CLI_HOME', 'DOTNET_NOLOGO', 'DOTNET_CLI_TELEMETRY_OPTOUT')) {
    $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
Push-Location $work
try {
    $env:NUGET_HTTP_CACHE_PATH = Join-Path $runRoot 'http-cache'
    $env:DOTNET_CLI_HOME = Join-Path $runRoot 'dotnet-home'
    $env:DOTNET_NOLOGO = '1'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $sdk = Assert-DemoSdk -Root $work
    [void](Invoke-DemoDotNet -Arguments @('--info') -LogPath (Join-Path $runRoot 'dotnet-info.txt'))
    [void](Invoke-DemoDotNet -Arguments @('sln', 'NuGetPruning.slnx', 'list') -LogPath (Join-Path $runRoot 'solution-projects.txt'))
    [void](Invoke-DemoDotNet -Arguments @('restore', 'NuGetPruning.slnx', '--force-evaluate', '--disable-parallel', '--disable-build-servers', '-m:1') -LogPath (Join-Path $runRoot 'restore.log'))
    [void](Invoke-DemoDotNet -Arguments @('build', 'NuGetPruning.slnx', '-c', 'Debug', '--no-restore', '-m:1') -LogPath (Join-Path $runRoot 'build-debug.log'))
    [void](Invoke-DemoDotNet -Arguments @('build', 'NuGetPruning.slnx', '-c', 'Release', '--no-restore', '-m:1') -LogPath (Join-Path $runRoot 'build-release.log'))
    $results = [System.Collections.Generic.List[object]]::new()
    $outputs = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('Consumer.Off', 'Consumer.On', 'Consumer.Direct')) {
        $caseRoot = Join-Path $runRoot $name
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $project = Join-Path $work "src/$name/$name.csproj"
        $projectRoot = Split-Path $project
        $assetsPath = Join-Path $projectRoot 'obj/project.assets.json'
        $assets = Get-Content -LiteralPath $assetsPath -Raw | ConvertFrom-Json -AsHashtable
        $keys = @($assets.libraries.Keys | Where-Object { $assets.libraries[$_].type -eq 'package' } | Sort-Object)
        $hasJson = $name -ne 'Consumer.On'
        $expectedCount = if ($hasJson) { 2 } else { 1 }
        Assert-Demo ($keys.Count -eq $expectedCount) "$name package count: $($keys.Count), erwartet: $expectedCount."
        Assert-Demo ($keys -contains 'PruningDemo.Bridge/1.0.0') "$name Bridge fehlt."
        Assert-Demo (($keys -contains 'System.Text.Json/8.0.5') -eq $hasJson) "$name unerwarteter JSON-Paketknoten."
        $cacheHasJson = Test-Path (Join-Path $work ".packages/$name/system.text.json/8.0.5")
        Assert-Demo ($cacheHasJson -eq $hasJson) "$name unerwarteter JSON-Paketdownload."
        $lockPath = Join-Path $projectRoot 'packages.lock.json'
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -AsHashtable
        $fixtureBytes = [IO.File]::ReadAllBytes((Join-Path $work 'feed/PruningDemo.Bridge.1.0.0.nupkg'))
        $fixtureHash = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData($fixtureBytes))
        Assert-Demo ($lock.dependencies['net10.0']['PruningDemo.Bridge'].contentHash -eq $fixtureHash) "$name Lockdatei passt nicht zum lokalen Bridge-Paket."
        Assert-Demo ($lock.dependencies['net10.0'].ContainsKey('System.Text.Json') -eq $hasJson) "$name unerwarteter Lockdateieintrag."
        $codes = if ($assets.ContainsKey('logs')) { @($assets.logs | ForEach-Object { $_.code }) } else { @() }
        if ($name -eq 'Consumer.Direct') {
            Assert-Demo ($codes -contains 'NU1510') 'Consumer.Direct: NU1510 fehlt.'
            $json = $assets.targets['net10.0']['System.Text.Json/8.0.5']
            $assetKeys = @($json.compile.Keys) + @($json.runtime.Keys)
            Assert-Demo (@($assetKeys | Where-Object { -not $_.EndsWith('/_._') }).Count -eq 0) 'Direkte JSON-Referenz liefert Assets.'
            $packed = Join-Path $caseRoot 'packed'
            [void](Invoke-DemoDotNet -Arguments @('pack', $project, '-c', 'Release', '--no-build', '--no-restore', '-p:IsPackable=true', '-p:PackageId=PruningDemo.Consumer.Direct', '-p:Version=1.0.0', '-o', $packed) -LogPath (Join-Path $caseRoot 'pack.log'))
            $zip = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $packed 'PruningDemo.Consumer.Direct.1.0.0.nupkg'))
            try {
                $entry = @($zip.Entries | Where-Object { $_.FullName.EndsWith('.nuspec') })[0]
                $reader = [System.IO.StreamReader]::new($entry.Open())
                try { $nuspec = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $nuspec | Set-Content (Join-Path $caseRoot 'consumer.nuspec') -Encoding utf8
                Assert-Demo (-not $nuspec.Contains('id="System.Text.Json"')) 'JSON fliesst in Paketabhaengigkeiten.'
                Assert-Demo ($nuspec.Contains('id="PruningDemo.Bridge"')) 'Bridge fehlt in Paketabhaengigkeiten.'
            }
            finally { $zip.Dispose() }
        }
        else { Assert-Demo ($codes -notcontains 'NU1510') "$name unerwartetes NU1510." }
        $output = Invoke-DemoDotNet -Arguments @('run', '--project', $project, '-c', 'Debug', '--no-build', '--no-restore') -LogPath (Join-Path $caseRoot 'run.log')
        Assert-Demo ($output.Contains('{"message":"Pruning funktioniert"}')) "$name JSON-Ergebnis fehlt."
        $outputs.Add($output)
        [void](Invoke-DemoDotNet -Arguments @('package', 'list', '--project', $project, '--include-transitive', '--no-restore') -LogPath (Join-Path $caseRoot 'packages.txt'))
        [void](Invoke-DemoDotNet -Arguments @('package', 'list', '--project', $project, '--include-transitive', '--no-restore', '--format', 'json', '--output-version', '1') -LogPath (Join-Path $caseRoot 'packages.json'))
        $before = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash
        [void](Invoke-DemoDotNet -Arguments @('restore', $project, '--locked-mode', '--disable-build-servers') -LogPath (Join-Path $caseRoot 'locked-restore.log'))
        Assert-Demo (((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash) -eq $before) "$name Locked Restore hat Lockdatei geaendert."
        if ($AuditReport) {
            [void](Invoke-DemoDotNet -Arguments @('package', 'list', '--project', $project, '--vulnerable', '--include-transitive', '--no-restore', '--format', 'json', '--output-version', '1') -LogPath (Join-Path $caseRoot 'audit.json'))
        }
        Copy-Item -LiteralPath $assetsPath -Destination (Join-Path $caseRoot 'project.assets.json')
        Copy-Item -LiteralPath $lockPath -Destination (Join-Path $caseRoot 'packages.lock.json')
        $results.Add([ordered]@{ project = $name; packages = $keys; packageCount = $keys.Count; jsonDownloaded = $cacheHasJson; run = 'passed'; lockedRestore = 'passed'; nu1510 = ($codes -contains 'NU1510') })
    }
    Assert-Demo (@($outputs | Select-Object -Unique).Count -eq 1) 'Konsolenausgaben sind unterschiedlich.'
    $multi = Get-Content (Join-Path $work 'src/MultiTarget/obj/project.assets.json') -Raw | ConvertFrom-Json -AsHashtable
    $modern = $multi.targets['net10.0']['System.Text.Json/8.0.5']
    $standardKey = @($multi.targets.Keys | Where-Object { $_ -match '(?i)standard' })[0]
    $standard = $multi.targets[$standardKey]['System.Text.Json/8.0.5']
    Assert-Demo (@($modern.compile.Keys | Where-Object { $_.EndsWith('.dll') }).Count -eq 0) 'MultiTarget/net10.0 liefert JSON-Paketassets.'
    Assert-Demo (@($standard.compile.Keys | Where-Object { $_.EndsWith('.dll') }).Count -gt 0) 'MultiTarget/netstandard2.0 fehlen JSON-Paketassets.'
    $multiCodes = if ($multi.ContainsKey('logs')) { @($multi.logs | ForEach-Object { $_.code }) } else { @() }
    Assert-Demo ($multiCodes -notcontains 'NU1510') 'MultiTarget darf nicht zu vollstaendiger Entfernung auffordern.'
    $results.Add([ordered]@{project = 'MultiTarget'; net10JsonAssets = 'none'; netstandardJsonAssets = 'retained'; nu1510 = $false; build = 'passed'})
    [ordered]@{ completedAtUtc = [DateTime]::UtcNow.ToString('o'); sdk = $sdk; powershell = $PSVersionTable.PSVersion.ToString(); platform = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription; solution = 'NuGetPruning.slnx'; debugBuild = 'passed'; releaseBuild = 'passed'; identicalOutput = $true; results = $results } | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $runRoot 'summary.json') -Encoding utf8
    Write-Host "Alle Solution-Pruefungen erfolgreich. Belege: $runRoot"
}
finally {
    Pop-Location
    foreach ($entry in $oldEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
}
