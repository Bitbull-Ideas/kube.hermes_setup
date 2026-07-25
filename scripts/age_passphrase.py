#!/usr/bin/env python3
"""Run age with a passphrase supplied through a pseudo-terminal.

Purpose: Support non-interactive, password-file-based age encryption/decryption
without putting the passphrase in process arguments, shell history, or ordinary stdin.
Uses the `script -q -c` utility to create a proper PTY session for `age`.

Usage: python3 scripts/age_passphrase.py PASSWORD_FILE -- age arguments...
Requirements: Python 3, `script` (util-linux), a local age executable, and a regular password file.
Exit status: Mirrors age's exit status; non-zero identifies validation or age failure.
"""
from __future__ import annotations

import os
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

    # Verify age is available
    try:
        subprocess.check_output(["sh", "-c", "command -v age"], text=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        raise SystemExit("Missing required command: age. Install it on Fedora/RHEL with: dnf install age.")

    # Verify script is available
    try:
        subprocess.check_output(["sh", "-c", "command -v script"], text=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        raise SystemExit("Missing required command: script. Install it with: dnf install util-linux")

    # Build the age command string (without the leading "age" executable name)
    argv = sys.argv[separator + 1 :]
    if argv and argv[0] == "age":
        argv = argv[1:]

    # For --passphrase (encryption), age prompts twice: password + confirmation.
    # For --decrypt, age prompts once.
    is_encrypt = "--passphrase" in argv or "-p" in argv
    if is_encrypt:
        stdin_data = f"{password}\n{password}\n"
    else:
        stdin_data = f"{password}\n"

    # Use script -q -c to create a proper PTY for age
    age_cmd = "age " + " ".join(shlex_quote(a) for a in argv)
    script_cmd = ["script", "-q", "-c", age_cmd, "/dev/null"]

    result = subprocess.run(
        script_cmd,
        input=stdin_data,
        capture_output=True,
        text=True,
        timeout=300,
        env={k: v for k, v in os.environ.items() if k not in {"AGE_PASSPHRASE"}},
    )
    # Forward age's stdout and stderr
    if result.stdout:
        sys.stdout.write(result.stdout)
    if result.stderr:
        sys.stderr.write(result.stderr)
    return result.returncode


def shlex_quote(s: str) -> str:
    """Simple shell quoting for a single argument."""
    if not s:
        return "''"
    if all(c.isalnum() or c in "._/-" for c in s):
        return s
    return "'" + s.replace("'", "'\\''") + "'"


if __name__ == "__main__":
    raise SystemExit(main())