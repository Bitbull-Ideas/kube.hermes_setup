#!/usr/bin/env python3
"""Exercise the interactive profile-default matrix through real PTYs."""
from __future__ import annotations

import os
import pty
import select
import signal
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILES = ROOT / "examples" / "bootstrap-profiles"
TIMEOUT = 20.0
FLAGS = {
    "ansible": ("HERMES_ANSIBLE_SETUP", "HERMES_PROFILE_DEFAULT_ANSIBLE_SETUP"),
    "ssh": ("HERMES_SSH_SETUP", "HERMES_PROFILE_DEFAULT_SSH_SETUP"),
    "npx": ("HERMES_NPX_SETUP", "HERMES_PROFILE_DEFAULT_NPX_SETUP"),
}


def profile_defaults(profile: Path) -> dict[str, bool]:
    raw: dict[str, str] = {}
    for line in (profile / "defaults.conf").read_text().splitlines():
        if "=" in line:
            name, value = line.split("=", 1)
            raw[name] = value
    result: dict[str, bool] = {}
    for flag, (_, profile_name) in FLAGS.items():
        value = raw.get(profile_name)
        if value not in {"true", "false"}:
            raise AssertionError(f"{profile.name}: missing valid {profile_name}")
        result[flag] = value == "true"
    return result


def clean_env(overrides: dict[str, str] | None = None) -> dict[str, str]:
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
    env.update(overrides or {})
    return env


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


def bool_suffix(value: bool) -> str:
    return "Y/n" if value else "y/N"


def bool_text(value: bool) -> str:
    return "true" if value else "false"


def read_assignment(path: Path, name: str) -> str:
    for line in path.read_text().splitlines():
        if line.startswith(name + "="):
            return line.split("=", 1)[1]
    raise AssertionError(f"{name} missing from {path}")


def replace_assignments(path: Path, values: dict[str, str]) -> None:
    lines: list[str] = []
    seen: set[str] = set()
    for line in path.read_text().splitlines():
        name = line.split("=", 1)[0] if "=" in line else ""
        if name in values:
            line = f"{name}={values[name]}"
            seen.add(name)
        lines.append(line)
    for name, value in values.items():
        if name not in seen:
            lines.append(f"{name}={value}")
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o600)


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


def expected_values(
    defaults: dict[str, bool],
    target: str | None,
    value: bool | None,
    preset: dict[str, bool] | None = None,
) -> dict[str, bool]:
    expected = dict(defaults)
    expected.update(preset or {})
    if target is not None:
        assert value is not None
        expected[target] = value
        if target == "ssh":
            expected["ansible"] = False
    if expected["ansible"]:
        expected["ssh"] = True
    return expected


def assert_outputs(
    profile: Path,
    case: str,
    config: Path,
    answers: Path,
    expected: dict[str, bool],
    output: str,
    requirements_from_profile: bool = True,
    requirements_marker: str | None = None,
) -> None:
    for flag, (setting, _) in FLAGS.items():
        value = bool_text(expected[flag])
        assert read_assignment(config / "hermes.env", setting) == value, (
            f"{profile.name}/{case}: {setting} environment mismatch"
        )
        assert read_assignment(answers, setting) == value, (
            f"{profile.name}/{case}: {setting} answers mismatch"
        )
    ansible_summary = "Ansible:     " + bool_text(expected["ansible"])
    if expected["ansible"]:
        ansible_summary += " (14.1.0)"
    assert ansible_summary in output, f"{profile.name}/{case}: Ansible summary mismatch"
    assert f"NPX:         {bool_text(expected['npx'])}" in output, (
        f"{profile.name}/{case}: NPX summary mismatch"
    )
    assert f"SSH keys:    {bool_text(expected['ssh'])}" in output, (
        f"{profile.name}/{case}: SSH summary mismatch"
    )
    requirements = config / "addon-requirements.txt"
    assert requirements.is_file(), f"{profile.name}/{case}: addon requirements missing"
    assert read_assignment(config / "hermes.env", "HERMES_ADDON_REQUIREMENTS") == str(requirements)
    answer_requirements = Path(read_assignment(answers, "HERMES_ADDON_REQUIREMENTS"))
    assert answer_requirements.is_file(), f"{profile.name}/{case}: saved requirements path missing"
    requirement_lines = requirements.read_text().splitlines()
    profile_requirements_value = bool_text(requirements_from_profile)
    assert read_assignment(config / "hermes.env", "HERMES_PROFILE_REQUIREMENTS_SELECTED") == profile_requirements_value
    assert read_assignment(answers, "HERMES_PROFILE_REQUIREMENTS_SELECTED") == profile_requirements_value
    if requirements_marker is not None:
        assert requirements_marker in requirement_lines
    ansible_lines = [line for line in requirement_lines if line.startswith("ansible==")]
    if requirements_from_profile and not expected["ansible"]:
        assert not ansible_lines, f"{profile.name}/{case}: disabled Ansible remains in profile requirements"


