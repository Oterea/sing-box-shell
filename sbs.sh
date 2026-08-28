#!/bin/bash
#
# sing-box-shell (sbs) —— 官方 sing-box 内核的客户端管理脚本
#
# 结构分五层，自上而下依赖，不许反向调用：
#
#   L0  常量与原语      core_*        输出、依赖检查、架构探测。无副作用或仅限自身
#   L1  纯查询          src_* gh_*    结果走 stdout，状态走返回码。不改状态、不交互
#   L2  动作            kern_* svc_* cfg_*   有副作用，但一律不交互，参数由上层给
#   L3  编排            cmd_*         唯一允许出现 read / prompt 的一层
#   L4  分发            cli_*         参数解析与路由
#
# 交互只准出现在 L3。下面每一层都靠参数拿输入，所以都能被单独调用和测试。
#
set -uo pipefail

# ============================================================ L0 常量
readonly SBS_WORK_DIR="${SBS_WORK_DIR:-$HOME/sing-box}"
readonly SBS_EXEC="${SBS_EXEC:-/usr/local/bin/sbs}"
readonly SBS_SERVICE="${SBS_SERVICE:-/etc/systemd/system/sbs.service}"
readonly SBS_UNIT_NAME="sbs"
readonly SBS_BIN="$SBS_WORK_DIR/sing-box"
readonly SBS_CONFIG="$SBS_WORK_DIR/config.json"
readonly SBS_SHARE="$SBS_WORK_DIR/share.txt"
readonly SBS_LAST_SOURCE="$SBS_WORK_DIR/.last_source"
readonly SBS_REPO="Oterea/sing-box-shell"
readonly SBS_UPSTREAM="SagerNet/sing-box"

# 全脚本唯一的可变全局，由 core_detect_target 写入，gh_asset_url 读取
SBS_TARGET_SUFFIX=""

# ============================================================ L0 输出原语
readonly C_RED="$(tput setaf 1 2>/dev/null || printf '')"
readonly C_GREEN="$(tput setaf 2 2>/dev/null || printf '')"
readonly C_YELLOW="$(tput setaf 3 2>/dev/null || printf '')"
readonly C_CYAN="$(tput setaf 6 2>/dev/null || printf '')"
readonly C_RESET="$(tput sgr0 2>/dev/null || printf '')"

# 四个都写 stderr。这是「返回值走 stdout」那条约定必须配套的另一半 ——
# 上层用 $(...) 捕获下层返回值时，任何写到 stdout 的提示文字都会混进返回值里。
core_info() { printf '%s\n' "${C_GREEN}[info]:${C_RESET} $*" >&2; }
core_warn() { printf '%s\n' "${C_YELLOW}[warn]:${C_RESET} $*" >&2; }
core_error() { printf '%s\n' "${C_RED}[error]:${C_RESET} $*" >&2; }
core_prompt() { printf '%s\n' "${C_CYAN}[prompt]:${C_RESET} $*" >&2; }
# 致命错误。只在 L3/L4 使用；L1/L2 一律 return 1，把是否终止的决定权交给上层
die() {
    core_error "$*"
    exit 1
}

# ============================================================ L0 环境
core_check_deps() {
    local missing="" t
    for t in curl tar jq; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    [ -z "$missing" ] && return 0
    core_error "缺少依赖:$missing，请先安装"
    return 1
}

core_ensure_workdir() {
    [ -d "$SBS_WORK_DIR" ] && return 0
    mkdir -p "$SBS_WORK_DIR"
}

# 探测本机架构与 C 库，拼出 release 资产的文件名后缀。
# 只在 -glibc / -musl 之间二选一，主动避开无后缀那个 —— 它是 glibc 动态链接
# 且捆了 libcronet.so，在 musl 系统（Alpine / OpenWrt）上跑不起来。
core_detect_target() {
    local machine arch libc
    machine=$(uname -m)
    case "$machine" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    armv7l | armv7) arch=armv7 ;;
    i386 | i686) arch=386 ;;
    riscv64) arch=riscv64 ;;
    loongarch64) arch=loong64 ;;
    s390x) arch=s390x ;;
    ppc64le) arch=ppc64le ;;
    *)
        core_error "不支持的架构: $machine"
        return 1
        ;;
    esac

    if ldd --version 2>&1 | grep -qi musl; then libc=musl; else libc=glibc; fi

    SBS_TARGET_SUFFIX="linux-${arch}-${libc}.tar.gz"
    core_info "target: ${arch}/${libc} (asset: *-${SBS_TARGET_SUFFIX})"
}

