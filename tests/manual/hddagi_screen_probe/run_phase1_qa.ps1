[CmdletBinding()]
param(
    [string]$EditorPath,
    [string]$OutputPath = (Join-Path $PSScriptRoot "qa-results\phase1-gpu-acceptance.json"),
    [string]$CpuOutputPath = (Join-Path $PSScriptRoot "qa-results\phase1-cpu-reference.json"),
    [ValidateRange(4096, 10000000)]
    [int]$CpuFrames = 65536,
    [ValidateRange(32, 100000)]
    [int]$Phase1LongFrames = 1000,
    [ValidateRange(2, 10000)]
    [int]$CandidateSampleFrames = 128,
    [switch]$Headless
)

$ErrorActionPreference = "Stop"
$cpuReference = Join-Path $PSScriptRoot "phase1_reference.py"
& python $cpuReference --frames $CpuFrames --json-output $CpuOutputPath
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$runnerParameters = @{
    Scenario = "phase1_fresh"
    OutputPath = $OutputPath
    ExpectedPath = (Join-Path $PSScriptRoot "expected_phase1_metrics.json")
    CpuReferencePath = $CpuOutputPath
    WarmupFrames = 64
    SampleFrames = $CandidateSampleFrames
    SettleFrames = 32
    SampleStride = 2
    Phase1LongFrames = $Phase1LongFrames
}
if ($EditorPath) {
    $runnerParameters.EditorPath = $EditorPath
}
if ($Headless) {
    $runnerParameters.Headless = $true
}

& (Join-Path $PSScriptRoot "run_qa.ps1") @runnerParameters
exit $LASTEXITCODE
