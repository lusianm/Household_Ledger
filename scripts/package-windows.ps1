param([string]$Flutter = 'flutter', [string]$Config = 'config.local.json', [switch]$SkipBuild, [switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $project
. (Join-Path $PSScriptRoot 'read-version.ps1')
$appVersion = Get-ChagokVersion
# Compile installers only on GitHub. Local development needs no Inno Setup.
if (-not $PrepareOnly -and $env:GITHUB_ACTIONS -ne 'true') {
    throw 'Installation EXEs are created by GitHub Actions. Use -PrepareOnly to verify the local application bundle.'
}
if (-not $SkipBuild) {
    $buildArgs = @('build', 'windows', '--release')
    if (Test-Path -LiteralPath $Config) { $buildArgs += "--dart-define-from-file=$Config" }
    if ($env:GITHUB_REPOSITORY) { $buildArgs += "--dart-define=UPDATE_REPOSITORY=$env:GITHUB_REPOSITORY" }
    & $Flutter @buildArgs
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows build failed.' }
}
$release = Join-Path $project 'build/windows/x64/runner/Release'
if (-not (Test-Path -LiteralPath (Join-Path $release 'chagok.exe'))) { throw 'Release executable is missing.' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio redistributable locator is missing.' }
$vs = & $vswhere -latest -products '*' -property installationPath
$crt = Get-ChildItem -LiteralPath (Join-Path $vs 'VC/Redist/MSVC') -Directory | Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'x64/Microsoft.VC143.CRT' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $crt) { throw 'Visual C++ runtime files are missing. Install the C++ desktop workload.' }
Get-ChildItem -LiteralPath $crt -Filter '*.dll' | Copy-Item -Destination $release
Copy-Item -LiteralPath (Join-Path $project 'README.md') -Destination $release
$output = Join-Path $project 'build/dist'
New-Item -ItemType Directory -Path $output -Force | Out-Null
if ($PrepareOnly) { Write-Output "Prepared application bundle: $release"; return }
$compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The GitHub Windows runner is missing Inno Setup 6. Check the pinned runner image.' }
& $compiler "/DAppVersion=$($appVersion.Version)" "/DAppBuild=$($appVersion.Build)" (Join-Path $project 'packaging/windows.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
$installer = Join-Path $output 'chagok-windows-setup.exe'
if (-not (Test-Path -LiteralPath $installer)) { throw 'Installer output is missing.' }
$checksum = Get-FileHash -LiteralPath $installer -Algorithm SHA256
"$($checksum.Hash.ToLowerInvariant())  chagok-windows-setup.exe" | Set-Content -LiteralPath (Join-Path $output 'chagok-windows-setup.exe.sha256') -Encoding utf8
Write-Output "Installer ready: $installer ($($appVersion.Tag))"
