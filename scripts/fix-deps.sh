#!/usr/bin/env bash
#
# fix-deps.sh — repair the langchain-core version conflict (macOS / Linux)
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
# USAGE (from anywhere, with your venv activated):
#   bash scripts/fix-deps.sh
#
# Run this AFTER:  pip install -r requirements.txt
#
set -euo pipefail

# Move to the repo root (this script lives in <repo>/scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Refuse to run outside a virtualenv — otherwise this installs into the wrong Python.
if [[ -z "${VIRTUAL_ENV:-}" ]]; then
  echo "ERROR: no virtualenv is active. Activate it first, then re-run:"
  echo "    source .venv/bin/activate"
  echo "    bash scripts/fix-deps.sh"
  exit 1
fi

echo "==> Pinning langchain-core + langsmith back to the 0.3.x line..."
python -m pip install "langchain-core>=0.3.63,<0.4" "langsmith>=0.1.125,<0.4"

echo ""
echo "==> Verifying the agent imports cleanly..."
python - <<'PY'
import sys
sys.path.insert(0, "project")
from fintech_support_agent import build_support_agent, ask  # noqa: F401
print("OK — agent imports cleanly. Modules A/B/D are ready.")
PY

echo ""
echo "Done. (A 'guardrails-ai requires langchain-core>=1.0' pip warning is expected and harmless.)"
