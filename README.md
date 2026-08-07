# Codex CLI 一键部署脚本

[![CI](https://github.com/zxfccmm4/deploy-codex/actions/workflows/ci.yml/badge.svg)](https://github.com/zxfccmm4/deploy-codex/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **v1.1.0** · 适用于 **Debian 12 / Ubuntu / macOS / Windows**，一键安装并配置 [OpenAI Codex CLI](https://github.com/openai/codex)。

## 支持平台

| 平台 | 脚本 | 包管理 / Node | 权限 |
|------|------|---------------|------|
| Linux（Debian 12 / Ubuntu） | `deploy-codex.sh` | `apt-get` + NodeSource | **需要 root**（`sudo`） |
| macOS（Darwin） | `deploy-codex.sh` | Homebrew `node@22` | **普通用户**（**不要** `sudo`） |
| Windows（PS 5.1+ / 7+） | `deploy-codex.ps1` | winget Node LTS | 当前用户 |

## 优化亮点（1.1.0）

- **macOS 无 root**：禁止用 `sudo` 跑 brew，避免污染系统
- **auth 写入方式**：`CODEX_AUTH_STYLE=api_key | bearer | both`（代理可用 `experimental_bearer_token`）
- **可配置 provider**：`CODEX_PROVIDER=OpenAI|custom|…`
- **功能开关**：`CODEX_GOALS` / `CODEX_DISABLE_RESPONSE_STORAGE` / `CODEX_NETWORK_ACCESS`
- **配置保留**：默认保留已有 `plugins` / `marketplaces` 段
- **原子写入 + 校验**：先写临时文件，Python/JSON 校验通过后再替换
- **备份与恢复**：自动备份最近 N 份；`--restore` / `-Restore` 一键回滚
- **管道可交互**：`curl | bash` / `irm | iex` 在终端里也能提问
- **密钥别名**：`OPENAI_API_KEY` 可代替 `CODEX_API_KEY`
- **CI**：ShellCheck + `bash -n` + PowerShell 语法检查

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
```

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
pwsh -File deploy-codex.ps1 -Restore
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

## 安全说明

- 脚本**无硬编码密钥**，可公开托管
- 交互输入 API Key **不回显**；摘要只显示前 8 位；URL 内嵌密码会打码
- `auth.json` / `config.toml` 权限 `600`（Windows 为当前用户 ACL）
- 写入前自动备份；失败时原配置不被破坏（原子替换）
- 临时文件在中断时自动清理

## 开发与 CI

```bash
bash -n deploy-codex.sh
shellcheck -x deploy-codex.sh   # 可选
bash deploy-codex.sh --help
```

GitHub Actions 会在 push / PR 时跑 bash 语法、ShellCheck 与 PowerShell 解析检查。

## 许可证

[MIT](LICENSE)
