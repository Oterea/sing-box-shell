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
# 颜色。优先问 terminfo，问不到就回落到硬编码 ANSI。
#
# 不能只依赖 tput：SSH 会把客户端的 TERM 原样带到服务器，而服务器的
# terminfo 数据库未必有那个条目 —— 比如 Ghostty 默认 TERM=xterm-ghostty，
# 多数服务器的 ncurses 里没有，tput 全部失败，界面就变成无色的。
# 而我们只用最基础的 SGR（30-37 / 1 / 2 / 7 / 0），任何 ANSI 终端都支持。
C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_DIM='' C_BOLD='' C_REV='' C_RESET=''
ui_init_colors() {
    # 非 tty、dumb 终端、或设了 NO_COLOR 就一律无色。
    # 判断 fd 2 而不是 1 —— 界面画在 stderr 上
    if [ ! -t 2 ] || [ "${TERM:-dumb}" = dumb ] || [ -n "${NO_COLOR:-}" ]; then
        return 0
    fi
    _cap() { # $1=回落用的裸 ANSI，其余参数原样传给 tput
        local fb="$1"
        shift
        local v
        v=$(tput "$@" 2>/dev/null)
        [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$fb"
    }
    C_RED=$(_cap $'\e[31m' setaf 1)
    C_GREEN=$(_cap $'\e[32m' setaf 2)
    C_YELLOW=$(_cap $'\e[33m' setaf 3)
    C_CYAN=$(_cap $'\e[36m' setaf 6)
    C_DIM=$(_cap $'\e[2m' dim)
    C_BOLD=$(_cap $'\e[1m' bold)
    C_REV=$(_cap $'\e[7m' rev)
    C_RESET=$(_cap $'\e[0m' sgr0)
    unset -f _cap
}

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

# ============================================================ L0 格式化
# 秒数格式化成 3d 4h / 2h 14m / 5m / 12s
fmt_dur() {
    local t=$1
    if [ "$t" -ge 86400 ]; then printf '%dd %dh\n' $((t / 86400)) $((t % 86400 / 3600))
    elif [ "$t" -ge 3600 ]; then printf '%dh %dm\n' $((t / 3600)) $((t % 3600 / 60))
    elif [ "$t" -ge 60 ]; then printf '%dm\n' $((t / 60))
    else printf '%ds\n' "$t"; fi
}

# 字节数转人类可读
fmt_size() {
    local b=$1
    if [ "$b" -ge 1073741824 ]; then awk -v b="$b" 'BEGIN{printf "%.1fG", b/1073741824}'
    elif [ "$b" -ge 1048576 ]; then awk -v b="$b" 'BEGIN{printf "%.1fM", b/1048576}'
    elif [ "$b" -ge 1024 ]; then awk -v b="$b" 'BEGIN{printf "%.1fK", b/1024}'
    else printf '%dB' "$b"; fi
}

# ============================================================ L0 界面原语
#
# 画框的两个坑，都必须靠「纯文本算宽度、带色版本打印」来绕：
#   1. 颜色转义序列会被 ${#str} 算进长度，直接拿带色字符串算 padding 必歪
#   2. 中文是双宽字符，${#str} 数的是字符数不是列数 —— 所以界面一律用英文
UI_W=58
UI_IN=$((UI_W - 2))
UI_BODY=8 # 当前视图的 body 行数，由各视图在绘制前设定。
# 固定行数是为了重绘时框不抖；不同视图行数不同，靠 ui_redraw 的 \e[J 清残留

# 符号集。Unicode 一档更好看，但两种场景必须降级成纯 ASCII：
#   TERM=linux  物理控制台没有 Unicode 字体
#   非 UTF-8 locale
# 另外 SBS_ASCII=1 可手动强制。
# 注：制表符 ─ │ ╭ 等是「东亚歧义宽度」，终端若把歧义当双宽，框会烂；
# 而 ✓ (U+2713) / ✗ (U+2717) 是 Neutral，恒占 1 列，比框线本身更安全。
# 选中标记用 ➤ (U+27A4)：Neutral 宽度且不在 emoji 集里。看着更像样的
# ▶ (U+25B6) 反而是最差的选择 —— 它既是歧义宽度，又带 Emoji=Yes 属性，
# 部分终端会给它 emoji 呈现，直接变成彩色双宽方块把框撑破。
ui_init_charset() {
    local ascii=0
    [ -n "${SBS_ASCII:-}" ] && ascii=1
    [ "${TERM:-}" = linux ] && ascii=1
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]*8* | *[Uu][Tt][Ff]8*) ;; *) ascii=1 ;; esac

    if [ "$ascii" -eq 1 ]; then
        UI_H='-' UI_V='|' UI_TL='+' UI_TR='+' UI_BL='+' UI_BR='+' UI_ML='+' UI_MR='+'
        UI_OK='+' UI_BAD='x' UI_DOT='*' UI_SEL='>'
    else
        UI_H='─' UI_V='│' UI_TL='╭' UI_TR='╮' UI_BL='╰' UI_BR='╯' UI_ML='├' UI_MR='┤'
        UI_OK='✓' UI_BAD='✗' UI_DOT='●' UI_SEL='➤'
    fi
    UI_SPIN=('|' '/' '-' $'\\')
}

# 终端控制
UI_HIDE=$'\e[?25l'
UI_SHOW=$'\e[?25h'
UI_HOME=$'\e[H'
UI_CLS=$'\e[2J\e[H'
UI_SYNC_ON=$'\e[?2026h'  # 同步输出：终端攒够一帧再显示，不支持的会忽略
UI_SYNC_OFF=$'\e[?2026l'

# 帧缓冲。整帧攒好一次写出 —— 逐行写会让终端边收边画，走 SSH 尤其明显
UI_BUF=""
ui_reset() { UI_BUF=""; }
ui_add() { UI_BUF+="$1"$'\n'; }

# ── 绘制原语。一律写入帧缓冲，由 ui_out / ui_redraw 统一输出 ──
ui_bar() {
    local n=$1
    local t
    printf -v t '%*s' "$n" ''
    printf '%s' "${t// /$UI_H}"
}
ui_top() { ui_add "$(printf '%s%s%s' "$UI_TL" "$(ui_bar $UI_IN)" "$UI_TR")"; }
ui_bot() { ui_add "$(printf '%s%s%s' "$UI_BL" "$(ui_bar $UI_IN)" "$UI_BR")"; }
ui_sep() { ui_add "$(printf '%s%s%s' "$UI_ML" "$(ui_bar $UI_IN)" "$UI_MR")"; }
ui_blank() { ui_add "$(printf '%s%*s%s' "$UI_V" "$UI_IN" '' "$UI_V")"; }

