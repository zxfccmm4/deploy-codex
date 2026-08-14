# Codex CLI 一键部署脚本

[![CI](https://github.com/zxfccmm4/deploy-codex/actions/workflows/ci.yml/badge.svg)](https://github.com/zxfccmm4/deploy-codex/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **v1.2.0** · 适用于 **Debian 12 / Ubuntu / macOS / Windows**，一键安装并配置 [OpenAI Codex CLI](https://github.com/openai/codex)。

## 支持平台

| 平台 | 脚本 | 包管理 / Node | 权限 |
|------|------|---------------|------|
| Linux（Debian 12 / Ubuntu） | `deploy-codex.sh` | `apt-get` + NodeSource | **需要 root**（`sudo`） |
| macOS（Darwin） | `deploy-codex.sh` | Homebrew `node@22` | **普通用户**（**不要** `sudo`） |
| Windows（PS 5.1+ / 7+） | `deploy-codex.ps1` | winget Node LTS | 当前用户 |

## 优化亮点（1.2.0）

- **macOS 无 root**：禁止用 `sudo` 跑 brew，避免污染系统
- **auth 写入方式**：`CODEX_AUTH_STYLE=api_key | bearer | both`（代理可用 `experimental_bearer_token`）
- **可配置 provider**：`CODEX_PROVIDER=OpenAI|custom|…`
- **功能开关**：`CODEX_GOALS` / `CODEX_DISABLE_RESPONSE_STORAGE` / `CODEX_NETWORK_ACCESS`
- **配置保留**：默认保留已有 `plugins` / `marketplaces` 段
- **原子写入 + 校验**：先写临时文件，Python/JSON 校验通过后再替换
- **备份与恢复**：自动备份最近 N 份；`--restore` / `-Restore` 一键回滚
- **管道可交互**：`curl | bash` / `irm | iex` 在终端里也能提问
- **密钥别名**：`OPENAI_API_KEY` 可代替 `CODEX_API_KEY`
- **CI**：ShellCheck + `bash -n` + PowerShell 语法检查（`actions/checkout@v5` / Node 24）
- **dry-run**：`--dry-run` / `-DryRun` 只写配置，不装 Node/npm/codex
- **卸载清理**：`--uninstall` / `-Uninstall` 删除配置与备份，并尝试 `npm uninstall -g @openai/codex`
- **跨机器迁移**：仓库内置 GPT-5.6 non-lite 模型目录、配置模板与 `deploy.sh`

## 快速开始

### Linux / macOS

**一行命令（推荐）** — 终端内可交互提问：

```bash
# Linux
curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
  | sudo bash

# macOS（不要 sudo）
curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
  | bash
```

**完全非交互（CI）**：

```bash
curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
  | sudo CODEX_API_KEY="sk-xxxx" \
         CODEX_BASE_URL="https://your.proxy" \
         CODEX_AUTH_STYLE="both" \
         bash
```

**下载后运行 / 恢复备份**：

```bash
curl -fsSL -o deploy-codex.sh \
  https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh
chmod +x deploy-codex.sh
less deploy-codex.sh          # 建议先审阅
sudo bash deploy-codex.sh     # Linux
# bash deploy-codex.sh        # macOS
bash deploy-codex.sh --restore
bash deploy-codex.sh --version
bash deploy-codex.sh --dry-run          # 只写配置
bash deploy-codex.sh --uninstall        # 卸载清理
```

### 部署到其他机器（推荐）

仓库已包含以下可公开提交的部署文件：

- `assets/models-gpt56-non-lite.json`：Codex CLI `0.147.0` 模型目录，包含 `gpt-5.6-sol` 与审查模型 `gpt-5.5`
- `templates/config.toml`：无密钥配置模板；部署时自动写入模型目录的**绝对路径**
- `deploy.sh`：安装固定版本 Codex CLI、复制模型目录并生成 `~/.codex/config.toml`
- `verify.sh`：检查版本、路径、权限、模型能力；可选发起一次真实工具调用

```bash
git clone https://github.com/zxfccmm4/deploy-codex.git
cd deploy-codex
bash deploy.sh
bash verify.sh
```

Linux 下使用 `sudo` 时，脚本默认部署到 `SUDO_USER`，不会误写到 `/root/.codex`：

```bash
sudo CODEX_TARGET_USER=alice bash deploy.sh
sudo CODEX_TARGET_USER=alice bash verify.sh
```

可用环境变量：

| 环境变量 | 说明 | 默认 |
|---------|------|------|
| `CODEX_TARGET_USER` | 接收配置的系统用户 | `SUDO_USER` 或当前用户 |
| `CODEX_TARGET_HOME` | 显式指定目标家目录（适合 CI） | 从系统用户信息解析 |
| `CODEX_VERSION` | 安装并验证的 Codex CLI 版本 | `0.147.0` |
| `CODEX_SKIP_INSTALL=1` | 只部署目录与配置，不执行 npm 全局安装 | `0` |
| `CODEX_SKIP_VERSION_CHECK=1` | 验证时跳过 CLI 版本检查 | `0` |
| `CODEX_LIVE_VERIFY=1` | 验证时发起真实 API 请求，并要求模型实际调用 `exec` | `0` |
| `CODEX_LIVE_SANDBOX` | 真实工具调用验证使用的 sandbox；GPT-5.6 不应设为 `read-only` | `workspace-write` |

`deploy.sh` 需要系统已有 Node.js/npm；如果 Codex CLI 已通过其他方式安装，可设置 `CODEX_SKIP_INSTALL=1`。覆盖已有 `config.toml` 前会生成带时间戳的备份。

#### macOS：避免 Homebrew Cask 缺少 code-mode host

[openai/codex#31906](https://github.com/openai/codex/issues/31906#issuecomment-4930014445) 记录过 macOS Homebrew Cask 只安装 `codex`、却缺少 `codex-code-mode-host` 的打包问题。症状通常是所有工具调用都报 `failed to spawn code-mode host`，导致 GPT-5.6 的 `exec` / `apply_patch` 无法使用。

本仓库统一使用 npm 安装 `@openai/codex@0.147.0`。当 `deploy.sh` 需要安装或修复 Codex，且在 macOS 检测到 Homebrew Cask 时，会先执行 `brew uninstall --cask codex`，再安装 npm 包并检查 code-mode host。手工修复命令如下：

```bash
brew uninstall --cask codex
npm install -g @openai/codex@0.147.0
hash -r
which codex
codex --version
bash verify.sh
```

npm 包中的 helper 可能位于平台包的 `vendor/.../bin/` 内，不一定单独出现在 `PATH`；因此 `command -v codex-code-mode-host` 为空不一定代表安装损坏。`verify.sh` 会同时检查 `PATH`、Codex 同目录和 npm 平台包中的 helper。

模型目录来自 `@openai/codex@0.147.0` 官方包内嵌目录，并将 GPT-5.6 coding 模型的 `use_responses_lite` 设为 `false`。`tool_mode = "code_mode_only"` 会让兼容 Responses API 的代理收到顶层 `type = "custom", name = "exec"` 工具，而 `apply_patch_tool_type = "freeform"` 会在 code mode 中暴露 `apply_patch`，避免把 `exec` 错误编码成 `functions → exec`。

此方案**不会复制、生成或提交 API Key**。请保留目标机器已有的 `~/.codex/auth.json`，或部署后自行执行 `codex login`。如需真实闭环验证：

```bash
CODEX_LIVE_VERIFY=1 bash verify.sh

# 也可手工验证；必须让模型实际调用工具，而不是只让它列出工具名
codex exec --ephemeral --skip-git-repo-check \
  --sandbox workspace-write \
  '先调用 exec 工具运行 printf CODEX_EXEC_OK，然后只回复该命令的输出。'
```

GPT-5.6 code mode 当前在 `--sandbox read-only` 下可能收到空工具列表，从而回复“无法可靠访问工作区执行工具”或 `NO-TOOLS`；请使用 `workspace-write`。参见 [openai/codex#31843](https://github.com/openai/codex/issues/31843)。另外，`apply_patch` 在 code mode 中可能作为 `exec` 内的 freeform 工具提供，不一定以独立顶层工具名出现，因此最可靠的检查方式是让模型实际执行上面的 `printf CODEX_EXEC_OK`。

### Windows（PowerShell）

```powershell
# 一行命令（可交互）
irm https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.ps1 | iex

# 非交互
$env:CODEX_API_KEY="sk-xxxx"
$env:CODEX_BASE_URL="https://your.proxy"
$env:CODEX_AUTH_STYLE="both"
irm https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.ps1 | iex

# 下载后
powershell -ExecutionPolicy Bypass -File deploy-codex.ps1
pwsh -File deploy-codex.ps1 -Version
pwsh -File deploy-codex.ps1 -DryRun
pwsh -File deploy-codex.ps1 -Restore
pwsh -File deploy-codex.ps1 -Uninstall
```

运行后会依次提示（**回车采用默认值**；API Key / base_url 必填）：

```text
  API Key (OPENAI_API_KEY) (输入不回显): _
  代理地址 (base_url): _
  模型 (model) [默认: gpt-5.5]: _
  审查模型 (review_model) [默认: gpt-5.5]: _
  推理强度 (reasoning_effort) [默认: xhigh]: _
  wire_api (responses/chat) [默认: responses]: _
  provider 名称 [默认: OpenAI]: _
  auth 写入方式 (api_key/bearer/both) [默认: api_key]: _
```

## 参数说明

优先级：**环境变量 > 交互输入 > 默认值**

| 环境变量 | 说明 | 默认 |
|---------|------|------|
| `CODEX_API_KEY` / `OPENAI_API_KEY` | API Key | 必填 |
| `CODEX_BASE_URL` | API 代理地址 | 必填 |
| `CODEX_MODEL` | 主模型 | `gpt-5.5` |
| `CODEX_REVIEW_MODEL` | 审查模型 | `gpt-5.5` |
| `CODEX_REASONING_EFFORT` | 推理强度 | `xhigh` |
| `CODEX_WIRE_API` | `responses` / `chat` | `responses` |
| `CODEX_PROVIDER` | `model_provider` 名称 | `OpenAI` |
| `CODEX_AUTH_STYLE` | `api_key` / `bearer` / `both` | `api_key` |
| `CODEX_GOALS` | `features.goals` | `true` |
| `CODEX_DISABLE_RESPONSE_STORAGE` | 禁用响应存储 | `true` |
| `CODEX_NETWORK_ACCESS` | 网络访问 | `enabled` |
| `CODEX_HOME` | 配置目录 | `~/.codex` |
| `CODEX_PRESERVE_EXTRA` | 保留 plugins/marketplaces | `1` |
| `NODE_MAJOR` | Node 主版本（Linux/macOS） | `22` |
| `NPM_REGISTRY` | npm 镜像，如 `https://registry.npmmirror.com` | — |
| `KEEP_BACKUPS` | 配置备份保留份数 | `5` |
| `CODEX_UNINSTALL_CONFIRM` | 非交互卸载确认（`1` / `yes`） | — |

### `CODEX_AUTH_STYLE` 说明

| 值 | 行为 |
|----|------|
| `api_key` | 只写 `auth.json` 的 `OPENAI_API_KEY`（默认，兼容官方） |
| `bearer` | 额外写入 provider 的 `experimental_bearer_token`（常见自定义代理） |
| `both` | 两处都写，兼容性最好 |

## 部署后

```bash
codex
```

- 用 `sudo` 执行时，配置写到 `SUDO_USER` 的家目录，而不是 `/root`
- macOS 请用执行部署的同一用户直接运行 `codex`


## dry-run 与卸载

### 只生成配置（不安装软件包）

适合先审阅会写出的 `config.toml` / `auth.json`，或在 CI 里校验参数：

```bash
# Linux
sudo CODEX_API_KEY="sk-xxxx" CODEX_BASE_URL="https://your.proxy" \
  bash deploy-codex.sh --dry-run

# macOS
CODEX_API_KEY="sk-xxxx" CODEX_BASE_URL="https://your.proxy" \
  bash deploy-codex.sh --dry-run
```

```powershell
$env:CODEX_API_KEY="sk-xxxx"; $env:CODEX_BASE_URL="https://your.proxy"
pwsh -File deploy-codex.ps1 -DryRun -NonInteractive
```

### 卸载 / 清理

会删除 `CODEX_HOME`（默认 `~/.codex`）、同级 `.bak.*` 备份，并尝试 `npm uninstall -g @openai/codex`。  
**不会**删除系统 Node / Homebrew / 其他方式安装的 `codex` 二进制。

```bash
# 交互确认
bash deploy-codex.sh --uninstall

# 非交互（必须显式确认）
CODEX_UNINSTALL_CONFIRM=1 bash deploy-codex.sh --uninstall
```

```powershell
pwsh -File deploy-codex.ps1 -Uninstall
$env:CODEX_UNINSTALL_CONFIRM="1"
pwsh -File deploy-codex.ps1 -Uninstall -NonInteractive
```

## 安全说明

- 脚本**无硬编码密钥**，可公开托管
- 交互输入 API Key **不回显**；摘要只显示前 8 位；URL 内嵌密码会打码
- `auth.json` / `config.toml` 权限 `600`（Windows 为当前用户 ACL）
- 写入前自动备份；失败时原配置不被破坏（原子替换）
- 临时文件在中断时自动清理
- 可迁移模型目录与模板不含 API Key；`deploy.sh` 不读写 `auth.json`

## 开发与 CI

```bash
bash -n deploy-codex.sh deploy.sh verify.sh
shellcheck -x deploy-codex.sh deploy.sh verify.sh   # 可选
bash deploy-codex.sh --help
```

GitHub Actions 会在 push / PR 时跑 bash 语法、ShellCheck 与 PowerShell 解析检查。

## 许可证

[MIT](LICENSE)
