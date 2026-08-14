#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${CODEX_TARGET_USER:-${SUDO_USER:-$(id -un)}}"
TARGET_HOME="${CODEX_TARGET_HOME:-}"
EXPECTED_VERSION="${CODEX_VERSION:-0.147.0}"

pass() { printf '✅ %s\n' "$*"; }
fail() { printf '❌ %s\n' "$*" >&2; exit 1; }

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
    [[ -n "${TARGET_HOME}" ]] || fail "无法解析用户 ${TARGET_USER} 的家目录"
}

file_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

resolve_executable() {
    local path="$1"
    local link_dir=""
    local link_target=""

    while [[ -L "${path}" ]]; do
        link_dir="$(cd -P -- "$(dirname -- "${path}")" && pwd)"
        link_target="$(readlink "${path}")"
        if [[ "${link_target}" == /* ]]; then
            path="${link_target}"
        else
            path="${link_dir}/${link_target}"
        fi
    done

    printf '%s\n' "${path}"
}

find_code_mode_host() {
    local codex_path=""
    local resolved_codex=""
    local package_root=""
    local search_root=""
    local candidate=""

    CODE_MODE_HOST=""
    codex_path="$(command -v codex 2>/dev/null || true)"
    [[ -n "${codex_path}" ]] || return 1

    candidate="$(dirname -- "${codex_path}")/codex-code-mode-host"
    if [[ -x "${candidate}" ]]; then
        CODE_MODE_HOST="${candidate}"
        return 0
    fi

    resolved_codex="$(resolve_executable "${codex_path}")"
    candidate="$(dirname -- "${resolved_codex}")/codex-code-mode-host"
    if [[ -x "${candidate}" ]]; then
        CODE_MODE_HOST="${candidate}"
        return 0
    fi

    if [[ "${resolved_codex}" == */bin/codex.js ]]; then
        package_root="$(cd -- "$(dirname -- "${resolved_codex}")/.." && pwd)"
        for search_root in \
            "${package_root}/node_modules/@openai" \
            "$(dirname -- "${package_root}")"; do
            [[ -d "${search_root}" ]] || continue
            while IFS= read -r candidate; do
                if [[ -x "${candidate}" ]]; then
                    CODE_MODE_HOST="${candidate}"
                    return 0
                fi
            done < <(find "${search_root}" -type f -name codex-code-mode-host -print 2>/dev/null)
        done
    fi

    return 1
}

id "${TARGET_USER}" >/dev/null 2>&1 || fail "目标用户不存在: ${TARGET_USER}"
resolve_home
CODEX_DIR="${TARGET_HOME}/.codex"
CONFIG_FILE="${CODEX_DIR}/config.toml"
MODEL_FILE="${CODEX_DIR}/models-gpt56-non-lite.json"

[[ -f "${CONFIG_FILE}" ]] || fail "缺少 ${CONFIG_FILE}"
[[ -f "${MODEL_FILE}" ]] || fail "缺少 ${MODEL_FILE}"
pass "部署文件存在"

