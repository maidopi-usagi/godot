[CmdletBinding()]
param(
    [string]$EditorPath,
    [string]$OutputPath = (Join-Path $PSScriptRoot "qa-results\phase2-gpu-acceptance.json"),
    [string]$CpuOutputPath = (Join-Path $PSScriptRoot "qa-results\phase2-cpu-reference.json"),
    [ValidateRange(4096, 10000000)]
    [int]$CpuTrials = 65536,
    [ValidateRange(1000, 10000000)]
    [int]$CpuStressFrames = 1000,
    [ValidateRange(1000, 100000)]
    [int]$Phase2LongFrames = 1000,
    [ValidateRange(2, 10000)]
    [int]$ComparisonSampleFrames = 128,
    [switch]$Headless
)

$ErrorActionPreference = "Stop"
$cpuReference = Join-Path $PSScriptRoot "phase2_reference.py"
& python $cpuReference `
    --trials $CpuTrials `
    --stress-frames $CpuStressFrames `
    --json-output $CpuOutputPath
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$runnerParameters = @{
    Scenario = "phase2_temporal"
    OutputPath = $OutputPath
    ExpectedPath = (Join-Path $PSScriptRoot "expected_phase2_metrics.json")
    CpuReferencePath = $CpuOutputPath
    WarmupFrames = 64
    SampleFrames = $ComparisonSampleFrames
    SettleFrames = 32
    SampleStride = 2
    Phase2LongFrames = $Phase2LongFrames
}
if ($EditorPath) {
    $runnerParameters.EditorPath = $EditorPath
}
if ($Headless) {
    $runnerParameters.Headless = $true
}

& (Join-Path $PSScriptRoot "run_qa.ps1") @runnerParameters
exit $LASTEXITCODE
