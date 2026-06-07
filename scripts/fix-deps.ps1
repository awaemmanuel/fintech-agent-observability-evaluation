# fix-deps.ps1 — repair the langchain-core version conflict (Windows PowerShell)
#
# WHY THIS EXISTS:
#   guardrails-ai (installed via requirements.txt) declares a hard requirement on
#   langchain-core >=1.0. pip installs it LAST and silently upgrades langchain-core
#   to the 1.x line — which is incompatible with langchain 0.3.x, the version the
#   agent is built on. The result is a fatal import at runtime:
#
#     ImportError: cannot import name 'PipelinePromptTemplate' from 'langchain_core.prompts'
#
#   This script pins langchain-core and langsmith back to the 0.3.x line. The agent
#   (Modules A/B/D) then works. guardrails (Module C) still imports and runs fine
#   under 0.3.x — pip prints a cosmetic version-conflict warning you can ignore.
#
# USAGE (with your venv activated):
#   powershell -ExecutionPolicy Bypass -File scripts\fix-deps.ps1
#
# Run this AFTER:  pip install -r requirements.txt

$ErrorActionPreference = "Stop"

# Move to the repo root (this script lives in <repo>\scripts\)
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

# Refuse to run outside a virtualenv — otherwise this installs into the wrong Python.
if (-not $env:VIRTUAL_ENV) {
    Write-Host "ERROR: no virtualenv is active. Activate it first, then re-run:"
    Write-Host "    .\.venv\Scripts\Activate.ps1"
    Write-Host "    powershell -ExecutionPolicy Bypass -File scripts\fix-deps.ps1"
    exit 1
}

Write-Host "==> Pinning langchain-core + langsmith back to the 0.3.x line..."
python -m pip install "langchain-core>=0.3.63,<0.4" "langsmith>=0.1.125,<0.4"

Write-Host ""
Write-Host "==> Verifying the agent imports cleanly..."
python -c "import sys; sys.path.insert(0, 'project'); from fintech_support_agent import build_support_agent, ask; print('OK - agent imports cleanly. Modules A/B/D are ready.')"

Write-Host ""
Write-Host "Done. (A 'guardrails-ai requires langchain-core>=1.0' pip warning is expected and harmless.)"
