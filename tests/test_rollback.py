"""Rollback tests operate exclusively on synthetic user accounts."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RollbackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rollback-test-")
        self.root = Path(self.temp.name)
        self.account = self.root / "test account"
        self.account.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("MISE_", "__MISE", "XDG_", "ROLLBACK_"))}
        self.env.update(HOME=str(self.account), TEST_ROOT=str(self.root))
        for key in ("BASH_ENV", "CARGO_HOME", "RUSTUP_HOME", "ZIM_HOME", "ZDOTDIR", "ZIM_CONFIG_FILE"):
            self.env.pop(key, None)

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, script, ok=True):
        result = subprocess.run(["/bin/bash", "-c", script], env=self.env,
                                cwd=self.root, text=True, capture_output=True, timeout=20)
        output = result.stdout + result.stderr
        if ok:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        return output

    def record(self, script):
        return self.shell('source ' + shlex.quote(str(ROOT / "setup.sh")) + '''
begin_rollback_record
trap rollback_unlock EXIT
''' + script)

    def uninstall(self, args="", ok=True, entry="uninstall.sh"):
        return self.shell('''
brew() { echo UNEXPECTED_BREW >&2; exit 99; }
sudo() { echo UNEXPECTED_SUDO >&2; exit 98; }
uname() { if [[ "$1" == -s ]]; then echo Darwin; else echo arm64; fi; }
sysctl() { echo 0; }
id() { echo 501; }
export -f brew sudo uname sysctl id
/bin/bash ''' + shlex.quote(str(ROOT / entry)) + " " + args, ok=ok)

    def runs(self):
        return sorted((self.account / ".local/state/mac-bootstrap/backups").glob("*/.rollback-v1"))

    def test_restore_original_remove_new_and_keep_current_recovery_copy(self):
        (self.account / ".zshrc").write_text("original\n")
        self.record('''
backup_file "$HOME/.zshrc"
printf 'installed\n' > "$HOME/.zshrc"
backup_file "$HOME/.zprofile"
printf 'new\n' > "$HOME/.zprofile"
track_path "$HOME/runtime"
mkdir -p "$HOME/runtime/bin"
printf 'runtime\n' > "$HOME/runtime/bin/python"
finish_rollback_record
''')
        (self.account / ".zshrc").write_text("edited after installation\n")
        self.uninstall()
        self.assertEqual((self.account / ".zshrc").read_text(), "original\n")
        self.assertFalse((self.account / ".zprofile").exists())
        self.assertFalse((self.account / "runtime").exists())
        recoveries = [p.read_text() for p in self.runs()[0].glob("entries/*/current") if p.is_file()]
        self.assertIn("edited after installation\n", recoveries)
        self.uninstall()  # Idempotent, already restored paths remain untouched.
        self.assertEqual((self.account / ".zshrc").read_text(), "original\n")

    def test_directory_snapshot_restores_existing_runtime_packages(self):
        data = self.account / "mise-data"
        data.mkdir()
        (data / "pip.txt").write_text("old pip")
        self.record('''
track_path "$HOME/mise-data"
printf 'upgraded pip' > "$HOME/mise-data/pip.txt"
printf 'new node' > "$HOME/mise-data/node.txt"
''')  # Interrupted installs are also eligible for rollback.
        self.uninstall()
        self.assertEqual((data / "pip.txt").read_text(), "old pip")
        self.assertFalse((data / "node.txt").exists())

    def test_dry_run_does_not_mutate_any_record_or_target(self):
        self.record('''
track_path "$HOME/new-file"
printf 'keep' > "$HOME/new-file"
finish_rollback_record
''')
        before = {str(p): p.read_bytes() for p in self.account.rglob("*") if p.is_file()}
        self.uninstall("--dry-run")
        after = {str(p): p.read_bytes() for p in self.account.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_latest_then_all_roll_back_in_reverse_order(self):
        target = self.account / ".zshrc"
        target.write_text("original")
        self.record('backup_file "$HOME/.zshrc"; printf first > "$HOME/.zshrc"; finish_rollback_record')
        self.record('backup_file "$HOME/.zshrc"; printf second > "$HOME/.zshrc"; finish_rollback_record')
        self.uninstall("--latest")
        self.assertEqual(target.read_text(), "first")
        self.uninstall()
        self.assertEqual(target.read_text(), "original")

    def test_symlink_and_referent_are_both_restored(self):
        (self.account / "config").write_text("old")
        (self.account / ".zshrc").symlink_to("config")
        self.record('backup_file "$HOME/.zshrc"; printf new > "$HOME/.zshrc"')
        self.uninstall()
        self.assertTrue((self.account / ".zshrc").is_symlink())
        self.assertEqual((self.account / "config").read_text(), "old")

    def test_new_parent_directory_pruning_keeps_unrelated_files(self):
        self.record('''
track_path "$HOME/nested/empty/file"
mkdir -p "$HOME/nested/empty"
printf created > "$HOME/nested/empty/file"
''')
        (self.account / "nested/personal").write_text("keep")
        self.uninstall()
        self.assertFalse((self.account / "nested/empty").exists())
        self.assertEqual((self.account / "nested/personal").read_text(), "keep")

    def test_existing_directory_permissions_are_restored(self):
        folder = self.account / ".config"
        folder.mkdir(mode=0o755)
        self.record('track_directory "$HOME/.config"; chmod 700 "$HOME/.config"')
        self.uninstall()
        self.assertEqual(folder.stat().st_mode & 0o777, 0o755)

    def test_state_ancestor_can_restore_permissions_without_copying_state(self):
        folder = self.account / ".local"
        folder.mkdir(mode=0o755)
        self.record('track_directory "$HOME/.local"; chmod 700 "$HOME/.local"')
        self.uninstall()
        self.assertEqual(folder.stat().st_mode & 0o777, 0o755)
        self.assertTrue(self.runs()[0].exists())

    def test_shell_tmux_and_rust_install_hooks_are_reversible(self):
        (self.account / ".zshrc").write_text("# before\n")
        rustup = self.account / ".cargo/bin/rustup"
        rustup.parent.mkdir(parents=True)
        rustup.write_text('#!/bin/bash\nprintf updated > "$CARGO_HOME/package"\n'
                          'mkdir -p "$RUSTUP_HOME"\nprintf stable > "$RUSTUP_HOME/toolchain"\n')
        rustup.chmod(0o755)
        (self.account / ".cargo/package").write_text("old")
        manager = self.root / "brew/opt/zimfw/share/zimfw.zsh"
        manager.parent.mkdir(parents=True)
        manager.write_text('mkdir -p "$ZIM_HOME/modules"\nprint init > "$ZIM_HOME/init.zsh"\n')
        self.record('''
BREW_PREFIX="$TEST_ROOT/brew"
BREW="$BREW_PREFIX/bin/brew"
SETUP_TMP="$TEST_ROOT/work"; mkdir "$SETUP_TMP"
export RUSTUP_HOME="$HOME/.rustup"
git() {
  local dest="${@: -1}"
  mkdir -p "$dest"
  printf main > "$dest/.tmux.conf"
  printf local > "$dest/.tmux.conf.local"
}
configure_environment
install_zimfw
install_tmux_config
install_rust
finish_rollback_record
''')
        self.uninstall()
        self.assertEqual((self.account / ".zshrc").read_text(), "# before\n")
        self.assertEqual((self.account / ".cargo/package").read_text(), "old")
        self.assertTrue(rustup.exists())
        self.assertTrue(manager.exists())
        for relative in (".zprofile", ".zim", ".zimrc", ".tmux", ".tmux.conf", ".tmux.conf.local", ".rustup"):
            self.assertFalse((self.account / relative).exists(), relative)
            self.assertFalse((self.account / relative).is_symlink(), relative)

    def test_reject_outside_home_or_state_ancestor(self):
        for target in ('/opt/homebrew', '$HOME/.local', '$TEST_ROOT/outside'):
            with self.subTest(target=target):
                self.shell('source ' + shlex.quote(str(ROOT / "setup.sh")) + '''
begin_rollback_record
trap rollback_unlock EXIT
track_path "''' + target + '"', ok=False)

    def test_changed_parent_symlink_is_rejected(self):
        self.record('''
track_path "$HOME/config/value"
mkdir -p "$HOME/config"
printf old > "$HOME/config/value"
''')
        (self.account / "config").rename(self.account / "saved-config")
        (self.account / "redirect").mkdir()
        (self.account / "redirect/value").write_text("must survive")
        (self.account / "config").symlink_to("redirect", target_is_directory=True)
        self.uninstall(ok=False)
        self.assertEqual((self.account / "redirect/value").read_text(), "must survive")

    def test_corrupt_snapshot_stops_before_mutation(self):
        (self.account / ".zshrc").write_text("original")
        self.record('backup_file "$HOME/.zshrc"; printf new > "$HOME/.zshrc"')
        next(self.runs()[0].glob("entries/*/before")).unlink()
        self.uninstall(ok=False)
        self.assertEqual((self.account / ".zshrc").read_text(), "new")

    def test_resume_after_current_was_moved(self):
        (self.account / ".zshrc").write_text("original")
        self.record('backup_file "$HOME/.zshrc"; printf new > "$HOME/.zshrc"')
        entry = next(self.runs()[0].glob("entries/*"))
        (self.account / ".zshrc").rename(entry / "current")
        self.uninstall()
        self.assertEqual((self.account / ".zshrc").read_text(), "original")
        self.assertEqual((entry / "current").read_text(), "new")

    def test_dispatch_from_install_entry(self):
        self.record('track_path "$HOME/new-file"; printf new > "$HOME/new-file"')
        self.uninstall("uninstall --dry-run", entry="install.sh")
        self.assertTrue((self.account / "new-file").exists())
        self.uninstall("uninstall", entry="install.sh")
        self.assertFalse((self.account / "new-file").exists())

    def test_rosetta_reexec_preserves_uninstall_command(self):
        self.shell('source ' + shlex.quote(str(ROOT / "install.sh")) + '''
uname() { echo Darwin; }
sysctl() { echo 1; }
exec() {
  [[ "$1 $2 $3" == '/usr/bin/arch -arm64 /bin/bash' ]] || exit 90
  [[ "${@: -2:1}" == uninstall && "${@: -1}" == --dry-run ]] || exit 91
  exit 0
}
bootstrap uninstall --dry-run
exit 92
''')

    @unittest.skipUnless(shutil.which("chezmoi"), "Optional integration check needs chezmoi")
    def test_dotfiles_install_then_uninstall_restores_files_and_directory_mode(self):
        config = self.account / ".config"
        config.mkdir(mode=0o755)
        (config / "settings").write_text("old settings")
        (self.account / ".zshrc").write_text("old shell")
        self.record('''
WITH_DOTFILES=1
SETUP_TMP="$TEST_ROOT/work"; mkdir "$SETUP_TMP"
git() {
  local dest="${@: -1}"
  mkdir -p "$dest/private_dot_config" "$dest/dot_local/bin"
  printf new > "$dest/private_dot_config/settings"
  printf new > "$dest/private_dot_zshrc"
  printf new > "$dest/dot_local/bin/command"
  printf 'zmodule git\\nzmodule exa\\n' > "$dest/dot_zimrc"
}
apply_dotfiles
[[ "$(cat "$HOME/.config/settings")" == new ]]
finish_rollback_record
''')
        self.uninstall()
        self.assertEqual((config / "settings").read_text(), "old settings")
        self.assertEqual((self.account / ".zshrc").read_text(), "old shell")
        self.assertEqual(config.stat().st_mode & 0o777, 0o755)
        self.assertFalse((self.account / ".local/bin/command").exists())
        self.assertFalse((self.account / ".zimrc").exists())

    def test_no_record_and_legacy_backup_are_non_destructive(self):
        self.uninstall()
        legacy = self.account / ".local/state/mac-bootstrap/backups/old"
        legacy.mkdir(parents=True)
        (legacy / ".zshrc").write_text("old backup")
        self.assertIn("旧版备份", self.uninstall())
        self.assertTrue((legacy / ".zshrc").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
