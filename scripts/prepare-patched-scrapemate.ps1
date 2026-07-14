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
$patchTestSource = Join-Path $ProjectRoot 'patches\scrapemate\testdata\session_slot_recovery_patch_test.go'
$patchTestTarget = Join-Path $targetRoot 'adapters\fetchers\jshttp\session_slot_recovery_patch_test.go'
$testStdout = Join-Path $reportDir 'scrapemate-patch-test.stdout.log'
$testStderr = Join-Path $reportDir 'scrapemate-patch-test.stderr.log'

New-Item -ItemType Directory -Force -Path $patchRoot, $reportDir | Out-Null
Remove-Item -LiteralPath $targetRoot -Recurse -Force -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $patchTestSource)) {
    throw "Patch regression test is missing: $patchTestSource"
}

Write-Host "Downloading pinned dependency $modulePath@$moduleVersion"
$downloadOutput = & go mod download -json "$modulePath@$moduleVersion" | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "go mod download failed with exit code $LASTEXITCODE"
}

$downloadJson = $downloadOutput | ConvertFrom-Json
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
Copy-Item -LiteralPath $patchTestSource -Destination $patchTestTarget -Force

& gofmt -w $sessionSlotFile $patchTestTarget
if ($LASTEXITCODE -ne 0) {
    throw "gofmt failed with exit code $LASTEXITCODE"
}

Remove-Item -LiteralPath $testStdout, $testStderr -Force -ErrorAction SilentlyContinue
$go = (Get-Command go).Source
$testProcess = Start-Process -FilePath $go `
    -ArgumentList @(
        'test',
        './adapters/fetchers/jshttp',
        '-run',
        '^TestPatched',
        '-count=1'
    ) `
    -WorkingDirectory $targetRoot `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $testStdout `
    -RedirectStandardError $testStderr

if (Test-Path -LiteralPath $testStdout) {
    Get-Content -LiteralPath $testStdout
}
if (Test-Path -LiteralPath $testStderr) {
    Get-Content -LiteralPath $testStderr
}
if ($testProcess.ExitCode -ne 0) {
    throw "Patched scrapemate regression tests failed with exit code $($testProcess.ExitCode)"
}

Push-Location $ProjectRoot
try {
    & go mod edit "-replace=$modulePath=./.patched/scrapemate"
    if ($LASTEXITCODE -ne 0) {
        throw "go mod edit failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

$proof = @(
    "module=$modulePath"
    "version=$moduleVersion"
    "source_dir=$($downloadJson.Dir)"
    "patched_dir=$targetRoot"
    "fixed_is_closed=true"
    "fixed_recreate_browser_return=true"
    "regression_tests_passed=true"
    "prepared_utc=$([DateTime]::UtcNow.ToString('o'))"
)
[System.IO.File]::WriteAllLines((Join-Path $reportDir 'patched-scrapemate.txt'), $proof, $utf8NoBom)

Write-Host 'Pinned scrapemate patch prepared successfully.'
