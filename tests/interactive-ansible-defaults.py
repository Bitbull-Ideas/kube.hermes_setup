#!/usr/bin/env python3
"""Exercise blank interactive Ansible answers for every bootstrap profile."""
from __future__ import annotations

import os
import pty
import select
import signal
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILES = ROOT / "examples" / "bootstrap-profiles"
TIMEOUT = 20.0


def profile_bool_default(profile: Path, setting: str) -> bool:
    for line in (profile / "defaults.conf").read_text().splitlines():
        if line.startswith(setting + "="):
            value = line.split("=", 1)[1]
            if value in {"true", "false"}:
                return value == "true"
    raise AssertionError(f"{profile.name}: missing valid {setting} profile default")


def expect(fd: int, transcript: bytearray, needle: str) -> None:
    target = needle.encode()
    deadline = time.monotonic() + TIMEOUT
    while target not in transcript:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError(
                f"timed out waiting for {needle!r}\n"
                + transcript.decode(errors="replace")[-4000:]
            )
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            raise AssertionError(
                f"wizard exited before {needle!r}\n"
                + transcript.decode(errors="replace")[-4000:]
            )
        transcript.extend(chunk)


def answer(fd: int, transcript: bytearray, prompt: str, value: str = "") -> None:
    expect(fd, transcript, prompt)
    os.write(fd, (value + "\n").encode())


def read_assignment(path: Path, name: str) -> str:
    for line in path.read_text().splitlines():
        if line.startswith(name + "="):
            return line.split("=", 1)[1]
    raise AssertionError(f"{name} missing from {path}")


def drain_pty(fd: int, transcript: bytearray) -> None:
    while True:
        ready, _, _ = select.select([fd], [], [], 0)
        if not ready:
            return
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            return
        if not chunk:
            return
        transcript.extend(chunk)


def terminate_and_reap(pid: int) -> None:
    try:
        waited, _ = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        return
    if waited == pid:
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        try:
            waited, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return
        if waited == pid:
            return
        time.sleep(0.05)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


def run_profile(profile: Path, work: Path) -> None:
    expected = profile_bool_default(profile, "HERMES_PROFILE_DEFAULT_ANSIBLE_SETUP")
    expected_ssh = profile_bool_default(profile, "HERMES_PROFILE_DEFAULT_SSH_SETUP")
    config = work / f"config-{profile.name}"
    answers = work / f"answers-{profile.name}"
    env = os.environ.copy()
    for name in list(env):
        if name.startswith("HERMES_") or name in {
            "MODEL_PROVIDER",
            "MODEL_NAME",
            "DASHBOARD_AUTH_USER",
            "DASHBOARD_AUTH_PASSWORD",
            "WEBUI_HOST",
            "DASHBOARD_HOST",
        }:
            env.pop(name, None)

    pid, fd = pty.fork()
    if pid == 0:
        os.execve(
            str(ROOT / "configure.sh"),
            [
                str(ROOT / "configure.sh"),
                "--no-install",
                "--config-dir",
                str(config),
                "--answers-file",
                str(answers),
            ],
            env,
        )

    transcript = bytearray()
    child_reaped = False
    try:
        answer(fd, transcript, "Kubernetes namespace [hermes]:")
        answer(fd, transcript, "Select profile [", profile.name)
        answer(fd, transcript, "Hermes model provider [openai-codex]:")
        answer(fd, transcript, "Hermes model [gpt-5.6-luna]:")
        answer(fd, transcript, "Hermes Agent container image [nousresearch/hermes-agent:latest]:")
        answer(fd, transcript, "Hermes WebUI container image [ghcr.io/nesquena/hermes-webui:latest]:")
        answer(fd, transcript, "Browserless Chromium container image [ghcr.io/browserless/chromium:latest]:")
        answer(fd, transcript, "Image pull policy [IfNotPresent] (IfNotPresent/Always):")
        answer(fd, transcript, "Install Dashboard? [Y/n]:", "n")
        answer(fd, transcript, "Install WebUI? [Y/n]:", "n")
        answer(fd, transcript, "Install Browserless Chromium? [Y/n]:", "n")

        suffix = "Y/n" if expected else "y/N"
        answer(fd, transcript, f"Install and configure Ansible? [{suffix}]:")
        if expected:
            answer(fd, transcript, "Ansible package version [14.1.0]:")
        else:
            ssh_suffix = "Y/n" if expected_ssh else "y/N"
            answer(fd, transcript, f"Prepare a persistent SSH keypair? [{ssh_suffix}]:")
        answer(fd, transcript, "Prepare Node.js/npx for MCP and skill support?", "n")
        answer(fd, transcript, "Install addon Python packages? [y/N]:", "n")
        answer(fd, transcript, "Overwrite existing bootstrap-managed files on the PVC? [y/N]:", "n")

        deadline = time.monotonic() + TIMEOUT
        while True:
            waited, status = os.waitpid(pid, os.WNOHANG)
            if waited == pid:
                child_reaped = True
                drain_pty(fd, transcript)
                if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
                    raise AssertionError(
                        f"{profile.name}: wizard exited with status {status}\n"
                        + transcript.decode(errors="replace")[-4000:]
                    )
                break
            if time.monotonic() >= deadline:
                raise AssertionError(f"{profile.name}: wizard did not exit")
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    transcript.extend(os.read(fd, 65536))
                except OSError:
                    pass
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        if not child_reaped:
            terminate_and_reap(pid)

    value = "true" if expected else "false"
    assert read_assignment(config / "hermes.env", "HERMES_ANSIBLE_SETUP") == value
    assert read_assignment(answers, "HERMES_ANSIBLE_SETUP") == value
    output = transcript.decode(errors="replace")
    summary = f"Ansible:     {value}" + (" (14.1.0)" if expected else "")
    assert summary in output, f"{profile.name}: summary mismatch\n{output[-2000:]}"
    if expected:
        assert read_assignment(config / "hermes.env", "HERMES_SSH_SETUP") == "true"
        assert read_assignment(answers, "HERMES_SSH_SETUP") == "true"
        assert "SSH key setup enabled because Ansible was selected." in output


def main() -> None:
    work = Path(os.environ["TEST_TMP_DIR"])
    profiles = sorted(path for path in PROFILES.iterdir() if (path / "defaults.conf").is_file())
    assert profiles, "no bootstrap profiles discovered"
    for profile in profiles:
        run_profile(profile, work)
    print(f"interactive Ansible defaults passed for {len(profiles)} profiles")


if __name__ == "__main__":
    main()
