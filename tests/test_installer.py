"""Offline behavior tests: no packages, sudo, network, or real home changes."""
import os
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="setup-macos-test-")
        self.root = Path(self.temp.name)
        self.account = self.root / "test account"
        self.account.mkdir()
        # Give the subprocess a synthetic user account, never the real home.
        self.env = dict(os.environ, HOME=str(self.account), TEST_ROOT=str(self.root))
        for key in ("ZDOTDIR", "ZIM_HOME", "ASDF_DATA_DIR", "CARGO_HOME", "BASH_ENV",
                    "NODEJS_VERSION", "RUBY_VERSION", "PYTHON_VERSION", "CI", "INSTALLER_ENV"):
            self.env.pop(key, None)
        for key in list(self.env):
            if key.startswith(("MISE_", "__MISE", "XDG_")):
                self.env.pop(key)

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, code, ok=True):
        result = subprocess.run(
            ["/bin/bash", "-c", code], cwd=self.root, env=self.env,
            text=True, errors="backslashreplace", stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def setup_source(self):
        return "source " + shlex.quote(str(ROOT / "setup.sh")) + "\n"

    def os_stubs(self, version="27.0", arch="arm64", os_name="Darwin", uid="501", translated="0"):
        return f'''
uname() {{ if [[ "$1" == -s ]]; then echo {os_name}; else echo {arch}; fi; }}
sw_vers() {{ echo {version}; }}
id() {{ echo {uid}; }}
sysctl() {{ echo {translated}; }}
'''

    def test_platform_matrix(self):
        for version in ("15.0", "26.3", "27.0", "27.1", "28.0"):
            with self.subTest(version=version):
                self.shell(self.setup_source() + self.os_stubs(version) +
                           'check_requirements; [[ "$BREW" == /opt/homebrew/bin/brew ]]')
        for kwargs in ({"version": "14.7"}, {"os_name": "Linux"}, {"uid": "0"},
                       {"arch": "i386"}, {"arch": "x86_64"},
                       {"version": "26.0", "arch": "x86_64", "translated": "1"}):
            with self.subTest(kwargs=kwargs):
                self.shell(self.setup_source() + self.os_stubs(**kwargs) + 'check_requirements', ok=False)
        self.shell(self.setup_source() + self.os_stubs("26.0", "x86_64") +
                   'check_requirements; [[ "$BREW" == /usr/local/bin/brew ]]')

    def test_local_entry_from_unrelated_directory(self):
        out = self.shell(self.os_stubs() + 'export -f uname sw_vers id sysctl\n' +
                         '/bin/bash ' + shlex.quote(str(ROOT / "install.sh")) +
                         ' --dry-run --with-extra --test')
        self.assertIn("macOS 27.0", out)
        self.assertIn('brew "mise"', out)
        self.assertNotIn('brew "asdf"', out)
        self.assertNotIn('cask "', out)
        self.assertEqual(list(self.account.iterdir()), [])

    def test_preview_and_option_errors_never_mutate(self):
        self.shell(self.setup_source() + self.os_stubs() + '''
sudo() { echo UNEXPECTED; exit 90; }
brew() { echo UNEXPECTED; exit 91; }
curl() { echo UNEXPECTED; exit 92; }
main --dry-run --with-extra --with-dotfiles
''')
        self.assertEqual(list(self.account.iterdir()), [])
        self.shell(self.setup_source() + 'parse_options --bad-option', ok=False)
        self.shell(self.setup_source() + 'parse_options --with-dotfiles --skip-shell', ok=False)

    def test_personal_dotfiles_are_enabled_by_default(self):
        self.shell(self.setup_source() + '''
parse_options
[[ "$WITH_DOTFILES" == 1 ]]
parse_options --skip-dotfiles --skip-shell
[[ "$WITH_DOTFILES" == 0 && "$SKIP_SHELL" == 1 ]]
''')

    @unittest.skipUnless(shutil.which("chezmoi"), "Optional integration check needs chezmoi")
    def test_dotfiles_backup_and_legacy_migration(self):
        self.shell(self.setup_source() + '''
parse_options
SETUP_TMP="$TEST_ROOT/work"; mkdir "$SETUP_TMP"
BACKUP_DIR="$HOME/backups"
printf '# original\\n' > "$HOME/.zshrc"
printf '# original env\\n' > "$HOME/.zshenv"
git() {
  local dest="${@: -1}"
  mkdir "$dest"
  printf '# new shell\\n' > "$dest/private_dot_zshrc"
  printf 'zmodule git\\nzmodule asdf\\nzmodule exa\\n' > "$dest/private_dot_zimrc"
  printf '%s\\n' 'export CARGO_HOME="$HOME/.cargo/bin"' \\
    'add_to_path_if_missing "$CARGO_HOME"' > "$dest/dot_zshenv"
}
apply_dotfiles
[[ $(cat "$BACKUP_DIR/.zshrc") == '# original' ]]
[[ $(cat "$BACKUP_DIR/.zshenv") == '# original env' ]]
[[ $(cat "$HOME/.zshrc") == '# new shell' ]]
[[ $(cat "$HOME/.zimrc") == 'zmodule git' ]]
grep -Fqx 'export CARGO_HOME="$HOME/.cargo"' "$HOME/.zshenv"
[[ ! -e "$HOME/.local/share/chezmoi" ]]
''')

    def test_clt_labels_use_numeric_order(self):
        out = self.shell(self.setup_source() + '''
printf '%s\n' ' * Label: Command Line Tools for Xcode-27.9' \
  ' * Label: macOS Golden Gate 27.1' ' * Label: Command Line Tools for Xcode-27.10' \
  ' * Command Line Tools for Xcode-16.4' | select_clt_label
''')
        self.assertEqual(out.strip(), "Command Line Tools for Xcode-27.10")
        self.assertEqual(self.shell(self.setup_source() +
                                   "printf 'No updates available\n' | select_clt_label").strip(), "")

    def test_broken_sdk_is_not_considered_ready(self):
        self.shell(self.setup_source() + '''
xcode-select() { return 0; }
xcrun() { echo /does/not/exist; }
command_line_tools_ready
''', ok=False)

    def test_config_repeat_preserves_original_backup(self):
        self.shell(self.setup_source() + '''
BACKUP_DIR="$TEST_ROOT/backup"
BREW=/opt/homebrew/bin/brew
BREW_PREFIX=/opt/homebrew
printf '# original\n' > "$HOME/.zshrc"
configure_environment
configure_environment
[[ $(grep -c 'shellenv' "$HOME/.zshrc") == 1 ]]
[[ $(grep -c 'typeset -U' "$HOME/.zshrc") == 1 ]]
[[ $(grep -c 'mise activate zsh' "$HOME/.zshrc") == 1 ]]
[[ $(grep -c 'mise activate zsh --shims' "$HOME/.zprofile") == 1 ]]
[[ $(cat "$BACKUP_DIR/.zshrc") == '# original' ]]
''')
        self.assertIn("# original", (self.account / ".zshrc").read_text())

    def test_old_installer_asdf_path_is_backed_up_and_replaced(self):
        self.shell(self.setup_source() + '''
BACKUP_DIR="$HOME/backups"
SETUP_TMP="$TEST_ROOT/work"; mkdir "$SETUP_TMP"
BREW_PREFIX=/opt/homebrew
BREW="$BREW_PREFIX/bin/brew"
printf '%s\\n' '# personal settings' \\
  'typeset -U path; path=("${ASDF_DATA_DIR:-$HOME/.asdf}/shims" "${CARGO_HOME:-$HOME/.cargo}/bin" "$HOME/.local/bin" $path)' > "$HOME/.zshrc"
configure_environment
configure_environment
! grep -q ASDF_DATA_DIR "$HOME/.zshrc"
grep -q ASDF_DATA_DIR "$BACKUP_DIR/.zshrc"
grep -Fqx '# personal settings' "$HOME/.zshrc"
[[ $(grep -c 'mise activate zsh' "$HOME/.zshrc") == 1 ]]
''')

    def test_existing_tmux_config_is_preserved(self):
        self.shell(self.setup_source() + '''
printf '# custom\n' > "$HOME/.tmux.conf"
git() { exit 99; }
install_tmux_config
[[ $(cat "$HOME/.tmux.conf") == '# custom' ]]
''')

    def test_tmux_installs_once(self):
        self.shell(self.setup_source() + '''
git() {
  local dest="${@: -1}"
  mkdir -p "$dest"
  printf '# main\n' > "$dest/.tmux.conf"
  printf '# local\n' > "$dest/.tmux.conf.local"
}
install_tmux_config
install_tmux_config
[[ -L "$HOME/.tmux.conf" && -f "$HOME/.tmux.conf.local" ]]
''')

    def test_failed_bundle_stops_before_runtime_install(self):
        out = self.shell(self.setup_source() + '''
check_requirements() { :; }
print_plan() { :; }
start_sudo_session() { :; }
install_command_line_tools() { :; }
install_homebrew() { BREW=fake_brew; }
fake_brew() { return 42; }
install_runtimes() { echo SHOULD_NOT_RUN; }
main --skip-shell --skip-dotfiles --skip-rust
''', ok=False)
        self.assertNotIn("SHOULD_NOT_RUN", out)
        self.assertIn("42", out)
        self.assertEqual(list(self.root.glob("setup-macos.*")), [])

    def test_bundle_uses_explicit_manifest_and_filters_casks(self):
        modes = (
            'parse_options --skip-casks',
            'parse_options --test',
            'INSTALLER_ENV=test; parse_options',
            'CI=true; parse_options',
            'CI=1; parse_options',
        )
        for mode in modes:
            with self.subTest(mode=mode):
                self.shell(self.setup_source() + mode + ' --with-extra --skip-runtimes\n' + '''
SETUP_TMP="$TEST_ROOT/work"; mkdir -p "$SETUP_TMP"
: > "$TEST_ROOT/bundles"
BREW=fake_brew
fake_brew() {
  [[ "$1 $2" == 'bundle install' ]]
  local manifest="${3#--file=}"
  [[ -f "$manifest" && "$4" == --no-upgrade ]]
  ! grep -q '^cask ' "$manifest"
  printf '%s\n' "$manifest" >> "$TEST_ROOT/bundles"
}
install_packages
[[ $(wc -l < "$TEST_ROOT/bundles" | tr -d ' ') == 2 ]]
''')

    def test_normal_environment_keeps_casks(self):
        for setting in ('unset CI INSTALLER_ENV', 'CI=false', 'CI=0'):
            with self.subTest(setting=setting):
                out = self.shell(self.setup_source() + setting + '''
parse_options --with-extra
[[ "$SKIP_CASKS" == 0 && "$TEST_ENVIRONMENT" == 0 ]]
print_plan
''')
                self.assertIn('cask "visual-studio-code"', out)
                self.assertIn('cask "google-chrome"', out)

    def remote_entry(self, failure=False, broken=False, uninstall=False):
        # Execute the exact bash -c bootstrap shape with local download fixtures.
        archive = self.root / "source.tar.gz"
        fixture = self.root / "fixture"
        fixture.mkdir()
        setup = fixture / "setup.sh"
        setup.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$TEST_ROOT/args"\n')
        if not broken:
            for file in ("utils.sh", "rollback.sh", "uninstall.sh", "brewfile", "brewfile-extra"):
                (fixture / file).write_text("# fixture\n")
            (fixture / "uninstall.sh").write_text(setup.read_text())
        subprocess.run(["tar", "-czf", str(archive), "-C", str(self.root), "fixture"], check=True)
        stubs = self.os_stubs() + '''
curl() {
  if [[ "${FAIL_DOWNLOAD:-0}" == 1 ]]; then return 22; fi
  cp "$TEST_ROOT/source.tar.gz" "${@: -1}"
}
export -f uname sysctl curl
export TMPDIR="$TEST_ROOT"
'''
        if failure:
            stubs += "export FAIL_DOWNLOAD=1\n"
        args = 'uninstall --dry-run --latest' if uninstall else '--dry-run --with-extra --test'
        command = (stubs + '/bin/bash -c "$(cat ' + shlex.quote(str(ROOT / "install.sh")) +
                   ')" -- ' + args)
        out = self.shell(command, ok=not (failure or broken))
        self.assertEqual(list(self.root.glob("setup-macos-bootstrap.*")), [])
        if failure or broken:
            self.assertFalse((self.root / "args").exists())
        else:
            expected = "--dry-run\n--latest\n" if uninstall else "--dry-run\n--with-extra\n--test\n"
            self.assertEqual((self.root / "args").read_text(), expected)
        return out

    def test_remote_entry_needs_no_git_or_cwd_files(self):
        self.remote_entry()

    def test_remote_uninstall_dispatch(self):
        self.remote_entry(uninstall=True)

    def test_remote_download_failure_is_fatal_and_cleans_up(self):
        self.remote_entry(failure=True)

    def test_incomplete_archive_is_rejected_and_cleans_up(self):
        self.remote_entry(broken=True)

    def prepare_mise(self):
        fakebin = self.root / "brew" / "bin"
        fakebin.mkdir(parents=True)
        mise = fakebin / "mise"
        mise.write_text('''#!/bin/bash
set -eu
printf '%s\\n' "$*" >> "$TEST_ROOT/mise-calls"
case "$*" in
  'latest node@lts') echo "${FAKE_NODE_VERSION:-24.9.0}" ;;
  'latest ruby') echo 3.4.5 ;;
  'latest python') echo 3.14.0 ;;
  'where node@'*) printf '%s\\n' "$HOME/.local/share/mise/installs/node/${2#node@}" ;;
  'use --global --pin '*)
    [[ "${FAIL_MISE_USE:-0}" == 0 ]] || exit 42
    config="${MISE_GLOBAL_CONFIG_FILE:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/config.toml}"
    mkdir -p "$(dirname "$config")"
    printf '# selected versions\\n' > "$config"
    for folder in "$HOME/.local/share/mise" "$HOME/Library/Caches/mise" "$HOME/.local/state/mise"; do
      mkdir -p "$folder"
      printf 'installed\\n' > "$folder/changed"
    done
    ;;
  'exec '*' -- python -m venv '*)
    target="${@: -1}"
    mkdir -p "$target/bin"
    printf '#!/bin/bash\\nexit 0\\n' > "$target/bin/python"
    chmod +x "$target/bin/python"
    touch "$target/bin/poetry"
    ;;
  'exec '*' -- npm install --global --prefix '*' pnpm'|'exec '*' -- python -m pip --isolated --no-cache-dir install --upgrade pip'|'reshim') ;;
  *) printf 'Unexpected mise call: %s\\n' "$*" >&2; exit 95 ;;
esac
''')
        mise.chmod(0o755)
        config = self.account / ".config/mise/config.toml"
        config.parent.mkdir(parents=True)
        config.write_text("# existing mise config\n")
        (self.account / ".tool-versions").write_text("nodejs 20.1.0\n")
        return self.setup_source() + '''
BREW_PREFIX="$TEST_ROOT/brew"
BACKUP_DIR="$HOME/backups"
SETUP_TMP="$TEST_ROOT/work"; mkdir -p "$SETUP_TMP"
'''

    def test_runtimes_use_mise_and_current_lts(self):
        self.shell(self.prepare_mise() + 'install_runtimes')
        calls = (self.root / "mise-calls").read_text()
        self.assertIn("latest node@lts", calls)
        versions = "node@24.9.0 ruby@3.4.5 python@3.14.0"
        self.assertIn("use --global --pin " + versions, calls)
        self.assertIn("exec " + versions + " -- npm install --global --prefix ", calls)
        self.assertIn("exec " + versions + " -- python -m pip --isolated --no-cache-dir install --upgrade pip", calls)
        self.assertIn("reshim", calls)
        self.assertNotIn("asdf", calls)
        self.assertEqual((self.account / "backups/.config/mise/config.toml").read_text(),
                         "# existing mise config\n")
        self.assertEqual((self.account / ".tool-versions").read_text(), "nodejs 20.1.0\n")
        self.assertTrue((self.account / ".local/bin/poetry").is_symlink())

    def test_runtime_install_then_uninstall_restores_prior_state(self):
        code = self.prepare_mise()
        cache = self.account / "Library/Caches/mise"
        cache.mkdir(parents=True)
        (cache / "changed").write_text("previous cache")
        self.shell(code + '''
begin_rollback_record
trap rollback_unlock EXIT
install_runtimes
finish_rollback_record
''')
        self.shell('id() { echo 501; }; export -f id\n/bin/bash ' +
                   shlex.quote(str(ROOT / "uninstall.sh")))
        self.assertEqual((self.account / ".config/mise/config.toml").read_text(),
                         "# existing mise config\n")
        self.assertEqual((cache / "changed").read_text(), "previous cache")
        for relative in (".local/share/mise", ".local/state/mise",
                         ".local/share/mac-bootstrap/poetry", ".local/bin/poetry"):
            self.assertFalse((self.account / relative).exists(), relative)
            self.assertFalse((self.account / relative).is_symlink(), relative)
        self.assertTrue((self.root / "brew/bin/mise").exists())

    def test_explicit_runtime_versions_skip_latest_lookup(self):
        self.shell(self.prepare_mise() + '''
NODEJS_VERSION=22.12.0 RUBY_VERSION=3.3.6 PYTHON_VERSION=3.12.8 install_runtimes
''')
        calls = (self.root / "mise-calls").read_text()
        self.assertNotIn("latest ", calls)
        self.assertIn("use --global --pin node@22.12.0 ruby@3.3.6 python@3.12.8", calls)

    def test_failed_mise_install_stops_before_package_commands(self):
        self.shell(self.prepare_mise() + 'export FAIL_MISE_USE=1; install_runtimes', ok=False)
        calls = (self.root / "mise-calls").read_text()
        self.assertNotIn("exec ", calls)
        self.assertEqual((self.account / ".config/mise/config.toml").read_text(),
                         "# existing mise config\n")

    def test_invalid_resolved_version_does_not_write_global_config(self):
        self.shell(self.prepare_mise() + 'export FAKE_NODE_VERSION=invalid; install_runtimes', ok=False)
        self.assertNotIn("use --global", (self.root / "mise-calls").read_text())

    def test_custom_mise_config_is_backed_up(self):
        code = self.prepare_mise()
        config = self.account / "custom mise.toml"
        config.write_text("# custom config\n")
        self.env["MISE_GLOBAL_CONFIG_FILE"] = str(config)
        self.shell(code + 'install_runtimes')
        self.assertEqual((self.account / "backups/custom mise.toml").read_text(), "# custom config\n")

    @unittest.skipUnless(shutil.which("mise"), "Optional integration check needs mise")
    def test_real_mise_preserves_project_tool_versions_compatibility(self):
        config = self.account / ".config/mise/config.toml"
        config.parent.mkdir(parents=True)
        config.write_text('[tools]\nnode = "24.9.0"\n')
        (self.account / ".tool-versions").write_text("nodejs 20.1.0\n")
        project = self.account / "project"
        project.mkdir()
        # These exact declarations are only inspected; no runtimes are installed.
        self.env.update(MISE_AUTO_INSTALL="false", MISE_DATA_DIR=str(self.root / "mise-data"),
                        MISE_CACHE_DIR=str(self.root / "mise-cache"), MISE_STATE_DIR=str(self.root / "mise-state"))
        command = ('cd ' + shlex.quote(str(project)) + '; ' +
                   shlex.quote(shutil.which("mise")) + ' ls --current --json')
        self.assertEqual(json.loads(self.shell(command))["node"][0]["version"], "24.9.0")
        (project / ".tool-versions").write_text("nodejs 22.12.0\n")
        self.assertEqual(json.loads(self.shell(command))["node"][0]["version"], "22.12.0")
        self.assertFalse((self.root / "mise-data/installs").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
