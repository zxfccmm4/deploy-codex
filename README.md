# Codex CLI 一键部署脚本

> 适用于 **Debian 12 / Ubuntu**，一键安装并配置 [OpenAI Codex CLI](https://github.com/openai/codex)。

## 功能

- 安装基础依赖（`curl`、`ca-certificates`、`gnupg`、`gettext` 等）
- 通过 NodeSource 安装 Node.js 20（已安装且版本 ≥ 18 则跳过）
- 通过 npm 全局安装 `@openai/codex`
- 写入 `~/.codex/config.toml` 与 `~/.codex/auth.json`
- 自动修正属主与权限（`auth.json` 设为 `600`）
- **幂等**：可重复执行，不会出错

## 快速开始

### 方式一：交互式（推荐）

```bash
sudo bash deploy-codex.sh
```

运行后会依次提示输入，**回车采用方括号内的默认值**：

```text
  API Key (OPENAI_API_KEY) (输入不回显): _
  代理地址 (base_url) [默认: https://opencode.2020713.xyz]: _
  模型 (model) [默认: gpt-5.5]: _
  审查模型 (review_model) [默认: gpt-5.5]: _
  推理强度 (reasoning_effort) [默认: xhigh]: _
  wire_api (responses/chat) [默认: responses]: _
```

输入完成后会打印配置摘要并要求确认（`Y/n`），确认后才开始部署。

> API Key 为隐藏输入（不回显），摘要中也只显示前 8 位。

### 方式二：非交互 / 自动化

通过环境变量传参，跳过所有提示，适合 CI 或远程一键部署：

```bash
sudo CODEX_API_KEY="sk-xxxx" \
     CODEX_BASE_URL="https://your.proxy" \
     bash deploy-codex.sh
```

### 方式三：远程一键（curl | bash）

```bash
curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
  | sudo CODEX_API_KEY="sk-xxxx" bash
```

### 方式四：克隆后运行

```bash
git clone https://github.com/zxfccmm4/deploy-codex.git
cd deploy-codex
sudo bash deploy-codex.sh
```

## 参数说明

每个参数取值顺序：**环境变量 > 交互输入 > 默认值**

| 环境变量 | 对应配置项 | 默认值 | 说明 |
|----------|-----------|--------|------|
| `CODEX_API_KEY` | `auth.json` → `OPENAI_API_KEY` | —（必填） | OpenAI API Key，隐藏输入 |
| `CODEX_BASE_URL` | `base_url` | `https://opencode.2020713.xyz` | API 代理地址 |
| `CODEX_MODEL` | `model` | `gpt-5.5` | 模型名 |
| `CODEX_REVIEW_MODEL` | `review_model` | `gpt-5.5` | 审查模型名 |
| `CODEX_REASONING_EFFORT` | `model_reasoning_effort` | `xhigh` | 推理强度 |
| `CODEX_WIRE_API` | `wire_api` | `responses` | wire API 类型，可选 `responses` / `chat` |
| `NODE_MAJOR` | — | `20` | Node.js 大版本 |

## 部署后

```bash
codex
```

> 用 `sudo` 执行时，配置会写到执行 `sudo` 的普通用户家目录（通过 `SUDO_USER` 识别），而非 `/root`。直接以 root 登录运行则写到 `/root`。

## 安全说明

- 脚本**不包含任何硬编码密钥**，可放心公开
- API Key 在交互输入时不回显，摘要中只显示前 8 位
- `auth.json` 权限设为 `600`，仅属主可读
- `.gitignore` 已排除 `auth.json`、`.env`、`.DS_Store` 等

## 许可证

MIT
