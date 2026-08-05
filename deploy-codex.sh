#!/usr/bin/env bash
#
# Codex CLI 一键部署脚本（Debian 12 / Ubuntu / macOS）
#
# 一行命令即可完成安装与配置 (终端内可交互提问):
#   curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
#     | sudo bash
#   或加环境变量完全非交互 (适合 CI):
#   curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
#     | sudo CODEX_API_KEY="sk-xxxx" CODEX_BASE_URL="https://your.proxy" bash
#
# 其他用法:
#   下载后运行:   sudo bash deploy-codex.sh
#   恢复备份:     sudo bash deploy-codex.sh --restore
#
# 平台支持:
#   - Linux (Debian 12 / Ubuntu): apt-get + NodeSource
#   - macOS (Darwin):             Homebrew (需先安装好 brew)
#
set -euo pipefail

# 整个脚本体用 { } 包裹: bash 会在执行前一次性读完整个文件,
# 避免 bash <(curl ...) 场景下 Ctrl+C 导致 curl 报 (23) 写错误;
# 同时保证管道模式下 stdin 已被读完, read_tty 得以回退到 /dev/tty 交互提问。
{
SCRIPT_URL="https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh"
INSTALL_CMD="curl -fsSL ${SCRIPT_URL} | sudo bash"

trap 'printf "\n已取消。\n"; exit 130' INT

# ============== 默认值(交互时作为回车默认项) ==============
# 注意: API Key 与 base_url 为必填项, 无默认值。
DEFAULT_MODEL="gpt-5.5"
DEFAULT_REVIEW_MODEL="gpt-5.5"
DEFAULT_REASONING_EFFORT="xhigh"
DEFAULT_WIRE_API="responses"
NODE_MAJOR="${NODE_MAJOR:-22}"        # Node 主版本 (Node 20 已于 2026-04 EOL, 默认装 22 LTS)
NODE_MIN_MAJOR=20                     # 已安装 Node 大版本 >= 该值则跳过安装
NPM_REGISTRY="${NPM_REGISTRY:-}"      # 可选 npm 镜像源, 如 https://registry.npmmirror.com
KEEP_BACKUPS=5                        # 旧配置备份保留份数

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

# ============== 交互式输入 ==============
# stdin 是 tty 或 /dev/tty 可读都视为可交互 (支持 curl | bash 管道中提问)
INTERACTIVE=1
if [[ ! -t 0 ]] && [[ ! -r /dev/tty ]]; then
    INTERACTIVE=0
fi

# read_tty <变量名> <提示语> <是否隐藏输入 0/1>
# stdin 是管道时先从 stdin 读 (适配自动化测试), 否则回退到 /dev/tty 提问
read_tty() {
    local __var="$1" __prompt="$2" __secret="${3:-0}" __ans='' __got=1
    if [[ ! -t 0 ]]; then
        printf '%s' "${__prompt}"
        if IFS= read -r __ans; then __got=0; fi
    fi
    if [[ "${__got}" -ne 0 ]] && [[ -r /dev/tty ]]; then
        printf '%s' "${__prompt}" > /dev/tty
        if [[ "${__secret}" -eq 1 ]]; then
            IFS= read -r -s __ans < /dev/tty
        else
            IFS= read -r __ans < /dev/tty
        fi
        printf '\n' > /dev/tty
    fi
    eval "${__var}=\"\$__ans\""
}

# ============== 帮助 ==============
usage() {
    cat <<EOF
一行命令安装并配置 (终端内可交互提问):
  ${INSTALL_CMD}
  或加环境变量完全非交互 (适合 CI):
  curl -fsSL ${SCRIPT_URL} | sudo CODEX_API_KEY="sk-xxxx" CODEX_BASE_URL="https://your.proxy" bash

选项:
  -h, --help     显示本帮助
  -r, --restore  用最近一次的备份恢复配置

参数通过环境变量传入(优先级: 环境变量 > 交互输入 > 默认值):
  CODEX_API_KEY          必填, API Key
  CODEX_BASE_URL         必填, API 代理地址
  CODEX_MODEL            模型名, 默认 gpt-5.5
  CODEX_REVIEW_MODEL     审查模型, 默认 gpt-5.5
  CODEX_REASONING_EFFORT 推理强度, 默认 xhigh
  CODEX_WIRE_API         responses / chat, 默认 responses
  CODEX_HOME             Codex 配置目录, 默认 <家目录>/.codex
  NODE_MAJOR             Node 主版本, 默认 22 (仅 Linux)
  NPM_REGISTRY           npm 镜像源, 如 https://registry.npmmirror.com
EOF
}
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

# ============== 平台检测 ==============
detect_os() {
    case "$(uname -s)" in
        Darwin) OS="macos" ;;
        Linux)  OS="linux" ;;
        *)      die "不支持的系统: $(uname -s), 仅支持 Debian/Ubuntu/macOS" ;;
    esac
}
detect_os

