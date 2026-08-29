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
readonly SBS_IPCACHE="$SBS_WORK_DIR/.exit_ip"
readonly SBS_REPO="Oterea/sing-box-shell"
readonly SBS_UPSTREAM="SagerNet/sing-box"

# 全脚本唯一的可变全局，由 core_detect_target 写入，gh_asset_url 读取
SBS_TARGET_SUFFIX=""

# ============================================================ L0 输出原语
readonly C_RED="$(tput setaf 1 2>/dev/null || printf '')"
readonly C_GREEN="$(tput setaf 2 2>/dev/null || printf '')"
readonly C_YELLOW="$(tput setaf 3 2>/dev/null || printf '')"
readonly C_CYAN="$(tput setaf 6 2>/dev/null || printf '')"
readonly C_DIM="$(tput dim 2>/dev/null || printf '')"
readonly C_BOLD="$(tput bold 2>/dev/null || printf '')"
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
# 不用 `... | head -1`：开了 pipefail 时，head 提前关闭管道会给前面的进程
# 送 SIGPIPE，整条管道的状态变成 141，调用方会误判成「二进制跑不起来」。
# 输出很小时通常不触发，但那是靠管道缓冲区侥幸，不是保证。
kern_version() {
    [ -x "$SBS_BIN" ] || return 1
    local out
    out=$("$SBS_BIN" version 2>/dev/null) || return 1
    printf '%s\n' "${out%%$'\n'*}"
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

    selfcheck=$("$stage/sing-box" version 2>&1) || {
        core_error "新二进制无法运行，保留原有版本。输出：${selfcheck%%$'\n'*}"
        rm -rf "$stage"
        return 1
    }
    selfcheck=${selfcheck%%$'\n'*}
    core_info "self-check ok: $selfcheck"

    mv -f "$stage/sing-box" "$SBS_BIN" || {
        core_error "替换失败，保留原有版本"
        rm -rf "$stage"
        return 1
    }
    rm -rf "$stage"
    core_info "sing-box installed to $SBS_BIN"
}