# ============================================================ L1 下载源
#
# 两类下载源，性质不同，不能共用一个列表：
#
#   内核二进制是 GitHub release 资产。jsDelivr 不服务这类文件，只能走反代。
#   脚本自身是仓库内文件，什么源都行。
#
# 共同的排序原则是「新鲜度优先」：jsDelivr 的 @main 有约 12h TTL，push 之后会
# 持续吐旧版（purge 接口是异步的，实测 purge 后边缘节点仍返回旧版本），
# 对一个能自更新的脚本这个性质不可接受，所以它一律排最后。

src_kernel() {
    [ -n "${SBS_PROXY:-}" ] && printf '%s\n' "$SBS_PROXY"
    [ -s "$SBS_LAST_SOURCE" ] && cat "$SBS_LAST_SOURCE"
    printf '%s\n' "https://gh-proxy.com"
    printf '%s\n' "https://ghfast.top"
    printf '%s\n' "direct"
    return 0
}

src_script() {
    [ -n "${SBS_MIRROR:-}" ] && printf '%s\n' "$SBS_MIRROR"
    printf '%s\n' "https://gh-proxy.com/https://raw.githubusercontent.com/$SBS_REPO/main"
    printf '%s\n' "https://ghfast.top/https://raw.githubusercontent.com/$SBS_REPO/main"
    printf '%s\n' "https://raw.githubusercontent.com/$SBS_REPO/main"
    printf '%s\n' "https://testingcf.jsdelivr.net/gh/$SBS_REPO@main"
    return 0
}

src_remember() { printf '%s\n' "$1" >"$SBS_LAST_SOURCE" 2>/dev/null; }

# ============================================================ L1 取回
#
# 只有失败才换源，慢不换。曾经考虑过用 --speed-limit 把「慢」也判成失败，
# 但那样末位源一旦触发就等于什么都拿不到（慢总比没有强），而且网络抖动会误伤。

# 取回 release 资产（大文件，带进度条，源需要 URL 前缀拼接）
sb_fetch() { # $1=目标文件 $2=原始 URL
    local dst="$1" url="$2" src full
    for src in $(src_kernel | awk '!seen[$0]++'); do
        if [ "$src" = direct ]; then full="$url"; else full="$src/$url"; fi
        core_info "source: $src"
        if curl -fL --connect-timeout 5 --retry 2 --progress-bar -o "$dst" "$full"; then
            src_remember "$src"
            return 0
        fi
        core_warn "$src 失败，试下一个"
    done
    core_error "所有源都失败。可用 SBS_PROXY=<base-url> 手动指定"
    return 1
}

# 取回仓库内文件（小文件，源是完整 base URL）
script_fetch() { # $1=本地目标路径 $2=远端文件名
    local dst="$1" name="$2" base
    for base in $(src_script | awk '!seen[$0]++'); do
        core_info "source: $base"
        curl -fsSL --connect-timeout 5 --retry 2 -o "$dst" "$base/$name" && return 0
        core_warn "$base 失败，试下一个"
    done
    core_error "所有脚本源都失败。可用 SBS_MIRROR=<base-url> 手动指定"
    return 1
}

# ============================================================ L1 版本发现
#
# 不走 GitHub API：单个 release 的 JSON 就有约 340KB（每个 release 携带
# 154 个 asset 的元数据），per_page=15 要拉约 5MB，而国内链路只有约 35KB/s，
# 实测必然超时且无超时参数时会无限挂起。改用两条轻量通路。

# atom：8KB，最快，但窗口只有约 10 条
gh_tags_atom() {
    curl -sfL --connect-timeout 5 --max-time 25 \
        "https://github.com/$SBS_UPSTREAM/releases.atom" |
        grep -o 'href="[^"]*releases/tag/[^"]*"' | sed 's|.*/tag/||; s|"$||'
}

