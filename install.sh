#!/bin/bash
# 定义颜色变量
GREEN='\033[32m'
RESET='\033[0m' # 重置颜色
YELLOW='\033[33m'

exec="/usr/local/bin/sbs"

# 检查 /usr/local/bin/ 是否存在，不存在则创建
if [ ! -d "/usr/local/bin" ]; then
    echo "Directory /usr/local/bin/ does not exist. Creating it now..."
    sudo mkdir -p /usr/local/bin
    sudo chmod 755 /usr/local/bin
    echo "Directory /usr/local/bin/ created."
fi

curl -o sbs.sh -fsSL https://gitee.com/Oterea/sing-box-shell/raw/main/sbs.sh
sudo chmod +x sbs.sh

sudo mv -f sbs.sh $exec
echo -e "${GREEN}INFO: sing-box-shell has been successfully installed to ${exec}.${RESET}"
