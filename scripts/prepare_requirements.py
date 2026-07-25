#!/usr/bin/env python3
"""Prepare installer-owned addon requirements without modifying source files.

Purpose: Add or remove the pinned Ansible runtime line in a generated requirements file.
Usage: python3 scripts/prepare_requirements.py OUTPUT ANSIBLE_SETUP ANSIBLE_VERSION REMOVE_WHEN_DISABLED
Exit status: 0 on success; non-zero for invalid arguments or an invalid Ansible version.
"""

import re
import sys
from pathlib import Path

if len(sys.argv) != 5:
    raise SystemExit(
        "usage: prepare_requirements.py OUTPUT ANSIBLE_SETUP ANSIBLE_VERSION REMOVE_WHEN_DISABLED"
    )

output = Path(sys.argv[1])
setup = sys.argv[2].lower() in {"1", "true", "yes", "on"}
version = sys.argv[3]
remove_when_disabled = sys.argv[4].lower() in {"1", "true", "yes", "on"}
lines = output.read_text().splitlines() if output.exists() else []
ansible_requirement = re.compile(
    r"^\s*ansible(?:\s*(?:[#;@<>=!~].*)?)?\s*$", re.IGNORECASE
)

if setup or remove_when_disabled:
    lines = [line for line in lines if not ansible_requirement.match(line)]
if setup:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version):
        raise SystemExit("Ansible version must look like 14.1.0")
    if lines and lines[-1] != "":
        lines.append("")
    lines.extend(["# ansible runtime selected by HERMES_ANSIBLE_SETUP", f"ansible=={version}"])

if lines:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n")
elif output.exists():
    output.unlink()
