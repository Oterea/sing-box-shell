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
script_sources="
https://testingcf.jsdelivr.net/gh/Oterea/sing-box-shell@main
https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main
https://ghfast.top/https://raw.githubusercontent.com/Oterea/sing-box-shell/main
https://raw.githubusercontent.com/Oterea/sing-box-shell/main
"

ok=0
for base in ${SBS_MIRROR:-$script_sources}; do
    echo -e "${YELLOW}INFO: trying ${base}${RESET}"
    if curl -fsSL --connect-timeout 5 --retry 2 -o sbs.sh "$base/sbs.sh"; then
        echo -e "${GREEN}INFO: fetched from ${base}${RESET}"
        ok=1
        break
    fi
done

if [ "$ok" -ne 1 ]; then
    echo -e "${RED}ERROR: all sources failed. 可用 SBS_MIRROR=<base-url> 手动指定${RESET}"
    exit 1
fi
sudo chmod +x sbs.sh

sudo mv -f sbs.sh $exec
echo -e "${GREEN}INFO: sing-box-shell has been successfully installed to ${exec}.${RESET}"
