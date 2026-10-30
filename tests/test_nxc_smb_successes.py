import os
import shlex
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
FUNCTION = REPOSITORY / "functions" / "nxc_smb_successes.sh"


class NxcSmbSuccessesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.nxc_path = self.root / ".nxc"
        self.workspace = "assessment"
        workspace_dir = self.nxc_path / "workspaces" / self.workspace
        workspace_dir.mkdir(parents=True)
        (self.nxc_path / "nxc.conf").write_text(
            f"[nxc]\nworkspace = {self.workspace}\n",
            encoding="utf-8",
        )
        self.database = workspace_dir / "smb.db"
        with sqlite3.connect(self.database) as connection:
            connection.executescript(
                """
                CREATE TABLE hosts (
                    id INTEGER PRIMARY KEY,
                    ip TEXT,
                    hostname TEXT,
                    os TEXT
                );
                CREATE TABLE loggedin_relations (
                    id INTEGER PRIMARY KEY,
                    userid INTEGER,
                    hostid INTEGER
                );
                CREATE TABLE admin_relations (
                    id INTEGER PRIMARY KEY,
                    userid INTEGER,
                    hostid INTEGER
                );
                INSERT INTO hosts VALUES
                    (1, '192.0.2.10', 'WS10', 'Windows 11 Pro'),
                    (2, '192.0.2.20', 'WS20', 'Windows 10 Enterprise');
                INSERT INTO loggedin_relations VALUES
                    (1, 7, 1),
                    (2, 7, 2);
                INSERT INTO admin_relations VALUES (1, 7, 1);
                """
            )
        self.environment = os.environ.copy()
        self.environment["NXC_PATH"] = str(self.nxc_path)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_helper(self, argument: str = "") -> subprocess.CompletedProcess[str]:
        command = (
            f"source {shlex.quote(str(FUNCTION))}; "
            f"nxc_smb_successes {shlex.quote(argument)}"
        )
        return subprocess.run(
            ["bash", "--noprofile", "--norc", "-c", command],
            check=False,
            capture_output=True,
            text=True,
            env=self.environment,
        )

    def test_reports_successful_hosts_from_active_workspace(self) -> None:
        completed = self.run_helper()

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("192.0.2.10", completed.stdout)
        self.assertIn("Windows 11 Pro", completed.stdout)
        self.assertIn("yes", completed.stdout)
        self.assertIn("192.0.2.20", completed.stdout)
        self.assertIn("Windows 10 Enterprise", completed.stdout)
        self.assertIn("no", completed.stdout)

    def test_accepts_an_explicit_workspace(self) -> None:
        (self.nxc_path / "nxc.conf").write_text(
            "[nxc]\nworkspace = missing\n",
            encoding="utf-8",
        )

        completed = self.run_helper(self.workspace)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("192.0.2.10", completed.stdout)

    def test_missing_database_is_reported_without_creating_it(self) -> None:
        missing = self.nxc_path / "workspaces" / "missing" / "smb.db"

        completed = self.run_helper("missing")

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("cannot read", completed.stderr)
        self.assertFalse(missing.exists())


if __name__ == "__main__":
    unittest.main()
