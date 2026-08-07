#!/usr/bin/env bash
#
# Codex CLI 一键部署脚本（Debian 12 / Ubuntu / macOS）
# Version: 1.2.0
#
# 一行命令即可完成安装与配置 (终端内可交互提问):
#   # Linux:
#   curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
#     | sudo bash
#   # macOS (无需 sudo):
#   curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
#     | bash
#   或加环境变量完全非交互 (适合 CI):
#   curl -fsSL https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh \
#     | sudo CODEX_API_KEY="sk-xxxx" CODEX_BASE_URL="https://your.proxy" bash
#
# 其他用法:
#   下载后运行:   bash deploy-codex.sh          # macOS
#                 sudo bash deploy-codex.sh     # Linux
#   恢复备份:     bash deploy-codex.sh --restore
#   版本信息:     bash deploy-codex.sh --version
#   仅写配置:     bash deploy-codex.sh --dry-run
#   卸载清理:     bash deploy-codex.sh --uninstall
#
# 平台支持:
#   - Linux (Debian 12 / Ubuntu): apt-get + NodeSource (需 root)
#   - macOS (Darwin):             Homebrew (普通用户即可, 勿用 sudo)
#
set -euo pipefail

# 整个脚本体用 { } 包裹: bash 会在执行前一次性读完整个文件,
# 避免 bash <(curl ...) 场景下 Ctrl+C 导致 curl 报 (23) 写错误;
# 同时保证管道模式下 stdin 已被读完, read_tty 得以回退到 /dev/tty 交互提问。
{
SCRIPT_VERSION="1.2.0"
SCRIPT_URL="https://raw.githubusercontent.com/zxfccmm4/deploy-codex/main/deploy-codex.sh"

# 临时文件列表 (中断时清理)
TMP_FILES=()
cleanup_tmp() {
    local f
    for f in "${TMP_FILES[@]:-}"; do
        [[ -n "${f}" && -e "${f}" ]] && rm -f "${f}" 2>/dev/null || true
    done
}
trap 'cleanup_tmp; printf "\n已取消。\n"; exit 130' INT
trap 'cleanup_tmp' EXIT

# ============== 默认值(交互时作为回车默认项) ==============
# 注意: API Key 与 base_url 为必填项, 无默认值。
DEFAULT_MODEL="gpt-5.5"
DEFAULT_REVIEW_MODEL="gpt-5.5"
DEFAULT_REASONING_EFFORT="xhigh"
DEFAULT_WIRE_API="responses"
DEFAULT_PROVIDER="OpenAI"             # model_provider 名称
DEFAULT_AUTH_STYLE="api_key"          # api_key | bearer | both
DEFAULT_GOALS="true"
DEFAULT_DISABLE_RESPONSE_STORAGE="true"
DEFAULT_NETWORK_ACCESS="enabled"
NODE_MAJOR="${NODE_MAJOR:-22}"        # Node 主版本 (Node 20 已于 2026-04 EOL, 默认装 22 LTS)
NODE_MIN_MAJOR=20                     # 已安装 Node 大版本 >= 该值则跳过安装
NPM_REGISTRY="${NPM_REGISTRY:-}"      # 可选 npm 镜像源, 如 https://registry.npmmirror.com
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"     # 旧配置备份保留份数
PRESERVE_EXTRA="${CODEX_PRESERVE_EXTRA:-1}"  # 保留已有 plugins/marketplaces 段

# OPENAI_API_KEY 作为 CODEX_API_KEY 的别名
if [[ -z "${CODEX_API_KEY:-}" && -n "${OPENAI_API_KEY:-}" ]]; then
    CODEX_API_KEY="${OPENAI_API_KEY}"
fi

# ============== 颜色输出 ==============
if [[ -t 1 ]]; then
    C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'
    C_BLUE='\033[0;34m'; C_NC='\033[0m'
else
    C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_NC=''
fi
info()  { printf "${C_BLUE}[INFO]${C_NC} %s\n"  "$*"; }
ok()    { printf "${C_GREEN}[ OK ]${C_NC} %s\n"  "$*"; }
warn()  { printf "${C_YELLOW}[WARN]${C_NC} %s\n" "$*"; }
die()   { printf "${C_RED}[FAIL]${C_NC} %s\n" "$*" >&2; exit 1; }

# ============== 交互式输入 ==============
# stdin 是 tty, 或能真正打开 /dev/tty 时视为可交互 (支持 curl | bash 管道中提问)
# 注意: 仅 -r /dev/tty 不够 — CI/沙箱里设备节点可能存在但无法 open
INTERACTIVE=1
if [[ ! -t 0 ]]; then
    if ! { exec 3<>/dev/tty; } 2>/dev/null; then
        INTERACTIVE=0
    else
        exec 3>&- 3<&- 2>/dev/null || true
    fi
fi

# read_tty <变量名> <提示语> <是否隐藏输入 0/1>
# stdin 是管道时先从 stdin 读 (适配自动化测试), 否则回退到 /dev/tty 提问
# 使用 printf -v 避免 eval 注入风险
read_tty() {
    local __var="$1" __prompt="$2" __secret="${3:-0}" __ans='' __got=1
    if [[ ! -t 0 ]]; then
        printf '%s' "${__prompt}"
        if IFS= read -r __ans; then __got=0; fi
    fi
    if [[ "${__got}" -ne 0 ]] && [[ -r /dev/tty ]]; then
        printf '%s' "${__prompt}" > /dev/tty
        if [[ "${__secret}" -eq 1 ]]; then
            IFS= read -r -s __ans < /dev/tty || true
            printf '\n' > /dev/tty
        else
            IFS= read -r __ans < /dev/tty || true
            printf '\n' > /dev/tty
        fi
    fi
    printf -v "${__var}" '%s' "${__ans}"
}

# ============== 平台检测 (尽早, 以便 usage 显示正确安装命令) ==============
detect_os() {
    case "$(uname -s)" in
        Darwin) OS="macos" ;;
        Linux)  OS="linux" ;;
        *)      die "不支持的系统: $(uname -s), 仅支持 Debian/Ubuntu/macOS" ;;
    esac
}
detect_os

