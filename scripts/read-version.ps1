function Get-ChagokVersion {
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pubspec.yaml')
    $match = [regex]::Match($manifest, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
    if (-not $match.Success) { throw 'Use a stable version with an increasing build number: version: 0.1.1+2' }
    $version = $match.Groups[1].Value
    $build = [int]$match.Groups[2].Value
    if ($build -lt 1 -or $build -gt 65535) { throw 'Build number must be 1..65535 for Windows version resources.' }
    foreach ($part in $version.Split('.')) { if ([int]$part -gt 65535) { throw 'Version component exceeds the Windows resource limit.' } }
    [pscustomobject]@{ Version = $version; Build = $build; Tag = "v$version+$build" }
}