# 一行左右两段。$1/$2 是纯文本（只用来算 padding），$3/$4 是带色版本（负责显示）。
# 必须分开：颜色转义序列会被 ${#str} 算进长度，拿带色串算 padding 必歪。
ui_lr() {
    local pad=$((UI_IN - ${#1} - ${#2}))
    [ "$pad" -lt 0 ] && pad=0
    ui_add "$(printf '%s%s%*s%s%s' "$UI_V" "${3:-$1}" "$pad" '' "${4:-$2}" "$UI_V")"
}

# 分区标题嵌在边线上：├─ service ────┤
ui_sec() {
    local t="$1"
    local lc="${2:-$UI_ML}"
    local rc="${3:-$UI_MR}"
    local n=$((UI_IN - ${#t} - 3))
    [ "$n" -lt 0 ] && n=0
    ui_add "$(printf '%s%s %s%s%s %s%s' "$lc" "$UI_H" "$C_DIM" "$t" "$C_RESET" "$(ui_bar $n)" "$rc")"
}

# 键值行，键固定 10 列并置灰
ui_kv() {
    local plain colored
    printf -v plain '  %-10s%s' "$1" "$2"
    printf -v colored '  %s%-10s%s%s' "$C_DIM" "$1" "$C_RESET" "${4:-$2}"
    ui_lr "$plain" "$3" "$colored" "${5:-$3}"
}

# 值太长时截断，保证不撑破框
ui_fit() {
    local t="$1"
    local n="$2"
    if [ "${#t}" -le "$n" ]; then printf '%s' "$t"; else printf '%s...' "${t:0:$((n - 3))}"; fi
}

# 一个「键 + 标签」单元格。$3 非空时整体置灰，表示该动作当前不可用
_ui_cell() {
    if [ -n "$3" ]; then
        printf '%s%s   %-15s%s' "$3" "$1" "$2" "$C_RESET"
    else
        printf '%s%s%s   %-15s' "$C_CYAN" "$1" "$C_RESET" "$2"
    fi
}

ui_item() {
    local plain colored
    printf -v plain '    %s   %-15s  %s   %-15s' "$1" "$2" "$3" "$4"
    printf -v colored '    %s  %s' "$(_ui_cell "$1" "$2" "${5:-}")" "$(_ui_cell "$3" "$4" "${6:-}")"
    ui_lr "$plain" "" "$colored" ""
}

# 步骤行：状态列前置 1 列。$1=状态符 $2=步骤名 $3=细节 $4=右侧 $5=状态色
ui_step() {
    local plain colored
    printf -v plain '  %s  %-10s%s' "$1" "$2" "$3"
    printf -v colored '  %s%s%s  %s%-10s%s%s' "$5" "$1" "$C_RESET" "$C_DIM" "$2" "$C_RESET" "$3"
    ui_lr "$plain" "${4:+$4  }" "$colored" "$C_DIM${4:+$4  }$C_RESET"
}

# body 补齐到固定高度，重绘时框才不跳动
ui_pad() {
    local n=$1
    while [ "$n" -lt "$UI_BODY" ]; do
        ui_blank
        n=$((n + 1))
    done
}

# 一次性输出（status 这类静态面板）
UI_IN_MENU=0
# 菜单里原地重绘，命令行下顺序输出
ui_out() {
    if [ "$UI_IN_MENU" -eq 1 ]; then ui_redraw; else printf '%s\n' "${UI_BUF%$'\n'}"; fi
}
# 动画重绘：光标归位 + 同步输出，不清屏（清屏会闪）。
# 走 stderr —— 这是「画屏幕」不是「输出数据」。若走 stdout，
# key=$(ui_choose ...) 这类命令替换会把整个界面吞进变量，屏幕上什么都不显示。
ui_redraw() {
    # 每行末尾补 \e[K 清到行尾。下载时 eta 会从 "eta 1h 20m" 缩到 "eta 0s"，
    # 行一变短，旧帧右边多出来的字符就原地留着 —— 看起来就是框的右边线旁边
    # 又多一根竖线。\e[J 只清光标之后的整屏，管不到每一行各自的行尾。
    #
    # \e[J 仍然要留：上一帧若更高（任务 8 行 -> 菜单 4 行），多出来的整行
    # 得抹掉，否则会挂在框下面
    local nl=$'\n' k=$'\e[K' buf="${UI_BUF%$'\n'}"
    printf '%s%s%s\e[K\e[J%s' "$UI_SYNC_ON" "$UI_HOME" "${buf//$nl/$k$nl}" "$UI_SYNC_OFF" >&2
}

# ── footer 区 ──
# 菜单永远绘制，footer 随当前活动伸缩：空闲 0 行、有结果 1 行、
# 任务进行中 N 行（步骤列表）、失败 N 行（步骤 + 建议）。
# 没有视图切换，没有模态 —— 这是整个界面唯一会变高的部分。
FOOT_L=() FOOT_R=() FOOT_LC=() FOOT_RC=()
foot_reset() { FOOT_L=() FOOT_R=() FOOT_LC=() FOOT_RC=(); }
foot_add() { # $1=纯左 $2=纯右 $3=带色左 $4=带色右
    FOOT_L+=("$1") FOOT_R+=("${2:-}") FOOT_LC+=("${3:-$1}") FOOT_RC+=("${4:-${2:-}}")
}
foot_rows() { printf '%s' "${#FOOT_L[@]}"; }

# 读一个键，方向键与回车归一化成名字
# 读一个键，结果写进 UI_KEY。刻意不做成 $(ui_read_key) —— 命令替换是子 shell，
# UI_PENDING 回推缓冲存不下来，而且每次按键白搭一个 fork。
UI_KEY='' UI_PENDING='' UI_INPUT='' SUB_URL=''
ui_read_key() {
    local k rest
    if [ -n "$UI_PENDING" ]; then
        k=${UI_PENDING:0:1}
        UI_PENDING=${UI_PENDING:1}
    elif ! IFS= read -rsn1 k 2>/dev/null; then
        UI_KEY=esc
        return
    fi
    case "$k" in
    '')
        UI_KEY=enter
        return
        ;;
    $'\e')
        # 逐字节前探，绝不能一次吞 2 个。原来用 read -rsn2 的写法，连按两次
        # esc 时第二个 esc 会被当成转义序列的一部分吃掉 —— 实测连按 3 下也
        # 只产生 1 个 esc 事件，正是「按了没反应、得按两次」的由来。
        IFS= read -rsn1 -t 0.05 rest 2>/dev/null || {
            UI_KEY=esc
            return
        }
        case "$rest" in
        '[' | O) ;;
        *)
            # 不是转义序列的引导字符，说明这是个裸 esc。多读的那个字节不能
            # 丢，回推给下一次调用
            UI_PENDING="$rest$UI_PENDING"
            UI_KEY=esc
            return
            ;;
        esac
        IFS= read -rsn1 -t 0.05 rest 2>/dev/null || {
            UI_KEY=esc
            return
        }
        case "$rest" in
        A) UI_KEY=up ;;
        B) UI_KEY=down ;;
        C) UI_KEY=right ;;
        D) UI_KEY=left ;;
        *) UI_KEY=esc ;;
        esac
        return
        ;;
    esac
    UI_KEY=$k
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

