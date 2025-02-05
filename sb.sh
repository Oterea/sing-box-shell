#!/bin/bash
# 定义颜色变量
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
PURPLE='\033[35m'
CYAN='\033[36m'
WHITE='\033[37m'
RESET='\033[0m' # 重置颜色

TARGET_DIR="$HOME"
EXTRACT_DIR="$HOME/sing-box"  # 提取内容到的目标目录
# 创建目标目录（如果不存在）
if [ ! -d "$EXTRACT_DIR" ]; then
    mkdir -p "$EXTRACT_DIR"
fi

URL=$EXTRACT_DIR/url.txt
source $URL
CONFIG_FILE="$EXTRACT_DIR/config.json"  # 保存为 config.json 文件

# 检查curl下载工具
if command -v curl >/dev/null 2>&1; then
    echo -e "${GREEN}curl 已安装${RESET}"
else
    echo -e "${YELLOW}curl 未安装${RESET}"
    exit
fi

# 一级菜单
while true; do

    echo -e "${PURPLE}+==========================================+${RESET}"
    echo -e "${PURPLE}+                  Main menu               +${RESET}"
    echo -e "${WHITE}+---+--------------------------------------+${RESET}"
    echo -e "${CYAN}  1 ${WHITE}|              ${CYAN}Update sing-box          ${RESET}"
    echo -e "${WHITE}+---+--------------------------------------+${RESET}"
    echo -e "${CYAN}  2 ${WHITE}|              ${CYAN}Update config            ${RESET}"
    echo -e "${WHITE}+---+--------------------------------------+${RESET}"
    echo -e "${CYAN}  3 ${WHITE}|              ${CYAN}Start sing-box           ${RESET}"
    echo -e "${WHITE}+---+--------------------------------------+${RESET}"
    echo -e "${CYAN}  4 ${WHITE}|              ${CYAN}Stop sing-box           ${RESET}"
    echo -e "${WHITE}+---+--------------------------------------+${RESET}"
    echo -e "${CYAN}  0 ${WHITE}|              ${CYAN}Exit shell               ${RESET}"
    echo -e "${WHITE}+---+--------------------------------------+${RESET}"

    # 提示用户输入
    echo -e "${CYAN}请输入对应序号: ${RESET}"
    read choice

    case $choice in

        1)
            echo -e "${PURPLE}============================================${RESET}"
            echo -e "${PURPLE}              Updating sing-box             ${RESET}"

            echo -e "${CYAN}默认下载链接: $SB_URL${RESET}"
            echo -e "${CYAN}是否使用默认下载链接([Y]/n): ${RESET}"
            read sub_choice
            sub_choice=${sub_choice:-y}

            # 转换为小写并使用 if 语句判断
            if [[ "${sub_choice,,}" == "y" ]]; then
                :
                # 在这里执行使用默认链接的操作
            elif [[ "${sub_choice,,}" == "n" ]]; then
                # 在这里执行不使用默认链接的操作
                echo -e "${CYAN}请输入 sing-box 下载链接: ${RESET}"
                read sb_url
                # 检查 url.txt 是否已经有 SB_URL，如果有则替换，否则追加
                if grep -q '^SB_URL=' $URL; then
                    # 替换已有的 SB_URL
                    sed -i 's|^SB_URL=.*|SB_URL="'"$PROXY/$sb_url"'"|' $URL
                else
                    # 追加新变量到 url.txt
                    echo "SB_URL=\"$PROXY/$sb_url\"" >> $URL
                fi

            else
                echo -e "${YELLOW}WARN: 无效的选择，请输入 y 或 n${RESET}"
            fi

            source $URL
            FILE_NAME=$(basename "$SB_URL")

            success=1
            # curl 下载
         
            echo -e "${GREEN}INFO: Using curl to download the file...${RESET}"
            curl -o "$TARGET_DIR/$FILE_NAME" -L "$SB_URL"
            if [ $? -eq 0 ]; then
                success=0
            fi
    

            # 检查下载是否成功
            if [ "$success" -eq 0 ]; then
                echo -e "${GREEN}INFO: sing-box downloaded successfully to $TARGET_DIR/$FILE_NAME${RESET}"
            else
                echo -e "${RED}ERROE: File download failed.${RESET}"
                rm $TARGET_DIR/$FILE_NAME
                break
            fi

            # 检查解压工具 tar 是否安装，如果没有则自动安装
            if ! command -v tar >/dev/null 2>&1; then
                echo -e "${YELLOW}WARN: tar is not installed. Installing tar...${RESET}"
                sudo apt update && sudo apt install -y tar
                if [ $? -ne 0 ]; then
                    echo -e "${RED}ERROR: Failed to install tar. Exiting...${RESET}"
                    break
                fi
            fi

            # 解压并提取内容到目标目录
            tar --strip-components=1 -xzf "$TARGET_DIR/$FILE_NAME" -C "$EXTRACT_DIR"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}INFO: ${FILE_NAME} extracted successfully to $EXTRACT_DIR${RESET}"
            else
                echo -e "${RED}ERROR: Failed to extract sing-box.${RESET}"
                break
            fi
            # 删除源文件
            rm "$TARGET_DIR/$FILE_NAME"

            # 提取版本信息
            VERSION_DATA=$($EXTRACT_DIR/sing-box version)
            VERSION=$(echo "$VERSION_DATA" | grep -oP 'sing-box version \K[0-9]+\.[0-9]+\.[0-9]+')
            VERSION_INFO="sing-box-$VERSION"



            ;;
        2)
            echo -e "${PURPLE}============================================${RESET}"
            echo -e "${PURPLE}              Updating config             ${RESET}"
            echo -e "${CYAN}默认订阅链接: $CONFIG_URL${RESET}"
            echo -e "${CYAN}是否使用默认订阅链接([Y]/n): ${RESET}"
            read sub_choice
            sub_choice=${sub_choice:-y}

            # 转换为小写并使用 if 语句判断
            if [[ "${sub_choice,,}" == "y" ]]; then
                :
                # 在这里执行使用默认链接的操作
            elif [[ "${sub_choice,,}" == "n" ]]; then
                # 在这里执行不使用默认链接的操作
                echo -e "${CYAN}请输入 config 下载链接: ${RESET}"
                read config_url
                # 检查 url.txt 是否已经有 SB_URL，如果有则替换，否则追加
                if grep -q '^CONFIG_URL=' $URL; then
                    # 替换已有的 CONFIG_URL
                    sed -i 's|^CONFIG_URL=.*|CONFIG_URL="'"$PROXY/$config_url"'"|' $URL
                else
                    # 追加新变量到 url.txt
                    echo "CONFIG_URL=\"$PROXY/$config_url\"" >> $URL
                fi
                source $URL

            else
                echo -e "${YELLOW}WARN: 无效的选择，请输入 y 或 n${RESET}"
            fi


            # 检查是否安装 curl 或 wget
            echo -e "${GREEN}INFO: Using curl to fetch the config.json...${RESET}"
            curl -s "$CONFIG_URL" -o "$CONFIG_FILE"  # 直接覆盖目标文件
            

            # 检查写入是否成功
            if [ -f "$CONFIG_FILE" ]; then
                echo -e "${GREEN}INFO: config updating successfully${RESET}"
            else
                echo -e "${RED}ERROR: Failed to save config${RESET}"
                break
            fi

            # 设置 sb.service 文件路径
            #
            SERVICE_FILE="/etc/systemd/system/sb.service"
            # 检查文件是否存在，若存在则覆盖
            if [ -f "$SERVICE_FILE" ]; then
                echo -e "${YELLOW}WARN: The file $SERVICE_FILE already exists. It will be overwritten.${RESET}"
            fi

            # 创建 sb.service 文件并写入内容，直接覆盖内容
            echo "[Unit]
            Description=$VERSION_INFO
            After=network.target

            [Service]
            ExecStart=$EXTRACT_DIR/sing-box run
            WorkingDirectory=$EXTRACT_DIR/
            Restart=always

            [Install]
            WantedBy=multi-user.target" | sudo tee "$SERVICE_FILE" > /dev/null

            # 检查文件是否创建并覆盖成功
            if [ -f "$SERVICE_FILE" ]; then
                echo -e "${GREEN}INFO: Service file created successfully at $SERVICE_FILE${RESET}"
                # 重新加载 systemd 配置
                sudo systemctl daemon-reload
            else
                echo -e "${RED}ERROR: Failed to create sb.service file.${RESET}"
                break
            fi


            ;;
        3)  
            sudo systemctl start sb
            curl ipinfo.io
            echo
            echo -e "${GREEN}INFO: sing-box started successfully.${RESET}"
            ;;
        4)  
            sudo systemctl stop sb
            curl ipinfo.io
            echo
            echo -e "${GREEN}INFO: sing-box stoped successfully.${RESET}"
            ;;
        5)  
            sudo rm -r $EXTRACT_DIR
            sudo rm /etc/systemd/system/sb.service
            echo
            echo -e "${GREEN}INFO: sing-box removed successfully.${RESET}"
            break
            ;;

        0)
            echo -e "${GREEN}INFO: Exit sing-box shell successfully.${RESET}"
            break
            ;;
        *)
            echo -e "${YELLOW}WARN:not a valid number${RESET}"
            ;;
    esac
done
