param(
    [string]$ProjectRoot = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = 'github.com/gosom/scrapemate'
$moduleVersion = 'v1.2.1'
$patchRoot = Join-Path $ProjectRoot '.patched'
$targetRoot = Join-Path $patchRoot 'scrapemate'
$reportDir = Join-Path $ProjectRoot 'reports'

New-Item -ItemType Directory -Force -Path $patchRoot, $reportDir | Out-Null
Remove-Item -LiteralPath $targetRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Downloading pinned dependency $modulePath@$moduleVersion"
$downloadJson = (& go mod download -json "$modulePath@$moduleVersion" | Out-String) | ConvertFrom-Json
if (-not $downloadJson.Dir) {
    throw "Go did not return a source directory for $modulePath@$moduleVersion"
}

New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
Copy-Item -Path (Join-Path $downloadJson.Dir '*') -Destination $targetRoot -Recurse -Force
& attrib -R (Join-Path $targetRoot '*') /S /D | Out-Null

$sessionSlotFile = Join-Path $targetRoot 'adapters\fetchers\jshttp\session_slot.go'
if (-not (Test-Path -LiteralPath $sessionSlotFile)) {
    throw "Expected dependency file is missing: $sessionSlotFile"
}

$source = [System.IO.File]::ReadAllText($sessionSlotFile)

$closedPattern = 'return\s+!p\.p\.IsClosed\(\)'
$closedMatches = [regex]::Matches($source, $closedPattern)
if ($closedMatches.Count -ne 1) {
    throw "Expected exactly one inverted isClosed implementation, found $($closedMatches.Count)"
}
$source = [regex]::Replace($source, $closedPattern, 'return p.p.IsClosed()', 1)

$recoveryPattern = '(?ms)\tif err := s\.runtime\.recreatePage\(\); err != nil \{\r?\n\t\tif err := s\.runtime\.recreateContext\(\); err != nil \{\r?\n\t\t\treturn nil, s\.runtime\.recreateBrowser\(\)\r?\n\t\t\}\r?\n\t\}'
$recoveryMatches = [regex]::Matches($source, $recoveryPattern)
if ($recoveryMatches.Count -ne 1) {
    throw "Expected exactly one broken browser recovery block, found $($recoveryMatches.Count)"
}
$recoveryReplacement = @"
`tif err := s.runtime.recreatePage(); err != nil {
`t`tif err := s.runtime.recreateContext(); err != nil {
`t`t`tif err := s.runtime.recreateBrowser(); err != nil {
`t`t`t`treturn nil, err
`t`t`t}
`t`t}
`t}
"@
$source = [regex]::Replace($source, $recoveryPattern, $recoveryReplacement, 1)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($sessionSlotFile, $source, $utf8NoBom)
& gofmt -w $sessionSlotFile

& go mod edit "-replace=$modulePath=./.patched/scrapemate"
if ($LASTEXITCODE -ne 0) {
    throw "go mod edit failed with exit code $LASTEXITCODE"
}

$proof = @(
    "module=$modulePath"
    "version=$moduleVersion"
    "source_dir=$($downloadJson.Dir)"
    "patched_dir=$targetRoot"
    "fixed_is_closed=true"
    "fixed_recreate_browser_return=true"
    "prepared_utc=$([DateTime]::UtcNow.ToString('o'))"
)
[System.IO.File]::WriteAllLines((Join-Path $reportDir 'patched-scrapemate.txt'), $proof, $utf8NoBom)

Write-Host 'Pinned scrapemate patch prepared successfully.'