# ============================================================ L1 现场信息
# tun 设备名与地址，没有则返回 1
tun_info() {
    local out
    out=$(ip -br -4 addr 2>/dev/null | awk '$1 ~ /^tun/ {print $1, $3; exit}')
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
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

# 只取版本号，去掉 "sing-box version " 前缀。菜单与 status 面板共用
kern_version_short() {
    local v
    v=$(kern_version) || return 1
    v=$(printf '%s' "$v" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*') || return 1
    printf '%s\n' "${v%%$'\n'*}"
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
# 解压到临时目录。整包解出来，LICENSE 之类随临时目录一起删
kern_extract() { # $1=stage $2=tarball
    tar --strip-components=1 -xzf "$2" -C "$1" || return 1
    [ -f "$1/sing-box" ] || return 1
    chmod +x "$1/sing-box"
}

# 顶替前自检：架构选错、libc 不匹配、包损坏都在这一步暴露
kern_selfcheck() { # $1=stage，成功时 echo 版本行
    local out
    out=$("$1/sing-box" version 2>&1) || {
        printf '%s\n' "${out%%$'\n'*}"
        return 1
    }
    printf '%s\n' "${out%%$'\n'*}"
}

# 同盘改名顶替。GNU tar 是「先 unlink 再新建」，直接往最终位置解压的话，
# 解压一开始旧二进制就没了，中途失败就两头空。所以先在临时目录里做完再换。
kern_replace() { # $1=stage
    mv -f "$1/sing-box" "$SBS_BIN"
}

kern_stage_new() {
    local d="$SBS_WORK_DIR/.stage.$$"
    rm -rf "$d"
    mkdir -p "$d" || return 1
    printf '%s\n' "$d"
}

# 非交互路径（CLI / 非 tty）。交互路径见 task_install_kernel
kern_install() { # $1=下载地址
    local url="$1" stage tarball selfcheck
    stage=$(kern_stage_new) || {
        core_error "无法创建临时目录"
        return 1
    }
    tarball="$stage/sing-box.tar.gz"

    core_info "downloading sing-box."
    sb_fetch "$tarball" "$url" || { rm -rf "$stage"; return 1; }
    kern_extract "$stage" "$tarball" || {
        core_error "解压失败或包内没有 sing-box"
        rm -rf "$stage"
        return 1
    }
    selfcheck=$(kern_selfcheck "$stage") || {
        core_error "新二进制无法运行，保留原有版本。输出：$selfcheck"
        rm -rf "$stage"
        return 1
    }
    core_info "self-check ok: $selfcheck"
    kern_replace "$stage" || {
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

# 配置里有几个真正的出站节点（排除 direct/block 与分组类）
# 数任意配置文件里的节点
cfg_node_count_of() {
    [ -f "$1" ] || return 1
    jq '[.outbounds[]? | select(.type != "direct" and .type != "block" and .type != "selector" and .type != "urltest")] | length' \
        "$1" 2>/dev/null
}

cfg_node_count() {
    [ -f "$SBS_CONFIG" ] || return 1
    jq '[.outbounds[]? | select(.type != "direct" and .type != "block" and .type != "selector" and .type != "urltest")] | length' \
        "$SBS_CONFIG" 2>/dev/null
}

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

# 拉订阅到临时文件。订阅地址是用户自己的服务，不走反代
cfg_download() { # $1=url $2=目标临时文件
    curl -fL --connect-timeout 5 --max-time 60 --retry 2 -s -o "$2" "$1"
}

# 校验一份配置文件；不合法时把 sing-box 的原始输出打到 stdout
cfg_validate() { # $1=文件
    [ -x "$SBS_BIN" ] || return 0 # 内核没装就跳过校验
    local out
    out=$("$SBS_BIN" check -c "$1" 2>&1)
    [ -z "$out" ] && return 0
    printf '%s\n' "$out"
    return 1
}

# 落盘并留备份。返回 0 且 stdout 为 backup 时表示有旧版可回退
cfg_commit() { # $1=临时文件
    local backup="$SBS_CONFIG.backup"
    if [ -f "$SBS_CONFIG" ]; then
        cp -f "$SBS_CONFIG" "$backup" && printf 'backup\n'
    fi
    mv -f "$1" "$SBS_CONFIG"
}

# 非交互路径（CLI / 非 tty）
cfg_fetch() { # $1=订阅地址
    local url="$1" tmp="$SBS_WORK_DIR/.config.$$.json" out had
    core_info "fetching config.json"
    if ! cfg_download "$url" "$tmp"; then
        core_error "订阅拉取失败，原配置未动"
        rm -f "$tmp"
        return 1
    fi
    if ! out=$(cfg_validate "$tmp"); then
        core_error "拉到的配置不合法，原配置未动"
        printf '%s\n' "$out" >&2
        rm -f "$tmp"
        return 1
    fi
    had=$(cfg_commit "$tmp") || {
        core_error "写入配置失败"
        rm -f "$tmp"
        return 1
    }
    if [ "$had" = backup ]; then
        core_info "config.json 已更新（上一版备份在 $SBS_CONFIG.backup）"
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

svc_is_active() { systemctl is-active --quiet "$SBS_UNIT_NAME"; }

# /proc/uptime 转微秒，纯 bash 不 fork（原来这里要起一个 awk）
now_mono_us() {
    local up rest f
    read -r up rest </proc/uptime || return 1
    f="${up#*.}000000"
    printf '%s' $((${up%%.*} * 1000000 + 10#${f:0:6}))
}

# header 每次重画都要服务状态，原先分成 is-active + is-failed + show NRestarts
# + uptime(3 个 fork) 共 5 次 systemctl。这里一次 show 全取回来放进全局。
SVC_STATE=inactive SVC_NRESTARTS=0 SVC_UPTIME_S=-1
svc_snapshot() {
    local k v mono=0
    SVC_STATE=inactive SVC_NRESTARTS=0 SVC_UPTIME_S=-1
    while IFS='=' read -r k v; do
        case "$k" in
        ActiveState) SVC_STATE="$v" ;;
        NRestarts) SVC_NRESTARTS="$v" ;;
        ActiveEnterTimestampMonotonic) mono="$v" ;;
        esac
    done < <(systemctl show "$SBS_UNIT_NAME" \
        -p ActiveState -p NRestarts -p ActiveEnterTimestampMonotonic 2>/dev/null)
    if [ "$SVC_STATE" = active ] && [ "${mono:-0}" -gt 0 ] 2>/dev/null; then
        SVC_UPTIME_S=$((($(now_mono_us) - mono) / 1000000))
    fi
}

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

# 进入 / 退出全屏界面会话。命令行直接调 install 时也要用
ui_session_begin() {
    UI_IN_MENU=1
    printf '%s%s' "$UI_CLS" "$UI_HIDE" >&2
    trap 'UI_IN_MENU=0; printf "%s" "$UI_SHOW" >&2' EXIT INT TERM
}
ui_session_end() {
    UI_IN_MENU=0
    printf '%s%s' "$UI_SHOW" "$UI_CLS" >&2
    trap - EXIT INT TERM
}

cmd_install() {
    # tty 下走任务视图；管道 / 脚本里退回朴素输出
    if [ -t 0 ] && [ -t 1 ] && [ "$UI_IN_MENU" -eq 0 ]; then
        local rc
        ui_session_begin
        menu_kernel_flow && task_update_config
        rc=$?
        ui_session_end
        return "$rc"
    fi
    _cmd_install_plain
}

_cmd_install_plain() {
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
    else
        core_error "启动失败，看日志: journalctl -u $SBS_UNIT_NAME -n 30 --output cat"
        return 1
    fi
}

# 不检查配置：停服务和配置对不对无关。恰恰是配置坏了的时候最需要停得下来
cmd_stop() {
    if svc_stop; then
        core_info "sing-box stopped"
    else
        core_error "停止失败"
        return 1
    fi
}

cmd_restart() {
    cfg_check || return 1
    if svc_restart; then
        core_info "sing-box restarted"
    else
        core_error "重启失败，看日志: journalctl -u $SBS_UNIT_NAME -n 30 --output cat"
        return 1
    fi
}

# 同样不检查配置：状态该如实显示，不该因为配置无效就拒绝回答。
# 面板宽度不够时退回 systemctl 原始输出。
# 命令行下的 sbs status：就是菜单那个框，body 空着
cmd_status() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    if [ "$cols" -lt "$UI_W" ]; then
        svc_status
        return 0
    fi
    UI_BODY=0 # 命令行下的 status 就是 header，不留空 body
    ui_reset
    ui_menu_header
    ui_bot
    ui_out
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

# ============================================================ L4 任务视图
#
# 一个任务 = 若干步骤。每步有状态（pending / running / ok / fail）、细节、右侧信息。
# 画在与菜单同一个框里：header 三行不变，只有 body 换成步骤列表。
#
# 成功 -> 自动回菜单，结果留在菜单底部
# 失败 -> 停在失败那一步，附一句「下一步怎么办」，等按键

TASK_TITLE=""
TASK_SUB=""
TASK_NAMES=()
TASK_STATE=()
TASK_DETAIL=()
TASK_RIGHT=()
TASK_HINT=()   # 失败时的说明行
TASK_CUR=-1
TASK_TICK=0

task_begin() {
    TASK_TITLE="$1"
    TASK_SUB="${2:-}"
    TASK_NAMES=()
    TASK_STATE=()
    TASK_DETAIL=()
    TASK_RIGHT=()
    TASK_HINT=()
    TASK_CUR=-1
    TASK_TICK=0
    shift 2 2>/dev/null || shift $#
    local n
    for n in "$@"; do
        TASK_NAMES+=("$n")
        TASK_STATE+=(pending)
        TASK_DETAIL+=("")
        TASK_RIGHT+=("")
    done
}

# 进入第 N 步（0 起）
task_step() {
    TASK_CUR=$1
    TASK_STATE[$1]=running
    [ -n "${2:-}" ] && TASK_DETAIL[$1]="$2"
    task_draw
}
task_detail() { [ "$TASK_CUR" -ge 0 ] && TASK_DETAIL[$TASK_CUR]="$1"; task_draw; }
task_ok() {
    [ "$TASK_CUR" -ge 0 ] || return 0
    TASK_STATE[$TASK_CUR]=ok
    [ $# -ge 1 ] && TASK_DETAIL[$TASK_CUR]="$1"
    # 总是覆盖（含置空）：下载轮询会往右侧写速率/eta，完成后必须清掉
    TASK_RIGHT[$TASK_CUR]="${2:-}"
    task_draw
}
task_fail() {
    [ "$TASK_CUR" -ge 0 ] && TASK_STATE[$TASK_CUR]=fail
    [ "$TASK_CUR" -ge 0 ] && TASK_RIGHT[$TASK_CUR]="" # 清掉上一次轮询留下的速率/eta
    [ -n "${1:-}" ] && TASK_DETAIL[$TASK_CUR]="$1"
    TASK_HINT=("${@:2}")
    task_draw
}

# 非阻塞探一个键。按下 esc 返回 0，用于中断正在跑的任务
ui_esc_pressed() {
    local k rest
    read -rsn1 -t 0.001 k 2>/dev/null || return 1
    [ "$k" = $'\e' ] || return 1
    # 方向键、功能键也都以 \e 开头。后面还跟着字节就是转义序列而不是取消，
    # 顺手把余下的字节读掉免得漏进下一次探测 —— 否则下载时手滑按个方向键，
    # 任务直接就没了（实测确实会）
    read -rsn2 -t 0.05 rest 2>/dev/null && return 1
    [ -z "$rest" ]
}

# 后台跑一条命令，同时让 spinner 转起来。返回 130 表示用户按 esc 取消
task_wait() { # $1=pid
    local pid=$1
    while kill -0 "$pid" 2>/dev/null; do
        if ui_esc_pressed; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 130
        fi
        TASK_TICK=$((TASK_TICK + 1))
        task_draw
        sleep 0.12
    done
    wait "$pid"
}

# 把步骤列表塞进 footer 区，然后让菜单整体重绘。
# 任务视图不再是「另一个界面」—— 菜单始终在上面，步骤长在下面。
task_draw() {
    local i st sym color
    foot_reset
    for i in "${!TASK_NAMES[@]}"; do
        st="${TASK_STATE[$i]}"
        case "$st" in
        ok) sym="$UI_OK" color="$C_GREEN" ;;
        fail) sym="$UI_BAD" color="$C_RED" ;;
        skip) sym="$UI_BAD" color="$C_YELLOW" ;;
        running)
            sym="${UI_SPIN[$((TASK_TICK % 4))]}"
            color="$C_CYAN"
            ;;
        *) sym=" " color="$C_DIM" ;;
        esac
        foot_add \
            "  $sym  $(printf '%-10s' "${TASK_NAMES[$i]}")${TASK_DETAIL[$i]}" \
            "${TASK_RIGHT[$i]:+${TASK_RIGHT[$i]}  }" \
            "  $color$sym$C_RESET  $C_DIM$(printf '%-10s' "${TASK_NAMES[$i]}")$C_RESET${TASK_DETAIL[$i]}" \
            "$C_DIM${TASK_RIGHT[$i]:+${TASK_RIGHT[$i]}  }$C_RESET"
    done
    if [ "${#TASK_HINT[@]}" -gt 0 ]; then
        foot_add "" ""
        local h
        for h in "${TASK_HINT[@]}"; do
            foot_add "  $h" "" "$C_DIM  $h$C_RESET" ""
        done
    fi
    cli_menu_draw
}


# ── 带真进度的下载 ──
#
# curl 自己的进度条格式我们控制不了，会打断框内排版。改成：curl 丢后台静默下载，
# 前台轮询目标文件已写入的字节数，对比 Content-Length 自己画条。
# 顺带白拿速率与 eta —— 这两个 curl 的进度条也给不了。
#
# 拿不到 Content-Length 时退化为「只显示已下载量 + 速率」，不画百分比。

dl_content_length() { # $1=url
    curl -sIL --connect-timeout 5 --max-time 20 "$1" 2>/dev/null |
        tr -d '\r' | awk 'tolower($1)=="content-length:"{n=$2} END{print n+0}'
}

# $1=目标文件 $2=完整 URL $3=步骤下标
dl_with_progress() {
    local dst="$1" url="$2" idx="$3"
    local total now prev=0 t0 elapsed spd pct eta bar f
    # 进度条列宽。左半边 = 2+符号+2+名字10 + 条 + " nnn%" = 20+w，
    # 右半边最长 "12.3M/s  eta 23h 59m" 20 字再加 2 字尾距。框内只有 56，
    # 所以 w=16 配合下面对右半边 18 字的封顶才刚好放得下
    local w=16
    total=$(dl_content_length "$url")
    t0=$(date +%s)

    curl -fL --connect-timeout 5 --retry 2 -s -o "$dst" "$url" &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        if ui_esc_pressed; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 130
        fi
        now=$(stat -c %s "$dst" 2>/dev/null || echo 0)
        elapsed=$(($(date +%s) - t0))
        [ "$elapsed" -lt 1 ] && elapsed=1
        spd=$(fmt_size $((now / elapsed)))
        if [ "$total" -gt 0 ]; then
            pct=$((now * 100 / total))
            [ "$pct" -gt 100 ] && pct=100
            f=$((pct * w / 100))
            printf -v bar '%*s' "$f" ''
            bar="${bar// /#}"
            printf -v f '%*s' $((w - f)) ''
            bar="$bar${f// /.}"
            if [ "$now" -gt 0 ] && [ "$now" -lt "$total" ]; then
                eta="eta $(fmt_dur $(((total - now) * elapsed / now)))"
            else eta=""; fi
            TASK_DETAIL[$idx]="$bar $(printf '%3d' $pct)%"
            # 速率快且 eta 长时两者加起来会撑破框。放不下就丢掉 eta ——
            # 真到这一步说明慢到 24MB 要下一天，那时候速率才是要看的
            local r="$spd/s${eta:+  $eta}"
            [ "${#r}" -gt 18 ] && r="$spd/s"
            TASK_RIGHT[$idx]="$r"
        else
            TASK_DETAIL[$idx]="$(fmt_size "$now")"
            TASK_RIGHT[$idx]="$spd/s"
        fi
        TASK_TICK=$((TASK_TICK + 1))
        task_draw
        sleep 0.2
    done
    wait "$pid"
}

# ── 选择视图：在同一个框里做单键选择 ──
# $1=标题 $2..=「键|标签」，返回按下的键
# footer 里的横向选择。方向键切换、回车确认、esc 取消。
# $1=提示 $2..=选项文本，选中的下标写进 UI_CHOICE（-1 表示取消）
ui_choose() {
    local title="$1"
    shift
    local opts=("$@")
    local cur=0 key i lp lc
    local hint="enter ok   esc cancel  "
    # 标题超长会把提示挤出框外。ui_lr 遇到负 padding 只是钳到 0，行照样变长、
    # 框照样破，所以在这里先裁进可用宽度
    title=$(ui_fit "$title" $((UI_IN - ${#hint} - 4)))
    while true; do
        foot_reset
        foot_add "  $title" "$hint" \
            "$C_DIM  $title$C_RESET" \
            "${C_DIM}enter$C_RESET ok   ${C_DIM}esc$C_RESET cancel  "
        # 每个选项前留一格给三角标记，未选中时留空 —— 这样切换时文字不会左右跳
        lp="   " lc="   "
        for i in "${!opts[@]}"; do
            if [ "$i" -eq "$cur" ]; then
                # 三角 + 反色，两者分工不同：
                #   三角是「形状」线索 —— NO_COLOR / dumb 终端 / terminfo 缺条目时
                #     颜色全失效，它是唯一还能指出选中项的东西
                #   反色是「颜色」线索 —— \e[7m 是相对当前主题取反而非固定颜色，
                #     深色浅色主题下都必然是高对比块，比青色之类稳得多
                lp+="$UI_SEL  ${opts[$i]}     "
                lc+="$C_CYAN$UI_SEL$C_RESET $C_REV ${opts[$i]} $C_RESET    "
            else
                lp+="   ${opts[$i]}     "
                lc+="   $C_DIM${opts[$i]}$C_RESET     "
            fi
        done
        foot_add "$lp" "" "$lc" ""
        cli_menu_draw
        ui_read_key
        key=$UI_KEY
        case "$key" in
        left | up) cur=$(((cur - 1 + ${#opts[@]}) % ${#opts[@]})) ;;
        right | down) cur=$(((cur + 1) % ${#opts[@]})) ;;
        enter)
            UI_CHOICE=$cur
            foot_reset
            return 0
            ;;
        esc | q)
            UI_CHOICE=-1
            # 提示行是一次性的，必须在这里清掉。cli_menu 的 foot_reset 写在
            # 读键「之后」，所以取消返回主菜单时这两行还留在屏幕上，看着像
            # esc 没生效 —— 于是再按一次，那一次其实只是把残留清掉了。
            # 「按两次 esc 才有用」就是这么来的。
            foot_reset
            foot_add "  cancelled" "" "$C_DIM  cancelled$C_RESET" ""
            return 1
            ;;
        esac
    done
}


# footer 里的单行输入，结果写 UI_INPUT，esc 取消返回 1。
# 不用 read -e：readline 把 ESC 当作 meta 前缀吞掉再等下一个键，esc 根本
# 不可能中断读取（试过 inputrc 里绑 "\e": abort 也没用，它只是丢掉行然后
# 接着等）。更糟的是连按几次 esc 之后，回车会被当成 M-RET 一并吃掉，人就
# 卡在输入框里出不来了。
ui_input() { # $1=标题 $2=预填值 $3=可选提示，敲第一个键就让位给标题
    local title="$1" val="$2" note="${3:-}" disp k
    while true; do
        foot_reset
        foot_add "  ${note:-$title}" "enter ok   esc cancel  " \
            "$C_DIM  ${note:-$title}$C_RESET" "${C_DIM}enter$C_RESET ok   ${C_DIM}esc$C_RESET cancel  "
        # 地址通常比框还长，看尾巴 —— 那才是正在敲的一头
        disp="$val"
        [ "${#disp}" -gt 50 ] && disp="...${val: -47}"
        # 行尾那个反色空格是光标，纯文本版对应补一个空格好让宽度算得准
        foot_add "  > $disp " "" "  $C_CYAN>$C_RESET $disp$C_REV $C_RESET" ""
        cli_menu_draw

        ui_read_key
        case "$UI_KEY" in
        enter)
            UI_INPUT="$val"
            foot_reset
            return 0
            ;;
        esc)
            foot_reset
            foot_add "  cancelled" "" "$C_DIM  cancelled$C_RESET" ""
            return 1
            ;;
        left | right | up | down) continue ;;
        $'\177' | $'\b') val="${val%?}" ;;
        $'\025') val="" ;; # Ctrl-U 清空
        *) val="$val$UI_KEY" ;;
        esac
        note="" # 动过就别再挂着上一轮的抱怨

        # 粘贴时几十个字节是连着到的。一个字节重画一帧要 ~50ms，一条订阅
        # 地址就能卡两三秒。先把已经排队的字节一次吃干净，再画下一帧。
        while IFS= read -rsn1 -t 0.002 k 2>/dev/null; do
            case "$k" in
            '')
                UI_INPUT="$val"
                foot_reset
                return 0
                ;;
            $'\e')
                UI_PENDING="$k$UI_PENDING" # 交回主循环去做转义序列判定
                break
                ;;
            $'\177' | $'\b') val="${val%?}" ;;
            $'\025') val="" ;;
            *) val="$val$k" ;;
            esac
        done
    done
}