if [[ "${OS}" == "macos" ]]; then
    INSTALL_CMD="curl -fsSL ${SCRIPT_URL} | bash"
else
    INSTALL_CMD="curl -fsSL ${SCRIPT_URL} | sudo bash"
fi

# ============== 帮助 / 版本 ==============
usage() {
    cat <<EOF
Codex CLI 一键部署脚本 v${SCRIPT_VERSION}

一行命令安装并配置 (终端内可交互提问):
  ${INSTALL_CMD}
  或加环境变量完全非交互 (适合 CI):
  curl -fsSL ${SCRIPT_URL} | $([ "${OS}" = "linux" ] && echo 'sudo ')CODEX_API_KEY="sk-xxxx" CODEX_BASE_URL="https://your.proxy" bash

选项:
  -h, --help       显示本帮助
  -V, --version    显示脚本版本
  -r, --restore    用最近一次的备份恢复配置
  -d, --dry-run    只生成/预览配置, 不安装 Node/npm/codex
  -u, --uninstall  卸载: 移除配置目录、备份, 并尝试 npm uninstall -g @openai/codex

参数通过环境变量传入(优先级: 环境变量 > 交互输入 > 默认值):
  CODEX_API_KEY / OPENAI_API_KEY  必填, API Key
  CODEX_BASE_URL                  必填, API 代理地址
  CODEX_MODEL                     模型名, 默认 ${DEFAULT_MODEL}
  CODEX_REVIEW_MODEL              审查模型, 默认 ${DEFAULT_REVIEW_MODEL}
  CODEX_REASONING_EFFORT          推理强度, 默认 ${DEFAULT_REASONING_EFFORT}
  CODEX_WIRE_API                  responses / chat, 默认 ${DEFAULT_WIRE_API}
  CODEX_PROVIDER                  model_provider 名称, 默认 ${DEFAULT_PROVIDER}
  CODEX_AUTH_STYLE                api_key | bearer | both, 默认 ${DEFAULT_AUTH_STYLE}
  CODEX_GOALS                     features.goals, 默认 ${DEFAULT_GOALS}
  CODEX_DISABLE_RESPONSE_STORAGE  默认 ${DEFAULT_DISABLE_RESPONSE_STORAGE}
  CODEX_NETWORK_ACCESS            默认 ${DEFAULT_NETWORK_ACCESS}
  CODEX_HOME                      Codex 配置目录, 默认 <家目录>/.codex
  CODEX_PRESERVE_EXTRA            保留已有 plugins/marketplaces (1/0), 默认 1
  NODE_MAJOR                      Node 主版本, 默认 ${NODE_MAJOR}
  NPM_REGISTRY                    npm 镜像源, 如 https://registry.npmmirror.com
  KEEP_BACKUPS                    配置备份保留份数, 默认 ${KEEP_BACKUPS}
EOF
}
MODE="deploy"   # deploy | restore | dry-run | uninstall
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)       usage; exit 0 ;;
        -V|--version)    printf 'deploy-codex %s\n' "${SCRIPT_VERSION}"; exit 0 ;;
        -r|--restore)    MODE="restore" ;;
        -d|--dry-run)    MODE="dry-run" ;;
        -u|--uninstall)  MODE="uninstall" ;;
        --)              shift; break ;;
        -*)              die "未知选项: $1 (用 --help 查看)" ;;
        *)               die "未知参数: $1 (用 --help 查看)" ;;
    esac
    shift
