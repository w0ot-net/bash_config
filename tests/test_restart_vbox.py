import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
FUNCTION = REPOSITORY / "functions" / "restart_vbox.sh"

FAKE_COMMAND = """#!/usr/bin/env python3
import os
import sys
from pathlib import Path

name = Path(sys.argv[0]).name
args = sys.argv[1:]
log = Path(os.environ["RESTART_VBOX_CALL_LOG"])
with log.open("a", encoding="utf-8") as output:
    output.write(" ".join((name, *args)) + "\\n")

if name == "systemd-detect-virt":
    print(os.environ.get("RESTART_VBOX_VIRTUALIZER", "oracle"))
    raise SystemExit(0)
if name == "systemctl" and args[:1] == ["cat"]:
    raise SystemExit(0 if args[1] == "virtualbox-guest-utils.service" else 1)
if name == "pkill":
    raise SystemExit(1)
raise SystemExit(0)
"""


class RestartVBoxTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.log = self.root / "calls.log"
        self.log.touch()
        self.launcher = self.root / "98vboxadd-xclient"
        self.launcher.write_text(
            """#!/bin/sh
/usr/bin/VBoxClient --clipboard || true
/usr/bin/VBoxClient --seamless || true
/usr/bin/VBoxClient --draganddrop || true
/usr/bin/VBoxClient --checkhostversion || true
/usr/bin/VBoxClient --vmsvga-session || true
/usr/bin/VBoxClient --wayland || true
# /usr/bin/VBoxClient --clipboard || true
""",
            encoding="utf-8",
        )

        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        dispatcher = fake_bin / "dispatcher"
        dispatcher.write_text(FAKE_COMMAND, encoding="utf-8")
        dispatcher.chmod(0o755)
        for name in (
            "VBoxClient",
            "pkill",
            "sleep",
            "sudo",
            "systemctl",
            "systemd-detect-virt",
        ):
            (fake_bin / name).symlink_to(dispatcher)

        self.environment = os.environ.copy()
        self.environment.update(
            {
                "DISPLAY": ":0",
                "HOME": str(self.home),
                "PATH": f"{fake_bin}:{self.environment['PATH']}",
                "RESTART_VBOX_CALL_LOG": str(self.log),
                "RESTART_VBOX_VIRTUALIZER": "oracle",
                "VBOX_XSESSION_LAUNCHER": str(self.launcher),
                "XDG_SESSION_TYPE": "x11",
            }
        )
        self.environment.pop("WAYLAND_DISPLAY", None)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_helper(self) -> subprocess.CompletedProcess[str]:
        command = f"set -u; source {shlex.quote(str(FUNCTION))}; restart_vbox"
        return subprocess.run(
            ["bash", "--noprofile", "--norc", "-c", command],
            check=False,
            capture_output=True,
            text=True,
            env=self.environment,
        )

    def test_installer_links_restart_vbox_function(self) -> None:
        environment = os.environ.copy()
        environment["HOME"] = str(self.home)

        completed = subprocess.run(
            [sys.executable, str(REPOSITORY / "install.py")],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        installed = self.home / ".bash_functions" / "restart_vbox.sh"
        self.assertTrue(installed.is_symlink())
        self.assertEqual(installed.resolve(), FUNCTION)
        bashrc = (self.home / ".bashrc").read_text(encoding="utf-8")
        self.assertIn("# bash_config loader v3", bashrc)

    def test_restarts_safe_clients_and_removes_stale_pid(self) -> None:
        stale_pid = self.home / ".vboxclient-clipboard.pid"
        stale_pid.write_text("123\n", encoding="utf-8")

        completed = self.run_helper()

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(stale_pid.exists())
        calls = self.log.read_text(encoding="utf-8")
        self.assertIn("VBoxClient --clipboard\n", calls)
        self.assertIn("VBoxClient --seamless\n", calls)
        self.assertIn("VBoxClient --checkhostversion\n", calls)
        self.assertIn("VBoxClient --vmsvga-session\n", calls)
        self.assertNotIn("VBoxClient --draganddrop", calls)
        self.assertNotIn("VBoxClient --wayland", calls)
        self.assertRegex(
            calls,
            r"(?:systemctl restart|sudo systemctl restart) "
            r"virtualbox-guest-utils\.service",
        )

    def test_non_virtualbox_guest_is_a_successful_noop(self) -> None:
        self.environment["RESTART_VBOX_VIRTUALIZER"] = "kvm"

        completed = self.run_helper()

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("not a VirtualBox guest", completed.stdout)
        calls = self.log.read_text(encoding="utf-8")
        self.assertNotIn("systemctl", calls)
        self.assertNotIn("VBoxClient", calls)

    def test_wayland_is_rejected_before_restart(self) -> None:
        self.environment["XDG_SESSION_TYPE"] = "wayland"
        self.environment["WAYLAND_DISPLAY"] = "wayland-0"

        completed = self.run_helper()

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Wayland client combines", completed.stderr)
        calls = self.log.read_text(encoding="utf-8")
        self.assertNotIn("systemctl", calls)
        self.assertNotIn("VBoxClient", calls)


if __name__ == "__main__":
    unittest.main()
