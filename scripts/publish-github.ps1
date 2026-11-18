# scripts/publish-github.ps1 -- publish this repository to GitHub without git.
#
# Uses the GitHub REST API only: creates the repository (if missing), uploads every
# tracked file as a commit on the default branch, creates the release tag, packs
# the bundle and attaches the .tgz to a GitHub Release.
#
# Usage:
#   $env:GITHUB_TOKEN = '<classic PAT with repo + workflow scopes>'
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/publish-github.ps1 -Repo dsh-vmouse
#
#   # Dry run: prints what would be uploaded, needs no token.
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/publish-github.ps1 -WhatIf
#
# The token is only read from -Token or $env:GITHUB_TOKEN and never written to disk.
param(
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$Owner,
    [string]$Repo = 'dsh-vmouse',
    [string]$Description = 'A separate virtual mouse for the DSH agent: an on-screen cyan cursor, clicks/drags/scrolls injected as window messages so the real pointer is never moved.',
    [ValidateSet('public', 'private')]
    [string]$Visibility = 'public',
    [string]$Tag = 'v1.0.0',
    [string]$ReleaseName = 'dsh-vmouse 1.0.0',
    [string]$ReleaseNotes = 'First public release: a virtual mouse for the agent. See README and CHANGELOG.',
    [string]$CommitMessage = 'release: dsh-vmouse 1.0.0',
    [switch]$WhatIf,
    [switch]$SkipRelease
)

$ErrorActionPreference = 'Stop'
$repoDir = Split-Path $PSScriptRoot -Parent

# ---------- collect files (same set git would track) ----------
$excludeDirs = @('dist', 'node_modules', '.git', 'test/.probe')
$files = New-Object System.Collections.Generic.List[object]
Get-ChildItem -LiteralPath $repoDir -File -Recurse -Force | ForEach-Object {
    $rel = $_.FullName.Substring($repoDir.Length).TrimStart('\', '/') -replace '\\', '/'
    foreach ($ex in $excludeDirs) {
        if ($rel -eq $ex -or $rel.StartsWith("$ex/")) { return }
    }
    if ($_.Name -match '\.(tgz|log)$') { return }
    if ($_.Name -in @('clicks.log', 'target.json', 'testtarget.error.log')) { return }
    $files.Add([pscustomobject]@{ Path = $rel; Full = $_.FullName })
}
$files = @($files | Sort-Object Path)
if ($files.Count -eq 0) { throw "no files to publish under $repoDir" }

"publish plan: $($files.Count) files -> $(if ($Owner) { $Owner } else { '<token owner>' })/$Repo ($Visibility), tag $Tag"
$files | ForEach-Object { "  " + $_.Path }

if ($WhatIf) {
    $packScript = Join-Path $PSScriptRoot 'pack.ps1'
    if (Test-Path -LiteralPath $packScript) {
        "dry run: would run scripts/pack.ps1 and attach dist/*.tgz to the release"
    }
    "dry run: no network calls performed"
    return
}

if (-not $Token) { throw 'no token: pass -Token or set $env:GITHUB_TOKEN (classic PAT with repo + workflow scopes)' }

# ---------- helpers ----------
$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'dsh-vmouse-publisher'
}

function Invoke-GitHub {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body,
        [switch]$AllowNotFound
    )
    try {
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 20 -Compress
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $json -ContentType 'application/json; charset=utf-8'
        }
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($AllowNotFound -and $status -eq 404) { return $null }
        throw
    }
}

# ---------- identity and repository ----------
if (-not $Owner) {
    $me = Invoke-GitHub -Method GET -Uri 'https://api.github.com/user'
    $Owner = $me.login
    "authenticated as: $Owner"
}

$repoUri = "https://api.github.com/repos/$Owner/$Repo"
$repoInfo = Invoke-GitHub -Method GET -Uri $repoUri -AllowNotFound
if ($null -eq $repoInfo) {
    "creating repository $Owner/$Repo ($Visibility)"
    $repoInfo = Invoke-GitHub -Method POST -Uri 'https://api.github.com/user/repos' -Body @{
        name        = $Repo
        description = $Description
        private     = ($Visibility -eq 'private')
        auto_init   = $true
        has_issues  = $true
        has_wiki    = $false
    }
    Start-Sleep -Milliseconds 800
}
else {
    "repository exists: $($repoInfo.html_url) (default branch: $($repoInfo.default_branch))"
}

$branch = $repoInfo.default_branch
if ([string]::IsNullOrEmpty($branch)) { $branch = 'main' }
"branch: $branch"

