# scripts/pack.ps1 -- build the release tarball for dsh-vmouse.
#
# The result is an npm-style tarball (top-level `package/` directory) so pnpm can
# install it directly from a URL:
#   install_bundle target: https://github.com/<user>/dsh-vmouse/archive/refs/tags/v1.0.0.tar.gz
#   or a local file:       D:\path\to\dsh-vmouse-1.0.0.tgz
#
# SAFETY: this script only reads the repository and writes the archive under
# dist/. It never deletes or moves source files; the only Remove-Item calls are
# for the archive being replaced and for temporary staging directories it owns.
param(
    [string]$Version,
    [string]$OutDir = 'dist'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

$manifestPath = Join-Path $repo 'package.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "package.json not found: $manifestPath" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$packageName = $manifest.name
if (-not $Version) { $Version = $manifest.version }
if (-not $Version) { throw 'no version in package.json and -Version not given' }
if ($packageName -ne 'dsh-vmouse') { throw "unexpected package name: $packageName" }

$patterns = @(
    'package.json',
    'cordis.patch.yml',
    'README.md',
    'LICENSE',
    'launch.ps1',
    'server.mjs',
    'vmouse.ps1',
    'locale/*.json',
    'icon.svg',
    'skills/**'
)
$required = @('cordis.patch.yml', 'launch.ps1', 'server.mjs', 'vmouse.ps1', 'skills/virtual-mouse/SKILL.md')

$stamp = [guid]::NewGuid().ToString('N')
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dsh-vmouse-pack-$stamp"
$pkgRoot = Join-Path $stageRoot 'package'
New-Item -ItemType Directory -Force -Path $pkgRoot | Out-Null

$copied = New-Object System.Collections.Generic.List[string]
foreach ($pattern in $patterns) {
    if ($pattern -match '/\*\*$') {
        # Recursive directory pattern, e.g. "skills/**".
        $dir = Join-Path $repo ($pattern -replace '/\*\*$', '')
        $hits = @(Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue)
    }
    else {
        # File or single-level wildcard pattern, e.g. "locale/*.json".
        $hits = @(Get-ChildItem -Path (Join-Path $repo $pattern) -File -ErrorAction SilentlyContinue)
    }
    foreach ($file in $hits) {
        $rel = $file.FullName.Substring($repo.Length).TrimStart('\', '/')
        $rel = $rel -replace '\\', '/'
        $dest = Join-Path $pkgRoot $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
        $copied.Add($rel)
    }
}
if ($copied.Count -eq 0) { throw 'no files matched package.json "files"' }

foreach ($must in $required) {
    if (-not ($copied | Where-Object { $_ -eq $must })) { throw "required release file missing: $must" }
}

$destDir = Join-Path $repo $OutDir
New-Item -ItemType Directory -Force -Path $destDir | Out-Null
$tgz = Join-Path $destDir "$packageName-$Version.tgz"
if (Test-Path -LiteralPath $tgz) { Remove-Item -LiteralPath $tgz -Force }

& tar.exe -czf $tgz -C $stageRoot 'package'
if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit code $LASTEXITCODE" }

# Self-check: extract into a scratch directory and verify the npm-style layout.
$checkRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dsh-vmouse-check-$stamp"
New-Item -ItemType Directory -Force -Path $checkRoot | Out-Null
try {
    & tar.exe -xzf $tgz -C $checkRoot
    if ($LASTEXITCODE -ne 0) { throw "tar.exe extraction self-check failed: $LASTEXITCODE" }
    $checkManifest = Join-Path $checkRoot 'package/package.json'
    if (-not (Test-Path -LiteralPath $checkManifest)) { throw 'self-check: package/package.json missing from archive' }
    $check = Get-Content -LiteralPath $checkManifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($check.name -ne $packageName) { throw "self-check: archive package name is $($check.name), expected $packageName" }
    foreach ($must in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $checkRoot ("package/$must")))) { throw "self-check: $must missing from archive" }
    }
    "self-check: OK ($($copied.Count) files, package name $($check.name)@$($check.version))"
}
finally {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $checkRoot -Recurse -Force -ErrorAction SilentlyContinue
}

"packed {0} files -> {1} ({2:N0} bytes)" -f $copied.Count, $tgz, (Get-Item -LiteralPath $tgz).Length
