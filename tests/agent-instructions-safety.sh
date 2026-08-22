#!/usr/bin/env bash
# Purpose: Keep root agent instructions compatible with common security scanners.
# Scope: Reject inline insecure fetches and download-to-execution patterns in AGENTS.md.
# Usage: ./tests/agent-instructions-safety.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS="$ROOT_DIR/AGENTS.md"

[[ -f "$AGENTS" ]]

if grep -Ein -- '\bwget\b|http://' "$AGENTS"; then
  printf 'AGENTS.md contains a scanner-sensitive fetch pattern.\n' >&2
  exit 1
fi

python3 - "$AGENTS" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
patterns = {
    "download piped to shell": r"(?im)^.*\b(?:curl|wget)\b.*\|\s*(?:ba)?sh\b",
    "download followed by execution": r"(?is)\b(?:curl|wget)\b.{0,300}\b(?:chmod\s+\+x|(?:ba)?sh\s+|\./)",
}
for label, pattern in patterns.items():
    if re.search(pattern, text):
        raise SystemExit(f"AGENTS.md contains {label}")
PY

grep -Fq 'Operator-run diagnostic; agents must not execute it automatically.' "$AGENTS"
grep -Fq './doctor.sh' "$AGENTS"

printf 'agent instruction safety checks passed\n'
