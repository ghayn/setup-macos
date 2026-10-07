"""Retain real Git repositories while applying dotfiles in disposable homes."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DOTFILES_URL = "https://github.com/ghayn/dotfiles.git"


class ChezmoiSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="setup-macos-chezmoi-")
        self.root = Path(self.temp.name)
        self.account = self.root / "test account"
        self.account.mkdir()
        self.source = self.account / ".local/share/chezmoi"
        self.remote = self.root / "upstream"
        self.remote.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("GIT_", "CHEZMOI_", "XDG_", "ROLLBACK_"))}
        for key in ("BASH_ENV", "ZDOTDIR", "ZIM_HOME", "ZIM_CONFIG_FILE", "CARGO_HOME", "CI", "INSTALLER_ENV"):
            self.env.pop(key, None)
        self.env.update(HOME=str(self.account), TEST_ROOT=str(self.root),
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_TERMINAL_PROMPT="0", GIT_ALLOW_PROTOCOL="file")
        self.git("init", str(self.remote))
        (self.remote / "dot_message.tmpl").write_text("{{ .greeting | default \"hello\" }}\n")
        self.git("-C", str(self.remote), "add", ".")
        self.git("-C", str(self.remote), "-c", "user.name=Setup test",
                 "-c", "user.email=setup@example.invalid", "-c", "commit.gpgsign=false",
                 "commit", "-m", "Fixture")

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        result = subprocess.run(["git", *args], env=self.env, cwd=self.root,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def shell(self, script, ok=True):
        # Git rewrites the public URL to a local fixture, without persisting the
        # rewrite. The cloned origin retains the exact URL used by the installer.
        prelude = 'source ' + shlex.quote(str(ROOT / "setup.sh")) + '''
SETUP_TMP="$TEST_ROOT/work"; mkdir -p "$SETUP_TMP"
WITH_DOTFILES=1
git() {
  command git -c "url.$TEST_ROOT/upstream.insteadOf=https://github.com/ghayn/dotfiles.git" \\
    -c "url.$TEST_ROOT/tmux-upstream.insteadOf=https://github.com/gpakosz/.tmux.git" "$@"
}
trap cleanup_setup EXIT
'''
        result = subprocess.run(["/bin/bash", "-c", prelude + script], env=self.env,
                                cwd=self.root, text=True, capture_output=True, timeout=20)
        output = result.stdout + result.stderr
        if ok:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        self.assertFalse((self.root / "work").exists())
        return output

    def test_clone_survives_cleanup_and_retains_origin(self):
        self.shell('prepare_dotfiles_source "$HOME/.local/share/chezmoi"')
        self.assertTrue((self.source / ".git").is_dir())
        self.assertEqual(self.git("-C", str(self.source), "remote", "get-url", "origin"), DOTFILES_URL)
        self.assertEqual(self.git("-C", str(self.source), "rev-parse", "HEAD"),
                         self.git("-C", str(self.remote), "rev-parse", "HEAD"))

    def test_existing_repository_and_local_edits_are_preserved(self):
        self.shell('prepare_dotfiles_source "$HOME/.local/share/chezmoi"')
        self.git("-C", str(self.source), "remote", "set-url", "origin", "git@github.com:me/config.git")
        self.git("-C", str(self.source), "remote", "add", "backup", "https://example.invalid/config.git")
        (self.source / "dot_message.tmpl").write_text("local edit\n")
        config_before = (self.source / ".git/config").read_bytes()
        self.shell('prepare_dotfiles_source "$HOME/.local/share/chezmoi"')
        self.assertEqual((self.source / ".git/config").read_bytes(), config_before)
        self.assertEqual((self.source / "dot_message.tmpl").read_text(), "local edit\n")

    def test_non_repository_directory_is_not_overwritten(self):
        self.source.mkdir(parents=True)
        (self.source / "personal").write_text("keep")
        self.shell('prepare_dotfiles_source "$HOME/.local/share/chezmoi"', ok=False)
        self.assertEqual((self.source / "personal").read_text(), "keep")
        self.assertFalse((self.source / ".git").exists())

    def test_new_source_can_be_rolled_back_with_repository_recovery_copy(self):
        self.shell('begin_rollback_record\nprepare_dotfiles_source "$HOME/.local/share/chezmoi"\nfinish_rollback_record')
        self.shell('id() { echo 501; }; export -f id\n/bin/bash ' +
                   shlex.quote(str(ROOT / "uninstall.sh")))
        self.assertFalse(self.source.exists())
        backups = self.account / ".local/state/mac-bootstrap/backups"
        recovered = list(backups.glob("*/.rollback-v1/entries/*/current/.git/config"))
        self.assertEqual(len(recovered), 1)
        self.assertIn(DOTFILES_URL, recovered[0].read_text())

    @unittest.skipUnless(shutil.which("chezmoi"), "Optional integration check needs chezmoi")
    def test_apply_uses_persistent_custom_source_and_existing_template_data(self):
        custom_source = self.account / "my dotfiles"
        config = self.account / ".config/chezmoi/chezmoi.toml"
        config.parent.mkdir(parents=True)
        config.write_text('sourceDir = "' + str(custom_source) + '"\n[data]\ngreeting = "welcome"\n')
        for _ in range(2):
            self.shell('begin_rollback_record\napply_dotfiles\nfinish_rollback_record')
            self.assertEqual((self.account / ".message").read_text(), "welcome\n")
            self.assertEqual(self.git("-C", str(custom_source), "remote", "get-url", "origin"), DOTFILES_URL)
            self.assertFalse(self.source.exists())
        self.assertIn('greeting = "welcome"', config.read_text())

    @unittest.skipUnless(shutil.which("chezmoi"), "Optional integration check needs chezmoi")
    def test_main_preserves_managed_dotfiles_and_installs_tmux_and_shell_defaults(self):
        files = {
            "private_dot_zshrc": (".zshrc", "# personal shell\n"),
            "dot_zshenv": (".zshenv", 'export CARGO_HOME="$HOME/.cargo/bin"\n'),
            "private_dot_zimrc": (".zimrc", "zmodule exa\n"),
            "dot_tmux.conf.local": (".tmux.conf.local", "# personal tmux\n"),
        }
        (self.remote / "dot_message.tmpl").unlink()
        for source, (_, content) in files.items():
            (self.remote / source).write_text(content)
        self.git("-C", str(self.remote), "add", "-A")
        self.git("-C", str(self.remote), "-c", "user.name=Setup test",
                 "-c", "user.email=setup@example.invalid", "-c", "commit.gpgsign=false",
                 "commit", "-m", "Personal dotfiles")
        tmux_source = self.root / "tmux-upstream"
        self.git("init", str(tmux_source))
        (tmux_source / ".tmux.conf").write_text("# tmux defaults\n")
        (tmux_source / ".tmux.conf.local").write_text("# default local overrides\n")
        self.git("-C", str(tmux_source), "add", ".")
        self.git("-C", str(tmux_source), "-c", "user.name=Setup test",
                 "-c", "user.email=setup@example.invalid", "-c", "commit.gpgsign=false",
                 "commit", "-m", "Tmux fixture")
        manager = self.root / "brew/opt/zimfw/share/zimfw.zsh"
        manager.parent.mkdir(parents=True)
        manager.write_text('mkdir -p "$ZIM_HOME/modules"\nprint init > "$ZIM_HOME/init.zsh"\n')
        self.shell('''
check_requirements() { BREW_PREFIX="$TEST_ROOT/brew"; BREW="$BREW_PREFIX/bin/brew"; }
start_sudo_session() { :; }
install_command_line_tools() { :; }
install_homebrew() { :; }
install_packages() { :; }
rmdir "$SETUP_TMP"
TMPDIR="$TEST_ROOT"
main --skip-runtimes --skip-rust
''')
        for source, (target, content) in files.items():
            self.assertEqual((self.account / target).read_text(), content, target)
            self.assertEqual((self.source / source).read_text(), content, source)
        self.assertTrue((self.account / ".zim/init.zsh").exists())
        self.assertTrue((self.account / ".tmux/.git").exists())
        self.assertTrue((self.account / ".tmux.conf").is_symlink())
        self.assertEqual((self.account / ".tmux.conf").read_text(), "# tmux defaults\n")
        self.assertIn("shellenv", (self.account / ".zprofile").read_text())
        self.assertIn("mise activate zsh --shims", (self.account / ".zprofile").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
