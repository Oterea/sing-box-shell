#!/bin/bash
# sing-box-shell 安装器。把 sbs.sh 取回来放到 /usr/local/bin/sbs。

exec="/usr/local/bin/sbs"

# ── 配色 ──────────────────────────────────────────────────────────
# 三档：真彩 -> 256 色 -> 无色。真彩看 COLORTERM 而不是 tput —— ncurses 只认
# terminfo 里声明的色数，而绝大多数终端的 terminfo 只写到 256。
# 输出不是终端（重定向、管道）或 NO_COLOR 时一个转义序列都不发。
# 不能只信 tput：ssh 不转发 COLORTERM，而服务器上往往没有客户端那套 terminfo
# （实测 xterm-ghostty 就没有，tput colors 直接报 unknown terminal），真彩终端
# 会被判成无色。所以再按 TERM 的名字认一遍。
CMODE=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    case "${COLORTERM:-}" in
    truecolor | 24bit) CMODE=24 ;;
    esac
    [ "$CMODE" -eq 0 ] && case "${TERM:-}" in
    *-direct* | *truecolor* | *ghostty* | *kitty* | alacritty* | wezterm* | contour* | foot* | *-24bit*) CMODE=24 ;;
    *256color* | *-256*) CMODE=8 ;;
    *) [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ] && CMODE=8 ;;
    esac
fi
if [ "$CMODE" -gt 0 ]; then
    DIM=$'\e[2m' GREEN=$'\e[32m' RED=$'\e[31m' BOLD=$'\e[1m' RESET=$'\e[0m'
else
    DIM='' GREEN='' RED='' BOLD='' RESET=''
fi

ART=(
    '   _____ ____  _____'
    '  / ___// __ )/ ___/'
    '  \__ \/ __  |\__ \ '
    ' ___/ / /_/ /___/ / '
    '/____/_____//____/  '
)

# 大写 SBS，橙 -> 粉 -> 紫五段渐变，斜着走（每往下一行整条色带偏一点）。
# 跟 sbs 菜单里那个同一套画法，只是这里是一次性的，取其中一组色带定住不动。
# 每两列共用一个颜色：转义序列少一半，肉眼看不出来
STOPS=(234 88 12 244 63 94 236 72 153 192 38 211 147 51 234)
logo() {
    local row col ch t r g b w=20 den=19 band last ri=0 seg=4 si fr
    if [ "$CMODE" -eq 0 ]; then
        printf '%s\n' "${ART[@]}"
        echo
        return 0
    fi
    for row in "${ART[@]}"; do
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
                r=$((STOPS[si * 3] + (STOPS[si * 3 + 3] - STOPS[si * 3]) * fr / 1000))
                g=$((STOPS[si * 3 + 1] + (STOPS[si * 3 + 4] - STOPS[si * 3 + 1]) * fr / 1000))
                b=$((STOPS[si * 3 + 2] + (STOPS[si * 3 + 5] - STOPS[si * 3 + 2]) * fr / 1000))
                if [ "$CMODE" -eq 24 ]; then
                    printf '\033[38;2;%d;%d;%dm' "$r" "$g" "$b"
                else
                    printf '\033[38;5;%dm' $((16 + 36 * (r * 5 / 255) + 6 * (g * 5 / 255) + (b * 5 / 255)))
                fi
            fi
            printf '%s' "$ch"
            col=$((col + 1))
        done
        printf '%s\n' "$RESET"
        ri=$((ri + 1))
    done
    echo
}

logo

[ -d /usr/local/bin ] || {
    sudo mkdir -p /usr/local/bin && sudo chmod 755 /usr/local/bin
} || {
    printf '  %s✗%s  cannot create /usr/local/bin\n' "$RED" "$RESET"
    exit 1
}

# 脚本源，按优先级排列。SBS_MIRROR 可覆盖（只用指定的那个）。
# 不缓存的排前面：jsDelivr 是 CDN，@main 有约 12h TTL，push 后会持续吐旧版
# （purge 接口也是异步的），所以只作兜底
script_sources="
https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main
https://ghfast.top/https://raw.githubusercontent.com/Oterea/sing-box-shell/main
https://raw.githubusercontent.com/Oterea/sing-box-shell/main
https://testingcf.jsdelivr.net/gh/Oterea/sing-box-shell@main
"

# 下载放独占的临时目录，不碰用户当前目录（curl -o 会静默覆盖同名文件）
tmpdir=$(mktemp -d) || {
    printf '  %s✗%s  cannot create a temp directory\n' "$RED" "$RESET"
    exit 1
}
# 落位用的中转名字，放在目标旁边以保证同一文件系统 —— 这样最后一步一定是真改名
stage="$(dirname "$exec")/.$(basename "$exec").$$.tmp"
cleanup() {
    rm -rf "$tmpdir"
    sudo rm -f "$stage" 2>/dev/null
}
trap cleanup EXIT # 正常结束、报错、Ctrl-C 都会清

ok=0
for base in ${SBS_MIRROR:-$script_sources}; do
    host=${base#https://}
    host=${host%%/*}
    printf '  %s·  %s%s\n' "$DIM" "$host" "$RESET"
    if curl -fsSL --connect-timeout 5 --retry 2 -o "$tmpdir/sbs.sh" "$base/sbs.sh"; then
        ok=1
        break
    fi
done

if [ "$ok" -ne 1 ]; then
    printf '  %s✗%s  all sources failed\n' "$RED" "$RESET"
    printf '     %sset SBS_MIRROR=<base-url> to pick one%s\n' "$DIM" "$RESET"
    exit 1
fi

# 先复制到中转名字（全新名字，没有进程在用，覆盖它是安全的）
sudo cp "$tmpdir/sbs.sh" "$stage" || exit 1
sudo chmod 755 "$stage" || exit 1
# 再改名顶替。同盘 rename，原子；正在运行的旧脚本仍持有旧 inode，不会被读串
sudo mv -f "$stage" "$exec" || exit 1

printf '  %s✓%s  installed to %s\n' "$GREEN" "$RESET" "$exec"
printf '     %srun%s %ssbs%s %sto get started%s\n' "$DIM" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