# ── 瞬时动作：成功就地反馈（不离开菜单），失败才进任务视图停住 ──
# 瞬时动作。成功在 footer 留一行，失败留两行（原因 + 去哪看日志）
menu_quick() { # $1=动作函数 $2=成功文案 $3=动作名
    local out rc first
    out=$("$1" 2>&1)
    rc=$?
    foot_reset
    if [ "$rc" -eq 0 ]; then
        foot_add "  $2" "" "$C_GREEN  $2$C_RESET" ""
        return 0
    fi
    first=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -viE '^\[info\]|^$' | head -n 1)
    foot_add "  $3 failed" "" "$C_RED  $3 failed$C_RESET" ""
    foot_add "  $(ui_fit "${first:-something went wrong}" 52)" "" \
        "$C_DIM  $(ui_fit "${first:-something went wrong}" 52)$C_RESET" ""
    return 1
}

# ── 订阅地址：沿用现有 / 输入新的 ──
# 订阅地址：有旧值先问要不要沿用，要新的就在 footer 里输入
menu_resolve_sub() {
    local cur host note=""
    cur=$(cfg_url_get 2>/dev/null) || cur=""
    if [ -n "$cur" ]; then
        # 这点宽度别浪费在 https:// 和 query 上，主机名才认得出是哪个订阅
        host="${cur#*://}"
        host="${host%%/*}"
        ui_choose "subscription  $host" "keep it" "enter a new one" || return 1
        [ "$UI_CHOICE" -eq 0 ] && {
            SUB_URL="$cur"
            return 0
        }
    fi

    while true; do
        ui_input "subscription url" "$cur" "$note" || return 1
        cfg_url_valid "$UI_INPUT" && break
        # 不合法就地重问。原来是静默退回菜单，看着又像按键没反应
        cur="$UI_INPUT"
        note="url must start with http://"
    done
    SUB_URL="$UI_INPUT"
}


