# Starts the local Laya decision server for GhostHand (AI_PROVIDER=laya).
# First run downloads the checkpoints from Hugging Face (~1-2 GB each) into the HF cache.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$env:LAYA_HOST = "127.0.0.1"          # local only
$env:LAYA_PORT = "8000"
$env:LAYA_PRELOAD = "1"               # load at startup, so the first GhostHand step isn't slow
# multilingual: reads up to 8,192 tokens (a GhostHand step is ~1.5-3k). typed-decisions: 1,024-token checkpoint.
if (-not $env:LAYA_MODELS) { $env:LAYA_MODELS = "multilingual,typed-decisions" }

& "$PSScriptRoot\.venv\Scripts\laya-serve.exe"