# jsDelivr：145KB，全量 600+ 条，完全不碰 github.com
gh_tags_jsdelivr() {
    curl -sfL --connect-timeout 5 --max-time 25 \
        "https://data.jsdelivr.com/v1/packages/gh/$SBS_UPSTREAM" |
        jq -r '.versions[].version' | sed 's/^/v/'
}

# $1=full 时直接要全量列表
gh_tag_list() {
    local tags
    if [ "${1:-}" != full ]; then
        tags=$(gh_tags_atom) && [ -n "$tags" ] && {
            printf '%s\n' "$tags"
            return 0
        }
    fi
    gh_tags_jsdelivr
}

# 从 stdin 读 tag 列表，挑出第一个。rc / alpha 不算 beta —— 只要 beta 那一档
gh_pick_stable() { grep -vE -- '-(alpha|beta|rc)' | head -n 1; }
gh_pick_beta() { grep -- '-beta' | head -n 1; }

# 按命名规则拼出下载地址。stable 与 beta 规则一致，已验证
gh_asset_url() { # $1=tag
    printf '%s\n' "https://github.com/$SBS_UPSTREAM/releases/download/$1/sing-box-${1#v}-${SBS_TARGET_SUFFIX}"
}

# 0=存在 1=确认不存在 2=判定不了（网络问题，交给 sb_fetch 兜底）
gh_verify_asset() { # $1=url
    local code
    code=$(curl -sI -o /dev/null -w '%{http_code}' -L --connect-timeout 5 --max-time 20 "$1" 2>/dev/null)
    case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *) return 2 ;;
    esac
}

# 输出两行：稳定版 tag、beta tag（beta 可能为空行）
gh_resolve_tags() {
    local tags stable beta
    tags=$(gh_tag_list)
    stable=$(printf '%s\n' "$tags" | gh_pick_stable)
    beta=$(printf '%s\n' "$tags" | gh_pick_beta)

    # atom 窗口太小或拉不到时，落到全量列表
    if [ -z "$stable" ] || [ -z "$beta" ]; then
        core_warn "atom feed 不足，改用 jsDelivr 版本列表"
        tags=$(gh_tag_list full)
        [ -z "$stable" ] && stable=$(printf '%s\n' "$tags" | gh_pick_stable)
        [ -z "$beta" ] && beta=$(printf '%s\n' "$tags" | gh_pick_beta)
    fi

    [ -z "$stable" ] && return 1
    printf '%s\n%s\n' "$stable" "$beta"
}

# ============================================================ L2 内核
kern_version() {
    [ -x "$SBS_BIN" ] || return 1
    "$SBS_BIN" version 2>/dev/null | head -n 1
}

# 下载、解压、自检、顶替。全程在 $SBS_WORK_DIR 下的临时目录里进行。
#
# 之所以不直接往最终位置解压：GNU tar 是「先 unlink 旧文件再新建」，解压一开始
# 旧二进制就没了；中途断网 / 磁盘满 / 包损坏就会既没有新的也没有旧的。而顶替前
# 的一次 version 自检，能把架构选错、libc 不匹配、包损坏全部挡在替换之前。
#
# 临时目录必须放在 $SBS_WORK_DIR 内部以保证与目标同一文件系统 —— 跨文件系统时
# mv 无法 rename，会退化成复制覆盖，上面两条保证就都不成立了。
#
# 注：实测 tar 与 install 都会先 unlink，不会撞 Text file busy；只有 cp 这类
# 就地写入才会。所以选 mv 不是为了绕开 ETXTBSY，而是为了「先验证再顶替」。
kern_install() { # $1=下载地址
    local url="$1"
    local stage="$SBS_WORK_DIR/.stage.$$"
    local tarball="$stage/sing-box.tar.gz"
    local selfcheck

    rm -rf "$stage"
    mkdir -p "$stage" || {
        core_error "无法创建临时目录 $stage"
        return 1
    }

    core_info "downloading sing-box."
    sb_fetch "$tarball" "$url" || {
        rm -rf "$stage"
        return 1
    }

    # 整包解到临时目录，LICENSE 之类跟着进来也无所谓，随临时目录一起删
    tar --strip-components=1 -xzf "$tarball" -C "$stage" || {
        core_error "解压失败"
        rm -rf "$stage"
        return 1
    }

    [ -f "$stage/sing-box" ] || {
        core_error "包里没有 sing-box 可执行文件"
        rm -rf "$stage"
        return 1
    }
    chmod +x "$stage/sing-box"

    selfcheck=$("$stage/sing-box" version 2>&1 | head -n 1) || {
        core_error "新二进制无法运行，保留原有版本。输出：$selfcheck"
        rm -rf "$stage"
        return 1
    }
    core_info "self-check ok: $selfcheck"

    mv -f "$stage/sing-box" "$SBS_BIN" || {
        core_error "替换失败，保留原有版本"
        rm -rf "$stage"
        return 1
    }
    rm -rf "$stage"
    core_info "sing-box installed to $SBS_BIN"
}