# ── 任务：更新订阅配置 ──
task_update_config() {
    local sub tmp out had
    menu_resolve_sub || return 0 # 取消不算失败
    sub="$SUB_URL"
    task_begin "update config" "" fetch validate save
    tmp="$SBS_WORK_DIR/.config.$$.json"

    task_step 0 "$(ui_fit "$sub" 38)"
    (cfg_download "$sub" "$tmp") &
    task_wait $!
    case $? in
    0) ;;
    130)
        rm -f "$tmp"
        return 130
        ;;
    *)
        task_fail "download failed" "cannot fetch the subscription - config unchanged" \
            "check the URL and the network"
        rm -f "$tmp"
        return 1
        ;;
    esac
    task_ok "$(fmt_size "$(stat -c %s "$tmp" 2>/dev/null || echo 0)")" ""

    task_step 1
    if ! out=$(cfg_validate "$tmp"); then
        task_fail "invalid" "the fetched config does not pass sing-box check" \
            "$(ui_fit "$(printf '%s' "$out" | head -n 1)" 52)" "config unchanged"
        rm -f "$tmp"
        return 1
    fi
    task_ok "$(cfg_node_count_of "$tmp") nodes" ""

    task_step 2
    had=$(cfg_commit "$tmp") || {
        task_fail "write failed" "cannot write $SBS_CONFIG" "check permissions"
        rm -f "$tmp"
        return 1
    }
    task_ok "${had:+backup kept}" ""
    # 步骤全绿本身就是结果，不再另起一行。只在需要重启才生效时补一句
    svc_is_active && {
        TASK_HINT=("restart to apply the new config")
        task_draw
    }
    return 0
}

