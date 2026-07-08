#!/usr/bin/env python3
import os
import re
import sys
from pathlib import Path

if len(sys.argv) != 3:
    print("usage: render_template.py TEMPLATE OUTPUT", file=sys.stderr)
    sys.exit(2)

tpl = Path(sys.argv[1]).read_text()

# Handle the few shell-style conditional blocks used in the manifest template.
storage_line = "${STORAGE_CLASS_NAME:+storageClassName: ${STORAGE_CLASS_NAME}}"
storage = os.environ.get("STORAGE_CLASS_NAME", "")
tpl = tpl.replace(storage_line, f"storageClassName: {storage}" if storage else "")

for host_var in ("WEBUI_HOST", "DASHBOARD_HOST"):
    block = "${TLS_SECRET_NAME:+tls:\n  - hosts:\n    - ${" + host_var + "}\n    secretName: ${TLS_SECRET_NAME}}"
    tls_secret = os.environ.get("TLS_SECRET_NAME", "")
    host = os.environ.get(host_var, "")
    replacement = f"tls:\n  - hosts:\n    - {host}\n    secretName: {tls_secret}" if tls_secret else ""
    tpl = tpl.replace(block, replacement)

pattern = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-(.*?))?\}")

def repl(match: re.Match[str]) -> str:
    name, default = match.group(1), match.group(2)
    return os.environ.get(name, default or "")

out = pattern.sub(repl, tpl)
leftovers = re.findall(r"\$\{[^}]+\}", out)
if leftovers:
    print("unrendered placeholders remain:", ", ".join(sorted(set(leftovers))), file=sys.stderr)
    sys.exit(1)

Path(sys.argv[2]).parent.mkdir(parents=True, exist_ok=True)
Path(sys.argv[2]).write_text(out)
