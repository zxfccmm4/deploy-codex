# Codex CLI 一键部署脚本

> 适用于 **Debian 12 / Ubuntu / macOS / Windows**，一键安装并配置 [OpenAI Codex CLI](https://github.com/openai/codex)。

## 支持平台

| 平台 | 脚本 | 包管理器 | Node.js 来源 |
|------|------|----------|--------------|
| Linux（Debian 12 / Ubuntu） | `deploy-codex.sh` | `apt-get` | NodeSource |
| macOS（Darwin） | `deploy-codex.sh` | Homebrew | `brew install node@22` |
| Windows（PowerShell 5.1+ / 7+） | `deploy-codex.ps1` | winget | `OpenJS.NodeJS.LTS` |

## 功能

- 多平台一键安装，自动识别当前系统
- 安装基础依赖并配置 Node.js（已安装且版本 ≥ 20 则跳过）
- 通过 npm 全局安装 `@openai/codex`，支持自定义镜像源（`NPM_REGISTRY`）
- 写入 `~/.codex/config.toml` 与 `~/.codex/auth.json`
- 写入前自动备份旧配置（保留最近 5 份），重复执行不丢配置
- 自动修正属主与权限（`auth.json` 与 `config.toml` 均设为 `600` / 仅当前用户可读）
- 参数自动校验（`wire_api` 取值、`base_url` 格式），错误立即终止
- **幂等**：可重复执行，不会出错

## 快速开始

有两种运行模式：

- **交互式**：脚本会逐项提问，回车采用默认值，适合首次部署。
- **非交互式**：用环境变量传参，一行命令跑完，适合 CI / 自动化。

变量优先级：**环境变量 > 交互输入 > 默认值**。

---

### Linux / macOS（bash 脚本）

#### 方式一：远程一键（最快，无需下载脚本）

直接从 GitHub 拉取脚本并通过管道执行。**必须用环境变量传参**（管道模式下脚本无法交互提问），且两个必填项 `CODEX_API_KEY`、`CODEX_BASE_URL` 都要传：

```bash
curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
  | sudo CODEX_API_KEY="sk-xxxx" \
         CODEX_BASE_URL="https://your.proxy" \
         bash
```

> **macOS 前提**：需先安装 [Homebrew](https://brew.sh/)（`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`）。脚本会自动检测平台并选择 `apt-get` 或 `brew`。

> 如果只想跑交互式，请改用方式二或方式三，先下载脚本到本地。

#### 方式二：下载脚本 + 交互式运行（推荐）

**第 1 步：下载脚本**

```bash
curl -fsSL -o deploy-codex.sh \
  https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh
```

（可选）先看一眼内容再执行：

```bash
less deploy-codex.sh
```

**第 2 步：运行**

```bash
sudo bash deploy-codex.sh
```

运行后会依次提示输入，**回车采用方括号内的默认值**（API Key 和 base_url 为必填，无默认值）：

```text
  API Key (OPENAI_API_KEY) (输入不回显): _
  代理地址 (base_url): _
  模型 (model) [默认: gpt-5.5]: _
  审查模型 (review_model) [默认: gpt-5.5]: _
  推理强度 (reasoning_effort) [默认: xhigh]: _
  wire_api (responses/chat) [默认: responses]: _
```

输入完成后会打印配置摘要并要求确认（`Y/n`），确认后才开始部署。

> API Key 为隐藏输入（不回显），摘要中也只显示前 8 位；`base_url` 若含用户名密码也会被打码。

下载好的脚本也支持非交互式（用环境变量传参）：

```bash
sudo CODEX_API_KEY="sk-xxxx" \
     CODEX_BASE_URL="https://your.proxy" \
     bash deploy-codex.sh
```

国内网络可加 `NPM_REGISTRY` 走镜像安装 codex：

```bash
sudo CODEX_API_KEY="sk-xxxx" \
     CODEX_BASE_URL="https://your.proxy" \
     NPM_REGISTRY="https://registry.npmmirror.com" \
     bash deploy-codex.sh
```

#### 方式三：克隆仓库后运行

```bash
git clone https://github.com/zxfccmm4/deploy-codex.git
cd deploy-codex
sudo bash deploy-codex.sh          # 交互式
# 或非交互式:
# sudo CODEX_API_KEY="sk-xxxx" CODEX_BASE_URL="https://your.proxy" bash deploy-codex.sh
```

---

### Windows（PowerShell 脚本）

无需安装 WSL 或 Git Bash，Windows 自带 PowerShell 即可运行。

#### 方式一：下载脚本（推荐）

```powershell
Invoke-WebRequest -OutFile deploy-codex.ps1 `
  https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.ps1
```

#### 方式二：交互式运行

```powershell
powershell -ExecutionPolicy Bypass -File deploy-codex.ps1
```

提示与 Linux 版一致：API Key 隐藏输入，摘要打码，确认后开始部署。

#### 方式三：非交互式（环境变量）

```powershell
$env:CODEX_API_KEY = "sk-xxxx"
$env:CODEX_BASE_URL = "https://your.proxy"
"" | powershell -NonInteractive -ExecutionPolicy Bypass -File deploy-codex.ps1
```

> 管道传入空串是为了让 PowerShell 正确识别为非交互模式（stdin 被重定向）。

> Windows 版通过 winget 安装 Node.js LTS，无需手动安装 Node。

---

## 参数说明

| 环境变量 | 对应配置项 | 默认值 | 说明 |
|----------|-----------|--------|------|
| `CODEX_API_KEY` | `auth.json` → `OPENAI_API_KEY` | —（必填） | OpenAI API Key，隐藏输入 |
| `CODEX_BASE_URL` | `base_url` | —（必填） | API 代理地址 |
| `CODEX_MODEL` | `model` | `gpt-5.5` | 模型名 |
| `CODEX_REVIEW_MODEL` | `review_model` | `gpt-5.5` | 审查模型名 |
| `CODEX_REASONING_EFFORT` | `model_reasoning_effort` | `xhigh` | 推理强度 |
| `CODEX_WIRE_API` | `wire_api` | `responses` | wire API 类型，可选 `responses` / `chat` |
| `NODE_MAJOR` | — | `22` | Node.js 大版本（20 已 EOL，默认装 22 LTS）。**仅 Linux**（NodeSource）；macOS 用 brew 固定 `node@22`，Windows 用 winget 装 LTS |
| `NPM_REGISTRY` | — | 官方源 | npm 镜像源，如 `https://registry.npmmirror.com`（三平台通用） |

## 部署后

```bash
codex
```

> bash 版：用 `sudo` 执行时，配置会写到执行 `sudo` 的普通用户家目录（通过 `SUDO_USER` 识别），而非 `/root`。直接以 root 登录运行则写到 `/root`。
> PowerShell 版：配置写到当前 Windows 用户家目录 `%USERPROFILE%\.codex`。

## 安全说明

- 脚本**不包含任何硬编码密钥**，可放心公开
- API Key 在交互输入时不回显，摘要中只显示前 8 位
- 配置文件权限：`auth.json` 与 `config.toml`（Linux/macOS 为 `600`，Windows 为仅当前用户可读的 ACL），`base_url` 可能含凭据故一并收紧
- 配置文件以受限权限写入，无明文暴露窗口
- 重复执行会先备份旧配置（保留最近 5 份），不会静默覆盖
- `.gitignore` 已排除 `auth.json`、`.env`、`.DS_Store` 等

## 许可证

MIT