config_catalog="$(awk -F'"' '/^[[:space:]]*model_catalog_json[[:space:]]*=/ { print $2; exit }' "${CONFIG_FILE}")"
[[ "${config_catalog}" == /* ]] || fail "model_catalog_json 不是绝对路径: ${config_catalog:-<空>}"
[[ "${config_catalog}" == "${MODEL_FILE}" ]] || fail "model_catalog_json 未指向 ${MODEL_FILE}"
pass "model_catalog_json 使用正确的绝对路径"

grep -Fq 'model = "gpt-5.6-sol"' "${CONFIG_FILE}" || fail "主模型不是 gpt-5.6-sol"
grep -Fq 'review_model = "gpt-5.5"' "${CONFIG_FILE}" || fail "review_model 不是 gpt-5.5"
grep -Fq 'base_url = "https://opencode.2020713.xyz"' "${CONFIG_FILE}" || fail "base_url 不正确"
grep -Fq 'wire_api = "responses"' "${CONFIG_FILE}" || fail "wire_api 不是 responses"
pass "Codex 配置项正确"

if command -v python3 >/dev/null 2>&1; then
    python3 - "${MODEL_FILE}" <<'PY'
import json
import sys
from pathlib import Path
models = {m["slug"]: m for m in json.loads(Path(sys.argv[1]).read_text()).get("models", [])}
for slug in ("gpt-5.6-sol", "gpt-5.5"):
    assert slug in models, f"missing {slug}"
for slug in ("gpt-5.6-sol",):
    assert models[slug].get("use_responses_lite") is False, f"{slug}: use_responses_lite != false"
    assert models[slug].get("tool_mode") == "code_mode_only", f"{slug}: tool_mode"
    assert models[slug].get("apply_patch_tool_type") == "freeform", f"{slug}: apply_patch_tool_type"
PY
elif command -v node >/dev/null 2>&1; then
    node - "${MODEL_FILE}" <<'JS'
const fs = require("fs");
const models = Object.fromEntries(JSON.parse(fs.readFileSync(process.argv[2], "utf8")).models.map((m) => [m.slug, m]));
for (const slug of ["gpt-5.6-sol", "gpt-5.5"]) if (!models[slug]) throw new Error(`missing ${slug}`);
for (const slug of ["gpt-5.6-sol"]) {
  if (models[slug].use_responses_lite !== false) throw new Error(`${slug}: use_responses_lite != false`);
  if (models[slug].tool_mode !== "code_mode_only") throw new Error(`${slug}: tool_mode`);
  if (models[slug].apply_patch_tool_type !== "freeform") throw new Error(`${slug}: apply_patch_tool_type`);
}
JS
else
    fail "需要 python3 或 node 来校验模型目录"
fi
pass "模型目录包含 GPT-5.6 non-lite 与 freeform apply_patch 配置"

config_mode="$(file_mode "${CONFIG_FILE}")"
model_mode="$(file_mode "${MODEL_FILE}")"
[[ "${config_mode}" == "600" ]] || fail "config.toml 权限应为 600，当前为 ${config_mode}"
[[ "${model_mode}" == "644" ]] || fail "模型目录权限应为 644，当前为 ${model_mode}"
pass "文件权限正确"

if [[ "${CODEX_SKIP_VERSION_CHECK:-0}" != "1" ]]; then
    command -v codex >/dev/null 2>&1 || fail "未找到 codex 命令"
    version_output="$(codex --version)"
    [[ "${version_output##* }" == "${EXPECTED_VERSION}" ]] \
        || fail "Codex 版本应为 ${EXPECTED_VERSION}，当前为 ${version_output}"
    pass "${version_output}"

    if ! find_code_mode_host; then
        if [[ "$(uname -s)" == "Darwin" ]] \
            && command -v brew >/dev/null 2>&1 \
            && brew list --cask codex >/dev/null 2>&1; then
            fail "Homebrew Cask Codex 缺少 codex-code-mode-host；请运行 brew uninstall --cask codex 后改用 npm 安装"
        fi
        fail "未找到 codex-code-mode-host（PATH、Codex 同目录和 npm 平台包均已检查）"
    fi
    pass "code-mode host: ${CODE_MODE_HOST}"
fi

if [[ "${CODEX_LIVE_VERIFY:-0}" == "1" ]]; then
    command -v codex >/dev/null 2>&1 || fail "未找到 codex 命令"
    output_file="$(mktemp)"
    trap 'rm -f "${output_file:-}"' EXIT
    CODEX_HOME="${CODEX_DIR}" codex --ask-for-approval never exec \
        --ephemeral --skip-git-repo-check --sandbox read-only \
        --output-last-message "${output_file}" \
        '先调用 exec 工具运行 printf CODEX_EXEC_OK，然后只回复该命令的输出。'
    grep -Fq 'CODEX_EXEC_OK' "${output_file}" || fail "Codex exec 实际调用验证失败"
    pass "Codex exec 工具实际调用成功"
    rm -f "${output_file}"
    trap - EXIT
else
    printf '\n提示: 设置 CODEX_LIVE_VERIFY=1 可执行一次真实 API 工具调用验证。\n'
fi

printf '\n🎉 验证通过。模型目录声明 exec/code mode，并将 apply_patch 配置为 freeform。\n'