# ============================================================ L2 配置
cfg_url_get() {
    [ -f "$SBS_SHARE" ] || return 1
    local url
    url=$(sed -n 's/^config_url=//p' "$SBS_SHARE" | tail -n 1 | tr -d '"')
    [ -n "$url" ] || return 1
    printf '%s\n' "$url"
}

cfg_url_set() { printf 'config_url="%s"\n' "$1" >"$SBS_SHARE"; }

cfg_url_valid() { case "$1" in http://* | https://*) return 0 ;; *) return 1 ;; esac; }

# 配置是否可用：二进制在、文件在、语法过
cfg_check() {
    [ -x "$SBS_BIN" ] || {
        core_error "sing-box 未安装"
        return 1
    }
    [ -f "$SBS_CONFIG" ] || {
        core_error "config.json 不存在"
        return 1
    }
    local out
    out=$("$SBS_BIN" check -c "$SBS_CONFIG" 2>&1)
    [ -z "$out" ] && return 0
    core_error "config.json 不合法"
    printf '%s\n' "$out" >&2
    return 1
}

# 拉订阅并原地校验，坏了就回滚。订阅地址是用户自己的服务，不走反代
cfg_fetch() { # $1=订阅地址
    local url="$1"
    local backup="$SBS_CONFIG.backup"
    local tmp="$SBS_WORK_DIR/.config.$$.json"

    core_info "fetching config.json"
    # -f：HTTP 错误码不当成功，否则 404 页面会被存成配置文件
    if ! curl -fL --connect-timeout 5 --max-time 60 --retry 2 --progress-bar -o "$tmp" "$url"; then
        core_error "订阅拉取失败，原配置未动"
        rm -f "$tmp"
        return 1
    fi

    if [ -x "$SBS_BIN" ]; then
        local out
        out=$("$SBS_BIN" check -c "$tmp" 2>&1)
        if [ -n "$out" ]; then
            core_error "拉到的配置不合法，原配置未动"
            printf '%s\n' "$out" >&2
            rm -f "$tmp"
            return 1
        fi
    else
        core_warn "sing-box 未安装，跳过配置校验"
    fi

    local had_old=0
    if [ -f "$SBS_CONFIG" ]; then
        cp -f "$SBS_CONFIG" "$backup" && had_old=1
    fi
    mv -f "$tmp" "$SBS_CONFIG" || {
        core_error "写入配置失败"
        rm -f "$tmp"
        return 1
    }
    if [ "$had_old" -eq 1 ]; then
        core_info "config.json 已更新（上一版备份在 $backup）"
    else
        core_info "config.json 已写入"
    fi
}

# ============================================================ L2 服务
svc_write_unit() {
    local ver
    ver=$(kern_version) || ver="unknown"

    # Restart=on-failure 而非 always：正常退出（exit 0）不该被反复拉起
    # RestartSec：配置写错导致起来就崩时，避免秒级重启刷爆日志、淹没真正的错误
    # LimitNOFILE：TUN 模式下整机连接都过 sing-box，默认 1024 个句柄容易撞上限
    sudo tee "$SBS_SERVICE" >/dev/null <<UNIT
[Unit]
Description=$ver (managed by sbs)
After=network.target

[Service]
ExecStart=$SBS_BIN run
WorkingDirectory=$SBS_WORK_DIR/
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT

    [ -f "$SBS_SERVICE" ] || {
        core_error "写入 $SBS_SERVICE 失败"
        return 1
    }
    sudo systemctl daemon-reload
    core_info "service file written: $SBS_SERVICE"
}

svc_start() { sudo systemctl start "$SBS_UNIT_NAME"; }
svc_stop() { sudo systemctl stop "$SBS_UNIT_NAME"; }
svc_status() { sudo systemctl status "$SBS_UNIT_NAME" --no-pager; }
svc_is_active() { systemctl is-active --quiet "$SBS_UNIT_NAME"; }
svc_purge() {
    sudo systemctl disable "$SBS_UNIT_NAME" >/dev/null 2>&1
    sudo systemctl stop "$SBS_UNIT_NAME" >/dev/null 2>&1
    sudo rm -f "$SBS_SERVICE"
    sudo systemctl daemon-reload
}

# ============================================================ L3 编排（唯一允许交互的一层）
_ask() { # $1=提示 $2=默认值 —— 回显提示并读一行
    local reply
    core_prompt "$1"
    read -r reply || reply=""
    printf '%s\n' "${reply:-$2}"
}

# 解析版本并让用户选档，输出选定的下载地址
_choose_release() {
    local tags stable beta pick url
    tags=$(gh_resolve_tags) || {
        core_error "无法获取版本列表（github.com 与 jsDelivr 都不可达）"
        return 1
    }
    stable=$(printf '%s\n' "$tags" | sed -n 1p)
    beta=$(printf '%s\n' "$tags" | sed -n 2p)
    core_info "latest stable: $stable"
    core_info "latest beta:   ${beta:-未找到}"

    pick=$(_ask "install stable version? [Y/n]:" y)
    case "$pick" in
    [Nn])
        [ -n "$beta" ] || {
            core_error "没有找到 beta 版本"
            return 1
        }
        url=$(gh_asset_url "$beta")
        ;;
    *) url=$(gh_asset_url "$stable") ;;
    esac

    gh_verify_asset "$url"
    case $? in
    1)
        core_error "asset 不存在，上游可能改了命名: $url"
        return 1
        ;;
    2) core_warn "无法预检 asset，继续（下载时再判）" ;;
    esac

    printf '%s\n' "$url"
}

