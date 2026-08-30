#!/bin/bash
# sing-box-shell 安装器。把 sbs.sh 取回来放到 /usr/local/bin/sbs。

exec="/usr/local/bin/sbs"

# ── 配色 ──────────────────────────────────────────────────────────
# 三档：真彩 -> 256 色 -> 无色。真彩看 COLORTERM 而不是 tput —— ncurses 只认
# terminfo 里声明的色数，而绝大多数终端的 terminfo 只写到 256。
# 输出不是终端（重定向、管道）或 NO_COLOR 时一个转义序列都不发。
CMODE=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    case "${COLORTERM:-}" in
    truecolor | 24bit) CMODE=24 ;;
    *) [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ] && CMODE=8 ;;
    esac
fi
if [ "$CMODE" -gt 0 ]; then
    DIM=$'\e[2m' GREEN=$'\e[32m' RED=$'\e[31m' BOLD=$'\e[1m' RESET=$'\e[0m'
else
    DIM='' GREEN='' RED='' BOLD='' RESET=''
fi

# 大写 SBS，紫 -> 粉 -> 橙横向渐变
logo() {
    local art=(
        '   _____ ____  _____'
        '  / ___// __ )/ ___/'
        '  \__ \/ __  |\__ \ '
        ' ___/ / /_/ /___/ / '
        '/____/_____//____/  '
    )
    local row col ch t r g b w=20 den=19
    if [ "$CMODE" -eq 0 ]; then
        printf '%s\n' "${art[@]}"
        echo
        return 0
    fi
    for row in "${art[@]}"; do
        col=0
        while [ "$col" -lt "$w" ]; do
            ch=${row:col:1}
            t=$((col * 1000 / den))
            if [ "$t" -lt 500 ]; then
                r=$((139 + (236 - 139) * t / 500))
                g=$((92 + (72 - 92) * t / 500))
                b=$((246 + (153 - 246) * t / 500))
            else
                t=$((t - 500))
                r=$((236 + (251 - 236) * t / 500))
                g=$((72 + (146 - 72) * t / 500))
                b=$((153 + (60 - 153) * t / 500))
            fi
            if [ "$CMODE" -eq 24 ]; then
                printf '\033[38;2;%d;%d;%dm%s' "$r" "$g" "$b" "$ch"
            else
                printf '\033[38;5;%dm%s' $((16 + 36 * (r * 5 / 255) + 6 * (g * 5 / 255) + (b * 5 / 255))) "$ch"
            fi
            col=$((col + 1))
        done
        printf '%s\n' "$RESET"
    done
    echo
}

logo

[ -d /usr/local/bin ] || {
    sudo mkdir -p /usr/local/bin && sudo chmod 755 /usr/local/bin
} || {
    printf '  %s✗%s  无法创建 /usr/local/bin\n' "$RED" "$RESET"
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
    printf '  %s✗%s  无法创建临时目录\n' "$RED" "$RESET"
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
    printf '  %s✗%s  所有源都拉不到\n' "$RED" "$RESET"
    printf '     %s可用 SBS_MIRROR=<base-url> 手动指定%s\n' "$DIM" "$RESET"
    exit 1
fi

# 先复制到中转名字（全新名字，没有进程在用，覆盖它是安全的）
sudo cp "$tmpdir/sbs.sh" "$stage" || exit 1
sudo chmod 755 "$stage" || exit 1
# 再改名顶替。同盘 rename，原子；正在运行的旧脚本仍持有旧 inode，不会被读串
sudo mv -f "$stage" "$exec" || exit 1

printf '  %s✓%s  installed to %s\n' "$GREEN" "$RESET" "$exec"
printf '     %srun%s %ssbs%s %sto get started%s\n' "$DIM" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