# ---------- blobs, tree, commit ----------
$parentSha = $null
$parentCommit = Invoke-GitHub -Method GET -Uri "$repoUri/git/ref/heads/$branch" -AllowNotFound
if ($null -ne $parentCommit) { $parentSha = $parentCommit.object.sha }

$treeItems = New-Object System.Collections.Generic.List[object]
foreach ($file in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($file.Full)
    $blob = Invoke-GitHub -Method POST -Uri "$repoUri/git/blobs" -Body @{
        content  = [Convert]::ToBase64String($bytes)
        encoding = 'base64'
    }
    $treeItems.Add(@{ path = $file.Path; mode = '100644'; type = 'blob'; sha = $blob.sha })
    "uploaded blob $($file.Path) ($($bytes.Length) bytes)"
}

$treeBody = @{ tree = $treeItems }
if ($parentSha) { $treeBody.base_tree = $parentSha }
$tree = Invoke-GitHub -Method POST -Uri "$repoUri/git/trees" -Body $treeBody

$commitBody = @{ message = $CommitMessage; tree = $tree.sha }
if ($parentSha) { $commitBody.parents = @($parentSha) }
$commit = Invoke-GitHub -Method POST -Uri "$repoUri/git/commits" -Body $commitBody

if ($parentSha) {
    Invoke-GitHub -Method PATCH -Uri "$repoUri/git/refs/heads/$branch" -Body @{ sha = $commit.sha; force = $true } | Out-Null
}
else {
    Invoke-GitHub -Method POST -Uri "$repoUri/git/refs" -Body @{ ref = "refs/heads/$branch"; sha = $commit.sha } | Out-Null
}
"pushed commit $($commit.sha): https://github.com/$Owner/$Repo/commit/$($commit.sha)"

# ---------- tag ----------
$existingTag = Invoke-GitHub -Method GET -Uri "$repoUri/git/ref/tags/$Tag" -AllowNotFound
if ($null -eq $existingTag) {
    Invoke-GitHub -Method POST -Uri "$repoUri/git/refs" -Body @{ ref = "refs/tags/$Tag"; sha = $commit.sha } | Out-Null
    "created tag $Tag"
}
else {
    "tag $Tag already exists (left untouched)"
}

# ---------- release with the packed bundle ----------
if (-not $SkipRelease) {
    $packScript = Join-Path $PSScriptRoot 'pack.ps1'
    if (Test-Path -LiteralPath $packScript) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $packScript -OutDir 'dist'
        if ($LASTEXITCODE -ne 0) { throw "pack.ps1 failed with exit code $LASTEXITCODE" }
    }
    $asset = Get-ChildItem -LiteralPath (Join-Path $repoDir 'dist') -Filter '*.tgz' | Select-Object -First 1
    if (-not $asset) { throw 'no release asset found under dist/ (run scripts/pack.ps1)' }

    $release = Invoke-GitHub -Method GET -Uri "$repoUri/releases/tags/$Tag" -AllowNotFound
    if ($null -eq $release) {
        $release = Invoke-GitHub -Method POST -Uri "$repoUri/releases" -Body @{
            tag_name         = $Tag
            name             = $ReleaseName
            body             = $ReleaseNotes
            draft            = $false
            prerelease       = $false
            generate_release_notes = $false
        }
        "created release: $($release.html_url)"
    }
    else {
        "release exists: $($release.html_url)"
    }

    $uploadUrl = ($release.upload_url -replace '\{.*$', '')
    $uploadUri = "$uploadUrl?name=$($asset.Name)"
    $bytes = [System.IO.File]::ReadAllBytes($asset.FullName)
    $uploadHeaders = @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'dsh-vmouse-publisher'
    }
    try {
        Invoke-RestMethod -Method POST -Uri $uploadUri -Headers $uploadHeaders -ContentType 'application/gzip' -Body $bytes | Out-Null
        "attached release asset: $($asset.Name) ($([math]::Round($bytes.Length / 1kb, 1)) KiB)"
    }
    catch {
        Write-Warning "release asset upload failed: $($_.Exception.Message)"
    }
}

"done: https://github.com/$Owner/$Repo"
"install one-liner for other users:"
"  https://github.com/$Owner/$Repo/archive/refs/tags/$Tag.tar.gz"
"  (or the release asset: https://github.com/$Owner/$Repo/releases/download/$Tag/$(Get-ChildItem -LiteralPath (Join-Path $repoDir 'dist') -Filter '*.tgz' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Name))"
