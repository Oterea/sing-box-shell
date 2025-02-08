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

proxy="https://github.oterea.top"
work_dir="$HOME/sing-box"
exec="/usr/local/bin/sb"
service="/etc/systemd/system/sb.service"
share="$work_dir/share.txt"
source $share



config_file="$work_dir/config.json"  # 保存为 config.json 文件



get_latest_version() {
    # ====================================获取最新版本下载链接====================================
    latest_beta_v=""
    latest_stable_v=""

    beta_url="https://api.github.com/repos/SagerNet/sing-box/releases?per_page=15"
    stable_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    # 获取最新的稳定版本和下载链接
    stable_data=$(curl -fsSL "$stable_url")
    latest_stable_v=$(echo "$stable_data" | jq -r '.tag_name')
    latest_stable_linux_amd64_url=$(echo "$stable_data" | jq -r '.assets[] | select(.browser_download_url | test("linux-amd64")) | .browser_download_url')
    # 获取最新的测试版本（beta）和下载链接
    # 循环每页返回 15 个 releases
    next_url="$beta_url"
    while [[ -n "$next_url" ]]; do
        # 获取当前页的 release 数据，并解析 `Link` 头部
        beta_data_list=$(curl -fsSL -D headers.txt "$next_url")
        if [[ $? -ne 0 ]]; then
            echo "❌ 获取 beta 版本数据失败！"
            exit 1
        fi
        # 提取 beta 版本
        beta_data=""
        beta_data=$(echo "$beta_data_list" | jq -c '.[] | select(.tag_name | test("-beta"))' | head -n 1)

        # 如果找到了 beta 版本，立刻退出循环
        if [[ -n "$beta_data" ]]; then
            # TODO===============assets修改
            latest_beta_v=$(echo "$beta_data" | jq -r '.tag_name')
            latest_beta_linux_amd64_url=$(echo "$beta_data" | jq -r '.assets[] | select(.browser_download_url | test("linux-amd64")) | .browser_download_url')
            break
        fi
        # 解析 `Link` 头部，获取下一页的 URL
        next_url=$(grep -i '^link:' headers.txt | sed -n 's/.*<\(.*\)>; rel="next".*/\1/p')
        if [[ -z "$next_url" ]]; then
            echo "❌ 没有找到下一页的链接，停止查询。"
            break
        fi
        # 清理临时文件
        rm -f headers.txt
    done
    echo -e "${GREEN}INFO: latest stable version ✅: $latest_stable_v.${RESET}"
    echo -e "${GREEN}INFO: latest beta version 🚀: $latest_beta_v.${RESET}"

}
check_installed_version() {
    if [ -e "$work_dir/sing-box" ]; then
        
        # 提取版本信息
        version_data=$($work_dir/sing-box version)
        version="v$(echo "$version_data" | grep -oP 'sing-box version \K[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9\.]+)?')"
        echo -e "${GREEN}INFO: sing-box version: $version."
        return 0
    
    fi

    
    echo -e "${YELLOW}WARN: sing-box is not installed.${RESET}"
    return 1
    
}

install() {
    # 提示用户输入
    echo -e "${CYAN}PROMPT: install stable version? [Y/n]: ${RESET}"
    read -n 1 is_stable
    is_stable=${is_stable:-y}

    # 转换为小写并使用 if 语句判断
    if [[ "${is_stable,,}" == "y" ]]; then
        echo -e "${GREEN}INFO: downloading stable version. ${RESET}"
        download_url=$latest_stable_linux_amd64_url
    elif [[ "${is_stable,,}" == "n" ]]; then
        echo -e "${GREEN}INFO: downloading beta version. ${RESET}"
        download_url=$latest_beta_linux_amd64_url

    else
        echo -e "${YELLOW}WARN: invalid input, please input 'y' or 'n'.${RESET}"
    fi
    
    # ====================================下载解压====================================
    file_name=$(basename "$download_url")
    success=1
    # curl 下载
    
    echo -e "${GREEN}INFO: using curl to download sing-box...${RESET}"
    curl --progress-bar -o "$work_dir/$file_name" -L "$proxy/$download_url"
    if [ $? -eq 0 ]; then
        success=0
    fi


    # 检查下载是否成功
    if [ "$success" -eq 0 ]; then
        echo -e "${GREEN}INFO: sing-box downloaded successfully to $work_dir/$file_name.${RESET}"
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
        echo -e "${GREEN}INFO: ${file_name} extracted successfully to $work_dir.${RESET}"
    else
        echo -e "${RED}ERROR: Failed to extract sing-box.${RESET}"
        break
    fi
    # 删除源文件
    rm "$work_dir/$file_name"
    # ====================================设置sb.service==================================== 
    # 提取版本信息
    check_installed_version
  
    # 检查sb.service 文件是否存在，若存在则覆盖
    if [ -f "$service" ]; then
        echo -e "${YELLOW}INFO: The file $service already exists. It will be overwritten.${RESET}"
    fi

    # 创建 sb.service 文件并写入内容，直接覆盖内容
    echo "[Unit]
    Description=$version
    After=network.target

    [Service]
    ExecStart=$work_dir/sing-box run
    WorkingDirectory=$work_dir/
    Restart=always

    [Install]
    WantedBy=multi-user.target" | sudo tee "$service" > /dev/null

    # 检查文件是否创建并覆盖成功
    if [ -f "$service" ]; then
        echo -e "${GREEN}INFO: Service file created successfully at $service.${RESET}"
        # 重新加载 systemd 配置
        sudo systemctl daemon-reload
    else
        echo -e "${RED}ERROR: Failed to create sb.service file.${RESET}"
        break
    fi
}