done

# ============== 前置检查 ==============
case "${OS}" in
    linux)
        [[ $EUID -eq 0 ]] || die "Linux 请使用 root 运行: ${INSTALL_CMD}"
        [[ -f /etc/os-release ]] || die "未找到 /etc/os-release, 该脚本仅支持 Debian/Ubuntu"
        grep -qEi 'debian|ubuntu' /etc/os-release \
          || die "仅支持 Debian/Ubuntu 系统, 当前系统无法识别"
        command -v apt-get >/dev/null 2>&1 \
          || die "未找到 apt-get, 仅支持 Debian/Ubuntu 系统"
        ;;
    macos)
        if [[ $EUID -eq 0 ]]; then
            die "macOS 请勿使用 sudo 运行本脚本 (Homebrew 禁止 root)。请用普通用户: ${INSTALL_CMD}"
        fi
        # brew 仅在完整部署时必需; dry-run / restore / uninstall 可无 brew
        if [[ "${MODE}" == "deploy" ]] && ! command -v brew >/dev/null 2>&1; then
            die "未找到 Homebrew, 请先安装: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        fi
        ;;
esac

# 实际使用 codex 的目标用户(配置写到该用户家目录)
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="${SUDO_USER}"
else
    TARGET_USER="$(id -un)"
fi
# 解析目标用户家目录: Linux 用 getent, macOS 用 id -P / dscl 回退
if command -v getent >/dev/null 2>&1; then
    TARGET_HOME=$(getent passwd "${TARGET_USER}" | cut -d: -f6) \
      || die "无法解析用户 ${TARGET_USER} 的家目录"
elif command -v id >/dev/null 2>&1 && id -P "${TARGET_USER}" >/dev/null 2>&1; then
    TARGET_HOME=$(id -P "${TARGET_USER}" 2>/dev/null | cut -d: -f6)
    [[ -n "${TARGET_HOME}" ]] || die "无法解析用户 ${TARGET_USER} 的家目录"
else
    TARGET_HOME="${HOME}"
    [[ -n "${TARGET_HOME}" ]] || die "无法解析用户 ${TARGET_USER} 的家目录"
fi
# 主组 (用于 chown, 避免假设组名==用户名)
if command -v id >/dev/null 2>&1; then
    TARGET_GROUP=$(id -gn "${TARGET_USER}" 2>/dev/null || echo "${TARGET_USER}")
else
    TARGET_GROUP="${TARGET_USER}"
fi
CODEX_DIR="${CODEX_HOME:-${TARGET_HOME}/.codex}"

