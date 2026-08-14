#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${CODEX_TARGET_USER:-${SUDO_USER:-$(id -un)}}"
TARGET_HOME="${CODEX_TARGET_HOME:-}"
CODEX_VERSION="${CODEX_VERSION:-0.147.0}"
SKIP_INSTALL="${CODEX_SKIP_INSTALL:-0}"
MODEL_SOURCE="${SCRIPT_DIR}/assets/models-gpt56-non-lite.json"
CONFIG_TEMPLATE="${SCRIPT_DIR}/templates/config.toml"

log() {
    printf '%s\n' "$*"
}

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

resolve_home() {
    if [[ -n "${TARGET_HOME}" ]]; then
        return
    fi

    if command -v getent >/dev/null 2>&1; then
        TARGET_HOME="$(getent passwd "${TARGET_USER}" | awk -F: 'NR == 1 { print $6 }')"
    elif [[ "$(uname -s)" == "Darwin" ]] && command -v dscl >/dev/null 2>&1; then
        TARGET_HOME="$(dscl . -read "/Users/${TARGET_USER}" NFSHomeDirectory 2>/dev/null | awk '{ print $2 }')"
    elif [[ "${TARGET_USER}" == "$(id -un)" ]]; then
        TARGET_HOME="${HOME:-}"
    elif command -v python3 >/dev/null 2>&1; then
        TARGET_HOME="$(python3 - "${TARGET_USER}" <<'PY'
import pwd
import sys
print(pwd.getpwnam(sys.argv[1]).pw_dir)
PY
)"
    fi

    [[ -n "${TARGET_HOME}" ]] || die "无法解析用户 ${TARGET_USER} 的家目录；请设置 CODEX_TARGET_HOME"
}

validate_catalog() {
    if command -v python3 >/dev/null 2>&1; then
        python3 - "${MODEL_SOURCE}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
models = {item.get("slug"): item for item in data.get("models", [])}
for slug in ("gpt-5.6-sol", "gpt-5.5"):
    if slug not in models:
        raise SystemExit(f"模型目录缺少 {slug}")
for slug in ("gpt-5.6-sol",):
    if models[slug].get("use_responses_lite") is not False:
        raise SystemExit(f"{slug} 的 use_responses_lite 必须为 false")
    if models[slug].get("tool_mode") != "code_mode_only":
        raise SystemExit(f"{slug} 的 tool_mode 必须为 code_mode_only")
    if models[slug].get("apply_patch_tool_type") != "freeform":
        raise SystemExit(f"{slug} 的 apply_patch_tool_type 必须为 freeform")
PY
        return
    fi

    if command -v node >/dev/null 2>&1; then
        node - "${MODEL_SOURCE}" <<'JS'
const fs = require("fs");
const path = process.argv[2];
const data = JSON.parse(fs.readFileSync(path, "utf8"));
const models = Object.fromEntries((data.models || []).map((item) => [item.slug, item]));
for (const slug of ["gpt-5.6-sol", "gpt-5.5"]) {
  if (!models[slug]) throw new Error(`模型目录缺少 ${slug}`);
}
for (const slug of ["gpt-5.6-sol"]) {
  if (models[slug].use_responses_lite !== false) throw new Error(`${slug} 的 use_responses_lite 必须为 false`);
  if (models[slug].tool_mode !== "code_mode_only") throw new Error(`${slug} 的 tool_mode 必须为 code_mode_only`);
  if (models[slug].apply_patch_tool_type !== "freeform") throw new Error(`${slug} 的 apply_patch_tool_type 必须为 freeform`);
}
JS
        return
    fi

    die "需要 python3 或 node 来校验模型目录"
}

install_codex() {
    local installed_version=""

    if [[ "${SKIP_INSTALL}" == "1" ]]; then
        log "⏭️  已设置 CODEX_SKIP_INSTALL=1，跳过 Codex CLI 安装"
        return
    fi

    if command -v codex >/dev/null 2>&1; then
        installed_version="$(codex --version 2>/dev/null || true)"
    fi
    if [[ "${installed_version##* }" == "${CODEX_VERSION}" ]]; then
        log "✅ Codex CLI ${CODEX_VERSION} 已安装"
        return
    fi

    command -v npm >/dev/null 2>&1 || die "未找到 npm；请先安装 Node.js/npm，或设置 CODEX_SKIP_INSTALL=1"
    log "📦 安装 @openai/codex@${CODEX_VERSION} ..."
    npm install -g "@openai/codex@${CODEX_VERSION}"
}

[[ -f "${MODEL_SOURCE}" ]] || die "缺少模型目录: ${MODEL_SOURCE}"
[[ -f "${CONFIG_TEMPLATE}" ]] || die "缺少配置模板: ${CONFIG_TEMPLATE}"
id "${TARGET_USER}" >/dev/null 2>&1 || die "目标用户不存在: ${TARGET_USER}"
resolve_home
validate_catalog
install_codex

TARGET_GROUP="$(id -gn "${TARGET_USER}")"
TARGET_CODEX_DIR="${TARGET_HOME}/.codex"
MODEL_TARGET="${TARGET_CODEX_DIR}/models-gpt56-non-lite.json"
CONFIG_TARGET="${TARGET_CODEX_DIR}/config.toml"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

install -d -m 700 "${TARGET_CODEX_DIR}"
if [[ -f "${CONFIG_TARGET}" ]]; then
    cp -p "${CONFIG_TARGET}" "${CONFIG_TARGET}.bak.${TIMESTAMP}"
    log "🗄️  已备份原配置: ${CONFIG_TARGET}.bak.${TIMESTAMP}"
fi

install -m 644 "${MODEL_SOURCE}" "${MODEL_TARGET}"
TMP_CONFIG="${CONFIG_TARGET}.tmp.$$"
trap 'rm -f "${TMP_CONFIG:-}"' EXIT

escaped_model_target="${MODEL_TARGET//\\/\\\\}"
escaped_model_target="${escaped_model_target//&/\\&}"
escaped_model_target="${escaped_model_target//|/\\|}"
sed "s|__MODEL_CATALOG_JSON__|${escaped_model_target}|g" "${CONFIG_TEMPLATE}" > "${TMP_CONFIG}"

grep -Fq "model_catalog_json = \"${MODEL_TARGET}\"" "${TMP_CONFIG}" \
    || die "配置模板中的模型目录占位符替换失败"
chmod 600 "${TMP_CONFIG}"
mv -f "${TMP_CONFIG}" "${CONFIG_TARGET}"
trap - EXIT

if [[ "$(id -u)" == "0" ]]; then
    chown "${TARGET_USER}:${TARGET_GROUP}" "${TARGET_CODEX_DIR}" "${MODEL_TARGET}" "${CONFIG_TARGET}"
    [[ -f "${CONFIG_TARGET}.bak.${TIMESTAMP}" ]] \
        && chown "${TARGET_USER}:${TARGET_GROUP}" "${CONFIG_TARGET}.bak.${TIMESTAMP}"
fi

log ""
log "✅ 部署完成"
log "   目标用户: ${TARGET_USER}"
log "   Codex 目录: ${TARGET_CODEX_DIR}"
log "   模型目录: ${MODEL_TARGET}"
log "   配置文件: ${CONFIG_TARGET}"
log ""
log "本脚本不会复制或生成 API Key。请保留已有 auth.json，或另行执行 codex login。"
log "验证命令: CODEX_TARGET_USER=${TARGET_USER} bash \"${SCRIPT_DIR}/verify.sh\""
