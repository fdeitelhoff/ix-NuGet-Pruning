#requires -Version 7.2
[CmdletBinding()]
param([switch]$RebuildPackage)
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
$root = $PSScriptRoot
$logRoot = Join-Path $root ('artifacts/prepare-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$previousHttpCache = [Environment]::GetEnvironmentVariable('NUGET_HTTP_CACHE_PATH', 'Process')
Push-Location $root
try {
    $env:NUGET_HTTP_CACHE_PATH = Join-Path $logRoot 'http-cache'
    $null = Assert-DemoSdk -Root $root
    $package = Join-Path $root 'feed/PruningDemo.Bridge.1.0.0.nupkg'
    if ($RebuildPackage -or -not (Test-Path -LiteralPath $package)) {
        $producer = Join-Path $root 'src/Bridge/Bridge.csproj'
        [void](Invoke-DemoDotNet -Arguments @('restore', $producer, '--force-evaluate') -LogPath (Join-Path $logRoot 'bridge-restore.log'))
        [void](Invoke-DemoDotNet -Arguments @('build', $producer, '-c', 'Release', '--no-restore') -LogPath (Join-Path $logRoot 'bridge-build.log'))
        [void](Invoke-DemoDotNet -Arguments @('pack', $producer, '-c', 'Release', '--no-build', '--no-restore', '-o', (Join-Path $logRoot 'new-feed')) -LogPath (Join-Path $logRoot 'bridge-pack.log'))
        $newPackage = Join-Path $logRoot 'new-feed/PruningDemo.Bridge.1.0.0.nupkg'
        Assert-Demo (Test-Path -LiteralPath $newPackage) 'Bridge-Paket fehlt nach dotnet pack.'
        New-Item -ItemType Directory -Path (Join-Path $root 'feed') -Force | Out-Null
        Copy-Item -LiteralPath $newPackage -Destination $package -Force
    }
    # Separate restores avoid reuse of metadata for a replaced local fixture package.
    foreach ($name in @('Bridge', 'MultiTarget', 'Consumer.Off', 'Consumer.On', 'Consumer.Direct')) {
        if ($name.StartsWith('Consumer.')) {
            # Only this demo's Bridge cache entries can be removed. No global cache cleanup.
            $entry = Join-Path $root ".packages/$name/pruningdemo.bridge/1.0.0"
            if (Test-Path -LiteralPath $entry) { Remove-Item -LiteralPath $entry -Recurse -Force }
        }
        $project = Join-Path $root "src/$name/$name.csproj"
        [void](Invoke-DemoDotNet -Arguments @('restore', $project, '--force-evaluate', '--force', '--no-http-cache', '--disable-build-servers', '-m:1') -LogPath (Join-Path $logRoot "$name-restore.log"))
    }
    $expectedHash = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($package)))
    foreach ($name in @('Consumer.Off', 'Consumer.On', 'Consumer.Direct')) {
        $lock = Get-Content (Join-Path $root "src/$name/packages.lock.json") -Raw | ConvertFrom-Json -AsHashtable
        $actualHash = $lock.dependencies['net10.0']['PruningDemo.Bridge'].contentHash
        Assert-Demo ($actualHash -eq $expectedHash) "$name Lockdatei passt nicht zum lokalen Bridge-Paket."
    }
    Write-Host "Vorbereitung erfolgreich. NuGetPruning.slnx kann in Visual Studio geoeffnet werden. Logs: $logRoot"
}
finally {
    Pop-Location
    [Environment]::SetEnvironmentVariable('NUGET_HTTP_CACHE_PATH', $previousHttpCache, 'Process')
}
