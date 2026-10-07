# setup-macos

一键初始化 macOS 开发环境：安装常用开发工具、配置终端，并通过 **mise** 管理 Node.js、Ruby 和 Python。支持安装预览、测试模式和卸载回滚。

适用于 macOS 15 及以上，主要面向 macOS 27 / Apple Silicon。需要管理员账户和网络，无需提前安装 Git 或 Homebrew。macOS 27 尚未完成真机全量安装验证。

## 快速开始

打开终端，执行：

```bash
/bin/bash -c "$(curl -fsSL --retry 3 --connect-timeout 20 https://raw.githubusercontent.com/ghayn/setup-macos/main/install.sh)"
```

按提示输入系统密码，等待安装完成后重新打开终端。请使用 Bash，**不要给整个命令加 `sudo`**。

默认会备份并应用 [ghayn/dotfiles](https://github.com/ghayn/dotfiles) 中的个人配置；无需这套配置时，加上 `--skip-dotfiles`。

已下载仓库时，在项目目录运行：

```bash
# 预览安装内容
/bin/bash ./install.sh --dry-run

# 开始安装
/bin/bash ./install.sh
```

## 安装内容

- **基础工具**：Xcode Command Line Tools、Homebrew，以及 Git、Neovim、tmux、fzf、ripgrep 等。
- **开发语言**：mise 管理的 Node.js 当前 LTS、Ruby / Python 最新稳定版，以及 Rust stable。
- **配套工具**：pnpm、pip、Poetry，Zim 和 tmux 配置。
- **桌面应用与字体**：VS Code、1Password、Karabiner、Rectangle、kitty 等。

完整清单见 [brewfile](brewfile)；需要更多应用时，用 `--with-extra` 安装 [brewfile-extra](brewfile-extra)。可直接编辑这两个文件调整软件清单。应用的权限授权、登录和激活需自行完成。

## 常用选项

| 选项 | 用途 |
| --- | --- |
| `--dry-run` | 只预览，不安装软件或修改用户配置 |
| `--test` | 测试环境，跳过所有 cask 应用和字体 |
| `--with-extra` | 安装扩展软件清单 |
| `--skip-dotfiles` | 不应用个人 dotfiles |
| `--skip-casks` | 跳过所有 cask 应用和字体 |
| `--skip-runtimes` | 跳过 Node.js、Ruby、Python、pnpm、pip、Poetry |
| `--skip-shell` | 跳过 Zim / tmux 配置，需同时加 `--skip-dotfiles`；仍配置工具 PATH |
| `--skip-rust` | 跳过 Rust |
| `--help` | 查看帮助 |

选项可以组合使用，例如在测试环境安装，并跳过个人配置：

```bash
/bin/bash ./install.sh --test --skip-dotfiles
```

测试模式仍会实际安装命令行工具和运行时。设置 `INSTALLER_ENV=test`、`CI=1` 或 `CI=true` 也会自动跳过全部 cask，包括扩展清单。

一键远程安装时，在命令末尾加 `--`，再追加选项：

```bash
/bin/bash -c "$(curl -fsSL --retry 3 --connect-timeout 20 https://raw.githubusercontent.com/ghayn/setup-macos/main/install.sh)" -- --test --skip-dotfiles
```

## 卸载与回滚

恢复安装前的配置和运行时，**保留 Homebrew 及其安装的所有软件、依赖和字体**。系统 Command Line Tools 也会保留。

```bash
# 预览回滚内容
/bin/bash ./install.sh uninstall --dry-run

# 回滚所有有记录的安装
/bin/bash ./install.sh uninstall

# 只撤销最近一次安装
/bin/bash ./install.sh uninstall --latest
```

未保留本地仓库时，也可一键回滚：

```bash
/bin/bash -c "$(curl -fsSL --retry 3 --connect-timeout 20 https://raw.githubusercontent.com/ghayn/setup-macos/main/install.sh)" -- uninstall
```

请用原安装用户执行，完成后重新打开终端。回滚会恢复完整快照，受管目录中后来新增的包或改动也会被移走；当前内容会另行保存，便于找回。

备份与回滚记录位于 `~/.local/state/mac-bootstrap/backups/`，可能占用较多空间。**只有带回滚记录的安装才能自动恢复**；旧版安装需手动处理。

## 安装遇到问题

- **安装中断或失败**：根据终端提示解决问题后，重新运行原命令；也可以执行回滚。
- **提示缺少 Command Line Tools**：运行 `xcode-select --install`，完成系统安装窗口后重试。
- **使用自定义 `ZDOTDIR`**：加上 `--skip-dotfiles`。