# ============== 前置检查 ==============
[[ $EUID -eq 0 ]] || die "请使用 root 运行 (一行命令): ${INSTALL_CMD}"
case "${OS}" in
    linux)
        [[ -f /etc/os-release ]] || die "未找到 /etc/os-release, 该脚本仅支持 Debian/Ubuntu"
        grep -qEi 'debian|ubuntu' /etc/os-release \
          || die "仅支持 Debian/Ubuntu 系统, 当前系统无法识别"
        command -v apt-get >/dev/null 2>&1 \
          || die "未找到 apt-get, 仅支持 Debian/Ubuntu 系统"
        ;;
    macos)
        command -v brew >/dev/null 2>&1 \
          || die "未找到 Homebrew, 请先安装: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        ;;
esac

# 实际使用 codex 的目标用户(配置写到该用户家目录)
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="${SUDO_USER}"
else
    TARGET_USER="root"
fi
# 解析目标用户家目录: Linux 用 getent, macOS 用 id -P (输出 passwd 格式, 第6字段为家目录)
if command -v getent >/dev/null 2>&1; then
    TARGET_HOME=$(getent passwd "${TARGET_USER}" | cut -d: -f6) \
      || die "无法解析用户 ${TARGET_USER} 的家目录"
elif command -v id >/dev/null 2>&1 && id -P "${TARGET_USER}" >/dev/null 2>&1; then
    TARGET_HOME=$(id -P "${TARGET_USER}" 2>/dev/null | cut -d: -f6)
    [[ -n "${TARGET_HOME}" ]] || die "无法解析用户 ${TARGET_USER} 的家目录"
else
    die "无法解析用户 ${TARGET_USER} 的家目录"
fi
CODEX_DIR="${CODEX_HOME:-${TARGET_HOME}/.codex}"

# ============== 恢复最近一次备份 (--restore) ==============
if [[ "${1:-}" == "-r" || "${1:-}" == "--restore" ]]; then
    latest_backup=$(ls -dt "${CODEX_DIR}".bak.* 2>/dev/null | head -1)
    [[ -n "${latest_backup}" ]] || die "未找到任何备份 (${CODEX_DIR}.bak.*), 无需恢复"
    echo
    info "将用以下备份恢复: ${latest_backup}"
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
        read_tty confirm "确认恢复? [Y/n]"
        confirm="${confirm:-Y}"
        [[ "${confirm}" =~ ^[Yy]$ ]] || die "已取消恢复"
    fi
    [[ -f "${latest_backup}/config.toml" ]] && cp -p "${latest_backup}/config.toml" "${CODEX_DIR}/config.toml"
    [[ -f "${latest_backup}/auth.json" ]] && cp -p "${latest_backup}/auth.json" "${CODEX_DIR}/auth.json"
    chown -R "${TARGET_USER}:${TARGET_USER}" "${CODEX_DIR}" 2>/dev/null || :
    chmod 700 "${CODEX_DIR}"
    chmod 600 "${CODEX_DIR}/auth.json" "${CODEX_DIR}/config.toml" 2>/dev/null || :
    ok "已从 ${latest_backup} 恢复配置"
    exit 0
fi

# ============== 交互式参数读取 ==============
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
        read_tty val "${msg}${hint}" "${secret}"
        val="${val:-${def}}"
        [[ -z "${val}" && -z "${def}" ]] && die "必填项为空, 已取消部署"
        printf -v "${var}" '%s' "${val}"
    else
        # 3) 非交互模式 -> 必须有默认值, 否则报错
        [[ -z "${def}" ]] && die "非交互模式且未设置环境变量 ${var}, 请用 ${var}=... bash \$0"
        printf -v "${var}" '%s' "${def}"
    fi
}