# ── 任务：更新脚本自身 ──
task_update_self() {
    local tmpdir stage base ok=0
    task_begin "update sbs" "" fetch check install
    tmpdir=$(mktemp -d) || {
        task_step 0
        task_fail "no temp dir" "cannot create a temp directory"
        return 1
    }
    stage="$(dirname "$SBS_EXEC")/.$(basename "$SBS_EXEC").$$.tmp"

    task_step 0
    for base in $(src_script | awk '!seen[$0]++'); do
        TASK_DETAIL[0]="$(ui_fit "${base#https://}" 40)"
        task_draw
        if curl -fsSL --connect-timeout 5 --retry 2 -o "$tmpdir/sbs.sh" "$base/sbs.sh"; then
            ok=1
            break
        fi
    done
    if [ "$ok" -ne 1 ]; then
        task_fail "all sources failed" "cannot fetch sbs.sh from any source" \
            "" "  SBS_MIRROR=<base-url> sbs update sbs"
        rm -rf "$tmpdir"
        return 1
    fi
    task_ok "$(fmt_size "$(stat -c %s "$tmpdir/sbs.sh" 2>/dev/null || echo 0)")" ""

    task_step 1
    if ! bash -n "$tmpdir/sbs.sh" 2>/dev/null; then
        task_fail "syntax error" "the downloaded script does not parse - keeping the old one"
        rm -rf "$tmpdir"
        return 1
    fi
    task_ok "syntax ok" ""

    # 本脚本就是 $SBS_EXEC，而 bash 边读边执行、按字节偏移续读。
    # 就地覆盖会让它从新内容的行中间接上，把两个版本串起来跑，所以必须改名顶替。
    task_step 2
    if ! sudo cp "$tmpdir/sbs.sh" "$stage" || ! sudo chmod 755 "$stage" || ! sudo mv -f "$stage" "$SBS_EXEC"; then
        task_fail "install failed" "cannot replace $SBS_EXEC" "check sudo permissions"
        sudo rm -f "$stage" 2>/dev/null
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"
    task_ok "$SBS_EXEC" ""
    TASK_HINT=("run sbs again to load the new version")
    task_draw
    return 0
}

# ── 任务：卸载 ──
# 确认改成框内单键（原来是 read 输入 + 回车，和菜单其余部分不一致）。
# 用 d 而不是 y 做确认键：手滑按到 y 的概率远高于连按两次 d。
menu_remove_flow() {
    # 默认停在 no —— 危险操作不该按一下就走
    ui_choose "remove all?" "no" "yes" || return 1
    [ "$UI_CHOICE" -eq 1 ] || return 1

    task_begin "remove" "" service files script
    task_step 0
    svc_purge
    task_ok "unit disabled and removed" ""
    task_step 1
    sudo rm -rf "$SBS_WORK_DIR"
    task_ok "$SBS_WORK_DIR" ""
    # 删掉自己之后本进程仍能跑完 —— bash 攥着已打开的 fd，inode 还活着
    task_step 2
    sudo rm -f "$SBS_EXEC"
    task_ok "$SBS_EXEC" ""
    return 0
}

# ── 菜单里的「装/更新内核」完整流程 ──
menu_kernel_flow() {
    local tags stable beta tag url tmp
    core_detect_target >/dev/null 2>&1 || {
        task_begin "update kernel" "" resolve
        task_step 0
        task_fail "unsupported arch" "unsupported architecture: $(uname -m)"
        return 1
    }

    # 解析版本，spinner 转起来
    task_begin "update kernel" "" resolve
    task_step 0 "querying release tags"
    tmp=$(mktemp) || return 1
    (gh_resolve_tags >"$tmp" 2>/dev/null) &
    task_wait $!
    if [ $? -eq 130 ]; then
        rm -f "$tmp"
        return 130
    fi
    tags=$(cat "$tmp" 2>/dev/null)
    rm -f "$tmp"
    if [ -z "$tags" ]; then
        task_fail "cannot resolve" "cannot fetch the version list" "github.com and jsDelivr are both unreachable"
        return 1
    fi
    stable=$(printf '%s\n' "$tags" | sed -n 1p)
    beta=$(printf '%s\n' "$tags" | sed -n 2p)
    task_ok "stable ${stable#v}    beta ${beta#v}" ""

    if [ -n "$beta" ]; then
        ui_choose "which release?" "stable ${stable#v}" "beta ${beta#v}" || return 130
        [ "$UI_CHOICE" -eq 0 ] && tag="$stable" || tag="$beta"
    else
        ui_choose "which release?" "stable ${stable#v}" || return 130
        tag="$stable"
    fi
    url=$(gh_asset_url "$tag")
    task_install_kernel "$tag" "$url"
}

# ── 任务：装/更新内核。交互路径，走任务视图 ──
# 与 kern_install 共用同一批原语（kern_extract / kern_selfcheck / kern_replace），
# 区别只在于「谁来汇报进度」
task_install_kernel() { # $1=tag $2=下载地址
    local tag="$1" url="$2" stage tarball src full ok=0 selfcheck cur
    cur=$(kern_version_short 2>/dev/null) || cur="none"

    task_begin "update kernel" "$cur -> ${tag#v}" resolve download verify install
    task_step 0 "$SBS_TARGET_SUFFIX"
    task_ok "$SBS_TARGET_SUFFIX" ""

    stage=$(kern_stage_new) || {
        task_step 1
        task_fail "cannot create temp dir" "cannot create temp dir under $SBS_WORK_DIR" "check disk space and permissions"
        return 1
    }
    tarball="$stage/sing-box.tar.gz"

    # 逐个源试，每个源的结局都留在屏上
    task_step 1
    for src in $(src_kernel | awk '!seen[$0]++'); do
        if [ "$src" = direct ]; then full="$url"; else full="$src/$url"; fi
        TASK_DETAIL[1]="$src"
        TASK_RIGHT[1]=""
        task_draw
        dl_with_progress "$tarball" "$full" 1
        case $? in
        0)
            src_remember "$src"
            ok=1
            break
            ;;
        130)
            rm -rf "$stage"
            return 130 # 用户取消，不再试下一个源
            ;;
        esac
        ui_step "$UI_BAD" download "$src" "failed" "$C_YELLOW"
    done
    if [ "$ok" -ne 1 ]; then
        task_fail "all sources unreachable" \
            "all download sources are unreachable" "check the network, or pick a mirror:" "  SBS_PROXY=https://ghfast.top sbs update"
        rm -rf "$stage"
        return 1
    fi
    task_ok "$(fmt_size "$(stat -c %s "$tarball" 2>/dev/null || echo 0)") downloaded" ""

    task_step 2
    if ! kern_extract "$stage" "$tarball"; then
        task_fail "extract failed" "extract failed, or no sing-box binary in the archive" "likely a partial download - retry"
        rm -rf "$stage"
        return 1
    fi
    if ! selfcheck=$(kern_selfcheck "$stage"); then
        task_fail "cannot run" "the new binary does not run - kept the old one" "$selfcheck"
        rm -rf "$stage"
        return 1
    fi
    task_ok "${selfcheck#sing-box version }" ""

    task_step 3
    if ! kern_replace "$stage"; then
        task_fail "replace failed" "replace failed - kept the old one" "check permissions on $SBS_BIN"
        rm -rf "$stage"
        return 1
    fi
    rm -rf "$stage"
    svc_write_unit >/dev/null 2>&1
    task_ok "$SBS_BIN" "$(fmt_size "$(stat -c %s "$SBS_BIN" 2>/dev/null || echo 0)")"
    svc_is_active && {
        TASK_HINT=("restart to run the new kernel")
        task_draw
    }
    return 0
}

