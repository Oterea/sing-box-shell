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

# 四个都写 stderr。这是「返回值走 stdout」那条约定必须配套的另一半 ——
# 上层用 $(...) 捕获下层返回值时，任何写到 stdout 的提示文字都会混进返回值里。
core_info() { printf '%s\n' "${C_GREEN}[info]:${C_RESET} $*" >&2; }
core_warn() { printf '%s\n' "${C_YELLOW}[warn]:${C_RESET} $*" >&2; }
core_error() { printf '%s\n' "${C_RED}[error]:${C_RESET} $*" >&2; }
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

# ============================================================ L0 界面原语：帧缓冲与行渲染
#
# 画框的两个坑，都必须靠「纯文本算宽度、带色版本打印」来绕：
#   1. 颜色转义序列会被 ${#str} 算进长度，直接拿带色字符串算 padding 必歪
#   2. 中文是双宽字符，${#str} 数的是字符数不是列数 —— 所以界面一律用英文
UI_W=58
UI_IN=$((UI_W - 2))
# 两种提示框（ui_choose 选项、ui_input 输入）共用的按键提示。写成常量是因为
# 标题要按它的宽度来裁 —— 两边各写一份字面量，就会像之前那样只有一处记得裁，
# 另一处靠 ui_lr 兜底截断，那会掉色而且和提示挤在一起没间距
UI_HINT="enter ok   esc cancel  "
UI_HINT_C='' # 带色版，颜色初始化之后才能拼（见 ui_init_charset）
UI_BODY=8 # 当前视图的 body 行数，由各视图在绘制前设定。
# 固定行数是为了重绘时框不抖；不同视图行数不同，靠 ui_redraw 的 \e[J 清残留

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

    # 整行的横线和空白：每帧要画四五次，现拼就是每帧多几次 fork
    printf -v UI_HBAR '%*s' "$UI_IN" ''
    UI_HBAR="${UI_HBAR// /$UI_H}"
    printf -v UI_SPACES '%*s' "$UI_IN" ''
    UI_HINT_C="${C_DIM}enter$C_RESET ok   ${C_DIM}esc$C_RESET cancel  "
    ui_build_logo
}

# 大写 SBS，紫 -> 粉 -> 橙横向渐变。开头拼一次，之后每帧直接用。
# 三档降级：真彩 -> 256 色 -> 无色。真彩看 COLORTERM 而不是 tput ——
# ncurses 只认 terminfo 里声明的色数，而绝大多数终端的 terminfo 只写到 256
# 色深：24=真彩 8=256 色 0=不上色。
# 不能只信 tput —— ssh 不转发 COLORTERM，而服务器上往往没有客户端那套
# terminfo（实测 xterm-ghostty 就没有，tput colors 直接报 unknown terminal），
# 于是真彩终端会被判成无色。所以再按 TERM 的名字认一遍。
ui_color_depth() {
    case "${COLORTERM:-}" in
    truecolor | 24bit)
        printf 24
        return
        ;;
    esac
    case "${TERM:-}" in
    *-direct* | *truecolor* | *ghostty* | *kitty* | alacritty* | wezterm* | contour* | foot* | *-24bit*)
        printf 24
        return
        ;;
    *256color* | *-256*)
        printf 8
        return
        ;;
    esac
    # terminfo 认得且够 256 色就用；认不得（tput 报错）也别退到无色 ——
    # 走到这里说明外面已经判定「该上色」了，近十几年的终端都支持 256
    [ "$(tput colors 2>/dev/null || echo 256)" -ge 256 ] && printf 8 || printf 0
}

UI_ART=(
    '   _____ ____  _____'
    '  / ___// __ )/ ___/'
    '  \__ \/ __  |\__ \ '
    ' ___/ / /_/ /___/ / '
    '/____/_____//____/  '
)

# 拼一帧 logo，结果写 UI_LOGO。$1=相位（0 为静态那帧）。
# 相位让色带横向流动：t 走到头再折返，所以循环起来是无缝的
# $1 = 帧号，不是相位。三条时间轴都从它推导
ui_logo_render() {
    local f=${1:-0} mode row col ch t out='' w=20 den=19
    local band last ri=0 br seg si fr i u oa ob
    local -a SR SG SB
    mode=$(ui_color_depth)
    [ -n "$C_RESET$C_CYAN" ] || mode=0
    if [ "$mode" -eq 0 ]; then
        printf -v UI_LOGO '%s\n' "${UI_ART[@]}"
        UI_LOGO+=$'\n'
        return 0
    fi

    # 这一帧用哪两组色带、渗到几成
    u=$((f * UI_NPAL * 1000 / UI_FRAMES))
    oa=$((u / 1000 * UI_PALSZ))
    ob=$(((u / 1000 + 1) % UI_NPAL * UI_PALSZ))
    u=$((u % 1000))
    # 5 个有效停靠点先算好放进并行数组。原来每个色带都要 set -- 拆一次词，
    # 一帧 50 次 —— 那是渲染里最贵的一处
    i=0
    while [ "$i" -lt "$UI_NSTOP" ]; do
        SR[i]=$((UI_PALS[oa + i * 3] + (UI_PALS[ob + i * 3] - UI_PALS[oa + i * 3]) * u / 1000))
        SG[i]=$((UI_PALS[oa + i * 3 + 1] + (UI_PALS[ob + i * 3 + 1] - UI_PALS[oa + i * 3 + 1]) * u / 1000))
        SB[i]=$((UI_PALS[oa + i * 3 + 2] + (UI_PALS[ob + i * 3 + 2] - UI_PALS[oa + i * 3 + 2]) * u / 1000))
        i=$((i + 1))
    done

    local r g b
    seg=$((UI_NSTOP - 1))
    br=$(((f + UI_BREATH / 2) % UI_BREATH))
    [ "$br" -gt $((UI_BREATH / 2)) ] && br=$((UI_BREATH - br))
    br=$((550 + br * 450 / (UI_BREATH / 2)))
    for row in "${UI_ART[@]}"; do
        col=0 last=-1
        while [ "$col" -lt "$w" ]; do
            ch=${row:col:1}
            band=$((col / 2))
            if [ "$band" -ne "$last" ]; then
                last=$band
                t=$(((band * 2 * 1000 / den + ri * 260) % 2000))
                [ "$t" -gt 1000 ] && t=$((2000 - t))
                si=$((t * seg / 1000))
                [ "$si" -ge "$seg" ] && si=$((seg - 1))
                fr=$((t * seg - si * 1000))
                r=$(((SR[si] + (SR[si + 1] - SR[si]) * fr / 1000) * br / 1000))
                g=$(((SG[si] + (SG[si + 1] - SG[si]) * fr / 1000) * br / 1000))
                b=$(((SB[si] + (SB[si + 1] - SB[si]) * fr / 1000) * br / 1000))
                if [ "$mode" -eq 24 ]; then
                    out+=$'\e[38;2;'"$r;$g;$b"'m'
                else
                    out+=$'\e[38;5;'"$((16 + 36 * (r * 5 / 255) + 6 * (g * 5 / 255) + (b * 5 / 255)))"'m'
                fi
            fi
            out+="$ch"
            col=$((col + 1))
        done
        out+="$C_RESET"$'\n'
        ri=$((ri + 1))
    done
    UI_LOGO="$out"$'\n'
}

