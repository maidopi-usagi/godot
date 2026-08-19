[CmdletBinding()]
param(
    [string]$EditorPath,
    [ValidateSet("all", "baseline", "motion", "feature_off_toggle", "phase1_fresh", "phase2_temporal")]
    [string]$Scenario = "all",
    [string]$OutputPath = (Join-Path $PSScriptRoot "qa-results\hddagi_screen_probe_qa.json"),
    [string]$ExpectedPath = (Join-Path $PSScriptRoot "expected_metrics.json"),
    [string]$CpuReferencePath,
    [int]$WarmupFrames = 32,
    [int]$SampleFrames = 12,
    [int]$SettleFrames = 24,
    [ValidateRange(1, 8)]
    [int]$SampleStride = 2,
    [ValidateRange(32, 100000)]
    [int]$Phase1LongFrames = 1000,
    [ValidateRange(32, 100000)]
    [int]$Phase2LongFrames = 1000,
    [switch]$Headless
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path

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
$godotArguments = @("--path", $PSScriptRoot, "--log-file", $resolvedEngineLog, "--gpu-profile")
if ($Headless) {
    $godotArguments += "--headless"
}
$godotArguments += @(
    "--",
    "--scenario=$Scenario",
    "--output=$resolvedOutput",
    "--warmup=$WarmupFrames",
    "--frames=$SampleFrames",
    "--settle=$SettleFrames",
    "--sample-stride=$SampleStride",
    "--counter-log=$resolvedLog",
    "--gpu-profile-enabled"
)
if ($Scenario -eq "phase1_fresh") {
    $godotArguments += "--phase1-long-frames=$Phase1LongFrames"
} elseif ($Scenario -eq "phase2_temporal") {
    $godotArguments += "--phase2-long-frames=$Phase2LongFrames"
}

& $EditorPath @godotArguments 2>&1 | Tee-Object -FilePath $resolvedLog
$processExitCode = $LASTEXITCODE
$validatorPath = Join-Path $PSScriptRoot "validate_result.py"
$validatorArguments = @(
    $validatorPath,
    "--result", $resolvedOutput,
    "--console-log", $resolvedLog,
    "--engine-log", $resolvedEngineLog,
    "--expected", $ExpectedPath,
    "--editor", $EditorPath,
    "--repo-root", $repoRoot,
    "--scenario", $Scenario,
    "--editor-exit-code", $processExitCode
)
if ($CpuReferencePath) {
    $validatorArguments += @("--cpu-reference", (Resolve-Path $CpuReferencePath).Path)
}
& python @validatorArguments
$validationExitCode = $LASTEXITCODE
exit $validationExitCode
