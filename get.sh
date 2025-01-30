curl -L -o sb.sh https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/refs/heads/main/sb.sh?token=GHSAT0AAAAAAC5ZKK7DE6S5KUP2SPPJHVNAZ43GGFA
chmod +x sb.sh
mv -f sb.sh /usr/local/bin/sb

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


# 写入文件
echo "SB_URL=$SB_URL" > "$URL"
echo "CONFIG_URL=$CONFIG_URL" >> "$URL"
