curl -L -o sb.sh https://github.oterea.top/https://raw.githubusercontent.com/Oterea/sing-box-shell/main/sb.sh
chmod +x sb.sh


# 定义变量
SB_URL=""
CONFIG_URL=""

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
echo "SB_URL=$SB_URL" > "$URL"
echo "CONFIG_URL=$CONFIG_URL" >> "$URL"
