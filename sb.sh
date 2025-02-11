#!/bin/bash
# 定义颜色变量



UNDERLINE="$(tput smul 2>/dev/null || printf '')"
RED="$(tput setaf 1 2>/dev/null || printf '')"
GREEN="$(tput setaf 2 2>/dev/null || printf '')"
# GREEN='\033[32m'
YELLOW="$(tput setaf 3 2>/dev/null || printf '')"
BLUE="$(tput setaf 4 2>/dev/null || printf '')"
PURPLE="$(tput setaf 5 2>/dev/null || printf '')"
CYAN="$(tput setaf 6 2>/dev/null || printf '')"
WHITE="$(tput setaf 7 2>/dev/null || printf '')"
RESET="$(tput sgr0 2>/dev/null || printf '')"

proxy="https://github.oterea.top"
work_dir="$HOME/sing-box"
exec="/usr/local/bin/sb"
service="/etc/systemd/system/sb.service"
share="$work_dir/share.txt"

config_file="$work_dir/config.json"  # 保存为 config.json 文件

# 创建目标目录（如果不存在）
if [ ! -d "$work_dir" ]; then
    mkdir -p "$work_dir"
fi
info() {
    printf '%b\n' "${GREEN}INFO:${RESET} $*"
}
warn() {
    printf '%s\n' "${YELLOW}WARN:${RESET} $*"
}

error() {
    printf '%s\n' "${RED}ERROR:${RESET} $*"
}

prompt() {
    printf '%s\n' "${CYAN}PROMPT:${RESET} $*"
}

# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<检查工具<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
missing_tools=""
check_tools() {
    tool_name="$1"
    # 使用 command -v 来检查工具是否存在
    if ! command -v "$tool_name" > /dev/null 2>&1; then
        missing_tools="$missing_tools $tool_name"
    fi
}
check_tools "curl"
check_tools "tar"
check_tools "jq"


# 如果有工具没有安装，提示并退出
if [ -n "$missing_tools" ]; then
    error "the following tools are missing: $missing_tools, please install them and try again."
    exit
fi
# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>检查工具>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

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
    info "latest stable version ✅: $latest_stable_v."
    info "latest beta version 🚀: $latest_beta_v."


}
check_installed_version() {
    if [ -e "$work_dir/sing-box" ]; then
        
        # 提取版本信息
        version_data=$($work_dir/sing-box version)
        version="v$(echo "$version_data" | grep -oP 'sing-box version \K[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9\.]+)?')"
        info "sing-box version: $version."
        return 0
    
    fi

    
    warn "sing-box is not installed."
    return 1
    
}

install() {
    # 提示用户输入
    prompt "install stable version? [Y/n]:"
    read is_stable
    is_stable=${is_stable:-y}

    case "$is_stable" in
        [Nn])
            info "downloading beta version."
            download_url=$latest_beta_linux_amd64_url
        ;;
        # 默认稳定版
        *)
            info "downloading stable version."
            download_url=$latest_stable_linux_amd64_url
        ;;
    esac

    
    # ====================================下载解压====================================
    file_name=$(basename "$download_url")
    success=1
    # curl 下载
    
    info "using curl to download sing-box."
    curl --progress-bar -o "$work_dir/$file_name" -L "$proxy/$download_url"
    if [ $? -eq 0 ]; then
        success=0
    fi


    # 检查下载是否成功
    if [ "$success" -eq 0 ]; then
        info "sing-box downloaded successfully to $work_dir/$file_name."
    else
        echo -e "${RED}ERROE: File download failed.${RESET}"
        rm $work_dir/$file_name
        break
    fi

    # 检查解压工具 tar 是否安装，如果没有则自动安装
    if ! command -v tar >/dev/null 2>&1; then
        warn "tar is not installed. Installing tar."
        sudo apt update && sudo apt install -y tar
        if [ $? -ne 0 ]; then
            error "failed to install tar. exiting."
            break
        fi
    fi

    # 解压并提取内容到目标目录
    tar --strip-components=1 -xzf "$work_dir/$file_name" -C "$work_dir"
    if [ $? -eq 0 ]; then
        info "${file_name} extracted successfully to $work_dir."
    else
        error "failed to extract sing-box."
        break
    fi
    # 删除源文件
    rm "$work_dir/$file_name"
    # ====================================设置sb.service==================================== 
    # 提取版本信息
    check_installed_version
  
    # 检查sb.service 文件是否存在，若存在则覆盖
    if [ -f "$service" ]; then
        warn "the file $service already exists. it will be overwritten."
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
        info "service file created successfully at $service."
        # 重新加载 systemd 配置
        sudo systemctl daemon-reload
    else
        error "failed to create sb.service file."
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
                info "config.json is correct."
                return 0
                
            else
                error "config.json is not correct."
                echo "$output"
                return 1
            fi
            
        else
            error "config.json is not exist."
            return 1
        fi
    else
        return 1
    fi

}