# 帧按需拼、拼过就缓存。300 帧一次拼完要 2.4 秒，那是白让人等 ——
# 只有真看到的帧才会被拼，走一圈之后全在缓存里
ui_build_logo() {
    ui_logo_render 0
    UI_LOGO_F=() UI_PHASE=0 UI_ANIM=0
    [ -n "${SBS_NO_ANIM:-}" ] && return 0
    [ "$(ui_color_depth)" -gt 0 ] || return 0
    [ -n "$C_RESET$C_CYAN" ] || return 0
    UI_LOGO_F[0]="$UI_LOGO"
    UI_ANIM=1
}

# 取第 $1 相的帧放进 UI_LOGO_CUR，没拼过就现拼并存下来。
# 不用 $(...) 返回 —— 命令替换既吞掉末尾换行（那行空行就没了），又白搭一次 fork
ui_logo_frame() {
    local i=$1
    if [ -z "${UI_LOGO_F[$i]:-}" ]; then
        ui_logo_render "$i"
        UI_LOGO_F[$i]="$UI_LOGO"
    fi
    UI_LOGO_CUR="${UI_LOGO_F[$i]}"
}

# 推进一相，只重画 logo 那几行。光标回原点画完就停在 logo 下面，
# 下一次整帧重画照样从 \e[H 开始，位置不会错
ui_logo_step() {
    [ "$UI_ANIM" -eq 1 ] || return 0
    [ "$UI_LINES" -ge $((UI_FRAME_MAX + UI_LOGO_ROWS)) ] || return 0
    UI_PHASE=$(((UI_PHASE + 1) % UI_FRAMES))
    ui_logo_frame "$UI_PHASE"
    # 包一层同步刷新：这一千来字节要过 SSH，不圈起来的话终端可能画到一半就
    # 刷出去，看着像色带在往下抹
    printf '%s%s%s%s' "$UI_SYNC_ON" "$UI_HOME" \
        "${UI_LOGO_CUR//$'\n'/$'\e[K\r\n'}" "$UI_SYNC_OFF" >&$UI_FD
}


# 终端控制
UI_HIDE=$'\e[?25l'
UI_SHOW=$'\e[?25h'
UI_HOME=$'\e[H'
UI_CLS=$'\e[2J\e[H'
# 备用屏幕缓冲区。菜单画在自己的一块画布上，不和之前敲的命令、滚动历史共用
# —— 主屏幕上只要有任何东西让它滚一行，\e[H 回的「屏幕顶部」就不再是帧的
# 起点，之后每重画一次错位一点，越积越乱。退出时原样还回去，历史一行不丢。
# 老终端不认这两个序列会直接忽略，不会出乱码。
UI_ALT_ON=$'\e[?1049h'
UI_ALT_OFF=$'\e[?1049l'
# 界面独占一个 fd。信号 trap 可能在别的命令的重定向还生效时被执行 —— 实测
# SIGINT 打断 ui_read_key 里的 `read ... 2>/dev/null` 时，trap 里的 >&2 就写
# 进了 /dev/null，还原备用屏的序列凭空消失，用户停在一块空白画布上。
# 进菜单时复制一份 stderr 到自己的 fd，之后画屏和还原都只认它。
UI_FD=2
# 菜单顶上的 logo：5 行画 + 1 行空，画在框外面。任务视图最高能到 22 行，
# 加上 logo 就是 28 —— 窗口不够高时干脆不画，否则框会被顶出屏幕
UI_LOGO='' UI_LOGO_ROWS=6 UI_FRAME_MAX=22
# 色相动画：开头把每一帧都拼好存起来，之后每拍只是 printf 一个现成的字符串。
# 空闲时只重画 logo 那 5 行，不碰整帧 —— 整帧重画既贵又会打破「面板是快照」
# 那条规矩。SBS_NO_ANIM=1 可以关掉
UI_LOGO_F=() UI_PHASE=0 UI_ANIM=0
# 1 秒一帧。sbs 跑在服务器上，每一帧（约 1000 字节转义序列）都要过 SSH 传到
# 本地，菜单开着就一直在发。剩下的两层动效都很慢，1 fps 足够 —— 1.0 KB/s
UI_ANIM_TICK=1
# 只剩两条时间轴，都在最后一帧同时归零 —— 不同时归零的话循环接回起点会跳。
# 1 秒一帧，270 帧 = 4 分半，九组色带各占 30 秒。
#   呼吸  f % 18        270 / 18 = 15，整除（偏半个周期，第 0 帧最亮）
#   色带  f*9000/270    走完回到第 0 组
#
# 色相流动砍掉了：渐变位置固定（斜着的），只有明暗和色调在慢慢变。
# 它是三层里唯一撑着帧率下限的 —— 呼吸 18 秒一轮、配色 30 秒一换，1 fps
# 完全够看。砍掉之后帧率 3.3 -> 1，网络 3.3 -> 1.0 KB/s
UI_BREATH=18 UI_FRAMES=270 UI_LOGO_CUR=''
# 九组停靠点，每组 5 个，轮流慢慢渗过去。同序号的停靠点两两插值，所以中间
# 任何一刻都是一条完整平滑的渐变，只是整体色调在漂。
# 顺序按色相排成一个环 —— 蓝 → 靛 → 紫 → 品红 → 红金 → 橙紫 → 紫灰 → 蓝灰
# → 青灰 → 回蓝，相邻两组本来就相近，渗过去才不会出现两种不相干的颜色硬碰。
# 拍平成一个数组用偏移索引：每帧拷一份子数组比想象中贵，实测那样一帧要 8ms
UI_PALS=(
    30 58 138 37 99 235 59 130 246 96 165 250 147 197 253      # 深蓝 靛 亮蓝
    67 56 202 99 102 241 129 140 248 165 180 252 199 210 254   # 靛 紫 淡紫
    107 33 168 147 51 234 192 132 252 216 180 254 233 213 255  # 紫 品红 粉
    112 26 117 162 28 175 219 39 119 244 63 94 251 146 60      # 紫红 玫红 粉
    127 29 29 185 28 28 234 88 12 249 115 22 251 191 36        # 深红 橙 金
    234 88 12 244 63 94 236 72 153 192 38 211 147 51 234       # 橙 粉 紫
    59 47 79 88 68 115 126 100 158 167 139 200 205 187 227     # 紫灰
    51 65 85 71 85 105 100 116 139 148 163 184 203 213 225     # 石板蓝
    19 78 74 17 94 89 13 148 136 45 212 191 153 246 228        # 青灰
)
UI_NSTOP=5 UI_PALSZ=15 UI_NPAL=9
# 同理存一份终端设置，退出时无条件还回去。我们自己的 read -s 会关回显，
# sudo（sudoers 里 Defaults use_pty）中继期间还会把终端整个置成 raw ——
# 它正常退出会还原，但被 esc 取消时是被 kill 掉的，那一步就没跑。留下来的
# 后果是：退出后提示符全挤在一行、打字看不见回显。
UI_STTY=''
UI_SYNC_ON=$'\e[?2026h'  # 同步输出：终端攒够一帧再显示，不支持的会忽略
UI_SYNC_OFF=$'\e[?2026l'

# 帧缓冲。整帧攒好一次写出 —— 逐行写会让终端边收边画，走 SSH 尤其明显
UI_BUF=""
# 终端尺寸。只在进菜单和收到 SIGWINCH 时量 —— tput 是外部命令，不能每帧都问
UI_COLS=80 UI_LINES=24 UI_WINCH=0
ui_reset() { UI_BUF=""; }
ui_add() { UI_BUF+="$1"$'\n'; }

