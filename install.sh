GREEN='\033[32m'
RESET='\033[0m' # 重置颜色
YELLOW='\033[33m'
# 定义变量
# service="/etc/systemd/system/sb.service"
exec="/usr/local/bin/sb"
    # 定义工作文件夹
# work_dir="$HOME/sing-box"




# # 删除旧的 sing-box
# remove_sb() {
#     cd
#     sudo rm -rf $work_dir
#     sudo rm -f $service
#     sudo rm -f $exec
#     # echo -e "${GREEN}INFO: old sing-box removed successfully.${RESET}"
# }
# # echo -e "${GREEN}INFO: remove old sing-box and config? [Y/n].${RESET}"
# # read -n 1 is_remove
# # is_remove=${is_remove:-y}

# # # 转换为小写并使用 if 语句判断
# # if [[ "${is_remove,,}" == "y" ]]; then
# #     remove_sb
# # elif [[ "${is_remove,,}" == "n" ]]; then
# #     :
# # else
# #     echo -e "${YELLOW}WARN: invalid input, please input 'y' or 'n'.${RESET}"
# # fi
# remove_sb



curl -o sb.sh -fsSL https://gitee.com/Oterea/sing-box-shell/raw/main/sb.sh
sudo chmod +x sb.sh

sudo mv -f sb.sh $exec
echo -e "${GREEN}INFO: sing-box-shell installed successfully.${RESET}"