def run_interactive(
    profile: Path,
    work: Path,
    case: str,
    target: str | None = None,
    value: bool | None = None,
    reused_answers: Path | None = None,
    preset: dict[str, bool] | None = None,
    addon_requirements: Path | None = None,
) -> tuple[Path, Path]:
    defaults = profile_defaults(profile)
    expected = expected_values(defaults, target, value, preset)
    config = work / f"config-{profile.name}-{case}"
    answers = work / f"answers-{profile.name}-{case}"
    prompt_defaults = {**defaults, **(preset or {})}
    if reused_answers is not None:
        answers.write_bytes(reused_answers.read_bytes())
        answers.chmod(0o600)
        prompt_defaults = {
            flag: read_assignment(answers, setting) == "true"
            for flag, (setting, _) in FLAGS.items()
        }
        expected = expected_values(prompt_defaults, target, value)

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
            clean_env(
                {
                    FLAGS[flag][0]: bool_text(setting_value)
                    for flag, setting_value in (preset or {}).items()
                }
                | (
                    {"HERMES_ADDON_REQUIREMENTS": str(addon_requirements)}
                    if addon_requirements is not None
                    else {}
                )
            ),
        )

    transcript = bytearray()
    child_reaped = False
    try:
        if reused_answers is not None:
            answer(fd, transcript, "Reuse existing configuration answers from", "y")
        answer(fd, transcript, "Kubernetes namespace [")
        answer(fd, transcript, "Select profile [", profile.name if reused_answers is None else "")
        answer(fd, transcript, "Hermes model provider [")
        answer(fd, transcript, "Hermes model [")
        answer(fd, transcript, "Hermes Agent container image [")
        answer(fd, transcript, "Hermes WebUI container image [")
        answer(fd, transcript, "Browserless Chromium container image [")
        answer(fd, transcript, "Image pull policy [")
        answer(fd, transcript, "Install Dashboard? [", "n")
        answer(fd, transcript, "Install WebUI? [", "n")
        answer(fd, transcript, "Install Browserless Chromium? [", "n")

        ansible_default = prompt_defaults["ansible"]
        ansible_answer = ""
        if target == "ansible":
            ansible_answer = "y" if value else "n"
        elif target == "ssh":
            ansible_answer = "n"
        answer(
            fd,
            transcript,
            f"Install and configure Ansible? [{bool_suffix(ansible_default)}]:",
            ansible_answer,
        )
        selected_ansible = (
            value if target == "ansible" else False if target == "ssh" else ansible_default
        )
        if selected_ansible:
            answer(fd, transcript, "Ansible package version [")
        else:
            ssh_default = prompt_defaults["ssh"]
            ssh_answer = ""
            if target == "ssh":
                ssh_answer = "y" if value else "n"
            answer(
                fd,
                transcript,
                f"Prepare a persistent SSH keypair? [{bool_suffix(ssh_default)}]:",
                ssh_answer,
            )

        npx_default = prompt_defaults["npx"]
        npx_answer = ""
        if target == "npx":
            npx_answer = "y" if value else "n"
        answer(
            fd,
            transcript,
            f"Prepare Node.js/npx for MCP and skill support? [{bool_suffix(npx_default)}]:",
            npx_answer,
        )
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
                        f"{profile.name}/{case}: wizard exited with status {status}\n"
                        + transcript.decode(errors="replace")[-4000:]
                    )
                break
            if time.monotonic() >= deadline:
                raise AssertionError(f"{profile.name}/{case}: wizard did not exit")
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

    assert_outputs(
        profile,
        case,
        config,
        answers,
        expected,
        transcript.decode(errors="replace"),
        requirements_from_profile=addon_requirements is None,
        requirements_marker="custom-package==1.0" if addon_requirements is not None else None,
    )
    return config, answers