# 拿到订阅地址：有默认值就问要不要用，没有就直接要
_resolve_sub_url() {
    local current="" choice url
    current=$(cfg_url_get) || current=""

    if [ -n "$current" ]; then
        core_prompt "当前订阅: $current"
        choice=$(_ask "沿用这个地址? [Y/n]:" y)
        case "$choice" in
        [Nn]) : ;;
        *)
            printf '%s\n' "$current"
            return 0
            ;;
        esac
    else
        core_prompt "尚未设置订阅地址"
    fi

    url=$(_ask "请输入订阅地址:" "")
    cfg_url_valid "$url" || {
        core_error "订阅地址无效（需要 http:// 或 https:// 开头）"
        return 1
    }
    # 注意这里不落盘。地址要等 cfg_fetch 真的拉到一份合法配置之后才由调用方
    # 写进 share.txt —— 否则输错一次就把原来能用的地址永久覆盖掉了。
    printf '%s\n' "$url"
}

cmd_install() {
    local url sub
    core_detect_target || return 1
    url=$(_choose_release) || return 1
    kern_install "$url" || return 1
    svc_write_unit || return 1
    sub=$(_resolve_sub_url) || return 1
    cfg_fetch "$sub" || return 1
    cfg_url_set "$sub"
    core_info "安装完成。用 'sbs start' 启动"
}

cmd_update_kernel() {
    local url
    core_detect_target || return 1
    kern_version >/dev/null && core_info "当前: $(kern_version)"
    url=$(_choose_release) || return 1
    kern_install "$url" || return 1
    svc_write_unit || return 1
    svc_is_active && core_warn "服务正在运行，新内核需 'sbs stop && sbs start' 后生效"
    return 0
}

cmd_update_config() {
    local sub
    sub=$(_resolve_sub_url) || return 1
    cfg_fetch "$sub" || return 1
    cfg_url_set "$sub"
    svc_is_active && core_warn "服务正在运行，新配置需 'sbs stop && sbs start' 后生效"
    return 0
}

