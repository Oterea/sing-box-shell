GREEN='\033[32m'
RESET='\033[0m' # 重置颜色

# 定义变量
proxy="https://github.oterea.top"
sb_url="https://github.com/SagerNet/sing-box/releases/download/v1.11.0/sing-box-1.11.0-linux-amd64.tar.gz"
config_url=""
    # 定义工作文件夹
work_dir="$HOME/sing-box"
    # 下载配置和sing-box的链接文件
share="$work_dir/share.txt"
exec="/usr/local/bin/sb"
service="/etc/systemd/system/sb.service"

# 删除旧的 sing-box
remove_sb() {
    sudo rm -rf $work_dir
    sudo rm -f $service
    sudo rm -f $exec
    echo
    echo -e "${GREEN}INFO: Old sing-box removed successfully.${RESET}"
}
remove_sb

# 创建目标目录（如果不存在）
if [ ! -d "$work_dir" ]; then
    mkdir -p "$work_dir"
fi

echo "proxy=$proxy" > "$share"
echo "sb_url=$proxy/$sb_url" >> "$share"
echo "config_url=$config_url" >> "$share"
echo "exec=$exec" >> "$share"
echo "service=$service" >> "$share"


curl --progress-bar -o sb.sh -L https://gitee.com/Oterea/sing-box-shell/raw/main/sb.sh
sudo chmod +x sb.sh

sudo mv -f sb.sh /usr/local/bin/sb