# ============== 恢复最近一次备份 (--restore) ==============
if [[ "${MODE}" == "restore" ]]; then
    latest_backup=$(ls -dt "${CODEX_DIR}".bak.* 2>/dev/null | head -1 || true)
    [[ -n "${latest_backup}" ]] || die "未找到任何备份 (${CODEX_DIR}.bak.*), 无需恢复"
    echo
    info "将用以下备份恢复: ${latest_backup}"
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
        confirm=""
        read_tty confirm "确认恢复? [Y/n] "
        confirm="${confirm:-Y}"
        [[ "${confirm}" =~ ^[Yy]$ ]] || die "已取消恢复"
    fi
    install -d -m 700 "${CODEX_DIR}" 2>/dev/null || mkdir -p "${CODEX_DIR}"
    [[ -f "${latest_backup}/config.toml" ]] && cp -p "${latest_backup}/config.toml" "${CODEX_DIR}/config.toml"
    [[ -f "${latest_backup}/auth.json" ]] && cp -p "${latest_backup}/auth.json" "${CODEX_DIR}/auth.json"
    if [[ "${OS}" == "linux" ]]; then
        chown -R "${TARGET_USER}:${TARGET_GROUP}" "${CODEX_DIR}" 2>/dev/null || true
    fi
    chmod 700 "${CODEX_DIR}"
    chmod 600 "${CODEX_DIR}/auth.json" "${CODEX_DIR}/config.toml" 2>/dev/null || true
    ok "已从 ${latest_backup} 恢复配置"
    exit 0
fi

# ============== 卸载 / 清理 (--uninstall) ==============
if [[ "${MODE}" == "uninstall" ]]; then
    echo
    info "=========== 卸载 Codex 部署 ==========="
    printf "  配置目录 : %s\n" "${CODEX_DIR}"
    # 列举备份 (portable, 不依赖 bash 4 mapfile)
    _bak_count=0
    while IFS= read -r _b; do
        [[ -n "${_b}" ]] || continue
        _bak_count=$((_bak_count + 1))
    done < <(ls -dt "${CODEX_DIR}".bak.* 2>/dev/null || true)
    printf "  备份份数 : %s\n" "${_bak_count}"
    if command -v codex >/dev/null 2>&1; then
        printf "  codex    : %s\n" "$(command -v codex)"
    else
        printf "  codex    : (未在 PATH 中找到)\n"
    fi
    echo
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
        confirm=""
        read_tty confirm "确认卸载? 将删除配置目录与备份, 并尝试 npm uninstall -g @openai/codex [y/N] "
        [[ "${confirm}" =~ ^[Yy]$ ]] || die "已取消卸载"
    else
        # 非交互卸载需显式确认, 防止 CI/脚本误删
        if [[ "${CODEX_UNINSTALL_CONFIRM:-}" != "1" && "${CODEX_UNINSTALL_CONFIRM:-}" != "yes" ]]; then
            die "非交互卸载请设置 CODEX_UNINSTALL_CONFIRM=1"
        fi
    fi

    # 1) 移除配置与备份
    if [[ -d "${CODEX_DIR}" ]]; then
        rm -rf "${CODEX_DIR}"
        ok "已删除 ${CODEX_DIR}"
    else
        warn "配置目录不存在: ${CODEX_DIR}"
    fi
    while IFS= read -r old; do
        [[ -n "${old}" ]] || continue
        rm -rf "${old}"
        ok "已删除备份 ${old}"
    done < <(ls -dt "${CODEX_DIR}".bak.* 2>/dev/null || true)

    # 2) npm 全局卸载 (尽力而为, 失败不致命)
    if command -v npm >/dev/null 2>&1; then
        info "尝试 npm uninstall -g @openai/codex ..."
        if npm uninstall -g @openai/codex >/dev/null 2>&1; then
            ok "已卸载 npm 全局包 @openai/codex"
        else
            warn "npm uninstall 失败或包未安装, 可手动执行: npm uninstall -g @openai/codex"
        fi
    else
        warn "未找到 npm, 跳过全局包卸载"
    fi

    # 3) 提示残留
    if command -v codex >/dev/null 2>&1; then
        warn "PATH 中仍能找到 codex: $(command -v codex) (可能是其他安装方式, 请手动删除)"
    fi
    echo
    ok "============ 卸载完成 ============"
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
        if [[ "${secret}" -eq 1 ]]; then
            read_tty val "${msg}${hint} (输入不回显): " 1
        else
            read_tty val "${msg}${hint}: " 0
        fi
        val="${val:-${def}}"
        [[ -z "${val}" && -z "${def}" ]] && die "必填项为空, 已取消部署"
        printf -v "${var}" '%s' "${val}"
    else
        # 3) 非交互模式 -> 必须有默认值, 否则报错
        [[ -z "${def}" ]] && die "非交互模式且未设置环境变量 ${var}, 请用 ${var}=... bash \$0"
        printf -v "${var}" '%s' "${def}"
    fi
}