def run_replay(
    profile: Path,
    work: Path,
    case: str,
    source_answers: Path,
    expected: dict[str, bool],
) -> None:
    answers = work / f"answers-{profile.name}-{case}"
    answers.write_bytes(source_answers.read_bytes())
    answers.chmod(0o600)
    config = work / f"config-{profile.name}-{case}"
    result = subprocess.run(
        [
            str(ROOT / "configure.sh"),
            "--from-answers",
            "--no-install",
            "--config-dir",
            str(config),
            "--answers-file",
            str(answers),
        ],
        cwd=ROOT,
        env=clean_env(),
        text=True,
        capture_output=True,
        timeout=TIMEOUT,
        check=False,
    )
    output = result.stdout + result.stderr
    if result.returncode != 0:
        raise AssertionError(f"{profile.name}/{case}: replay failed\n{output[-4000:]}")
    assert "Rebuilding current_config from" in output
    assert_outputs(profile, case, config, answers, expected, output)


def main() -> None:
    work = Path(os.environ["TEST_TMP_DIR"])
    work.mkdir(parents=True, exist_ok=True)
    profiles = sorted(path for path in PROFILES.iterdir() if (path / "defaults.conf").is_file())
    assert profiles, "no bootstrap profiles discovered"
    cases = 0
    for profile in profiles:
        defaults = profile_defaults(profile)
        custom_requirements = work / f"custom-requirements-{profile.name}.txt"
        custom_requirements.write_text("custom-package==1.0\nansible==99.0.0\n")
        _, baseline_answers = run_interactive(profile, work, "blank")
        cases += 1
        run_interactive(
            profile,
            work,
            "process-environment",
            preset={"ansible": False, "ssh": False, "npx": not defaults["npx"]},
        )
        cases += 1
        run_interactive(
            profile,
            work,
            "process-addon-requirements",
            preset={"ansible": False},
            addon_requirements=custom_requirements,
        )
        cases += 1
        for target in FLAGS:
            for value in (False, True):
                run_interactive(profile, work, f"explicit-{target}-{bool_text(value)}", target, value)
                cases += 1

                saved = work / f"saved-{profile.name}-{target}-{bool_text(value)}"
                saved.write_bytes(baseline_answers.read_bytes())
                replay_expected = expected_values(defaults, target, value)
                replace_assignments(
                    saved,
                    {
                        **{
                            setting: bool_text(replay_expected[flag])
                            for flag, (setting, _) in FLAGS.items()
                        },
                        "HERMES_ANSIBLE_VERSION": (
                            "14.1.0" if replay_expected["ansible"] else ""
                        ),
                    },
                )
                run_interactive(
                    profile,
                    work,
                    f"reuse-{target}-{bool_text(value)}",
                    reused_answers=saved,
                )
                cases += 1
                run_replay(
                    profile,
                    work,
                    f"replay-{target}-{bool_text(value)}",
                    saved,
                    replay_expected,
                )
                cases += 1
    print(f"interactive profile-default matrix passed: {len(profiles)} profiles, {cases} cases")


if __name__ == "__main__":
    main()
