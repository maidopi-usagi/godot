[CmdletBinding()]
param(
    [string]$EditorPath,
    [string]$OutputPath = (Join-Path $PSScriptRoot "qa-results\phase3-gpu-smoke.json"),
    [string]$CpuOutputPath = (Join-Path $PSScriptRoot "qa-results\phase3-cpu-reference.json"),
    [string]$ExpectedPath = (Join-Path $PSScriptRoot "expected_phase3_smoke_metrics.json"),
    [ValidateRange(65536, 10000000)]
    [int]$CpuTrials = 65536,
    [ValidateRange(1000, 10000000)]
    [int]$CpuStressFrames = 1000,
    [ValidateRange(8, 10000)]
    [int]$WarmupFrames = 64,
    [ValidateRange(8, 10000)]
    [int]$SampleFrames = 128,
    [ValidateRange(1, 8)]
    [int]$SampleStride = 2,
    [switch]$Headless
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$cpuReference = Join-Path $PSScriptRoot "phase3_reference.py"
$validatorPath = Join-Path $PSScriptRoot "validate_phase3_result.py"
$scenePath = "res://phase3_qa_runner.tscn"

& python $cpuReference `
    --trials $CpuTrials `
    --stress-frames $CpuStressFrames `
    --json-output $CpuOutputPath
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

if (-not $EditorPath) {
    $candidate = Get-ChildItem -Path (Join-Path $repoRoot "bin") -Filter "godot.windows.editor*.console.exe" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        throw "No console editor binary found under '$repoRoot\bin'. Build the editor or pass -EditorPath."
    }
    $EditorPath = $candidate.FullName
}
$EditorPath = (Resolve-Path $EditorPath).Path
$ExpectedPath = (Resolve-Path $ExpectedPath).Path
$CpuOutputPath = (Resolve-Path $CpuOutputPath).Path

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
$resolvedLog = [System.IO.Path]::ChangeExtension($resolvedOutput, ".log")
$resolvedEngineLog = [System.IO.Path]::ChangeExtension($resolvedOutput, ".engine.log")
$outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutput)
if ($outputDirectory) {
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}
foreach ($stalePath in @($resolvedOutput, $resolvedLog, $resolvedEngineLog)) {
    if (Test-Path -LiteralPath $stalePath) {
        Remove-Item -LiteralPath $stalePath -Force
    }
}

$godotArguments = @(
    "--path", $PSScriptRoot,
    "--log-file", $resolvedEngineLog,
    "--gpu-profile"
)
if ($Headless) {
    $godotArguments += "--headless"
}
$godotArguments += @(
    $scenePath,
    "--",
    "--scenario=phase3_spatial",
    "--output=$resolvedOutput",
    "--warmup=$WarmupFrames",
    "--frames=$SampleFrames",
    "--settle=32",
    "--sample-stride=$SampleStride",
    "--counter-log=$resolvedLog",
    "--gpu-profile-enabled"
)

& $EditorPath @godotArguments 2>&1 | Tee-Object -FilePath $resolvedLog
$processExitCode = $LASTEXITCODE

& python $validatorPath `
    --result $resolvedOutput `
    --console-log $resolvedLog `
    --engine-log $resolvedEngineLog `
    --expected $ExpectedPath `
    --cpu-reference $CpuOutputPath `
    --editor $EditorPath `
    --repo-root $repoRoot `
    --editor-exit-code $processExitCode
exit $LASTEXITCODE
