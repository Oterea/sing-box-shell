#!/bin/bash
# 定义颜色变量
GREEN='\033[32m'
RESET='\033[0m' # 重置颜色
YELLOW='\033[33m'
RED='\033[31m'

exec="/usr/local/bin/sbs"

# 检查 /usr/local/bin/ 是否存在，不存在则创建
if [ ! -d "/usr/local/bin" ]; then
    echo "Directory /usr/local/bin/ does not exist. Creating it now..."
    sudo mkdir -p /usr/local/bin
    sudo chmod 755 /usr/local/bin
    echo "Directory /usr/local/bin/ created."
fi

# 脚本源，按优先级排列。SBS_MIRROR 可覆盖（只用指定的那个）
# 不缓存的排前面：jsDelivr 是 CDN，@main 有约 12h TTL，push 后会持续
# 吐旧版（purge 接口也是异步的），所以只作兜底
script_sources="
https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main
https://ghfast.top/https://raw.githubusercontent.com/Oterea/sing-box-shell/main
https://raw.githubusercontent.com/Oterea/sing-box-shell/main
https://testingcf.jsdelivr.net/gh/Oterea/sing-box-shell@main
"

# 下载放独占的临时目录，不碰用户当前目录（curl -o 会静默覆盖同名文件）
tmpdir=$(mktemp -d) || {
    echo -e "${RED}ERROR: 无法创建临时目录${RESET}"
    exit 1
}
# 落位用的中转名字，放在目标旁边以保证同一文件系统 —— 这样最后一步一定是真改名
stage="$(dirname "$exec")/.$(basename "$exec").$$.tmp"
cleanup() {
    rm -rf "$tmpdir"
    sudo rm -f "$stage" 2>/dev/null
}
trap cleanup EXIT   # 正常结束、报错、Ctrl-C 都会清

ok=0
for base in ${SBS_MIRROR:-$script_sources}; do
    echo -e "${YELLOW}INFO: trying ${base}${RESET}"
    if curl -fsSL --connect-timeout 5 --retry 2 -o "$tmpdir/sbs.sh" "$base/sbs.sh"; then
        echo -e "${GREEN}INFO: fetched from ${base}${RESET}"
        ok=1
        break
    fi
done

if [ "$ok" -ne 1 ]; then
    echo -e "${RED}ERROR: all sources failed. 可用 SBS_MIRROR=<base-url> 手动指定${RESET}"
    exit 1
fi

# 先复制到中转名字（全新名字，没有进程在用，覆盖它是安全的）
sudo cp "$tmpdir/sbs.sh" "$stage" || exit 1
sudo chmod 755 "$stage" || exit 1
# 再改名顶替。同盘 rename，原子；正在运行的旧脚本仍持有旧 inode，不会被读串
sudo mv -f "$stage" "$exec" || exit 1
echo -e "${GREEN}INFO: sing-box-shell has been successfully installed to ${exec}.${RESET}"