mask_key() { printf '%s********\n' "${1:0:8}"; }   # 只显示前8位

# 隐藏 URL 中的凭据: https://user:pass@host -> https://user:***@host
mask_url() {
    local u="$1"
    if [[ "${u}" =~ ^(https?://)([^/@:]+):[^/@]+@(.*)$ ]]; then
        printf '%s%s:***@%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    else
        printf '%s\n' "${u}"
    fi
}

# 转义字符串中的特殊字符 (兼容 TOML 与 JSON 字符串)
escape_string() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "${s}"
}

echo
info "=========== Codex 配置参数 ==========="
ask CODEX_API_KEY          "  API Key (OPENAI_API_KEY)"   ""                    1
ask CODEX_BASE_URL         "  代理地址 (base_url)"        ""                    0
ask CODEX_MODEL            "  模型 (model)"               "${DEFAULT_MODEL}"    0
ask CODEX_REVIEW_MODEL     "  审查模型 (review_model)"    "${DEFAULT_REVIEW_MODEL}" 0
ask CODEX_REASONING_EFFORT "  推理强度 (reasoning_effort)" "${DEFAULT_REASONING_EFFORT}" 0
ask CODEX_WIRE_API         "  wire_api (responses/chat)"  "${DEFAULT_WIRE_API}" 0

# ============== 参数校验 ==============
[[ "${CODEX_WIRE_API}" =~ ^(responses|chat)$ ]] \
  || die "wire_api 仅支持 responses 或 chat, 当前值: ${CODEX_WIRE_API}"
[[ "${CODEX_BASE_URL}" =~ ^https?:// ]] \
  || die "base_url 必须是 http(s):// 开头的地址, 当前值: $(mask_url "${CODEX_BASE_URL}")"
case "${CODEX_API_KEY}" in
    *'"'*) die "API Key 不能包含双引号" ;;
esac
if [[ "${CODEX_API_KEY}" != sk-* ]]; then
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
        # 交互模式: 重新提问, 最多 3 次
        KEY_ATTEMPT=0
        while [[ "${CODEX_API_KEY}" != sk-* ]]; do
            KEY_ATTEMPT=$((KEY_ATTEMPT+1))
            [[ "${KEY_ATTEMPT}" -ge 3 ]] && die "未能获得有效的 API Key (需以 sk- 开头), 已退出 (未修改任何文件)"
            warn "API Key 必须以 sk- 开头"
            read_tty CODEX_API_KEY "  请重新输入 API Key (OPENAI_API_KEY)" 1
        done
        case "${CODEX_API_KEY}" in
            *'"'*) die "API Key 不能包含双引号" ;;
        esac
    else
        die "API Key 必须以 sk- 开头, 当前值: $(mask_key "${CODEX_API_KEY}")"
    fi
fi

echo
info "配置摘要:"
printf "  目标用户    : %s\n" "${TARGET_USER}"
printf "  配置目录    : %s\n" "${CODEX_DIR}"
printf "  API Key     : %s\n" "$(mask_key "${CODEX_API_KEY}")"
printf "  base_url    : %s\n" "$(mask_url "${CODEX_BASE_URL}")"
printf "  model       : %s\n" "${CODEX_MODEL}"
printf "  review_model: %s\n" "${CODEX_REVIEW_MODEL}"
printf "  effort      : %s\n" "${CODEX_REASONING_EFFORT}"
printf "  wire_api    : %s\n" "${CODEX_WIRE_API}"
[[ -n "${NPM_REGISTRY}" ]] && printf "  npm 镜像    : %s\n" "${NPM_REGISTRY}"
echo

if [[ "${INTERACTIVE}" -eq 1 ]]; then
    read_tty confirm "确认以上配置并开始部署? [Y/n]"
    confirm="${confirm:-Y}"
    [[ "${confirm}" =~ ^[Yy]$ ]] || die "用户取消部署"
fi

# ============== 1. 安装基础依赖 ==============
case "${OS}" in
    linux)
        info "更新 apt 并安装基础依赖..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg gettext >/dev/null
        command -v curl >/dev/null 2>&1 || die "curl 安装失败"
        ;;
    macos)
        info "macOS: 使用 Homebrew, 系统自带 curl, 无需额外安装基础依赖"
        ;;
