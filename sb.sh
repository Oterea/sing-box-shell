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


work_dir="$HOME/sing-box"
share="$work_dir/share.txt"
source $share



config_file="$work_dir/config.json"  # 保存为 config.json 文件

# 检查curl下载工具
if command -v curl >/dev/null 2>&1; then
    echo -e "${GREEN}curl 已安装${RESET}"
else
    echo -e "${YELLOW}curl 未安装${RESET}"
    exit
fi


install_sb() {
    echo -e "${PURPLE}+==========================================+${RESET}"
    echo -e "${PURPLE}              Updating sing-box             ${RESET}"

    echo -e "${CYAN}默认下载链接: $sb_url${RESET}"
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
        read sb_url_temp
        # 检查 share.txt 是否已经有 sb_url，如果有则替换，否则追加
        if grep -q '^sb_url=' $share; then
            # 替换已有的 sb_url
            sed -i 's|^sb_url=.*|sb_url="'"$proxy/$sb_url_temp"'"|' $share
        else
            # 追加新变量到 url.txt
            echo "sb_url=\"$proxy/$sb_url_temp\"" >> $share
        fi

    else
        echo -e "${YELLOW}WARN: 无效的选择，请输入 y 或 n${RESET}"
    fi

    source $share
    file_name=$(basename "$sb_url")

    success=1
    # curl 下载
    
    echo -e "${GREEN}INFO: Using curl to download sing-box...${RESET}"
    curl -o "$work_dir/$file_name" -L "$sb_url"
    if [ $? -eq 0 ]; then
        success=0
    fi


    # 检查下载是否成功
    if [ "$success" -eq 0 ]; then
        echo -e "${GREEN}INFO: sing-box downloaded successfully to $work_dir/$file_name${RESET}"
    else
        echo -e "${RED}ERROE: File download failed.${RESET}"
        rm $work_dir/$file_name
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
    tar --strip-components=1 -xzf "$work_dir/$file_name" -C "$work_dir"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}INFO: ${file_name} extracted successfully to $work_dir${RESET}"
    else
        echo -e "${RED}ERROR: Failed to extract sing-box.${RESET}"
        break
    fi
    # 删除源文件
    rm "$work_dir/$file_name"

    # 提取版本信息
    version_data=$($work_dir/sing-box version)
    version=$(echo "$version_data" | grep -oP 'sing-box version \K[0-9]+\.[0-9]+\.[0-9]+')
    version_info="sing-box-$version"



    echo "Hello from my function!"
}

remove_sb() {
    sudo rm -rf $work_dir
    sudo rm -f $service
    sudo rm -f $exec
    echo
    echo -e "${GREEN}INFO: Old sing-box removed successfully.${RESET}"
}

create_main_menu(){
    echo -e "${PURPLE}+==========================================+${RESET}"
    echo -e "${PURPLE}+                  $1               +${RESET}"
    echo -e "${PURPLE}+==========================================+${RESET}"
    echo -e "${WHITE}+---+--------------------------------------+${RESET}"
}
create_menu(){
    echo -e "${CYAN}  $1 ${WHITE}|              ${CYAN}$2          ${RESET}"
    echo -e "${WHITE}+---+--------------------------------------+${RESET}"
}
install_tar(){

}

# 一级菜单
while true; do

  
    create_main_menu "Main menu"
    create_menu 1 "Install sing-box"
    create_menu 2 "Update sing-box"
    create_menu 3 "Update config"
    create_menu 4 "Start sing-box"
    create_menu 5 "Stop sing-box"
    create_menu 6 "Remove sing-box"
    create_menu 0 "Exit shell"


    # 提示用户输入
    echo -e "${CYAN}请输入对应序号: ${RESET}"
    read -n 1 choice
    echo

    case $choice in

        1)
            install_sb
            ;;
        2)
            install_sb
            ;;
        3)
            echo -e "${PURPLE}============================================${RESET}"
            echo -e "${PURPLE}              Updating config             ${RESET}"
            echo -e "${CYAN}默认订阅链接: $config_url${RESET}"
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
                read config_url_temp
                # 检查 share.txt 是否已经有 config_url
                if grep -q '^config_url=' $share; then
                    # 替换已有的 config_url
                    sed -i 's|^config_url=.*|config_url="'"$config_url_temp"'"|' $share
                else
                    # 追加新变量到 url.txt
                    echo "config_url=\"$config_url_temp\"" >> $share
                fi
                source $share

            else
                echo -e "${YELLOW}WARN: 无效的选择，请输入 y 或 n${RESET}"
            fi


            # 检查是否安装 curl
            echo -e "${GREEN}INFO: Using curl to fetch the config.json...${RESET}"
            curl -s "$config_url" -o "$config_file"  # 直接覆盖目标文件
            

            # 检查写入是否成功
            if [ -f "$config_file" ]; then
                echo -e "${GREEN}INFO: config updating successfully${RESET}"
            else
                echo -e "${RED}ERROR: Failed to save config${RESET}"
                break
            fi

            # 设置 sb.service 文件路径
         
            # 检查文件是否存在，若存在则覆盖
            if [ -f "$service" ]; then
                echo -e "${YELLOW}WARN: The file $service already exists. It will be overwritten.${RESET}"
            fi

            # 创建 sb.service 文件并写入内容，直接覆盖内容
            echo "[Unit]
            Description=$version_info
            After=network.target

            [Service]
            ExecStart=$work_dir/sing-box run
            WorkingDirectory=$work_dir/
            Restart=always

            [Install]
            WantedBy=multi-user.target" | sudo tee "$service" > /dev/null

            # 检查文件是否创建并覆盖成功
            if [ -f "$service" ]; then
                echo -e "${GREEN}INFO: Service file created successfully at $service${RESET}"
                # 重新加载 systemd 配置
                sudo systemctl daemon-reload
            else
                echo -e "${RED}ERROR: Failed to create sb.service file.${RESET}"
                break
            fi


            ;;
        4)  
            sudo systemctl start sb
            curl ipinfo.io
            echo
            echo -e "${GREEN}INFO: sing-box started successfully.${RESET}"
            ;;
        5)  
            sudo systemctl stop sb
            curl ipinfo.io
            echo
            echo -e "${GREEN}INFO: sing-box stoped successfully.${RESET}"
            ;;
        6)  
            remove_sb
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