# 只取版本号，去掉 "sing-box version " 前缀。菜单与 status 面板共用
kern_version_short() {
    local v
    v=$(kern_version) || return 1
    v=$(printf '%s' "$v" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*') || return 1
    printf '%s\n' "${v%%$'\n'*}"
}

# ============================================================ L1 现场信息
# tun 设备名与地址，没有则返回 1
tun_info() {
    local out
    out=$(ip -br -4 addr 2>/dev/null | awk '$1 ~ /^tun/ {print $1, $3; exit}')
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# 秒数格式化成 3d 4h / 2h 14m / 5m / 12s
fmt_dur() {
    local t=$1
    if [ "$t" -ge 86400 ]; then printf '%dd %dh\n' $((t / 86400)) $((t % 86400 / 3600))
    elif [ "$t" -ge 3600 ]; then printf '%dh %dm\n' $((t / 3600)) $((t % 3600 / 60))
    elif [ "$t" -ge 60 ]; then printf '%dm\n' $((t / 60))
    else printf '%ds\n' "$t"; fi
}

# 出口 IP 走缓存：菜单要瞬间打开，不能卡在网络请求上。
# 只在状态可能变化时（启停、看详情）才刷新。
net_exit_refresh() {
    local j ip city country
    j=$(curl -s --max-time 8 ipinfo.io 2>/dev/null) || return 1
    ip=$(printf '%s' "$j" | jq -r '.ip // empty' 2>/dev/null)
    [ -n "$ip" ] || return 1
    city=$(printf '%s' "$j" | jq -r '.city // empty' 2>/dev/null)
    country=$(printf '%s' "$j" | jq -r '.country // empty' 2>/dev/null)
    local org
    org=$(printf '%s' "$j" | jq -r '.org // empty' 2>/dev/null)
    local state
    svc_is_active && state=active || state=inactive
    # org 追加在末尾，这样旧的四字段缓存仍能正确解析（org 为空）
    printf '%s|%s|%s|%s|%s\n' "$ip" "${city:+$city, }${country:-}" "$(date +%s)" "$state" "$org" >"$SBS_IPCACHE"
}

# 输出三段：IP、地点、年龄描述
net_exit_cached() {
    [ -f "$SBS_IPCACHE" ] || return 1
    local ip loc ts st org cur age
    IFS='|' read -r ip loc ts st org <"$SBS_IPCACHE" || return 1
    [ -n "$ip" ] || return 1
    svc_is_active && cur=active || cur=inactive
    # 缓存记录的服务状态与当前不符 -> 这条出口信息已经不作数，标成 stale。
    # 这是比「停止时刷新」更硬的一道保险：刷新可能因为断网失败，而状态比对不会。
    if [ -n "${st:-}" ] && [ "$st" != "$cur" ]; then
        printf '%s\n%s\nstale\n%s\n' "$ip" "$loc" "${org:-}"
        return 0
    fi
    age=$(($(date +%s) - ${ts:-0}))
    printf '%s\n%s\n%s\n%s\n' "$ip" "$loc" "$(fmt_dur "$age") ago" "${org:-}"
}

# 字节数转人类可读
fmt_size() {
    local b=$1
    if [ "$b" -ge 1073741824 ]; then awk -v b="$b" 'BEGIN{printf "%.1fG", b/1073741824}'
    elif [ "$b" -ge 1048576 ]; then awk -v b="$b" 'BEGIN{printf "%.1fM", b/1048576}'
    elif [ "$b" -ge 1024 ]; then awk -v b="$b" 'BEGIN{printf "%.1fK", b/1024}'
    else printf '%dB' "$b"; fi
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
svc_restart() { sudo systemctl restart "$SBS_UNIT_NAME"; }

# 运行时长（秒）。用 monotonic 时间戳比解析日期稳
svc_uptime_sec() {
    local mono now
    mono=$(systemctl show "$SBS_UNIT_NAME" -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
    [ -n "$mono" ] && [ "$mono" != 0 ] || return 1
    svc_is_active || return 1
    now=$(awk '{printf "%d", $1 * 1000000}' /proc/uptime)
    printf '%s\n' $(((now - mono) / 1000000))
}
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
    if svc_start; then
        core_info "sing-box started"
        sleep 1
        # 刷新失败不能影响 start 的成败判定 —— 取不到出口 IP 是小事
        net_exit_refresh || core_warn "出口 IP 暂时取不到"
    else
        core_error "启动失败，看日志: journalctl -u $SBS_UNIT_NAME -n 30 --output cat"
        return 1
    fi
}

# 不检查配置：停服务和配置对不对无关。恰恰是配置坏了的时候最需要停得下来
cmd_stop() {
    if svc_stop; then
        core_info "sing-box stopped"
        sleep 1
        net_exit_refresh || core_warn "出口 IP 暂时取不到"
    else
        core_error "停止失败"
        return 1
    fi
}

cmd_restart() {
    cfg_check || return 1
    if svc_restart; then
        core_info "sing-box restarted"
        sleep 1
        net_exit_refresh || core_warn "出口 IP 暂时取不到"
    else
        core_error "重启失败，看日志: journalctl -u $SBS_UNIT_NAME -n 30 --output cat"
        return 1
    fi
}

# 同样不检查配置：状态该如实显示，不该因为配置无效就拒绝回答。
# 面板宽度不够时退回 systemctl 原始输出。
cmd_status() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    if [ "$cols" -lt "$UI_W" ]; then
        svc_status
        return 0
    fi

    net_exit_refresh || true

    # ---- service ----
    local state scolor up pid mem cpu nrs
    if svc_is_active; then
        state=running
        scolor="$C_GREEN"
    elif systemctl is-failed --quiet "$SBS_UNIT_NAME" 2>/dev/null; then
        state=failed
        scolor="$C_RED"
    else
        state=stopped
        scolor="$C_DIM"
    fi
    up=$(svc_uptime_sec 2>/dev/null) && up="up $(fmt_dur "$up")" || up=""
    pid=$(systemctl show "$SBS_UNIT_NAME" -p MainPID --value 2>/dev/null)
    [ "${pid:-0}" = 0 ] && pid="-"
    mem=$(systemctl show "$SBS_UNIT_NAME" -p MemoryCurrent --value 2>/dev/null)
    case "$mem" in '' | '[not set]' | 18446744073709551615) mem="-" ;; *) mem=$(fmt_size "$mem") ;; esac
    cpu=$(systemctl show "$SBS_UNIT_NAME" -p CPUUsageNSec --value 2>/dev/null)
    case "$cpu" in '' | '[not set]') cpu="-" ;; *) cpu=$(awk -v n="$cpu" 'BEGIN{printf "%.1fs", n/1e9}') ;; esac
    nrs=$(systemctl show "$SBS_UNIT_NAME" -p NRestarts --value 2>/dev/null)
    [ -n "${nrs:-}" ] || nrs=0

    # ---- kernel ----
    local ver bin bsize
    ver=$(kern_version_short 2>/dev/null) || ver="not installed"
    if [ -f "$SBS_BIN" ]; then
        bsize=$(fmt_size "$(stat -c %s "$SBS_BIN" 2>/dev/null || echo 0)")
        bin="${SBS_BIN/#$HOME/\~}"
    else
        bsize=""
        bin="-"
    fi

    # ---- network ----
    local tun ip loc age org
    tun=$(tun_info 2>/dev/null) || tun="-"
    { read -r ip; read -r loc; read -r age; read -r org; } < <(net_exit_cached) 2>/dev/null || true

    # ---- config ----
    local src nodes mtime valid vcolor
    src=$(cfg_url_get 2>/dev/null) || src="-"
    if [ -f "$SBS_CONFIG" ]; then
        nodes=$(jq '[.outbounds[]? | select(.type != "direct" and .type != "block" and .type != "selector" and .type != "urltest")] | length' "$SBS_CONFIG" 2>/dev/null) || nodes="?"
        mtime=$(stat -c %Y "$SBS_CONFIG" 2>/dev/null) && mtime="$(fmt_dur $(($(date +%s) - mtime))) ago" || mtime="-"
        if [ -x "$SBS_BIN" ] && [ -z "$("$SBS_BIN" check -c "$SBS_CONFIG" 2>&1)" ]; then
            valid=valid
            vcolor="$C_GREEN"
        else
            valid=invalid
            vcolor="$C_RED"
        fi
    else
        nodes="-"
        mtime="-"
        valid="missing"
        vcolor="$C_YELLOW"
    fi

    # ---- 画 ----
    ui_sec service '╭' '╮'
    ui_kv status "$state" "${up:+$up }" "$scolor$state$C_RESET" "$C_DIM${up:+$up }$C_RESET"
    ui_kv pid "$(printf '%-12s mem %-9s cpu %s' "$pid" "$mem" "$cpu")" ""
    ui_kv restarts "$nrs" ""
    ui_sec kernel
    ui_kv version "$ver" ""
    ui_kv binary "$(ui_fit "$bin" 32)" "${bsize:+$bsize }" "" "$C_DIM${bsize:+$bsize }$C_RESET"
    ui_sec network
    ui_kv tun "$tun" ""
    if [ -n "${ip:-}" ]; then
        ui_kv exit "$ip  $loc" "${age:+$age }" "" "$C_DIM${age:+$age }$C_RESET"
        [ -n "${org:-}" ] && ui_kv "" "$(ui_fit "$org" 42)" "" "$C_DIM$(ui_fit "$org" 42)$C_RESET"
    else
        ui_kv exit "n/a" ""
    fi
    ui_sec config
    ui_kv source "$(ui_fit "$src" 42)" ""
    ui_kv nodes "$(printf '%-10s updated %s' "$nodes" "$mtime")" "$valid " "" "$vcolor$valid$C_RESET "
    printf '╰%s╯\n' "$(ui_bar $UI_IN)"
    return 0
}

