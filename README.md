# Codex CLI 一键部署脚本（优化版 2026）

> **支持 Debian 12 / Ubuntu / macOS / Windows**，一键安装并配置 [OpenAI Codex CLI](https://github.com/openai/codex)。

## 优化亮点 (1.1.0)
- **macOS 完全友好**：无需 sudo，brew 正常运行
- **auth 模式配置**：`CODEX_AUTH_STYLE=api_key | bearer | both`（默认 api_key）
- **provider 名称配置**：`CODEX_PROVIDER=OpenAI|custom`
- **功能开关**：`CODEX_GOALS`、`CODEX_DISABLE_RESPONSE_STORAGE`、`CODEX_NETWORK_ACCESS`
- **配置保留**：保留原有 `plugins` / `marketplaces` 段（不覆盖）
- **临时文件自动清理**：中断后安全清理
- **版本信息**：`bash deploy-codex.sh --version`
- **多 auth 模式**：支持代理常用的 `experimental_bearer_token`
- **OpenAI_API_KEY 别名**：`OPENAI_API_KEY` 也支持作为 `CODEX_API_KEY`

## 快速开始

### 方式一：远程一键（推荐）

**Linux**（需 root）：
```bash
curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
  | sudo bash
```

**macOS**（普通用户即可）：
```bash
curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
  | bash
```

**非交互 / CI**：
```bash
curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
  | sudo CODEX_API_KEY="sk-xxx" CODEX_BASE_URL="https://your.proxy" bash
```

### 方式二：本地运行

```bash
# macOS (普通用户)
curl -fsSL -o deploy-codex.sh https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh
chmod +x deploy-codex.sh
./deploy-codex.sh

# Linux (root)
sudo bash deploy-codex.sh
```

运行后会依次提示输入，**回车采用方括号内的默认值**。

## 参数说明

| 环境变量                        | 说明                          | 默认值          |
|-------------------------------|-----------------------------|----------------|
| `CODEX_API_KEY` / `OPENAI_API_KEY` | API Key                      | 必填            |
| `CODEX_BASE_URL`               | API 代理地址                 | 必填            |
| `CODEX_MODEL`                  | 模型                         | gpt-5.5         |
| `CODEX_PROVIDER`               | model_provider 名称          | OpenAI          |
| `CODEX_AUTH_STYLE`             | 密钥写入方式 (api_key/bearer/both) | api_key     |
| `CODEX_GOALS`                  | features.goals               | true            |
| `CODEX_DISABLE_RESPONSE_STORAGE` | disable_response_storage   | true            |
| `CODEX_NETWORK_ACCESS`         | network_access               | enabled         |
| `NPM_REGISTRY`                 | npm 镜像源                   | -               |
| `KEEP_BACKUPS`                 | 旧配置备份份数               | 5               |

## macOS 使用说明

```bash
# 安装 Homebrew（如果没有）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 运行部署
curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
  | bash
```

## 部署后

```bash
codex
```

切换到目标用户后运行即可。

## 安全说明

- API Key 在交互输入时不回显
- 配置写到普通用户家目录（支持 sudo）
- `auth.json` 权限 `600`
- 自动备份旧配置
- 支持自定义代理（`base_url` + `experimental_bearer_token`）

## 许可证

MIT