esac

# ============== 2. 安装 Node.js (NodeSource / Homebrew) ==============
install_node() {
    if command -v node >/dev/null 2>&1; then
        local v
        v=$(node -v 2>/dev/null | sed -nE 's/^v?([0-9]+).*/\1/p' || true)
        if [[ -n "${v}" && "${v}" -ge "${NODE_MIN_MAJOR}" ]]; then
            ok "已安装 Node.js $(node -v), 跳过"
            return 0
        fi
        warn "Node.js 版本过低 ($(node -v 2>/dev/null || echo '未知')), 将安装 Node ${NODE_MAJOR}"
    fi
    case "${OS}" in
        linux)
            info "通过 NodeSource 安装 Node.js ${NODE_MAJOR}..."
            mkdir -p /etc/apt/keyrings
            curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
                | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
            echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
                > /etc/apt/sources.list.d/nodesource.list
            apt-get update -qq
            apt-get install -y -qq --no-install-recommends nodejs >/dev/null
            ;;
        macos)
            # node@XX 为 keg-only 公式, 装完需手动 link 才能进入 PATH
            info "通过 Homebrew 安装 Node.js ${NODE_MAJOR} (node@${NODE_MAJOR})..."
            if ! brew install "node@${NODE_MAJOR}" >/dev/null 2>&1; then
                warn "brew 安装 node@${NODE_MAJOR} 失败, 回退安装最新版 node"
                brew install node
            fi
            if ! command -v node >/dev/null 2>&1; then
                brew link --overwrite --force "node@${NODE_MAJOR}" >/dev/null 2>&1 || :
            fi
            ;;
    esac
    command -v node >/dev/null 2>&1 || die "Node.js 安装失败"
    command -v npm >/dev/null 2>&1 || die "npm 未随 Node.js 安装, 请手动安装 npm"
    ok "Node.js 安装完成: $(node -v)"
}
install_node

# ============== 3. 安装 Codex CLI ==============
command -v npm >/dev/null 2>&1 || die "未找到 npm, 请先安装 npm 或重新安装 Node.js"
info "通过 npm 全局安装 @openai/codex ..."
npm_install_log=$(mktemp)
npm_args=(install -g --no-audit --no-fund @openai/codex)
[[ -n "${NPM_REGISTRY}" ]] && npm_args+=(--registry="${NPM_REGISTRY}")
if ! npm "${npm_args[@]}" >"${npm_install_log}" 2>&1; then
    cat "${npm_install_log}" >&2 || :
    rm -f "${npm_install_log}"
    die "npm 安装 codex 失败, 请检查网络/镜像源 (国内网络可设置 NPM_REGISTRY=https://registry.npmmirror.com)"
fi
rm -f "${npm_install_log}"
command -v codex >/dev/null 2>&1 || die "codex 未在 PATH 中, 请检查 npm 全局 bin 目录"
ok "Codex 安装完成: $(codex --version 2>/dev/null || echo 'installed')"

# ============== 4. 写入配置文件 (先备份旧配置) ==============
info "写入配置到 ${CODEX_DIR} ..."
[[ -d "${CODEX_DIR}" ]] || install -d -m 700 "${CODEX_DIR}"

# 备份已有配置 (保留最近 ${KEEP_BACKUPS} 份)
if [[ -f "${CODEX_DIR}/config.toml" || -f "${CODEX_DIR}/auth.json" ]]; then
    backup_dir="${CODEX_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    mkdir -p "${backup_dir}"
    cp -p "${CODEX_DIR}/config.toml" "${backup_dir}/" 2>/dev/null || :
    cp -p "${CODEX_DIR}/auth.json"   "${backup_dir}/" 2>/dev/null || :
    ok "已备份旧配置到 ${backup_dir}"
    # 删除超出保留份数的旧备份 (portable, 不依赖 GNU xargs -r)
    while IFS= read -r old; do
        rm -rf "${old}"
    done < <(ls -dt "${CODEX_DIR}".bak.* 2>/dev/null | tail -n "+$((KEEP_BACKUPS+1))")
fi