cmd_remove() {
    local choice
    choice=$(_ask "删除 sing-box、配置与本脚本? [y/N]:" N)
    case "$choice" in
    [Yy]) : ;;
    *)
        # 返回 1 表示「什么都没做」。菜单据此判断是否退出：
        # 只有真正删干净了才该离开菜单，取消不该
        core_info "已取消"
        return 1
        ;;
    esac
    svc_purge
    sudo rm -rf "$SBS_WORK_DIR"
    sudo rm -f "$SBS_EXEC"
    core_info "已全部删除"
}

# ============================================================ L4 界面原语
#
# 画框的两个坑，都必须靠「纯文本算宽度、带色版本打印」来绕：
#   1. 颜色转义序列会被 ${#str} 算进长度，直接拿带色字符串算 padding 必歪
#   2. 中文是双宽字符，${#str} 数的是字符数不是列数 —— 所以界面一律用英文
UI_W=58
UI_IN=$((UI_W - 2))

ui_bar() {
    local n=$1 s
    printf -v s '%*s' "$n" ''
    printf '%s' "${s// /─}"
}
ui_top() { printf '╭%s╮\n' "$(ui_bar $UI_IN)"; }
ui_bot() { printf '╰%s╯\n' "$(ui_bar $UI_IN)"; }
ui_sep() { printf '├%s┤\n' "$(ui_bar $UI_IN)"; }
ui_blank() { printf '│%*s│\n' "$UI_IN" ''; }

