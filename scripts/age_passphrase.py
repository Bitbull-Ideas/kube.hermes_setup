#!/usr/bin/env python3
"""Run age with a passphrase supplied through a private pseudo-terminal.

Purpose: Support non-interactive, password-file-based age encryption/decryption without
putting the passphrase in process arguments, shell history, or ordinary stdin.
Usage: python3 scripts/age_passphrase.py PASSWORD_FILE -- age arguments...
Requirements: Python 3, a local age executable, and a regular password file.
Exit status: Mirrors age's exit status; non-zero identifies validation or age failure.
"""
from __future__ import annotations

import os
import pty
import select
import subprocess
import sys
from pathlib import Path


def main() -> int:
    if "--" not in sys.argv[1:]:
        raise SystemExit("usage: age_passphrase.py PASSWORD_FILE -- age arguments...")
    separator = sys.argv.index("--")
    if separator != 2 or len(sys.argv) <= separator + 1:
        raise SystemExit("usage: age_passphrase.py PASSWORD_FILE -- age arguments...")
    password_path = Path(sys.argv[1])
    if not password_path.is_file():
        raise SystemExit(f"password file not found: {password_path}")
    if password_path.stat().st_mode & 0o077:
        raise SystemExit("password file must not be accessible by group or other users")
    password = password_path.read_text(encoding="utf-8").rstrip("\r\n")
    if not password:
        raise SystemExit("password file must not be empty")

    master, slave = pty.openpty()
    try:
        process = subprocess.Popen(
            ["age", *sys.argv[separator + 1 :]],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
            env={k: v for k, v in os.environ.items() if k not in {"AGE_PASSPHRASE"}},
        )
        os.close(slave)
        slave = -1
        sent = False
        output = bytearray()
        while True:
            ready, _, _ = select.select([master], [], [], 0.25)
            if ready:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    chunk = b""
                if not chunk:
                    break
                output.extend(chunk)
                lower = bytes(output).lower()
                if not sent and (b"passphrase" in lower or b"password" in lower):
                    os.write(master, password.encode() + b"\n")
                    sent = True
            if process.poll() is not None and not ready:
                break
        return_code = process.wait()
        if output:
            sys.stdout.buffer.write(output)
            sys.stdout.buffer.flush()
        return return_code
    finally:
        if slave >= 0:
            os.close(slave)
        os.close(master)


if __name__ == "__main__":
    raise SystemExit(main())
