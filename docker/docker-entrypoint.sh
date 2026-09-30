#!/usr/bin/env bash
# =============================================================================
# Octop 容器入口脚本
#
# 环境变量:
#   HOME                      — 必须为 /data，使 ~/.octop 映射到数据卷
#   OCTOP_DEFAULT_PASSWORD    — 首次管理员密码（须 ≥8 位且含字母和数字；
#                               不设置则自动生成随机密码，凭据写入
#                               /data/.octop/credential.txt）
#   OCTOP_ADMIN_USERNAME      — 首次管理员用户名（默认: admin）
#   OCTOP_ADMIN_DISPLAY_NAME  — 可选显示名
#   OCTOP_PORT                — 服务端口（默认: 8088）
#
# 密码兜底（修复 issue #502）：应用侧密码策略带常见弱密码黑名单（含
# Octop123），旧版默认密码会让 octop init 报 "password is too common"
# 退出、容器反复重启。现在：未设置密码时自动生成随机强密码；只有错误
# 信息确认为密码策略拒绝时，才用随机密码加 --force 重试（失败的 init
# 可能已经写入了半成品目录）。
#
# 是否首次启动看数据目录是否为空，而不是看 octop.db 在不在。PostgreSQL
# 以及已有 config/日志的目录都没有这个文件；重启时再跑 octop init 会被
# 「目录非空」拒绝，容器直接退出。
# =============================================================================
set -euo pipefail

export HOME="${HOME:-/data}"
OCTOP_HOME="${HOME}/.octop"
CREDENTIAL_FILE="${OCTOP_HOME}/credential.txt"
ADMIN_USERNAME="${OCTOP_ADMIN_USERNAME:-admin}"
ADMIN_DISPLAY_NAME="${OCTOP_ADMIN_DISPLAY_NAME:-Admin}"
PORT="${OCTOP_PORT:-8088}"

# 生成随机密码（首字符字母、末字符数字，避开易混淆字符）。
octop_random_password() {
    local letters='abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ'
    local digits='23456789'
    local all="${letters}${digits}" n=16 out="" i b
    b="$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
    out="${letters:$((b % ${#letters})):1}"
    for ((i = 1; i < n - 1; i++)); do
        b="$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
        out+="${all:$((b % ${#all})):1}"
    done
    b="$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
    out+="${digits:$((b % ${#digits})):1}"
    printf '%s' "$out"
}

DEFAULT_PASSWORD="${OCTOP_DEFAULT_PASSWORD:-}"

octop_home_nonempty() {
    [ -d "$OCTOP_HOME" ] && [ -n "$(ls -A "$OCTOP_HOME" 2>/dev/null || true)" ]
}

run_octop_init() {
    local password="$1"
    local force="${2:-}"
    local -a args=(
        init
        --yes
        --admin-username "$ADMIN_USERNAME"
        --admin-password "$password"
    )
    if [ -n "$force" ]; then
        args+=(--force)
    fi
    if [ -n "$ADMIN_DISPLAY_NAME" ]; then
        args+=(--admin-display-name "$ADMIN_DISPLAY_NAME")
    fi
    octop "${args[@]}"
}

if octop_home_nonempty; then
    echo "[entrypoint] 数据目录已存在（${OCTOP_HOME}），跳过初始化。"
else
    echo "[entrypoint] 首次启动，正在初始化 Octop..."

    if [ -z "$DEFAULT_PASSWORD" ]; then
        DEFAULT_PASSWORD="$(octop_random_password)"
        echo "[entrypoint] 未设置 OCTOP_DEFAULT_PASSWORD，已自动生成随机密码。"
    fi

    init_log="$(mktemp)"
    set +e
    run_octop_init "$DEFAULT_PASSWORD" >"$init_log" 2>&1
    init_status=$?
    set -e
    cat "$init_log" >&2
    if [ "$init_status" -ne 0 ]; then
        if grep -Eq 'password (is too common|too short|must include letters and digits)' "$init_log"; then
            echo "[entrypoint] 指定的初始密码未通过应用密码策略（过弱或过于常见），改用随机密码重试 ..."
            DEFAULT_PASSWORD="$(octop_random_password)"
            # 密码校验发生在写库之后，目录已经不是空的，必须 --force 才能重试。
            run_octop_init "$DEFAULT_PASSWORD" --force
        else
            rm -f "$init_log"
            exit "$init_status"
        fi
    fi
    rm -f "$init_log"

    mkdir -p "$OCTOP_HOME"
    cat > "$CREDENTIAL_FILE" << EOF
Octop Login Credential
======================
URL:      http://<host>:${PORT}
Username: ${ADMIN_USERNAME}
Password: ${DEFAULT_PASSWORD}

Please change this password after first login!
  - Via Web: avatar menu → Change password
  - Via CLI: docker exec -it <container> octop user passwd --username $ADMIN_USERNAME

This file is rewritten whenever the initial password is (re)generated here.
If you changed the password inside the Web console, that password wins.
EOF
    chmod 600 "$CREDENTIAL_FILE"
    echo "[entrypoint] 凭据已保存至: $CREDENTIAL_FILE"
fi

if [ $# -eq 0 ]; then
    echo "[entrypoint] 正在启动 Octop，端口 $PORT..."
    exec octop run --host 0.0.0.0 --port "$PORT"
fi

if [ "$1" = "octop" ]; then
    echo "[entrypoint] 执行命令: $*"
    exec "$@"
fi

echo "[entrypoint] 执行命令: $*"
exec "$@"