# $1 纯文本左 $2 纯文本右 $3 带色左 $4 带色右
ui_lr() {
    local pad=$((UI_IN - ${#1} - ${#2}))
    [ "$pad" -lt 0 ] && pad=0
    printf '│%s%*s%s│\n' "$3" "$pad" '' "$4"
}

# 分区标题嵌在边线上：├─ service ────────┤
ui_sec() { # $1=标题 $2=左角(默认├) $3=右角(默认┤)
    local t="$1"
    local lc="${2:-├}"
    local rc="${3:-┤}"
    local n=$((UI_IN - ${#t} - 3))
    [ "$n" -lt 0 ] && n=0
    printf '%s─ %s%s%s %s%s\n' "$lc" "$C_DIM" "$t" "$C_RESET" "$(ui_bar $n)" "$rc"
}

# 键值行。键固定 10 列并置灰，值正常色，$3 为右对齐的附加信息
ui_kv() { # $1=键 $2=值(纯) $3=右(纯) $4=值(带色,省略则同纯) $5=右(带色,省略则同纯)
    local plain colored
    printf -v plain '  %-10s%s' "$1" "$2"
    printf -v colored '  %s%-10s%s%s' "$C_DIM" "$1" "$C_RESET" "${4:-$2}"
    ui_lr "$plain" "$3" "$colored" "${5:-$3}"
}

# 值太长时截断，保证不撑破框
ui_fit() { # $1=文本 $2=可用列数
    local t="$1"
    local n="$2"
    if [ "${#t}" -le "$n" ]; then printf '%s' "$t"; else printf '%s...' "${t:0:$((n - 3))}"; fi
}

# 一行两个条目。$5/$6 为 dim 时该项置灰（表示当前不可用）
ui_item() {
    local k1=$1 l1=$2 k2=$3 l2=$4 d1=${5:-} d2=${6:-} plain colored
    printf -v plain '    %s   %-15s  %s   %-15s' "$k1" "$l1" "$k2" "$l2"
    printf -v colored '    %s%s%s   %s%-15s%s  %s%s%s   %s%-15s%s' \
        "${d1:-$C_CYAN}" "$k1" "$C_RESET" "$d1" "$l1" "${d1:+$C_RESET}" \
        "${d2:-$C_CYAN}" "$k2" "$C_RESET" "$d2" "$l2" "${d2:+$C_RESET}"
    ui_lr "$plain" "" "$colored" ""
}

# ============================================================ L4 菜单
cli_menu_draw() {
    local state scolor ver tun uptime ip loc age
    local l2p l2c l3p l3c

    if svc_is_active; then
        state="RUNNING"
        scolor="$C_GREEN"
    else
        state="STOPPED"
        scolor="$C_DIM"
    fi

    ver=$(kern_version_short 2>/dev/null) || ver=""
    [ -n "$ver" ] || ver="not installed"
    tun=$(tun_info 2>/dev/null | awk '{print $1" "$2}') || tun=""
    uptime=$(svc_uptime_sec 2>/dev/null) && uptime="up $(fmt_dur "$uptime")" || uptime=""

    printf '\e[H\e[2J'
    echo
    ui_top
    ui_lr "  sing-box" "$state  " "$C_BOLD  sing-box$C_RESET" "$scolor$state$C_RESET  "

    printf -v l2p '  %s   %s   %s' "$ver" "${tun:-no tun}" "$uptime"
    printf -v l2c '%s  %s   %s   %s%s' "$C_DIM" "$ver" "${tun:-no tun}" "$uptime" "$C_RESET"
    ui_lr "$l2p" "" "$l2c" ""

    if { read -r ip; read -r loc; read -r age; } < <(net_exit_cached) 2>/dev/null && [ -n "${ip:-}" ]; then
        printf -v l3p '  exit  %s  %s' "$ip" "$loc"
        printf -v l3c '%s  exit  %s  %s%s' "$C_DIM" "$ip" "$loc" "$C_RESET"
        local agec="$C_DIM$age$C_RESET"
        [ "$age" = stale ] && agec="$C_YELLOW$age$C_RESET"
        ui_lr "$l3p" "$age  " "$l3c" "$agec  "
    else
        ui_lr "  exit  n/a" "" "$C_DIM  exit  n/a$C_RESET" ""
    fi

    ui_sep
    ui_blank
    # k 一个键两种含义：没装内核时是 install（内核+unit+订阅一条龙），
    # 装了之后才是 update kernel。全新机器上敲 sbs 必须有路可走。
    local klabel
    if [ -x "$SBS_BIN" ]; then klabel="update kernel"; else klabel="install"; fi

    if [ ! -x "$SBS_BIN" ]; then
        # 内核都没有，启动 / 停止 / 重启 / 状态全都没意义，一律置灰
        ui_item s start "k" "$klabel" "$C_DIM" ""
        ui_item x stop "c" "update config" "$C_DIM" "$C_DIM"
        ui_item r restart "u" "update sbs" "$C_DIM" ""
        ui_item i status "d" remove "$C_DIM" "$C_DIM"
    elif svc_is_active; then
        ui_item s start "k" "$klabel" "$C_DIM" ""
        ui_item x stop "c" "update config" "" ""
        ui_item r restart "u" "update sbs" "" ""
        ui_item i status "d" remove "" ""
    else
        ui_item s start "k" "$klabel" "" ""
        ui_item x stop "c" "update config" "$C_DIM" ""
        ui_item r restart "u" "update sbs" "$C_DIM" ""
        ui_item i status "d" remove "" ""
    fi
    ui_blank
    ui_sep
    ui_lr "  q  quit" "" "  ${C_CYAN}q$C_RESET  quit" ""
    ui_bot
    echo
}

cli_menu_pause() {
    echo
    printf '%s' "${C_DIM}  按任意键返回菜单${C_RESET}"
    read -rsn1 _ 2>/dev/null || true
}

cli_menu() {
    # 终端太窄画框会折行，比没框还难看；直接退回帮助
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    if [ "$cols" -lt "$UI_W" ]; then
        core_warn "终端宽度 $cols 小于 $UI_W，改用命令行模式"
        cli_help
        return 0
    fi

    local key
    while true; do
        cli_menu_draw
        read -rsn1 key 2>/dev/null || return 0
        echo
        case "$key" in
        s) cmd_start; cli_menu_pause ;;
        x) cmd_stop; cli_menu_pause ;;
        r) cmd_restart; cli_menu_pause ;;
        i) cmd_status; cli_menu_pause ;;
        k)
            # 与上面的标签保持一致：没装就走完整安装，装了就只更新内核
            if [ -x "$SBS_BIN" ]; then cmd_update_kernel; else cmd_install; fi
            cli_menu_pause
            ;;
        c) cmd_update_config; cli_menu_pause ;;
        u)
            if cmd_update_self; then
                core_info "脚本已更新，退出以加载新版本"
                return 0
            fi
            cli_menu_pause
            ;;
        d)
            # cmd_remove 取消或失败都返回 1，此时留在菜单
            if cmd_remove; then return 0; fi
            cli_menu_pause
            ;;
        q | $'\e') printf '\e[H\e[2J'; return 0 ;;
        *) : ;;
        esac
    done
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
  sbs restart         重启
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
    restart) cmd_restart ;;
    status) cmd_status ;;
    remove) cmd_remove ;;
    help | -h | --help) cli_help ;;
    "")
        # 非 tty（管道、脚本调用）不进菜单，保持可脚本化
        if [ -t 0 ] && [ -t 1 ]; then cli_menu; else cli_help; fi
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