# 这四个每帧都要画，原来每个都套着 $(printf ...) 甚至嵌一层 $(ui_bar ...)。
# 命令替换要 fork，实测 517us 一次，而 printf -v 只要 3.4us —— 差 150 倍。
# 横线和整行空白是常量，开头生成一次就够（见 ui_init_charset）。
ui_top() { ui_add "$UI_TL$UI_HBAR$UI_TR"; }
ui_bot() { ui_add "$UI_BL$UI_HBAR$UI_BR"; }
ui_sep() { ui_add "$UI_ML$UI_HBAR$UI_MR"; }
ui_blank() { ui_add "$UI_V$UI_SPACES$UI_V"; }

# 可见宽度：把转义序列剥掉再数。结果放 UI_VIS，剥干净的纯文本放 UI_VIS_TXT。
# 认两类：CSI（\e[ 到 @-~ 收尾，颜色的 \e[31m 属于此类）和字符集选择
# （\e(B 之类两字节，tput sgr0 在很多终端上就是 \e(B\e[m 这么一对）。
# 不走 sed —— 这函数每次重画每行都要跑一遍，不能每行 fork 一次。
ui_vis() {
    local s="$1" o=""
    while [[ $s == *$'\e'* ]]; do
        o+="${s%%$'\e'*}"
        s="${s#*$'\e'}"
        case $s in
        '['*)
            s="${s#?}"
            while [[ -n $s && $s != [@-~]* ]]; do s="${s#?}"; done
            s="${s#?}"
            ;;
        [\(\)*+]*) s="${s#??}" ;;
        *) s="${s#?}" ;;
        esac
    done
    o+="$s"
    UI_VIS_TXT="$o"
    UI_VIS=${#o}
}

# 只认带色版，宽度由它自己算出来。
# 原来的签名是「纯左 纯右 带色左 带色右」—— 每行写两遍，拿纯的算宽度、
# 打印带色的。两遍一旦不一致（比如带色版里多个 spinner 而纯版忘了写），
# 行就画歪，而且不报错。宽度既然能从带色版算出来，纯文本版就不该存在。
ui_lr() { # $1=左 $2=右，都可带色
    local a b at pad
    ui_vis "$1"
    a=$UI_VIS at="$UI_VIS_TXT"
    ui_vis "$2"
    b=$UI_VIS
    pad=$((UI_IN - a - b))
    if [ "$pad" -lt 0 ]; then
        # 放不下就退回「无色 + 裁剪」。按可见宽度裁带色串要在转义序列中间
        # 下刀，不安全，所以裁剥干净的那份。宁可这一行掉色也不能把框撑破,
        # 而且掉色本身就是溢出的信号
        ui_add "$UI_V$(ui_fit "$at" $((UI_IN - b)))$2$UI_V"
        return
    fi
    local line
    printf -v line '%s%s%*s%s%s' "$UI_V" "$1" "$pad" '' "$2" "$UI_V"
    ui_add "$line"
}

# 值太长时截断，保证不撑破框
ui_fit() {
    local t="$1"
    local n="$2"
    [ "$n" -lt 0 ] && n=0
    if [ "${#t}" -le "$n" ]; then
        printf '%s' "$t"
    elif [ "$n" -le 3 ]; then
        printf '%s' "${t:0:$n}" # 放不下省略号就直接截，${t:0:负数} 会从尾部截
    else
        printf '%s...' "${t:0:$((n - 3))}"
    fi
}

# 一个「键 + 标签」单元格。$3 非空时整体置灰，表示该动作当前不可用
# 结果写 UI_CELL 而不是打印出来 —— 用 $(_ui_cell ...) 的话菜单 5 行 10 个
# 单元格，每帧就白 fork 10 次
_ui_cell() {
    if [ -n "$3" ]; then
        printf -v UI_CELL '%s%s   %-15s%s' "$3" "$1" "$2" "$C_RESET"
    else
        printf -v UI_CELL '%s%s%s   %-15s' "$C_CYAN" "$1" "$C_RESET" "$2"
    fi
}

ui_item() {
    local a
    _ui_cell "$1" "$2" "${5:-}"
    a="$UI_CELL"
    _ui_cell "$3" "$4" "${6:-}"
    ui_lr "    $a  $UI_CELL" ""
}

