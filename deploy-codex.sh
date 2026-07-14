#!/usr/bin/env bash
#
# Codex CLI 一次性部署脚本（Debian 12）
#
# 用法:
#   1) 交互式(推荐):  sudo bash deploy-codex.sh
#      运行后会依次提示输入 API Key、代理地址、模型等参数。
#
#   2) 非交互 / 自动化(用环境变量传参, 适合 CI 或 curl|bash):
#        sudo CODEX_API_KEY="sk-xxxx" \
#             CODEX_BASE_URL="https://your.proxy" \
#             bash deploy-codex.sh
#
#   3) 远程一键:
#        curl -fsSL http://your-host/deploy-codex.sh \
#          | sudo CODEX_API_KEY="sk-xxxx" bash
#
set -euo pipefail

# ============== 默认值(交互时作为回车默认项) ==============
# 注意: API Key 与 base_url 为必填项, 无默认值。
DEFAULT_MODEL="gpt-5.5"
DEFAULT_REVIEW_MODEL="gpt-5.5"
DEFAULT_REASONING_EFFORT="xhigh"
DEFAULT_WIRE_API="responses"
NODE_MAJOR="${NODE_MAJOR:-20}"

# ============== 颜色输出 ==============
if [[ -t 1 ]]; then
    C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'
    C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
    C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_CYAN=''; C_NC=''
fi
info()  { printf "${C_BLUE}[INFO]${C_NC} %s\n"  "$*"; }
ok()    { printf "${C_GREEN}[ OK ]${C_NC} %s\n"  "$*"; }
warn()  { printf "${C_YELLOW}[WARN]${C_NC} %s\n" "$*"; }
die()   { printf "${C_RED}[FAIL]${C_NC} %s\n" "$*" >&2; exit 1; }

# ============== 前置检查 ==============
[[ $EUID -eq 0 ]] || die "请使用 root 运行: sudo bash $0"
[[ -f /etc/os-release ]] || die "未找到 /etc/os-release, 该脚本仅支持 Debian/Ubuntu"
grep -qi debian /etc/os-release 2>/dev/null \
  || warn "当前系统非 Debian, 脚本按 Debian/Ubuntu 兼容处理, 继续执行..."

# 实际使用 codex 的目标用户(配置写到该用户家目录)
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="${SUDO_USER}"
else
    TARGET_USER="root"
fi
TARGET_HOME=$(getent passwd "${TARGET_USER}" | cut -d: -f6) || die "无法解析用户 ${TARGET_USER} 的家目录"
CODEX_DIR="${TARGET_HOME}/.codex"

# ============== 交互式参数读取 ==============
# 优先级: 环境变量 > 交互输入 > 默认值
INTERACTIVE=1
[[ -t 0 ]] || INTERACTIVE=0   # stdin 不是 tty (如管道) 则视为非交互

# ask <变量名> <提示语> <默认值> <是否隐藏输入 0/1>
ask() {
    local var="$1" msg="$2" def="${3:-}" secret="${4:-0}" val hint=""
    # 1) 环境变量已设置且非空 -> 直接采用
    if [[ -n "${!var:-}" ]]; then
        return 0
    fi
    # 2) 交互式终端 -> 提示输入
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
        [[ -n "${def}" ]] && hint=" [默认: ${def}]"
        if [[ "${secret}" -eq 1 ]]; then
            read -r -s -p "${msg}${hint} (输入不回显): " val
            echo
        else
            read -r -p "${msg}${hint}: " val
            val="${val:-${def}}"
        fi
        [[ -z "${val}" && -z "${def}" ]] && die "必填项为空, 已取消部署"
        printf -v "${var}" '%s' "${val}"
    else
        # 3) 非交互模式 -> 必须有默认值, 否则报错
        [[ -z "${def}" ]] && die "非交互模式且未设置环境变量 ${var}, 请用 ${var}=... bash \$0"
        printf -v "${var}" '%s' "${def}"
    fi
}

mask_key() { printf '%s********\n' "${1:0:8}"; }   # 只显示前8位

echo
info "=========== Codex 配置参数 ==========="
ask CODEX_API_KEY          "  API Key (OPENAI_API_KEY)"   ""                    1
ask CODEX_BASE_URL         "  代理地址 (base_url)"        ""                    0
ask CODEX_MODEL            "  模型 (model)"               "${DEFAULT_MODEL}"    0
ask CODEX_REVIEW_MODEL     "  审查模型 (review_model)"    "${DEFAULT_REVIEW_MODEL}" 0
ask CODEX_REASONING_EFFORT "  推理强度 (reasoning_effort)" "${DEFAULT_REASONING_EFFORT}" 0
ask CODEX_WIRE_API         "  wire_api (responses/chat)"  "${DEFAULT_WIRE_API}" 0

