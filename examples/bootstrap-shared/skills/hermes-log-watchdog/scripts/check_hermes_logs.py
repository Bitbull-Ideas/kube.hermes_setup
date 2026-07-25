#!/usr/bin/env python3
"""Stateful Hermes log watchdog.

Scans only new bytes since the last run, like a small logtail checkpoint.
Prints an alert only when new warnings/errors are found; silent otherwise.
"""
from __future__ import annotations

import json
import os
import re
from collections import Counter, defaultdict
from pathlib import Path

HOME = Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes")))
LOG_DIR = HOME / "logs"
STATE_DIR = HOME / "state"
CHECKPOINT_FILE = STATE_DIR / "log-watchdog-checkpoints.json"
MAX_READ_BYTES = 1_500_000  # safety cap per file/run; enough for normal 12h deltas

LEVEL_RE = re.compile(r"\b(ERROR|CRITICAL|FATAL|EXCEPTION|TRACEBACK|WARNING)\b", re.I)

# Ignore known benign/repetitive messages here. Keep this list conservative.
IGNORE_PATTERNS = [
    re.compile(r"Auxiliary: marking nous unhealthy for 60s", re.I),
]


def load_checkpoints() -> dict[str, dict[str, int | str]]:
    try:
        if CHECKPOINT_FILE.exists():
            return json.loads(CHECKPOINT_FILE.read_text(encoding="utf-8"))
    except Exception:
        # If state is corrupt, start fresh from EOF below instead of spamming old logs.
        return {}
    return {}


def save_checkpoints(state: dict[str, dict[str, int | str]]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CHECKPOINT_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(CHECKPOINT_FILE)


def normalize(line: str) -> str:
    line = re.sub(r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:,\d+)?\s*", "", line.strip())
    line = re.sub(r'"ts"\s*:\s*"[^"]+"', '"ts":"<ts>"', line)
    line = re.sub(r"\b\d{2}:\d{2}:\d{2}\b", "<time>", line)
    line = re.sub(r"\b[0-9a-f]{8,}\b", "<id>", line, flags=re.I)
    line = re.sub(r"\s+", " ", line)
    return line[:240]


def should_ignore(line: str) -> bool:
    return any(p.search(line) for p in IGNORE_PATTERNS)


def read_new_text(path: Path, checkpoint: dict[str, int | str] | None) -> tuple[str, dict[str, int | str]]:
    st = path.stat()
    inode = str(getattr(st, "st_ino", ""))
    size = int(st.st_size)
    old_offset = int(checkpoint.get("offset", 0)) if checkpoint else None
    old_inode = str(checkpoint.get("inode", "")) if checkpoint else ""

    # First run for a file: checkpoint EOF and stay silent. This avoids reporting old history.
    if checkpoint is None:
        return "", {"inode": inode, "offset": size, "size": size, "mtime_ns": int(st.st_mtime_ns)}

    # Rotation/truncation/inode replacement: start at 0 for the new file.
    start = old_offset if old_inode == inode and old_offset is not None and old_offset <= size else 0

    # Avoid reading insane deltas; jump near the end but still report recent new issues.
    if size - start > MAX_READ_BYTES:
        start = max(0, size - MAX_READ_BYTES)

    with path.open("rb") as f:
        f.seek(start)
        text = f.read(size - start).decode("utf-8", errors="replace")

    return text, {"inode": inode, "offset": size, "size": size, "mtime_ns": int(st.st_mtime_ns)}


def main() -> int:
    if not LOG_DIR.exists():
        print(f"Hermes log check: log directory not found: {LOG_DIR}")
        return 0

    state = load_checkpoints()
    new_state: dict[str, dict[str, int | str]] = {}
    hits_by_file: dict[str, list[str]] = defaultdict(list)
    counters: Counter[str] = Counter()

    for path in sorted(LOG_DIR.glob("*.log")):
        key = str(path.resolve())
        try:
            text, cp = read_new_text(path, state.get(key))
            new_state[key] = cp
        except Exception as e:
            hits_by_file[path.name].append(f"Could not read log: {e}")
            counters[f"{path.name}: read error"] += 1
            continue

        for line in text.splitlines():
            if not LEVEL_RE.search(line):
                continue
            if should_ignore(line):
                continue
            n = normalize(line)
            counters[f"{path.name}: {n}"] += 1
            if len(hits_by_file[path.name]) < 8:
                hits_by_file[path.name].append(line.strip()[:500])

    # Save checkpoints even when alerts are found, so each log line is reported only once.
    save_checkpoints(new_state)

    if not hits_by_file:
        return 0

    total = sum(counters.values())
    print(f"⚠️ Hermes Log-Check: {total} neue Warnungen/Fehler seit dem letzten Check gefunden.")
    print("")
    print("Top-Muster:")
    for item, count in counters.most_common(8):
        print(f"- {count}x {item}")
    print("")
    print("Beispiele:")
    for fname, lines in hits_by_file.items():
        print(f"\n{fname}:")
        for line in lines[:5]:
            print(f"- {line}")
    print("")
    print(f"Quelle: {LOG_DIR}")
    print(f"Checkpoint: {CHECKPOINT_FILE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
