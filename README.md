# Codex CLI 一键部署脚本

适用于 **Debian 12 / Ubuntu**，一键安装并配置 [OpenAI Codex CLI](https://github.com/openai/codex)。

## 功能

- 安装基础依赖（curl、ca-certificates、gnupg 等）
- 通过 NodeSource 安装 Node.js 20（已装则跳过）
- 通过 npm 全局安装 `@openai/codex`
- 交互式或环境变量方式写入 `~/.codex/config.toml` 与 `~/.codex/auth.json`
- 自动修正属主与权限（`auth.json` 设为 `600`）
- 幂等：可重复执行，不会出错

## 使用方法

### 方式一：交互式（推荐）

```bash
sudo bash deploy-codex.sh
```

运行后会依次提示输入：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| API Key | `OPENAI_API_KEY`，隐藏输入 | （必填） |
| 代理地址 | `base_url` | `https://opencode.2020713.xyz` |
| 模型 | `model` | `gpt-5.5` |
| 审查模型 | `review_model` | `gpt-5.5` |
| 推理强度 | `model_reasoning_effort` | `xhigh` |
| wire_api | `responses` 或 `chat` | `responses` |

回车采用默认值，确认摘要后开始部署。

### 方式二：非交互 / 自动化

通过环境变量传参，跳过所有提示，适合 CI 或远程一键部署：

```bash
sudo CODEX_API_KEY="sk-xxxx" \
     CODEX_BASE_URL="https://your.proxy" \
     bash deploy-codex.sh
```

### 方式三：远程一键

```bash
curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/deploy-codex.sh \
  | sudo CODEX_API_KEY="sk-xxxx" bash
```

## 参数优先级

每个参数取值顺序：**环境变量 > 交互输入 > 默认值**

| 环境变量 | 说明 |
|----------|------|
| `CODEX_API_KEY` | OpenAI API Key（必填） |
| `CODEX_BASE_URL` | 代理地址 |
| `CODEX_MODEL` | 模型名 |
| `CODEX_REVIEW_MODEL` | 审查模型名 |
| `CODEX_REASONING_EFFORT` | 推理强度 |
| `CODEX_WIRE_API` | wire API 类型 |
| `NODE_MAJOR` | Node.js 大版本，默认 20 |

## 安全说明

- 脚本**不包含任何硬编码密钥**，可放心公开
- API Key 在交互输入时不回显，摘要中只显示前 8 位
- `auth.json` 权限设为 `600`，仅属主可读
- 建议将本仓库设为 Private 以获得额外保护

## 目标用户

用 `sudo` 执行时，配置会写到执行 `sudo` 的那个普通用户家目录（通过 `SUDO_USER` 识别），而非 `/root`。直接以 root 登录运行则写到 `/root`。

部署完成后：

```bash
codex
```