fetch_config() {
    # 文件不存在则写入，存在就不管
    if [ ! -e "$share" ]; then
        echo "config_url=$config_url" >> "$share"
    fi
    source $share


    prompt "default sub link: $config_url"
    prompt "use default? [Y/n]:"
    read sub_choice
  

    sub_choice=${sub_choice:-y}


    case "$sub_choice" in
        [Yy])
            #todo 检查链接是否有效
            case "$config_url" in
                http*) 
                ;;
                *)
                    prompt "config_url invalid."
                    return
                ;;
            esac
        ;;
       
        [Nn])
            # 在这里执行不使用默认链接的操作
            prompt "please input sub link:"
            read config_url
            #todo 检查链接是否有效
            case "$config_url" in
                http*) 
                    # 覆盖所有内容到 share.txt
                    echo "config_url=\"$config_url\"" > $share
                    source $share
                ;;
                *)
                    prompt "config_url invalid."
                    return
                ;;
            esac

            
        ;;
        *)
           prompt "not a valid input, please input N/n or Y/y" 
           return
    esac

    #  curl 拉取配置文件 
    info "using curl to fetch the config.json."
    curl --progress-bar -o "$config_file" -L "$config_url" # 直接覆盖目标文件
    
    # 检查写入是否成功
    check_config
    status=$? 
    if [ $status -eq 0 ]; then
        info "fetch config successfully"

    fi
}

remove_sb() {
    prompt "remove sing-box-shell and other config? [Y/n]"
    read choice
    choice=${choice:-y}
    case "$choice" in
        [Yy])
            cd
            if [ -e "$service" ]; then
                sudo systemctl stop sb
            fi
            
            sudo rm -rf $work_dir
            sudo rm -f $service
            sudo rm -f $exec
            info "old sing-box removed successfully."
        ;;
        [Nn])
        ;;
        *)
            warn "invalid input, please input 'y' or 'n'."
        ;;
    esac
    
}

# create_main_menu(){
#     echo -e "${PURPLE}+===================================+${RESET}"
#     echo -e "${CYAN}     $1   ${CYAN}$2          ${RESET}"
#     echo -e "${PURPLE}+===================================+${RESET}"
# }
# create_menu(){
#     echo -e "${CYAN}     $1   ${CYAN}$2          ${RESET}"
#     echo -e "${WHITE}+-----------------------------------+${RESET}"
# }

# 37
line="+-----------------------------------+"

line_len=${#line}
left_space_len=4
emoji_len=6
content_len=20
right_space_len=$((line_len - left_space_len - 1))


create_main_menu(){
    printf "%s\n" "${PURPLE}+===================================+===================================+${RESET}"
    printf "%-30s %-20s\n" "" "$1" 
    printf "%s\n" "${PURPLE}+===================================+===================================+${RESET}"
}
create_menu(){
    
    # echo $right_space_len
    printf "%-4s %-${right_space_len}s %-1s" "" "$1" "+"
    printf "%-4s %-${right_space_len}s\n" "" "$2"
    printf "%s\n" "${WHITE}+-----------------------------------+-----------------------------------+ ${RESET}"
}

create_info_menu() {
    printf "%-4s %s\n" "" "$1"
    printf "%s\n" "${WHITE}+-----------------------------------+-----------------------------------+ ${RESET}"
}

# 运行提示

check_config

# 一级菜单
while true; do

  
    # create_main_menu 🏠 "➤  Main Menu"
    # create_menu 🍉 "1. Install sing-box"
    # create_menu 🍒 "2. Update sing-box"
    # create_menu 🍊 "3. Update config"
    # create_menu 🌽 "4. Start sing-box"
    # create_menu 🥝 "5. Stop sing-box"
    # create_menu 🥭 "6. Status sing-box"
    # create_menu 🍋 "7. Remove sing-box"
    # create_menu 🍈 "8. Update shell"
    # create_menu 🍑 "0. Exit shell"


    json_data=$(curl -s ipinfo.io)  # 只发起一次请求并存储 JSON
    ip=$(echo "$json_data" | jq -r '.ip')
    country=$(echo "$json_data" | jq -r '.country')
    status=$(systemctl is-active sb)



    create_main_menu  "🏠   Main Menu"
    create_menu "🌽   1. Start sing-box"    "🥝   2. Stop sing-box"
    create_menu "🍊   3. Update config"     "🍒   4. Update sing-box"
    create_menu "🍉   5. Install sing-box"  "🥭   6. Status sing-box"
    create_menu "🍋   7. Remove sing-box"   "🍈   8. Update shell"
    create_menu "🍋   9. Reload status"   "🍑   0. Exit shell"
    create_info_menu "IP: $ip, Country: $country, Status: $status"


    # 提示用户输入
    prompt "please enter the number:"
    read -n 1 choice
    echo

    case $choice in

        5)  
            create_main_menu 🍉 "5. Install sing-box"
            info "fetching version data."
            get_latest_version
            install
            fetch_config
            ;;
        4)  
            create_main_menu 🍒 "4. Update sing-box"
            info "fetching version data."
            get_latest_version
            check_installed_version
            install
            ;;
        3)

            create_main_menu 🍊 "3. Update config"
            fetch_config
            ;;
        1)  
            # 检查 sing-box 和 config
            check_config
            status=$? 
            if [ $status -eq 0 ]; then
                sudo systemctl start sb
                info "sing-box started successfully."
            else
                continue
            fi


            ;;
        2)  
            # stop
            # 检查 sing-box 和 config
            check_config
            status=$?  # 获取返回值

            if [ $status -eq 0 ]; then
                sudo systemctl stop sb
                info "sing-box stoped successfully."
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
            exit
            
            
            ;;
        8)  
            # update shell
            remove_sb
            curl -o sb.sh -fsSL https://gitee.com/Oterea/sing-box-shell/raw/main/sb.sh
            sudo chmod +x sb.sh

            sudo mv -f sb.sh /usr/local/bin/sb
            info "sing-box-shell updated successfully."
            exit
            ;;
        9)
            # reload
            continue
            ;;
        0)
            info "exit sing-box shell successfully."
            exit
            ;;
        *)
            warn "not a valid number."
            ;;
    esac
done
