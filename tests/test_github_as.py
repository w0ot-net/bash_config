import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
FUNCTION = REPOSITORY / "functions" / "github_as.sh"
BASH = shutil.which("bash")

FAKE_COMMAND = r'''
import json
import os
import sys
from pathlib import Path

name = Path(sys.argv[0]).name
args = sys.argv[1:]
record = {"command": name, "args": args}
if name == "observe":
    record.update(
        stdin=sys.stdin.read(),
        token_matches=os.environ.get("GH_TOKEN") == os.environ["GITHUB_AS_EXPECTED_TOKEN"],
        config_dir=os.environ.get("GH_CONFIG_DIR"),
    )
with Path(os.environ["GITHUB_AS_CALL_LOG"]).open("a", encoding="utf-8") as output:
    output.write(json.dumps(record) + "\n")

if name == "gh":
    if len(args) != 6 or args[:5] != ["auth", "token", "--hostname", "github.com", "--user"]:
        raise SystemExit("unexpected gh command")
    mode = os.environ.get("GITHUB_AS_LOOKUP_MODE", "success")
    if mode == "failure":
        print("synthetic-rejected-token")
        raise SystemExit(1)
    if mode == "empty":
        raise SystemExit(0)
    tokens = {"alice": "synthetic-alice-token", "bob": "synthetic-bob-token"}
    if args[5] not in tokens:
        raise SystemExit("account not found")
    print(tokens[args[5]])
    raise SystemExit(0)

if not record["token_matches"]:
    raise SystemExit("wrong account token")
sys.stdout.write(os.environ.get("GITHUB_AS_STDOUT", ""))
sys.stderr.write(os.environ.get("GITHUB_AS_STDERR", ""))
raise SystemExit(int(os.environ.get("GITHUB_AS_EXIT_STATUS", "0")))
'''


class GithubAsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fake_bin = self.root / "bin"
        self.fake_bin.mkdir()
        dispatcher = self.fake_bin / "dispatcher"
        dispatcher.write_text(f"#!{sys.executable}\n{FAKE_COMMAND}", encoding="utf-8")
        dispatcher.chmod(0o755)
        for name in ("gh", "observe"):
            (self.fake_bin / name).symlink_to(dispatcher)
        self.log = self.root / "calls.jsonl"
        self.log.touch()
        self.config_dir = self.root / "gh-config"
        self.config_dir.mkdir()
        self.config = self.config_dir / "hosts.yml"
        self.config.write_text("github.com:\n    user: somebody-else\n", encoding="utf-8")
        self.config_before = self.config.read_bytes()
        self.environment = os.environ.copy()
        self.environment.pop("BASH_ENV", None)
        self.environment.update(
            {
                "PATH": f"{self.fake_bin}:{self.environment['PATH']}",
                "GH_CONFIG_DIR": str(self.config_dir),
                "GH_TOKEN": "synthetic-parent-token",
                "GITHUB_TOKEN": "synthetic-other-parent-token",
                "GITHUB_AS_EXPECTED_TOKEN": "synthetic-alice-token",
                "GITHUB_AS_CALL_LOG": str(self.log),
            }
        )

    def tearDown(self) -> None:
        self.assertEqual(self.config.read_bytes(), self.config_before)
        self.assertEqual(list(self.config_dir.iterdir()), [self.config])
        for call in self.calls():
            if call["command"] == "gh":
                self.assertEqual(
                    call["args"][:5],
                    ["auth", "token", "--hostname", "github.com", "--user"],
                )

    def calls(self) -> list[dict]:
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def run_shell(self, script: str, *arguments: str, stdin: str = "") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [BASH, "--noprofile", "--norc", "-c",
             f"set -u; source {shlex.quote(str(FUNCTION))}; {script}",
             "github-as-test", *arguments],
            input=stdin,
            capture_output=True,
            text=True,
            env=self.environment,
            check=False,
        )

    def run_helper(self, *arguments: str, stdin: str = "") -> subprocess.CompletedProcess[str]:
        return self.run_shell('github_as "$@"', *arguments, stdin=stdin)

    def test_selects_each_account_despite_ambient_tokens(self) -> None:
        for account in ("alice", "bob"):
            with self.subTest(account=account):
                self.environment["GITHUB_AS_EXPECTED_TOKEN"] = f"synthetic-{account}-token"
                completed = self.run_helper(account, "observe")
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(completed.stdout, "")
                self.assertEqual(completed.stderr, "")
        calls = self.calls()
        self.assertEqual([call["command"] for call in calls], ["gh", "observe", "gh", "observe"])
        self.assertEqual([calls[0]["args"][-1], calls[2]["args"][-1]], ["alice", "bob"])
        for call in (calls[1], calls[3]):
            self.assertTrue(call["token_matches"])
            self.assertEqual(call["config_dir"], str(self.config_dir))

    def test_preserves_arguments_streams_and_exit_status(self) -> None:
        self.environment.update(
            GITHUB_AS_STDOUT="command output\n",
            GITHUB_AS_STDERR="command error\n",
            GITHUB_AS_EXIT_STATUS="37",
        )
        arguments = ("two words", "", "$(exit 99)", "*", "; exit 98", "--flag")
        completed = self.run_helper("alice", "observe", *arguments, stdin="input\n")
        self.assertEqual(completed.returncode, 37, completed.stderr)
        self.assertEqual(completed.stdout, "command output\n")
        self.assertEqual(completed.stderr, "command error\n")
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1]["args"], list(arguments))
        self.assertEqual(calls[1]["stdin"], "input\n")

    def test_rejects_missing_inputs_before_lookup(self) -> None:
        for arguments in ((), ("alice",), ("", "observe"), ("alice", "")):
            with self.subTest(arguments=arguments):
                completed = self.run_helper(*arguments)
                self.assertEqual(completed.returncode, 2)
                self.assertIn("usage: github_as", completed.stderr)
                self.assertEqual(completed.stdout, "")
        self.assertEqual(self.calls(), [])

    def test_missing_gh_stops_execution(self) -> None:
        (self.fake_bin / "gh").unlink()
        self.environment["PATH"] = str(self.fake_bin)
        completed = self.run_helper("alice", "observe")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("gh not found", completed.stderr)
        self.assertEqual(self.calls(), [])

    def test_failed_empty_and_unknown_account_lookups_stop_execution(self) -> None:
        for mode, account in (("failure", "alice"), ("empty", "alice"), ("success", "unknown")):
            with self.subTest(mode=mode, account=account):
                self.environment["GITHUB_AS_LOOKUP_MODE"] = mode
                completed = self.run_helper(account, "observe")
                self.assertEqual(completed.returncode, 1)
                self.assertIn(account, completed.stderr)
                self.assertIn("gh auth login --hostname github.com", completed.stderr)
                self.assertEqual(completed.stdout, "")
                self.assertNotIn("synthetic-rejected-token", completed.stderr)
        self.assertEqual([call["command"] for call in self.calls()], ["gh"] * 3)

    def test_preserves_missing_command_status(self) -> None:
        completed = self.run_helper("alice", str(self.root / "missing-command"))
        self.assertEqual(completed.returncode, 127)
        self.assertEqual(len(self.calls()), 1)

    def test_preserves_parent_environment_and_xtrace_on_success_and_failure(self) -> None:
        for tokens_set in (True, False):
            for mode in ("success", "failure"):
                with self.subTest(tokens_set=tokens_set, mode=mode):
                    self.environment["GITHUB_AS_LOOKUP_MODE"] = mode
                    if not tokens_set:
                        self.environment.pop("GH_TOKEN", None)
                        self.environment.pop("GITHUB_TOKEN", None)
                    completed = self.run_shell('''
                        set -x
                        github_as alice observe
                        github_as_test_status=$?
                        case $- in *x*) ;; *) exit 90 ;; esac
                        set +x
                        printf '%s\n' "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}" "$github_as_test_status"
                    ''')
                    self.assertEqual(completed.returncode, 0, completed.stderr)
                    expected_tokens = (
                        ["synthetic-parent-token", "synthetic-other-parent-token"]
                        if tokens_set else ["unset", "unset"]
                    )
                    self.assertEqual(
                        completed.stdout.splitlines(),
                        [*expected_tokens, "0" if mode == "success" else "1"],
                    )
                    for secret in ("synthetic-alice-token", "synthetic-rejected-token"):
                        self.assertNotIn(secret, completed.stdout + completed.stderr)

    def test_installer_links_and_exports_function(self) -> None:
        test_home = self.root / "home"
        test_home.mkdir()
        environment = self.environment.copy()
        environment["HOME"] = str(test_home)
        installed = subprocess.run(
            [sys.executable, str(REPOSITORY / "install.py")],
            capture_output=True,
            text=True,
            env=environment,
            check=False,
        )
        self.assertEqual(installed.returncode, 0, installed.stderr)
        linked = test_home / ".bash_functions" / "github_as.sh"
        self.assertTrue(linked.is_symlink())
        self.assertEqual(linked.resolve(), FUNCTION)
        completed = subprocess.run(
            [BASH, "--noprofile", "--norc", "-c",
             'source "$HOME/.bashrc"; bash --noprofile --norc -c "github_as alice observe"'],
            input="",
            capture_output=True,
            text=True,
            env=environment,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual([call["command"] for call in self.calls()], ["gh", "observe"])


if __name__ == "__main__":
    unittest.main()