mask_key() {
    local k="${1:-}"
    if [[ ${#k} -le 8 ]]; then
        printf '********\n'
    else
        printf '%s********\n' "${k:0:8}"
    fi
}

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
# 以下可用环境变量覆盖, 交互时也提供
CODEX_PROVIDER="${CODEX_PROVIDER:-${DEFAULT_PROVIDER}}"
CODEX_AUTH_STYLE="${CODEX_AUTH_STYLE:-${DEFAULT_AUTH_STYLE}}"
CODEX_GOALS="${CODEX_GOALS:-${DEFAULT_GOALS}}"
CODEX_DISABLE_RESPONSE_STORAGE="${CODEX_DISABLE_RESPONSE_STORAGE:-${DEFAULT_DISABLE_RESPONSE_STORAGE}}"
CODEX_NETWORK_ACCESS="${CODEX_NETWORK_ACCESS:-${DEFAULT_NETWORK_ACCESS}}"

if [[ "${INTERACTIVE}" -eq 1 ]]; then
    ask CODEX_PROVIDER     "  provider 名称"              "${CODEX_PROVIDER}"   0
    ask CODEX_AUTH_STYLE   "  auth 写入方式 (api_key/bearer/both)" "${CODEX_AUTH_STYLE}" 0
fi

# ============== 参数校验 ==============
[[ "${CODEX_WIRE_API}" =~ ^(responses|chat)$ ]] \
  || die "wire_api 仅支持 responses 或 chat, 当前值: ${CODEX_WIRE_API}"
[[ "${CODEX_BASE_URL}" =~ ^https?:// ]] \
  || die "base_url 必须是 http(s):// 开头的地址, 当前值: $(mask_url "${CODEX_BASE_URL}")"
[[ "${CODEX_AUTH_STYLE}" =~ ^(api_key|bearer|both)$ ]] \
  || die "CODEX_AUTH_STYLE 仅支持 api_key / bearer / both, 当前值: ${CODEX_AUTH_STYLE}"
[[ "${CODEX_PROVIDER}" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] \
  || die "CODEX_PROVIDER 仅允许字母开头的 [A-Za-z0-9_-], 当前值: ${CODEX_PROVIDER}"
[[ "${CODEX_GOALS}" =~ ^(true|false)$ ]] \
  || die "CODEX_GOALS 仅支持 true/false, 当前值: ${CODEX_GOALS}"
[[ "${CODEX_DISABLE_RESPONSE_STORAGE}" =~ ^(true|false)$ ]] \
  || die "CODEX_DISABLE_RESPONSE_STORAGE 仅支持 true/false"
case "${CODEX_API_KEY}" in
    *'"'*) die "API Key 不能包含双引号" ;;
    *'$'*) die "API Key 不能包含 \$ 字符" ;;
    *'`'*) die "API Key 不能包含反引号" ;;
esac
if [[ "${CODEX_API_KEY}" != sk-* ]]; then
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
        warn "API Key 未以 sk- 开头 (部分代理密钥格式不同)"
        key_confirm=""
        read_tty key_confirm "  仍要继续? [y/N] "
        [[ "${key_confirm}" =~ ^[Yy]$ ]] || die "已取消部署 (未修改任何文件)"
    else
        # 非交互: 允许非 sk- 前缀, 仅警告 (兼容自建代理)
        warn "API Key 未以 sk- 开头, 将继续 (CODEX_API_KEY=$(mask_key "${CODEX_API_KEY}"))"
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
printf "  provider    : %s\n" "${CODEX_PROVIDER}"
printf "  auth_style  : %s\n" "${CODEX_AUTH_STYLE}"
printf "  goals       : %s\n" "${CODEX_GOALS}"
printf "  no_storage  : %s\n" "${CODEX_DISABLE_RESPONSE_STORAGE}"
printf "  network     : %s\n" "${CODEX_NETWORK_ACCESS}"
[[ -n "${NPM_REGISTRY}" ]] && printf "  npm 镜像    : %s\n" "${NPM_REGISTRY}"
echo

if [[ "${INTERACTIVE}" -eq 1 ]]; then
    confirm=""
    if [[ "${MODE}" == "dry-run" ]]; then
        read_tty confirm "确认以上配置并仅写入配置文件 (dry-run)? [Y/n] "
    else
        read_tty confirm "确认以上配置并开始部署? [Y/n] "
    fi
    confirm="${confirm:-Y}"
    [[ "${confirm}" =~ ^[Yy]$ ]] || die "用户取消部署"
fi

# ============== 1. 安装基础依赖 (dry-run 跳过) ==============
if [[ "${MODE}" == "dry-run" ]]; then
    info "dry-run: 跳过依赖 / Node / npm 安装, 仅生成配置"
else
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
                brew link --overwrite --force "node@${NODE_MAJOR}" >/dev/null 2>&1 || true
                # Apple Silicon / Intel Homebrew 前缀
                for prefix in /opt/homebrew /usr/local; do
                    if [[ -x "${prefix}/opt/node@${NODE_MAJOR}/bin/node" ]]; then
                        export PATH="${prefix}/opt/node@${NODE_MAJOR}/bin:${PATH}"
                        break
                    fi
                done
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
TMP_FILES+=("${npm_install_log}")
npm_args=(install -g --no-audit --no-fund @openai/codex)
[[ -n "${NPM_REGISTRY}" ]] && npm_args+=(--registry="${NPM_REGISTRY}")
if ! npm "${npm_args[@]}" >"${npm_install_log}" 2>&1; then
    cat "${npm_install_log}" >&2 || true
    die "npm 安装 codex 失败, 请检查网络/镜像源 (国内网络可设置 NPM_REGISTRY=https://registry.npmmirror.com)"
fi
# 刷新 PATH 常见全局 bin
if [[ "${OS}" == "macos" ]]; then
    NPM_BIN=$(npm bin -g 2>/dev/null || npm prefix -g 2>/dev/null | sed 's|$|/bin|' || true)
    [[ -n "${NPM_BIN}" ]] && export PATH="${NPM_BIN}:${PATH}"
fi
command -v codex >/dev/null 2>&1 || die "codex 未在 PATH 中, 请检查 npm 全局 bin 目录 (npm bin -g)"
ok "Codex 安装完成: $(codex --version 2>/dev/null || echo 'installed')"
fi  # end non-dry-run install block

# ============== 4. 写入配置文件 (先备份旧配置) ==============
info "写入配置到 ${CODEX_DIR} ..."
[[ -d "${CODEX_DIR}" ]] || install -d -m 700 "${CODEX_DIR}" 2>/dev/null || mkdir -p "${CODEX_DIR}" && chmod 700 "${CODEX_DIR}"

# 提取已有 plugins / marketplaces 段以便保留
PRESERVED_EXTRA=""
if [[ "${PRESERVE_EXTRA}" == "1" && -f "${CODEX_DIR}/config.toml" ]]; then
    PRESERVED_EXTRA=$(awk '
        /^\[(plugins|marketplaces)/ { keep=1 }
        keep { print }
    ' "${CODEX_DIR}/config.toml" 2>/dev/null || true)
    if [[ -n "${PRESERVED_EXTRA}" ]]; then
        info "将保留已有 plugins/marketplaces 配置段"
    fi
fi

# 备份已有配置 (保留最近 ${KEEP_BACKUPS} 份)
if [[ -f "${CODEX_DIR}/config.toml" || -f "${CODEX_DIR}/auth.json" ]]; then
    backup_dir="${CODEX_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    mkdir -p "${backup_dir}"
    cp -p "${CODEX_DIR}/config.toml" "${backup_dir}/" 2>/dev/null || true
    cp -p "${CODEX_DIR}/auth.json"   "${backup_dir}/" 2>/dev/null || true
    ok "已备份旧配置到 ${backup_dir}"
    # 删除超出保留份数的旧备份 (portable, 不依赖 GNU xargs -r)
    while IFS= read -r old; do
        [[ -n "${old}" ]] && rm -rf "${old}"
    done < <(ls -dt "${CODEX_DIR}".bak.* 2>/dev/null | tail -n "+$((KEEP_BACKUPS+1))" || true)
fi

# 生成配置到临时文件 (600 权限), 校验通过后再原子替换, 失败不影响原文件
TMP_CONFIG="${CODEX_DIR}/config.toml.tmp.$$"
TMP_AUTH="${CODEX_DIR}/auth.json.tmp.$$"
TMP_FILES+=("${TMP_CONFIG}" "${TMP_AUTH}")

ESC_MODEL=$(escape_string "${CODEX_MODEL}")
ESC_REVIEW=$(escape_string "${CODEX_REVIEW_MODEL}")
ESC_EFFORT=$(escape_string "${CODEX_REASONING_EFFORT}")
ESC_BASE=$(escape_string "${CODEX_BASE_URL}")
ESC_WIRE=$(escape_string "${CODEX_WIRE_API}")
ESC_PROVIDER=$(escape_string "${CODEX_PROVIDER}")
ESC_KEY=$(escape_string "${CODEX_API_KEY}")
ESC_NET=$(escape_string "${CODEX_NETWORK_ACCESS}")

( umask 077
# --- config.toml ---
{
    cat <<EOF
model_provider = "${ESC_PROVIDER}"
model = "${ESC_MODEL}"
review_model = "${ESC_REVIEW}"
model_reasoning_effort = "${ESC_EFFORT}"
disable_response_storage = ${CODEX_DISABLE_RESPONSE_STORAGE}
network_access = "${ESC_NET}"

[model_providers.${ESC_PROVIDER}]
name = "${ESC_PROVIDER}"
base_url = "${ESC_BASE}"
wire_api = "${ESC_WIRE}"
requires_openai_auth = true
EOF
    # bearer 模式把 token 写进 provider (常见于自定义代理)
    if [[ "${CODEX_AUTH_STYLE}" == "bearer" || "${CODEX_AUTH_STYLE}" == "both" ]]; then
        printf 'experimental_bearer_token = "%s"\n' "${ESC_KEY}"
    fi
    cat <<EOF

[features]
goals = ${CODEX_GOALS}
EOF
    if [[ -n "${PRESERVED_EXTRA}" ]]; then
        printf '\n# --- preserved from previous config ---\n'
        printf '%s\n' "${PRESERVED_EXTRA}"
    fi
} > "${TMP_CONFIG}"

# --- auth.json ---
case "${CODEX_AUTH_STYLE}" in
    api_key|both)
        cat > "${TMP_AUTH}" <<EOF
{
  "OPENAI_API_KEY": "${ESC_KEY}"
}
EOF
        ;;
    bearer)
        # bearer 只写 provider token 时, auth.json 仍放一份 key 作为兜底
        cat > "${TMP_AUTH}" <<EOF
{
  "OPENAI_API_KEY": "${ESC_KEY}"
}
EOF
        ;;
esac
)

# 严格校验 (python3): TOML 用 tomllib (3.11+), JSON 用 json
if command -v python3 >/dev/null 2>&1; then
    if python3 - "${TMP_CONFIG}" "${TMP_AUTH}" <<'PYVAL'
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
        providers = c.get('model_providers') or {}
        assert providers, 'model_providers missing'
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
        die "生成的配置未通过校验, 已中止 (原文件未被修改)"
    fi
else
    warn "未找到 python3, 跳过配置严格校验"
fi

mv "${TMP_CONFIG}" "${CODEX_DIR}/config.toml" || die "写入 config.toml 失败"
mv "${TMP_AUTH}" "${CODEX_DIR}/auth.json"     || die "写入 auth.json 失败"
# 已成功提交, 从清理列表移除
TMP_FILES=("${npm_install_log:-}")

# ============== 5. 修正属主与权限 ==============
if [[ "${OS}" == "linux" ]]; then
    chown -R "${TARGET_USER}:${TARGET_GROUP}" "${CODEX_DIR}"
fi
chmod 700 "${CODEX_DIR}"
chmod 600 "${CODEX_DIR}/auth.json" "${CODEX_DIR}/config.toml"
ok "权限设置完成"

# ============== 6. 验证 ==============
info "配置预览(auth.json, 密钥已打码):"
if command -v sed >/dev/null 2>&1; then
    sed -E 's/("OPENAI_API_KEY": ")([^"]{0,8})[^"]*"/\1\2********"/' "${CODEX_DIR}/auth.json" 2>/dev/null \
      || printf '{ "OPENAI_API_KEY": "%s" }\n' "$(mask_key "${CODEX_API_KEY}")"
else
    printf '{ "OPENAI_API_KEY": "%s" }\n' "$(mask_key "${CODEX_API_KEY}")"
fi

if curl -fsSL --connect-timeout 8 -o /dev/null "${CODEX_BASE_URL}" 2>/dev/null; then
    ok "代理地址可达: $(mask_url "${CODEX_BASE_URL}")"
else
    warn "代理地址探测无响应(可能是正常的): $(mask_url "${CODEX_BASE_URL}")"
fi

# 检查目标用户的 PATH 中是否能看到 codex (仅 Linux; dry-run 跳过)
if [[ "${MODE}" != "dry-run" && "${OS}" == "linux" && "${TARGET_USER}" != "root" ]]; then
    if ! su -s /bin/bash "${TARGET_USER}" -c 'command -v codex >/dev/null 2>&1'; then
        warn "codex 命令可能不在 ${TARGET_USER} 的 PATH 中, 请确认 npm 全局 bin 目录已加入该用户 PATH"
        warn "可尝试: npm bin -g  并将输出目录写入 ~/.bashrc / ~/.profile"
    fi
fi

echo
if [[ "${MODE}" == "dry-run" ]]; then
    ok "============ dry-run 完成 (未安装软件包) ============"
    echo "  版本 : deploy-codex v${SCRIPT_VERSION}"
    echo "  用户 : ${TARGET_USER}"
    echo "  配置 : ${CODEX_DIR}/config.toml"
    echo "  密钥 : ${CODEX_DIR}/auth.json"
    echo
    echo "  正式部署请去掉 --dry-run 重新运行"
    echo "  恢复备份 : bash deploy-codex.sh --restore"
    echo "  卸载清理 : bash deploy-codex.sh --uninstall"
    echo "===================================================="
else
    ok "============ 部署完成 ============"
    echo "  版本 : deploy-codex v${SCRIPT_VERSION}"
    echo "  用户 : ${TARGET_USER}"
    if command -v codex >/dev/null 2>&1; then
        echo "  命令 : $(command -v codex)"
    else
        echo "  命令 : (codex 未在 PATH)"
    fi
    echo "  配置 : ${CODEX_DIR}/config.toml"
    echo "  密钥 : ${CODEX_DIR}/auth.json"
    echo
    echo "  切换到该用户后直接运行:  codex"
    if [[ "${TARGET_USER}" != "$(id -un)" ]]; then
        echo "  例如: sudo -iu ${TARGET_USER} codex"
    fi
    echo "  恢复备份 : bash deploy-codex.sh --restore"
    echo "  卸载清理 : bash deploy-codex.sh --uninstall"
    echo "  或远程   : ${INSTALL_CMD%bash*}bash -s -- --restore"
    echo "=================================="
fi

}