check_config() {

    check_installed_version
    status=$?

    if [ $status -eq 0 ]; then
        if [ -e "$config_file" ]; then

            output=$($work_dir/sing-box check -c $config_file 2>&1)

            if [ -z "$output" ]; then
                echo -e "${GREEN}INFO: config.json correct.${RESET}"
                return 0
                
            else
                echo -e "${RED}ERROR: config.json is not correct.${RESET}"
                echo "$output"
                return 1
            fi
            
        else
            echo -e "${RED}ERROR: config.json is not exist.${RESET}"
            return 1
        fi
    else
        return 1
    fi

    # if [ -e "$work_dir/sing-box" ]; then
        

    # else
    #     echo -e "${YELLOW}WARN: sing-box is not installed, then check config.${RESET}"
    # fi
}

fetch_config() {
    if [ -z "$config_url" ]; then
        echo -e "${CYAN}PROMPT: please input sub link: ${RESET}"
        read config_url
    else
        echo -e "${CYAN}PROMPT: default sub link: $config_url${RESET}"
        echo -e "${CYAN}PROMPT: use default? [Y/n]: ${RESET}"
        read -n 1 sub_choice
    fi

    sub_choice=${sub_choice:-y}

    # 转换为小写并使用 if 语句判断
    if [[ "${sub_choice,,}" == "y" ]]; then
        :
        # 在这里执行使用默认链接的操作
    elif [[ "${sub_choice,,}" == "n" ]]; then
        # 在这里执行不使用默认链接的操作
        echo -e "${CYAN}PROMPT: please input sub link: ${RESET}"
        read config_url_temp
        # 检查 share.txt 是否已经有 config_url
        if grep -q '^config_url=' $share; then
            # 替换已有的 config_url
            sed -i 's|^config_url=.*|config_url="'"$config_url_temp"'"|' $share
        else
            # 追加新变量到 share.txt
            echo "config_url=\"$config_url_temp\"" >> $share
        fi
        source $share

    else
        echo -e "${YELLOW}WARN: invalid input, please input 'y' or 'n'.${RESET}"
    fi

    #  curl 拉取配置文件 
    echo -e "${GREEN}INFO: using curl to fetch the config.json...${RESET}"
    curl --progress-bar -o "$config_file" -L "$config_url" # 直接覆盖目标文件
    

    # 检查写入是否成功
    check_config
    status=$? 
    if [ $status -eq 0 ]; then
        echo -e "${GREEN}INFO: fetch config successfully${RESET}"

    fi
}

remove_sb() {
    cd
    sudo rm -rf $work_dir
    sudo rm -f $service
    sudo rm -f $exec
    echo -e "${GREEN}INFO: old sing-box removed successfully.${RESET}"
}

create_main_menu(){
    echo -e "${PURPLE}+===+==============================================+${RESET}"
    echo -e "${PURPLE}                   $1                ${RESET}"
    echo -e "${PURPLE}+===+==============================================+${RESET}"
}
create_menu(){
    echo -e "${CYAN}  $1 ${WHITE}|              ${CYAN}$2          ${RESET}"
    echo -e "${WHITE}+---+----------------------------------------------+${RESET}"
}

# 运行提示

check_config

# 一级菜单
while true; do

  
    create_main_menu "Main menu"
    create_menu 1 "Install sing-box"
    create_menu 2 "Update sing-box"
    create_menu 3 "Update config"
    create_menu 4 "Start sing-box"
    create_menu 5 "Stop sing-box"
    create_menu 6 "Status sing-box"
    create_menu 7 "Remove sing-box"
    create_menu 8 "Update shell"
    create_menu 0 "Exit shell"


    # 提示用户输入
    echo -e "${CYAN}PROMPT: Please enter the number: ${RESET}"
    read -n 1 choice
    echo

    case $choice in

        1)  
            create_main_menu "Installing sing-box"
            echo -e "${GREEN}INFO: fetching version data......${RESET}"
            get_latest_version
            install
            fetch_config
            ;;
        2)  
            create_main_menu "Updating sing-box"
            echo -e "${GREEN}INFO: fetching version data......${RESET}"
            get_latest_version
            check_installed_version
            install
            ;;
        3)

            create_main_menu "Updating config"
            fetch_config
            ;;
        4)  
            # 检查 sing-box 和 config
            check_config
            status=$? 
            if [ $status -eq 0 ]; then
                sudo systemctl start sb
                echo -e "${GREEN}INFO: sing-box started successfully.${RESET}"
            else
                continue
            fi


            ;;
        5)  
            # 检查 sing-box 和 config
            check_config
            status=$?  # 获取返回值

            if [ $status -eq 0 ]; then
                sudo systemctl stop sb
                echo -e "${GREEN}INFO: sing-box stoped successfully.${RESET}"
            else
                continue
            fi
            
            ;;
        6)  
            # status
            check_config
            status=$?  # 获取返回值

            if [ $status -eq 0 ]; then
                sudo systemctl status sb
                curl ipinfo.io
                echo
            else
                continue
            fi
            
            ;;
        7)  
            remove_sb
            break
            ;;
        8)  
            remove_sb
            curl -o sb.sh -fsSL https://gitee.com/Oterea/sing-box-shell/raw/main/sb.sh
            sudo chmod +x sb.sh

            sudo mv -f sb.sh /usr/local/bin/sb
            echo -e "${GREEN}INFO: sing-box-shell installed successfully.${RESET}"
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