# 生成配置到临时文件 (600 权限), 校验通过后再原子替换, 失败不影响原文件
TMP_CONFIG="${CODEX_DIR}/config.toml.tmp.$$"
TMP_AUTH="${CODEX_DIR}/auth.json.tmp.$$"
( umask 077
cat > "${TMP_CONFIG}" <<EOF
model_provider = "OpenAI"
model = "$(escape_string "${CODEX_MODEL}")"
review_model = "$(escape_string "${CODEX_REVIEW_MODEL}")"
model_reasoning_effort = "$(escape_string "${CODEX_REASONING_EFFORT}")"
disable_response_storage = true
network_access = "enabled"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "$(escape_string "${CODEX_BASE_URL}")"
wire_api = "$(escape_string "${CODEX_WIRE_API}")"
requires_openai_auth = true

[features]
goals = true
EOF

cat > "${TMP_AUTH}" <<EOF
{
  "OPENAI_API_KEY": "$(escape_string "${CODEX_API_KEY}")"
}
EOF
)

# 严格校验 (python3): TOML 用 tomllib (3.11+), JSON 用 json
if command -v python3 >/dev/null 2>&1; then
    if ! python3 - "${TMP_CONFIG}" "${TMP_AUTH}" <<'PYVAL' 2>/dev/null
import sys, json
try:
    import tomllib
except ImportError:
    tomllib = None
errors = []
if tomllib is not None:
    try:
        with open(sys.argv[1], 'rb') as f:
            c = tomllib.load(f)
        assert c.get('model') and c.get('model_provider'), 'model/model_provider missing'
        assert 'OpenAI' in c.get('model_providers', {}), 'model_providers.OpenAI missing'
    except Exception as e:
        errors.append('config.toml: %s' % e)
try:
    with open(sys.argv[2], 'r', encoding='utf-8') as f:
        d = json.load(f)
    assert isinstance(d.get('OPENAI_API_KEY'), str) and d['OPENAI_API_KEY'], 'auth.json 缺少 OPENAI_API_KEY'
except Exception as e:
    errors.append('auth.json: %s' % e)
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
PYVAL
    then
        ok "配置校验通过 (TOML/JSON)"
    else
        rm -f "${TMP_CONFIG}" "${TMP_AUTH}"
        die "生成的配置未通过校验, 已中止 (原文件未被修改)"
    fi
else
    warn "未找到 python3, 跳过配置严格校验"
fi

mv "${TMP_CONFIG}" "${CODEX_DIR}/config.toml" || { rm -f "${TMP_CONFIG}" "${TMP_AUTH}"; die "写入 config.toml 失败"; }
mv "${TMP_AUTH}" "${CODEX_DIR}/auth.json"     || { rm -f "${TMP_AUTH}"; die "写入 auth.json 失败"; }

# ============== 5. 修正属主与权限 ==============
chown -R "${TARGET_USER}:${TARGET_USER}" "${CODEX_DIR}"
chmod 700 "${CODEX_DIR}"
chmod 600 "${CODEX_DIR}/auth.json" "${CODEX_DIR}/config.toml"
ok "权限设置完成"

# ============== 6. 验证 ==============
info "配置预览(auth.json, 密钥已打码):"
sed -E 's/(sk-[a-zA-Z0-9]{6})[a-zA-Z0-9]+/\1********/' "${CODEX_DIR}/auth.json"

if curl -fsSL --connect-timeout 8 -o /dev/null "${CODEX_BASE_URL}" 2>/dev/null; then
    ok "代理地址可达: $(mask_url "${CODEX_BASE_URL}")"
else
    warn "代理地址探测无响应(可能是正常的): $(mask_url "${CODEX_BASE_URL}")"
fi

# 检查目标用户的 PATH 中是否能看到 codex (仅 Linux; macOS 的 brew 默认已加入 PATH)
if [[ "${OS}" == "linux" && "${TARGET_USER}" != "root" ]]; then
    if ! su -s /bin/bash "${TARGET_USER}" -c 'command -v codex >/dev/null 2>&1'; then
        warn "codex 命令可能不在 ${TARGET_USER} 的 PATH 中, 请确认 npm 全局 bin 目录已加入该用户 PATH"
    fi
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
    echo "  例如: sudo -iu ${TARGET_USER} codex"
fi
echo "  恢复备份 : ${INSTALL_CMD} --restore"
echo "=================================="

}