echo
info "配置摘要:"
printf "  目标用户    : %s\n" "${TARGET_USER}"
printf "  API Key     : %s\n" "$(mask_key "${CODEX_API_KEY}")"
printf "  base_url    : %s\n" "${CODEX_BASE_URL}"
printf "  model       : %s\n" "${CODEX_MODEL}"
printf "  review_model: %s\n" "${CODEX_REVIEW_MODEL}"
printf "  effort      : %s\n" "${CODEX_REASONING_EFFORT}"
printf "  wire_api    : %s\n" "${CODEX_WIRE_API}"
echo

if [[ "${INTERACTIVE}" -eq 1 ]]; then
    read -r -p "确认以上配置并开始部署? [Y/n] " confirm
    confirm="${confirm:-Y}"
    [[ "${confirm}" =~ ^[Yy]$ ]] || die "用户取消部署"
fi

# ============== 1. 安装基础依赖 ==============
info "更新 apt 并安装基础依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg gettext >/dev/null

# ============== 2. 安装 Node.js (NodeSource) ==============
install_node() {
    if command -v node >/dev/null 2>&1; then
        local v
        v=$(node -v | sed 's/v//; s/\..*//')
        if (( v >= 18 )); then
            ok "已安装 Node.js $(node -v), 跳过"
            return 0
        fi
        warn "Node.js 版本过低 ($(node -v)), 将安装 Node ${NODE_MAJOR}"
    fi
    info "通过 NodeSource 安装 Node.js ${NODE_MAJOR}..."
    apt-get install -y -qq gnupg >/dev/null
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq
    apt-get install -y -qq nodejs >/dev/null
    ok "Node.js 安装完成: $(node -v)"
}
install_node

# ============== 3. 安装 Codex CLI ==============
info "通过 npm 全局安装 @openai/codex ..."
npm install -g @openai/codex >/dev/null 2>&1 || die "npm 安装 codex 失败, 请检查网络/镜像源"
command -v codex >/dev/null 2>&1 || die "codex 未在 PATH 中, 请检查 npm 全局 bin 目录"
ok "Codex 安装完成: $(codex --version 2>/dev/null || echo 'installed')"

# ============== 4. 写入配置文件 ==============
info "写入配置到 ${CODEX_DIR} ..."
install -d -m 700 "${CODEX_DIR}"

cat > "${CODEX_DIR}/config.toml" <<EOF
model_provider = "OpenAI"
model = "${CODEX_MODEL}"
review_model = "${CODEX_REVIEW_MODEL}"
model_reasoning_effort = "${CODEX_REASONING_EFFORT}"
disable_response_storage = true
network_access = "enabled"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "${CODEX_BASE_URL}"
wire_api = "${CODEX_WIRE_API}"
requires_openai_auth = true

[features]
goals = true
EOF

cat > "${CODEX_DIR}/auth.json" <<EOF
{
  "OPENAI_API_KEY": "${CODEX_API_KEY}"
}
EOF

# ============== 5. 修正属主与权限 ==============
chown -R "${TARGET_USER}:${TARGET_USER}" "${CODEX_DIR}"
chmod 700 "${CODEX_DIR}"
chmod 600 "${CODEX_DIR}/auth.json"
chmod 644 "${CODEX_DIR}/config.toml"
ok "权限设置完成"

# ============== 6. 验证 ==============
info "配置预览(auth.json, 密钥已打码):"
sed -E 's/(sk-[a-zA-Z0-9]{6})[a-zA-Z0-9]+/\1********/' "${CODEX_DIR}/auth.json"

if curl -fsSL --connect-timeout 8 -o /dev/null "${CODEX_BASE_URL}" 2>/dev/null; then
    ok "代理地址可达: ${CODEX_BASE_URL}"
else
    warn "代理地址探测无响应(可能是正常的): ${CODEX_BASE_URL}"
fi

echo
ok "============ 部署完成 ============"
echo "  用户 : ${TARGET_USER}"
echo "  命令 : $(command -v codex)"
echo "  配置 : ${CODEX_DIR}/config.toml"
echo "  密钥 : ${CODEX_DIR}/auth.json"
echo
echo "  切换到该用户后直接运行:  codex"
if [[ "${TARGET_USER}" != "$(id -un)" ]]; then
    echo "  例如: su - ${TARGET_USER} -c codex"
fi
echo "=================================="
