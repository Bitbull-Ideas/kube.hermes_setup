#!/usr/bin/env python3
"""Verify configure.sh uses one typed model for profile-controlled settings."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
text = (ROOT / "configure.sh").read_text()

entries = {
    "HERMES_ANSIBLE_SETUP": "boolean|HERMES_PROFILE_DEFAULT_ANSIBLE_SETUP|false|Install and configure Ansible?|Ansible",
    "HERMES_SSH_SETUP": "boolean|HERMES_PROFILE_DEFAULT_SSH_SETUP|true|Prepare a persistent SSH keypair?|SSH keys",
    "HERMES_ADDON_REQUIREMENTS": "path|HERMES_PROFILE_DEFAULT_ADDON_REQUIREMENTS|||Addon packages",
}

assert "PROFILE_SETTING_DEFINITIONS=(" in text
for setting, fields in entries.items():
    assert f"'{setting}|{fields}'" in text, setting

assert "load_profile_setting_defaults" in text
assert "resolve_profile_setting_default" in text
assert "resolve_missing_profile_settings" in text
assert "prompt_profile_boolean_setting" in text
assert text.count('write_profile_settings "$ENV_OUT" environment') == 1
assert text.count('write_profile_settings "$ANSWERS_FILE" answers') == 1
assert "print_profile_setting_summary" in text

for old_name in (
    "profile_ssh_default",
    "profile_ansible_default",
    "profile_npx_default",
):
    assert old_name not in text

late_comment = "Resolve remaining profile defaults not set by wizard questions."
assert late_comment not in text
assert 'apply_profile_defaults "$HERMES_BOOTSTRAP_PROFILE"' not in text

print("profile resolution model contract passed")