# ============================================================ L4 菜单
# header 三行 + 分隔线。菜单和任务视图共用 —— 长任务进行时也能看到服务状态
# sing-box version(53ms) 和 sing-box check(100ms) 占了一次重画 222ms 里的七成，
# 而它们只在内核或配置文件变了之后才会变。拿 mtime:size 当键缓存，一次 stat
# 两个文件只要一个 fork。
HDR_KEY='' HDR_VER='' HDR_CFG=''
hdr_fields() {
    local key
    key=$(stat -c '%Y:%s' "$SBS_BIN" "$SBS_CONFIG" 2>/dev/null | tr '\n' ' ')
    [ "$key" = "$HDR_KEY" ] && return 0
    HDR_KEY="$key"
    HDR_VER=$(kern_version_short 2>/dev/null) || HDR_VER=""
    if [ ! -f "$SBS_CONFIG" ]; then
        HDR_CFG=missing
    elif [ -x "$SBS_BIN" ] && [ -z "$("$SBS_BIN" check -c "$SBS_CONFIG" 2>&1)" ]; then
        HDR_CFG=valid
    else
        HDR_CFG=invalid
    fi
}

ui_menu_header() {
    local state scolor ver tun uptime ip loc age
    local l2p l2c l3p l3c

    case "$SVC_STATE" in
    active)
        state="Running"
        scolor="$C_GREEN"
        ;;
    failed)
        state="Failed"
        scolor="$C_RED"
        ;;
    *)
        state="Stopped"
        scolor="$C_DIM"
        ;;
    esac

    hdr_fields
    ver="${HDR_VER:-not installed}"
    tun=$(tun_info 2>/dev/null | awk '{print $1" "$2}') || tun=""
    uptime=""
    [ "$SVC_UPTIME_S" -ge 0 ] && uptime=$(fmt_dur "$SVC_UPTIME_S")

    ui_top
    local title
    if [ -f "$SBS_BIN" ]; then title="${SBS_BIN/#$HOME/\~}"; else title="sing-box"; fi
    ui_lr "  $title" "$UI_DOT $state${uptime:+  $uptime}  " \
        "$C_BOLD  $title$C_RESET" "$scolor$UI_DOT $state$C_RESET$C_DIM${uptime:+  $uptime}$C_RESET  "

    # 配置是否合法挂在第 2 行右角常驻。这是 header 里唯一需要跑一次
    # sing-box check 的字段（306 节点约几十毫秒），值得 —— 光看 RUNNING
    # 看不出配置已经坏了。
    local valid="$HDR_CFG" vcolor
    case "$valid" in
    missing) vcolor="$C_YELLOW" ;;
    valid) vcolor="$C_GREEN" ;;
    *) vcolor="$C_RED" ;;
    esac
    printf -v l2p '  %s   %s' "$ver" "${tun:-no tun}"
    l2p=$(ui_fit "$l2p" $((UI_IN - ${#valid} - 10)))
    l2c="$C_DIM$l2p$C_RESET"
    ui_lr "$l2p" "config $valid  " "$l2c" "${C_DIM}config$C_RESET $vcolor$valid$C_RESET  "

    if { read -r ip; read -r loc; read -r age; } < <(net_exit_cached) 2>/dev/null && [ -n "${ip:-}" ]; then
        printf -v l3p '  %s  %s' "$ip" "$loc"
        printf -v l3c '%s  %s  %s%s' "$C_DIM" "$ip" "$loc" "$C_RESET"
        local agec="$C_DIM$age$C_RESET"
        [ "$age" = stale ] && agec="$C_YELLOW$age$C_RESET"
        if [ "$UI_REFRESHING" -eq 1 ]; then
            age="refreshing"
            agec="$C_CYAN$age$C_RESET"
        fi
        ui_lr "$l3p" "$age  " "$l3c" "$agec  "
    else
        ui_lr "  no exit ip yet" "" "$C_DIM  no exit ip yet$C_RESET" ""
    fi

    # 第 4 行只在出问题时出现。restarts 常态为 0，常驻显示纯粹是噪音
    if [ "${SVC_NRESTARTS:-0}" -gt 0 ] 2>/dev/null; then
        ui_lr "  restarted $SVC_NRESTARTS times - check the logs" "" \
            "$C_YELLOW  restarted $SVC_NRESTARTS times - check the logs$C_RESET" ""
    fi
}

UI_REFRESHING=0 # f 键刷新出口 IP 期间置 1，让 header 显示 refreshing

cli_menu_draw() {
    UI_BODY=5 # 9 个动作：2 列 4 行 + q 单独一行
    svc_snapshot # 整次重画只查一次服务状态，header 和下面的项都读这份快照
    ui_reset
    ui_menu_header
    ui_sep

    # k 一个键两种含义：没装内核时是 install（内核+unit+订阅一条龙），
    # 装了之后才是 update kernel。全新机器上敲 sbs 必须有路可走。
    local klabel
    if [ -x "$SBS_BIN" ]; then klabel="update kernel"; else klabel="install"; fi

    if [ ! -x "$SBS_BIN" ]; then
        ui_item s start "k" "$klabel" "$C_DIM" ""
        ui_item x stop "c" "update config" "$C_DIM" "$C_DIM"
        ui_item r restart "u" "update sbs" "$C_DIM" ""
        ui_item f refresh "d" remove "" "$C_DIM"
    elif [ "$SVC_STATE" = active ]; then
        ui_item s start "k" "$klabel" "$C_DIM" ""
        ui_item x stop "c" "update config" "" ""
        ui_item r restart "u" "update sbs" "" ""
        ui_item f refresh "d" remove "" ""
    else
        ui_item s start "k" "$klabel" "" ""
        ui_item x stop "c" "update config" "$C_DIM" ""
        ui_item r restart "u" "update sbs" "$C_DIM" ""
        ui_item f refresh "d" remove "" ""
    fi
    ui_item q quit "" "" "" ""
    ui_pad 5

    # footer 区：有内容才画分隔线
    local i
    if [ "${#FOOT_L[@]}" -gt 0 ]; then
        ui_sep
        for i in "${!FOOT_L[@]}"; do
            ui_lr "${FOOT_L[$i]}" "${FOOT_R[$i]}" "${FOOT_LC[$i]}" "${FOOT_RC[$i]}"
        done
    fi
    ui_bot
    ui_redraw
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
    # 无论怎么退出（正常 / Ctrl-C / 报错）都要把光标恢复出来
    ui_session_begin
    while true; do
        cli_menu_draw
        ui_read_key
        key=$UI_KEY
        # 上一个动作的结果显示到下次按键为止
        foot_reset
        case "$key" in
        s) menu_quick cmd_start "started" "start" ;;
        x) menu_quick cmd_stop "stopped" "stop" ;;
        r) menu_quick cmd_restart "restarted" "restart" ;;
        k)
            if [ -x "$SBS_BIN" ]; then
                menu_kernel_flow
            else
                menu_kernel_flow && task_update_config
            fi
            ;;
        c) task_update_config ;;
        u)
            if task_update_self; then
                ui_session_end
                core_info "sbs 已更新，重新运行以加载新版本"
                return 0
            fi
            ;;
        d)
            if menu_remove_flow; then
                ui_session_end
                return 0
            fi
            ;;
        f)
            foot_reset
            foot_add "  refreshing" "" "$C_CYAN  ${UI_SPIN[0]}$C_RESET  ${C_DIM}refreshing$C_RESET" ""
            cli_menu_draw
            foot_reset
            if net_exit_refresh; then
                foot_add "  refreshed" "" "$C_GREEN  refreshed$C_RESET" ""
            else
                foot_add "  exit ip unavailable" "" "$C_YELLOW  exit ip unavailable$C_RESET" ""
            fi
            ;;
        q)
            ui_session_end
            return 0
            ;;
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
  sbs status          查看状态
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
    ui_init_colors
    ui_init_charset
    core_check_deps || exit 1
    core_ensure_workdir || die "无法创建 $SBS_WORK_DIR"
    cli_dispatch "$@"
}

main "$@"