# 这两个不能是 local：trap 在函数返回之后才执行，那时 local 已销毁，
# set -u 下会报 unbound variable
_SELF_TMPDIR=""
_SELF_STAGE=""
cmd_update_self() {
    local tmpdir stage
    tmpdir=$(mktemp -d) || {
        core_error "无法创建临时目录"
        return 1
    }
    _SELF_TMPDIR="$tmpdir"
    # 中转名字放在目标旁边，保证最后一步是同盘改名。
    # 本脚本自己就是 $SBS_EXEC，而 bash 是边读边执行、按字节偏移续读的：
    # 就地覆盖会让它从新内容的行中间接上，把两个版本串起来跑（已实测复现）。
    stage="$(dirname "$SBS_EXEC")/.$(basename "$SBS_EXEC").$$.tmp"
    _SELF_STAGE="$stage"
    trap 'rm -rf "${_SELF_TMPDIR:-}" 2>/dev/null; sudo rm -f "${_SELF_STAGE:-}" 2>/dev/null' EXIT

    script_fetch "$tmpdir/sbs.sh" sbs.sh || return 1
    bash -n "$tmpdir/sbs.sh" || {
        core_error "拉到的脚本语法不合法，放弃更新"
        return 1
    }
    sudo cp "$tmpdir/sbs.sh" "$stage" || return 1
    sudo chmod 755 "$stage" || return 1
    sudo mv -f "$stage" "$SBS_EXEC" || return 1
    core_info "sbs 已更新"
}

# 只有 start 该关心配置是否有效 —— 配置坏了启动也是白启，不如早点说
cmd_start() {
    cfg_check || return 1
    svc_start && core_info "sing-box started" || {
        core_error "启动失败，看日志: journalctl -u $SBS_UNIT_NAME -n 30 --output cat"
        return 1
    }
}

# 不检查配置：停服务和配置对不对无关。恰恰是配置坏了的时候最需要停得下来
cmd_stop() {
    svc_stop && core_info "sing-box stopped" || {
        core_error "停止失败"
        return 1
    }
}

# 同样不检查配置：状态该如实显示，不该因为配置无效就拒绝回答
cmd_status() {
    svc_status
    core_info "出口 IP:"
    curl -s --max-time 10 ipinfo.io || core_warn "取不到出口 IP"
    return 0
}

cmd_remove() {
    local choice
    choice=$(_ask "删除 sing-box、配置与本脚本? [y/N]:" N)
    case "$choice" in
    [Yy]) : ;;
    *)
        core_info "已取消"
        return 0
        ;;
    esac
    svc_purge
    sudo rm -rf "$SBS_WORK_DIR"
    sudo rm -f "$SBS_EXEC"
    core_info "已全部删除"
}

# ============================================================ L4 分发
cli_help() {
    cat <<'USAGE'
Usage:
  sbs install         安装 sing-box 内核与配置
  sbs update          更新内核
  sbs update config   更新订阅配置
  sbs update sbs      更新本脚本
  sbs start           启动
  sbs stop            停止
  sbs status          查看状态与出口 IP
  sbs remove          卸载全部

环境变量:
  SBS_PROXY   指定内核下载反代，如 https://gh-proxy.com
  SBS_MIRROR  指定脚本源 base URL
USAGE
}

cli_dispatch() {
    local cmd="${1:-}" sub="${2:-}"
    case "$cmd" in
    install) cmd_install ;;
    update)
        case "$sub" in
        config) cmd_update_config ;;
        sbs) cmd_update_self ;;
        "") cmd_update_kernel ;;
        *)
            core_error "未知子命令: update $sub"
            cli_help
            return 1
            ;;
        esac
        ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    remove) cmd_remove ;;
    help | -h | --help) cli_help ;;
    "")
        cli_help
        return 0
        ;;
    *)
        core_error "未知命令: $cmd"
        cli_help
        return 1
        ;;
    esac
}

# ============================================================ 入口
main() {
    core_check_deps || exit 1
    core_ensure_workdir || die "无法创建 $SBS_WORK_DIR"
    cli_dispatch "$@"
}

main "$@"