# 步骤行：状态列前置 1 列。$1=状态符 $2=步骤名 $3=细节 $4=右侧 $5=状态色
ui_step() {
    local colored
    printf -v colored '  %s%s%s  %s%-10s%s%s' "$5" "$1" "$C_RESET" "$C_DIM" "$2" "$C_RESET" "$3"
    ui_lr "$colored" "$C_DIM${4:+$4  }$C_RESET"
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
# 用 stty 而不是 tput。ncurses 的 setupterm 会优先信 $LINES / $COLUMNS 这两个
# 环境变量，而它们是进程启动时的快照 —— 窗口拖动之后 tput 报的还是老尺寸。
# 实测：真实 50x40 时 tput 仍然说 100x40，stty size 说的是 40 50。
# stty size 直接走 TIOCGWINSZ，问的是内核里的真值。
ui_measure() {
    local sz
    # stty size 输出「行 列」两个数
    sz=$(stty size 2>/dev/null </dev/tty) || sz=""
    UI_LINES=${sz%% *} UI_COLS=${sz##* }
    # 拿不到就退回 tput，再拿不到用兜底值。数字校验统一放这里做，
    # 上面就不必再自己判断格式
    [ "${UI_LINES:-0}" -gt 0 ] 2>/dev/null || UI_LINES=$(tput lines 2>/dev/null)
    [ "${UI_COLS:-0}" -gt 0 ] 2>/dev/null || UI_COLS=$(tput cols 2>/dev/null)
    [ "${UI_LINES:-0}" -gt 0 ] 2>/dev/null || UI_LINES=24
    [ "${UI_COLS:-0}" -gt 0 ] 2>/dev/null || UI_COLS=80
}

ui_redraw() {
    # 行尾用 \r\n 而不是裸 \n。光靠 \n 下移一行、回不回第 0 列取决于终端的
    # ONLCR —— 而 sudo（sudoers 里 Defaults use_pty，Ubuntu 22.04+ 的默认）
    # 中继期间会把终端置成 raw 模式，OPOST/ONLCR 一关，落在那个窗口里的帧就
    # 每行往右缩一截，变成一屏阶梯。实测同一份代码两次运行，一次全是 \r\n，
    # 一次 84 个裸 \n。自己补上 \r 就跟终端模式无关了。
    local nl=$'\n' k=$'\e[K\r' buf="${UI_BUF%$'\n'}" nls rows
    # 窗口被拖动过：终端已经把旧内容按新尺寸重排了一遍，\e[H 之后逐行覆盖
    # 盖不干净，只能整屏清掉重来
    if [ "$UI_WINCH" -eq 1 ]; then
        UI_WINCH=0
        ui_measure
        printf '%s' "$UI_CLS" >&$UI_FD
    fi
    # 放不下就别画框。窄于 58 时每行折成两行，13 行的帧占满 26 行，和残留
    # 叠在一起就是一屏碎片；比屏幕高则顶部滚出去，而 \e[H 回的是屏幕顶不是
    # 帧的起点，越画越错位
    # 数帧有多少行：把非换行的字符全删掉，剩下的长度就是换行数。
    # 纯参数展开，不 fork —— 这函数每帧都要跑
    nls="${buf//[!$nl]/}"
    rows=$((${#nls} + 1))
    if [ "$UI_COLS" -lt "$UI_W" ] || [ "$rows" -gt "$UI_LINES" ]; then
        printf '%s%s  sbs: needs a %s x %s window, this one is %s x %s\e[K\e[J%s' \
            "$UI_SYNC_ON" "$UI_HOME" "$UI_W" "$rows" "$UI_COLS" "$UI_LINES" "$UI_SYNC_OFF" >&$UI_FD
        return
    fi
    # 每行末尾补 \e[K 清到行尾：上一帧若更宽，右边多出来的字符会原地留着。
    # \e[J 清光标之后的整屏 —— 上一帧若更高，多出来的整行靠它抹掉
    printf '%s%s%s\e[K\e[J%s' "$UI_SYNC_ON" "$UI_HOME" "${buf//$nl/$k$nl}" "$UI_SYNC_OFF" >&$UI_FD
}

# ── footer 区 ──
# 菜单永远绘制，footer 随当前活动伸缩：空闲 0 行、有结果 1 行、
# 任务进行中 N 行（步骤列表）、失败 N 行（步骤 + 建议）。
# 没有视图切换，没有模态 —— 这是整个界面唯一会变高的部分。
FOOT_L=() FOOT_R=()
foot_reset() { FOOT_L=() FOOT_R=(); }
foot_add() { # $1=左 $2=右，都可带色
    FOOT_L+=("$1") FOOT_R+=("${2:-}")
}

# 读一个键，方向键与回车归一化成名字
# 读一个键，结果写进 UI_KEY。刻意不做成 $(ui_read_key) —— 命令替换是子 shell，
# UI_PENDING 回推缓冲存不下来，而且每次按键白搭一个 fork。
UI_KEY='' UI_PENDING='' UI_INPUT='' SUB_URL=''

# ============================================================ L0 输入与等待原语

ui_read_key() {
    local k rest
    if [ -n "$UI_PENDING" ]; then
        k=${UI_PENDING:0:1}
        UI_PENDING=${UI_PENDING:1}
    elif [ "$UI_ANIM" -eq 1 ]; then
        # 开着动画就轮询：每 UI_ANIM_TICK 推进一相，有键立刻返回
        local rc
        while true; do
            IFS= read -rsn1 -t "$UI_ANIM_TICK" k 2>/dev/null && break
            rc=$?
            if [ "$UI_WINCH" -eq 1 ]; then
                UI_KEY=winch
                return
            fi
            if [ "$rc" -le 128 ]; then # 不是超时，是 EOF 或真出错
                UI_KEY=esc
                return
            fi
            ui_logo_step
        done
    elif ! IFS= read -rsn1 k 2>/dev/null; then
        # 窗口尺寸变化会用信号打断 read，那不是按了 esc
        if [ "$UI_WINCH" -eq 1 ]; then
            UI_KEY=winch
            return
        fi
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

# 等一拍，顺带探键。按下 esc 返回 0，表示要中断当前任务。
# 一个 read 同时管定速和探键：原来是 sleep 0.12 外加一个 -t 0.001 的 read，
# sleep 是外部命令每帧白 fork 一次，而且 esc 最坏要等满一整拍才被看见。
# 方向键、功能键也都以 \e 开头，后面还跟着字节就是转义序列不是取消，顺手
# 读掉免得漏进下一拍 —— 否则下载时手滑按个方向键任务就没了。
ui_tick() { # $1=这一拍等多久（秒）
    local k rest rc
    read -rsn1 -t "$1" k 2>/dev/null
    rc=$?
    [ "$rc" -gt 128 ] && return 1 # 超时 = 这一拍没人按键，正常
    if [ "$rc" -ne 0 ]; then
        # stdin 已 EOF（非交互调用），read 会立刻返回，得自己退回 sleep，
        # 否则循环空转烧 CPU
        sleep "$1"
        return 1
    fi
    [ "$k" = $'\e' ] || return 1
    read -rsn2 -t 0.05 rest 2>/dev/null && return 1
    [ -z "$rest" ]
}

# 动画相位。任务视图和 footer 单行 spinner 共用一个计数器 —— 它不是任务
# 视图的私产，所以放在这里而不是 TASK_* 那一堆里
UI_TICK=0

# 等一个后台进程结束，期间每拍调一次 $2 重画。用户按 esc 就杀掉它返回 130，
# 否则返回被等进程自己的退出码。任务视图和 footer 单行 spinner 都走这里。
ui_wait_pid() { # $1=pid $2=每拍调用的重画函数
    local pid=$1 draw=$2
    while kill -0 "$pid" 2>/dev/null; do
        UI_TICK=$((UI_TICK + 1))
        # 任务视图是 0.08 秒一拍，logo 是 1 秒一帧 —— 相位得按墙上时间推，
        # 一拍一帧的话装个内核回来颜色会凭空跳过去两分钟
        [ "$UI_ANIM" -eq 1 ] && [ $((UI_TICK % 12)) -eq 0 ] &&
            UI_PHASE=$(((UI_PHASE + 1) % UI_FRAMES))
        "$draw"
        if ui_tick 0.08; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 130
        fi
    done
    wait "$pid"
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

# 启停、写 unit、自更新全要 sudo，而且都跑在后台子 shell 里（要让 spinner 转）。
# sudo 问密码是从 /dev/tty 读的，后台子 shell 里那个提示看不见，用户敲的字又
# 被读键循环抢走 —— 实测会一直转下去转不完。所以全部用 sudo -n（不许交互），
# 拿不到权限就立刻失败，并在进菜单前先探一次。
core_check_sudo() {
    sudo -n true 2>/dev/null && return 0
    core_error "需要免密 sudo。先跑一次 sudo -v，或者直接 sudo sbs"
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
    local j ip city country state
    j=$(curl -s --max-time 8 ipinfo.io 2>/dev/null) || return 1
    # 一次 jq 取三个字段。原来对同一份 JSON 调了 4 次 jq，还多取一个 org ——
    # 那个 org 存进缓存又读出来，可消费端只读前三行，一路白走
    { read -r ip; read -r city; read -r country; } < <(
        printf '%s' "$j" | jq -r '.ip // "", .city // "", .country // ""' 2>/dev/null
    )
    [ -n "$ip" ] || return 1
    svc_is_active && state=active || state=inactive
    printf '%s|%s|%s|%s\n' "$ip" "${city:+$city, }${country:-}" "$(date +%s)" "$state" >"$SBS_IPCACHE"
}

# 输出三行：IP、地点、年龄描述
net_exit_cached() {
    [ -f "$SBS_IPCACHE" ] || return 1
    local ip loc ts st cur age
    # 末尾多接一个 _ ：早先的缓存文件是五段（多一个 org，后来发现从没被用过）。
    # 不接的话 read 会把剩下的全部塞进 st，状态比对就永远不相等
    IFS='|' read -r ip loc ts st _ <"$SBS_IPCACHE" || return 1
    [ -n "$ip" ] || return 1
    svc_is_active && cur=active || cur=inactive
    # 缓存记录的服务状态与当前不符 -> 这条出口信息已经不作数，标成 stale。
    # 这是比「停止时刷新」更硬的一道保险：刷新可能因为断网失败，而状态比对不会。
    if [ -n "${st:-}" ] && [ "$st" != "$cur" ]; then
        printf '%s\n%s\nstale\n' "$ip" "$loc"
        return 0
    fi
    age=$(($(date +%s) - ${ts:-0}))
    printf '%s\n%s\n%s\n' "$ip" "$loc" "$(fmt_dur "$age") ago"
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

# 清掉上次留下的临时文件/目录。安装或自更新中途被杀（断网、SSH 掉线）时，
# 里面躺着一个几十 MB 的二进制，而各处只删自己那个 $$，不扫就会一直攒。
# 按 PID 判活，免得误删另一个正在跑的实例
stage_sweep() { # $1=所在目录 $2=文件名前缀
    local s pid
    for s in "$1/$2".*; do
        [ -e "$s" ] || continue
        pid="${s#"$1/$2".}"
        pid="${pid%%.*}"
        case "$pid" in
        '' | *[!0-9]*) continue ;;
        esac
        kill -0 "$pid" 2>/dev/null && continue
        # /usr/local/bin 下的半成品要 root 才删得掉。报错一律吞掉 ——
        # 这函数在任务视图里跑，往 stderr 写一个字都会糊在框上
        rm -rf "$s" 2>/dev/null || sudo -n rm -rf "$s" 2>/dev/null || true
    done
    return 0
}

kern_stage_new() {
    local d="$SBS_WORK_DIR/.stage.$$"
    stage_sweep "$SBS_WORK_DIR" ".stage"
    rm -rf "$d"
    mkdir -p "$d" || return 1
    printf '%s\n' "$d"
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

# ============================================================ L2 服务
svc_write_unit() {
    local ver
    ver=$(kern_version) || ver="unknown"

    # Restart=on-failure 而非 always：正常退出（exit 0）不该被反复拉起
    # RestartSec：配置写错导致起来就崩时，避免秒级重启刷爆日志、淹没真正的错误
    # LimitNOFILE：TUN 模式下整机连接都过 sing-box，默认 1024 个句柄容易撞上限
    sudo -n tee "$SBS_SERVICE" >/dev/null <<UNIT
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
    sudo -n systemctl daemon-reload
    core_info "service file written: $SBS_SERVICE"
}

# 起之前先 reset-failed。systemd 默认 10 秒内最多起 5 次（StartLimitBurst=5），
# 手快连按几下 r 就撞上了 —— 撞上之后单元进 failed，Result=start-limit-hit，
# 此后连普通 restart 都一直失败，实测必须先 reset-failed 才救得回来。
# 崩溃循环的保护由 Restart=on-failure + RestartSec=10 提供（10 秒才重试一次，
# 本来也撞不到这个计数器），不靠它。
svc_start() {
    sudo -n systemctl reset-failed "$SBS_UNIT_NAME" 2>/dev/null
    sudo -n systemctl start "$SBS_UNIT_NAME"
}
svc_stop() { sudo -n systemctl stop "$SBS_UNIT_NAME"; }
svc_status() { sudo -n systemctl status "$SBS_UNIT_NAME" --no-pager; }
svc_restart() {
    sudo -n systemctl reset-failed "$SBS_UNIT_NAME" 2>/dev/null
    sudo -n systemctl restart "$SBS_UNIT_NAME"
}

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
# 面板是「快照」不是「实时」：只在进入菜单、跑完一个动作、按 f 之后才重查。
# 中间不管重画多少次（选择框、输入框、spinner 每秒十几帧）都复用上一次的
# 结果 —— 那些重查全是 systemctl / stat / ip 的 fork。
# 由 ui_menu_header 在重建完之后清零。
UI_DIRTY=1
svc_snapshot() {
    local k v mono=0
    [ "$UI_DIRTY" -eq 0 ] && return 0
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

# systemd 认为「起来了」= 进程 fork 出来了，而 sing-box 建 tun 还要 0.1~0.3s
# （实测 restart 返回耗时 0.06s，tun0 在 0.24s 才出现）。面板紧接着重建就会
# 显示 no tun —— 而面板是快照，这个错误会一直挂到下次操作。
# 只在配置里确实声明了 tun 入站时才等，否则本来就不该有。
svc_wait_tun() {
    jq -e '[.inbounds[]? | select(.type == "tun")] | length > 0' \
        "$SBS_CONFIG" >/dev/null 2>&1 || return 0
    local i
    for i in $(seq 1 40); do
        tun_info >/dev/null 2>&1 && return 0
        sleep 0.05
    done
    return 1 # 等不到也不算启动失败，面板照实显示 no tun
}

svc_purge() {
    sudo -n systemctl disable "$SBS_UNIT_NAME" >/dev/null 2>&1
    sudo -n systemctl stop "$SBS_UNIT_NAME" >/dev/null 2>&1
    sudo -n rm -f "$SBS_SERVICE"
    sudo -n systemctl daemon-reload
}


# ============================================================ L3 会话与不需要交互的命令

# 进入 / 退出全屏界面会话。命令行直接调 install 时也要用
ui_session_begin() {
    UI_IN_MENU=1
    UI_WINCH=0
    ui_measure
    UI_STTY=$(stty -g 2>/dev/null </dev/tty) || UI_STTY=""
    exec {UI_FD}>&2 # 复制一份 stderr 归界面专用
    # trap 必须装在「进备用屏」之前：信号正好落在两者之间的话就没人还原，
    # 用户停在一块空白画布上。反过来无害 —— 还没进备用屏就收到信号，那条
    # \e[?1049l 终端会直接忽略。
    # 三条都收敛到 ui_session_end，别各抄一份还原逻辑；它自己会清 trap，
    # 所以正常退出不会跑第二遍，重复调用也幂等。
    # INT / TERM 要额外 exit —— trap 执行完是接着往下跑的，不退出就还留在
    # 循环里接着画，比不还原更糟。
    trap ui_session_end EXIT
    trap 'ui_session_end; exit 130' INT TERM
    trap 'UI_WINCH=1' WINCH
    printf '%s%s%s' "$UI_ALT_ON" "$UI_CLS" "$UI_HIDE" >&$UI_FD
}
ui_session_end() {
    UI_IN_MENU=0
    printf '%s%s' "$UI_SHOW" "$UI_ALT_OFF" >&$UI_FD
    [ -n "$UI_STTY" ] && stty "$UI_STTY" 2>/dev/null </dev/tty
    UI_STTY=""
    trap - EXIT INT TERM WINCH
    [ "$UI_FD" -ne 2 ] && exec {UI_FD}>&-
    UI_FD=2
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
    trap 'rm -rf "${_SELF_TMPDIR:-}" 2>/dev/null; sudo -n rm -f "${_SELF_STAGE:-}" 2>/dev/null' EXIT

    script_fetch "$tmpdir/sbs.sh" sbs.sh || return 1
    bash -n "$tmpdir/sbs.sh" || {
        core_error "拉到的脚本语法不合法，放弃更新"
        return 1
    }
    sudo -n cp "$tmpdir/sbs.sh" "$stage" || return 1
    sudo -n chmod 755 "$stage" || return 1
    sudo -n mv -f "$stage" "$SBS_EXEC" || return 1
    core_info "sbs 已更新"
}

# 只有 start 该关心配置是否有效 —— 配置坏了启动也是白启，不如早点说
cmd_start() {
    cfg_check || return 1
    if svc_start; then
        svc_wait_tun
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
        svc_wait_tun
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
    ui_measure
    if [ "$UI_COLS" -lt "$UI_W" ]; then
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

# ============================================================ L4 任务视图：步骤列表与下载进度
#
# 一个任务 = 若干步骤。每步有状态（pending / running / ok / fail）、细节、右侧信息。
# 画在与菜单同一个框里：header 三行不变，只有 body 换成步骤列表。
#
# 成功 -> 自动回菜单，结果留在菜单底部
# 失败 -> 停在失败那一步，附一句「下一步怎么办」，等按键

TASK_NAMES=()
TASK_STATE=()
TASK_DETAIL=()
TASK_RIGHT=()
TASK_HINT=()   # 失败时的说明行
TASK_CUR=-1

# 只收步骤名。原来还吃「标题」「副标题」两个参数存进 TASK_TITLE / TASK_SUB，
# 但任务视图并进 footer 之后就没有标题行了，那两个全局写了从没被读过 ——
# 6 个调用点白传两个参数，还得靠 shift 2 2>/dev/null || shift $# 兜着
task_begin() { # $1.. = 步骤名
    TASK_NAMES=()
    TASK_STATE=()
    TASK_DETAIL=()
    TASK_RIGHT=()
    TASK_HINT=()
    TASK_CUR=-1
    UI_TICK=0
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

# 在任务视图里跑一条命令：后台执行、spinner 转起来，返回它自己的退出码，
# 130 表示用户按 esc 取消
task_run() {
    # 输出必须掐掉：界面是往 stderr 画的，被调命令随便往 stderr 写一行就会
    # 糊在框上（tar 的报错、systemctl 的提示都会）。任务视图自己会报步骤结果
    "$@" >/dev/null 2>&1 </dev/null &
    ui_wait_pid $! task_draw
}

# 同上，外加把命令的 stdout 收进 REPLY。省掉每个调用点自己 mktemp、读回、
# rm 的那一圈样板
task_capture() {
    local t rc
    t=$(mktemp) || return 1
    "$@" >"$t" 2>/dev/null </dev/null &
    ui_wait_pid $! task_draw
    rc=$?
    REPLY=$(cat "$t" 2>/dev/null)
    rm -f "$t"
    return "$rc"
}

# footer 里转一个 spinner 等命令跑完，不进任务视图。$1=文案 $2..=要跑的命令。
# 注意命令是在后台子 shell 里跑的，它设的变量传不回来 —— 结果只能走文件或
# 退出码（net_exit_refresh 写的是 $SBS_IPCACHE，所以没问题）
SPIN_LABEL=''
_spin_draw() {
    foot_reset
    foot_add "$C_CYAN  ${UI_SPIN[$((UI_TICK % 4))]}$C_RESET  $C_DIM$SPIN_LABEL$C_RESET" ""
    cli_menu_draw
}
ui_spin() { # $1=文案 $2..=命令。命令的 stdout+stderr 收进 REPLY
    local t rc
    SPIN_LABEL="$1"
    shift
    t=$(mktemp) || return 1
    "$@" >"$t" 2>&1 </dev/null &
    ui_wait_pid $! _spin_draw
    rc=$?
    REPLY=$(cat "$t" 2>/dev/null)
    rm -f "$t"
    return "$rc"
}

# 把步骤列表塞进 footer 区，然后让菜单整体重绘。
# 任务视图不再是「另一个界面」—— 菜单始终在上面，步骤长在下面。
task_draw() {
    local i st sym color nm
    foot_reset
    for i in "${!TASK_NAMES[@]}"; do
        printf -v nm '%-10s' "${TASK_NAMES[$i]}"
        st="${TASK_STATE[$i]}"
        case "$st" in
        ok) sym="$UI_OK" color="$C_GREEN" ;;
        fail) sym="$UI_BAD" color="$C_RED" ;;
        skip) sym="$UI_BAD" color="$C_YELLOW" ;;
        running)
            sym="${UI_SPIN[$((UI_TICK % 4))]}"
            color="$C_CYAN"
            ;;
        *) sym=" " color="$C_DIM" ;;
        esac
        foot_add \
            "  $color$sym$C_RESET  $C_DIM$nm$C_RESET${TASK_DETAIL[$i]}" \
            "$C_DIM${TASK_RIGHT[$i]:+${TASK_RIGHT[$i]}  }$C_RESET"
    done
    if [ "${#TASK_HINT[@]}" -gt 0 ]; then
        foot_add "" ""
        local h
        for h in "${TASK_HINT[@]}"; do
            foot_add "$C_DIM  $h$C_RESET" ""
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
# 下载进度：这是喂给 ui_wait_pid 的重画函数，每拍算一次进度再画。
# 状态走 DL_* 全局而不是闭包 —— bash 没有闭包，重画函数只能这么拿到上下文。
DL_DST='' DL_TOTAL=0 DL_T0=0 DL_IDX=0 DL_RW=0
_dl_draw() {
    # 条宽不写死。这一行的账是
    #   2 缩进 + 1 符号 + 2 + 10 名字 + w 条 + 5 " nnn%" + rw 右半边 + 2 尾距 <= UI_IN
    # 前后那些固定部分合计 22，剩下的都给条：w = UI_IN - 22 - rw。
    # rw 取「见过的最长右半边」，只增不减且按 4 格取整 —— eta 并不是单调变短
    # 的，"eta 2m" 跳到 "eta 39s" 反而长了一个字，不取整条宽就会中途抖一格。
    local wfix=22 now elapsed spd pct eta bar f r w
    now=$(stat -c %s "$DL_DST" 2>/dev/null || echo 0)
    elapsed=$(($(date +%s) - DL_T0))
    [ "$elapsed" -lt 1 ] && elapsed=1
    spd=$(fmt_size $((now / elapsed)))
    if [ "$DL_TOTAL" -gt 0 ]; then
        pct=$((now * 100 / DL_TOTAL))
        [ "$pct" -gt 100 ] && pct=100
        if [ "$now" -gt 0 ] && [ "$now" -lt "$DL_TOTAL" ]; then
            eta="eta $(fmt_dur $(((DL_TOTAL - now) * elapsed / now)))"
        else eta=""; fi

        # 先定右半边，再拿剩下的空间算条宽 —— 顺序反过来就又变成猜了
        r="$spd/s${eta:+  $eta}"
        # 条最窄留 8 格；右半边真宽到挤掉它，就丢 eta 保速率
        [ "${#r}" -gt $((UI_IN - wfix - 8)) ] && r="$spd/s"
        [ "${#r}" -gt "$DL_RW" ] && DL_RW=${#r}
        w=$((UI_IN - wfix - (DL_RW + 3) / 4 * 4))
        # 取整可能多吃几格，把条压到 8 以下。钳回 8 正好把预算还平
        [ "$w" -lt 8 ] && w=8

        f=$((pct * w / 100))
        printf -v bar '%*s' "$f" ''
        bar="${bar// /#}"
        printf -v f '%*s' $((w - f)) ''
        bar="$bar${f// /.}"
        printf -v pct '%3d' "$pct"
        TASK_DETAIL[$DL_IDX]="$bar $pct%"
        TASK_RIGHT[$DL_IDX]="$r"
    else
        TASK_DETAIL[$DL_IDX]="$(fmt_size "$now")"
        TASK_RIGHT[$DL_IDX]="$spd/s"
    fi
    task_draw
}

dl_with_progress() { # $1=落地路径 $2=url $3=步骤下标
    DL_DST="$1" DL_IDX="$3" DL_RW=0
    DL_TOTAL=$(dl_content_length "$2")
    DL_T0=$(date +%s)
    curl -fL --connect-timeout 5 --retry 2 -s -o "$DL_DST" "$2" </dev/null &
    ui_wait_pid $! _dl_draw
}


# ============================================================ L4 交互控件：底部的选择框与输入框

# ── 选择视图：在同一个框里做单键选择 ──
# $1=标题 $2..=「键|标签」，返回按下的键
# footer 里的横向选择。方向键切换、回车确认、esc 取消。
# $1=提示 $2..=选项文本，选中的下标写进 UI_CHOICE（-1 表示取消）
ui_choose() {
    local title="$1"
    shift
    local opts=("$@")
    local cur=0 key i lc
    # 标题超长会把提示挤出框外，先裁进可用宽度。-4 = 2 格左缩进 + 2 格间距，
    # 不留间距就挤成「...enter ok」
    title=$(ui_fit "$title" $((UI_IN - ${#UI_HINT} - 4)))
    while true; do
        foot_reset
        foot_add "$C_DIM  $title$C_RESET" "$UI_HINT_C"
        # 每个选项前留一格给三角标记，未选中时留空 —— 这样切换时文字不会左右跳
        lc="   "
        for i in "${!opts[@]}"; do
            if [ "$i" -eq "$cur" ]; then
                # 三角 + 反色，两者分工不同：
                #   三角是「形状」线索 —— NO_COLOR / dumb 终端 / terminfo 缺条目时
                #     颜色全失效，它是唯一还能指出选中项的东西
                #   反色是「颜色」线索 —— \e[7m 是相对当前主题取反而非固定颜色，
                #     深色浅色主题下都必然是高对比块，比青色之类稳得多
                lc+="$C_CYAN$UI_SEL$C_RESET $C_REV ${opts[$i]} $C_RESET    "
            else
                lc+="   $C_DIM${opts[$i]}$C_RESET     "
            fi
        done
        foot_add "$lc" ""
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
            foot_add "$C_DIM  cancelled$C_RESET" ""
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
    local title="$1" val="$2" note="${3:-}" disp k max
    # 和 ui_choose 同样的裁剪。循环外做一次，别每敲一个键 fork 一回
    max=$((UI_IN - ${#UI_HINT} - 4))
    title=$(ui_fit "$title" "$max")
    [ -n "$note" ] && note=$(ui_fit "$note" "$max")
    while true; do
        foot_reset
        foot_add "$C_DIM  ${note:-$title}$C_RESET" "$UI_HINT_C"
        # 地址通常比框还长，看尾巴 —— 那才是正在敲的一头
        disp="$val"
        [ "${#disp}" -gt 50 ] && disp="...${val: -47}"
        # 行尾那个反色空格是光标，纯文本版对应补一个空格好让宽度算得准
        foot_add "  $C_CYAN>$C_RESET $disp$C_REV $C_RESET" ""
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
            foot_add "$C_DIM  cancelled$C_RESET" ""
            return 1
            ;;
        left | right | up | down | winch) continue ;;
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


# ============================================================ L4 编排：一个动作从头到尾怎么走

# ── 瞬时动作：成功就地反馈（不离开菜单），失败才进任务视图停住 ──
# 瞬时动作。成功在 footer 留一行，失败留两行（原因 + 去哪看日志）
menu_quick() { # $1=动作函数 $2=成功文案 $3=动作名
    local rc first
    # 原来是 out=$("$1" 2>&1) 全同步：systemctl 要跑多久屏幕就冻多久，
    # 连一帧 spinner 都没有
    ui_spin "$3" "$1"
    rc=$?
    foot_reset
    if [ "$rc" -eq 0 ]; then
        foot_add "$C_GREEN  $2$C_RESET" ""
        return 0
    fi
    if [ "$rc" -eq 130 ]; then
        foot_add "$C_DIM  cancelled$C_RESET" ""
        return 1
    fi
    first=$(printf '%s' "$REPLY" | sed 's/\x1b\[[0-9;]*m//g' | grep -viE '^\[info\]|^$' | head -n 1)
    foot_add "$C_RED  $3 failed$C_RESET" ""
    foot_add "$C_DIM  $(ui_fit "${first:-something went wrong}" 52)$C_RESET" ""
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
        if [ "$UI_CHOICE" -eq 0 ]; then
            SUB_URL="$cur"
            return 0
        fi
        # 明确选了「输入新的」就别再用旧地址预填。输入框只有退格没有光标移动，
        # 预填一条 80 字的旧地址等于逼人连按 80 下退格 —— 而实际发生的是新地址
        # 被直接拼在旧地址屁股后面，拼出个不存在的 URL
        cur=""
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
    task_begin fetch validate save
    tmp="$SBS_WORK_DIR/.config.$$.json"

    task_step 0 "$(ui_fit "$sub" 38)"
    task_run cfg_download "$sub" "$tmp"
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
    # 落地成功才记住地址，下次按 c 就能直接沿用。
    # 这行原来只在 CLI 版里有，菜单版一直漏着 —— 表现是每次都要重新粘贴整条 URL
    cfg_url_set "$sub"
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
    task_begin fetch check install
    tmpdir=$(mktemp -d) || {
        task_step 0
        task_fail "no temp dir" "cannot create a temp directory"
        return 1
    }
    stage="$(dirname "$SBS_EXEC")/.$(basename "$SBS_EXEC").$$.tmp"
    stage_sweep "$(dirname "$SBS_EXEC")" ".$(basename "$SBS_EXEC")"

    task_step 0
    for base in $(src_script | awk '!seen[$0]++'); do
        TASK_DETAIL[0]="$(ui_fit "${base#https://}" 40)"
        task_run curl -fsSL --connect-timeout 5 --retry 2 -o "$tmpdir/sbs.sh" "$base/sbs.sh"
        case $? in
        0)
            ok=1
            break
            ;;
        130)
            rm -rf "$tmpdir"
            return 130
            ;;
        esac
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
    if ! sudo -n cp "$tmpdir/sbs.sh" "$stage" || ! sudo -n chmod 755 "$stage" || ! sudo -n mv -f "$stage" "$SBS_EXEC"; then
        task_fail "install failed" "cannot replace $SBS_EXEC" "check sudo -n permissions"
        sudo -n rm -f "$stage" 2>/dev/null
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

    task_begin service files script
    task_step 0
    task_run svc_purge # systemctl stop 可能要等服务自己收尾，别让屏幕冻着
    task_ok "unit disabled and removed" ""
    task_step 1
    task_run sudo -n rm -rf "$SBS_WORK_DIR"
    task_ok "$SBS_WORK_DIR" ""
    # 删掉自己之后本进程仍能跑完 —— bash 攥着已打开的 fd，inode 还活着
    task_step 2
    sudo -n rm -f "$SBS_EXEC"
    task_ok "$SBS_EXEC" ""
    return 0
}

# ── 菜单里的「装/更新内核」完整流程 ──
menu_kernel_flow() {
    local tags stable beta tag url
    core_detect_target >/dev/null 2>&1 || {
        task_begin resolve
        task_step 0
        task_fail "unsupported arch" "unsupported architecture: $(uname -m)"
        return 1
    }

    # 解析版本，spinner 转起来
    task_begin resolve
    task_step 0 "querying release tags"
    task_capture gh_resolve_tags
    [ $? -eq 130 ] && return 130
    tags="$REPLY"
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
    local tag="$1" url="$2" stage tarball src full ok=0 selfcheck

    task_begin resolve download verify install
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
            "all download sources are unreachable" "check the network, or pick a mirror:" "  SBS_PROXY=https://ghfast.top sbs"
        rm -rf "$stage"
        return 1
    fi
    task_ok "$(fmt_size "$(stat -c %s "$tarball" 2>/dev/null || echo 0)") downloaded" ""

    task_step 2
    if ! task_run kern_extract "$stage" "$tarball"; then
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
    task_run svc_write_unit # 里头 systemctl daemon-reload 要 435ms，同步会掉 6 帧
    task_ok "$SBS_BIN" "$(fmt_size "$(stat -c %s "$SBS_BIN" 2>/dev/null || echo 0)")"
    svc_is_active && {
        TASK_HINT=("restart to run the new kernel")
        task_draw
    }
    return 0
}

# ============================================================ L4 菜单渲染
# header 三行 + 分隔线。菜单和任务视图共用 —— 长任务进行时也能看到服务状态
# sing-box version(53ms) 和 sing-box check(100ms) 占了一次重画 222ms 里的七成，
# 而它们只在内核或配置文件变了之后才会变。拿 mtime:size 当键缓存，一次 stat
# 两个文件只要一个 fork。
HDR_KEY='?' HDR_VER='' HDR_CFG=''
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

# header 那三四行每秒要重建十来次，内容却以秒为单位才变（uptime、ago）。
# 按秒缓存渲染好的字符串：spinner 照转，systemctl / ip / stat 的 fork 全省。
# 用户一按键就作废（见 cli_menu），所以动作后的状态不会显示滞后。
HDR_LINES=''
ui_menu_header() {
    local before
    # 服务状态是 header 自己的依赖，放在这里而不是让调用方记得先调 ——
    # cmd_status 就是漏了这一步，SVC_STATE 停在初始值，status 永远显示 Stopped。
    # svc_snapshot 自己看 UI_DIRTY，缓存命中时是空操作
    svc_snapshot
    if [ "$UI_DIRTY" -eq 0 ] && [ -n "$HDR_LINES" ]; then
        UI_BUF+="$HDR_LINES"
        return
    fi
    before="$UI_BUF"
    _ui_menu_header
    HDR_LINES="${UI_BUF#"$before"}"
    UI_DIRTY=0
}

_ui_menu_header() {
    local state scolor ver tun uptime ip loc age
    local l2p l2c l3c

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
    ui_lr "$C_BOLD  $title$C_RESET" \
        "$scolor$UI_DOT $state$C_RESET$C_DIM${uptime:+  $uptime}$C_RESET  "

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
    ui_lr "$l2c" "${C_DIM}config$C_RESET $vcolor$valid$C_RESET  "

    if { read -r ip; read -r loc; read -r age; } < <(net_exit_cached) 2>/dev/null && [ -n "${ip:-}" ]; then
        printf -v l3c '%s  %s  %s%s' "$C_DIM" "$ip" "$loc" "$C_RESET"
        local agec="$C_DIM$age$C_RESET"
        [ "$age" = stale ] && agec="$C_YELLOW$age$C_RESET"
        ui_lr "$l3c" "$agec  "
    else
        ui_lr "$C_DIM  no exit ip yet$C_RESET" ""
    fi

    # 第 4 行只在出问题时出现。restarts 常态为 0，常驻显示纯粹是噪音
    if [ "${SVC_NRESTARTS:-0}" -gt 0 ] 2>/dev/null; then
        ui_lr "$C_YELLOW  restarted $SVC_NRESTARTS times - check the logs$C_RESET" ""
    fi
}


cli_menu_draw() {
    UI_BODY=5 # 9 个动作：2 列 4 行 + q 单独一行
    ui_reset
    # logo 画在框外面。按「最高的那一帧」判断放不放得下，而不是按当前这一帧
    # —— 否则任务视图长出几行时 logo 会突然消失，整个框往上跳
    if [ "$UI_LINES" -ge $((UI_FRAME_MAX + UI_LOGO_ROWS)) ]; then
        if [ "$UI_ANIM" -eq 1 ]; then
            ui_logo_frame "$UI_PHASE"
            UI_BUF+="$UI_LOGO_CUR"
        else
            UI_BUF+="$UI_LOGO"
        fi
    fi
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
            ui_lr "${FOOT_L[$i]}" "${FOOT_R[$i]}"
        done
    fi
    ui_bot
    ui_redraw
}


# ============================================================ L4 主循环与分发

cli_menu() {
    # 终端太窄画框会折行，比没框还难看；直接退回帮助
    if [ "$UI_COLS" -lt "$UI_W" ]; then
        core_warn "终端宽度 $UI_COLS 小于 $UI_W，改用命令行模式"
        cli_help
        return 0
    fi

    local key rc
    core_check_sudo || return 1
    ui_measure
    # 无论怎么退出（正常 / Ctrl-C / 报错）都要把光标恢复出来
    ui_session_begin
    while true; do
        cli_menu_draw
        ui_read_key
        key=$UI_KEY
        # 不认识的键（回车之类）什么都不做：不清上一次的结果，也不刷新面板。
        # 刷新是 f 的事，不该再有一条隐式的路 —— 之前任何按键都会强制重查，
        # 于是敲个回车 uptime 就跳一下，看着像面板在自己动
        case "$key" in
        q)
            ui_session_end
            return 0
            ;;
        s | x | r | k | c | u | d | f) ;;
        *) continue ;;
        esac
        # 上一个动作的结果显示到下次「有效」按键为止
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
            ui_spin refreshing net_exit_refresh
            rc=$?
            foot_reset
            case "$rc" in
            0) foot_add "$C_GREEN  refreshed$C_RESET" "" ;;
            130) foot_add "$C_DIM  cancelled$C_RESET" "" ;;
            *) foot_add "$C_YELLOW  exit ip unavailable$C_RESET" "" ;;
            esac
            ;;
        esac
        # 动作跑完了，面板要反映新状态
        UI_DIRTY=1
    done
}

cli_help() {
    cat <<'USAGE'
Usage:
  sbs                 进菜单（下面这些之外的操作都在里面）
  sbs start           启动
  sbs stop            停止
  sbs restart         重启
  sbs status          查看状态
  sbs update sbs      更新本脚本

菜单里的按键:
  k  安装 / 更新内核     c  更新订阅配置
  s  启动   x  停止      r  重启   f  刷新
  d  卸载全部            q  退出

环境变量:
  SBS_PROXY   指定内核下载反代，如 https://gh-proxy.com
  SBS_MIRROR  指定脚本源 base URL
USAGE
}

cli_dispatch() {
    local cmd="${1:-}" sub="${2:-}"
    case "$cmd" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    status) cmd_status ;;
    update)
        case "$sub" in
        sbs) cmd_update_self ;;
        *)
            core_error "未知子命令: update $sub"
            cli_help
            return 1
            ;;
        esac
        ;;
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
