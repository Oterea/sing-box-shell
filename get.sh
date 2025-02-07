GREEN='\033[32m'
RESET='\033[0m' # 重置颜色

# 定义变量

config_url=""
    # 定义工作文件夹
work_dir="$HOME/sing-box"
    # 下载配置和sing-box的链接文件
share="$work_dir/share.txt"

echo -e "${GREEN}INFO: installing jq${RESET}"
sudo apt install -y -qq jq >/dev/null 2>&1
# 删除旧的 sing-box
remove_sb() {
    cd
    sudo rm -rf $work_dir
    sudo rm -f $service
    sudo rm -f $exec
    echo -e "${GREEN}INFO: old sing-box removed successfully.${RESET}"
}
remove_sb

# 创建目标目录（如果不存在）
if [ ! -d "$work_dir" ]; then
    mkdir -p "$work_dir"
fi


echo "config_url=$config_url" >> "$share"



curl -o sb.sh -fsSL https://gitee.com/Oterea/sing-box-shell/raw/main/sb.sh
sudo chmod +x sb.sh

sudo mv -f sb.sh /usr/local/bin/sb
echo -e "${GREEN}INFO: Sbshell installed successfully.${RESET}"




