curl -L -o sb.sh https://github.oterea.top/https://raw.githubusercontent.com/Oterea/sing-box-shell/main/sb.sh
chmod +x sb.sh


# 定义变量
proxy="https://github.oterea.top"
sb_url="https://github.com/SagerNet/sing-box/releases/download/v1.11.0/sing-box-1.11.0-linux-amd64.tar.gz"
config_url=""

TARGET_DIR="$HOME"
EXTRACT_DIR="$HOME/sing-box"  # 提取内容到的目标目录
# 创建目标目录（如果不存在）
if [ ! -d "$EXTRACT_DIR" ]; then
    mkdir -p "$EXTRACT_DIR"
fi
URL=$EXTRACT_DIR/url.txt

mv -f sb.sh $EXTRACT_DIR/sb.sh
alias sb="source $EXTRACT_DIR/sb.sh"

# 写入文件
echo "PROXY=$proxy" > "$URL"
echo "SB_URL=$proxy/$sb_url" >> "$URL"
echo "CONFIG_URL=$config_url" >> "$URL"
