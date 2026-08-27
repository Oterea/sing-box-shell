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

work_dir="$HOME/sing-box"
exec="/usr/local/bin/sbs"
service="/etc/systemd/system/sbs.service"
share="$work_dir/share.txt"
last_source="$work_dir/.last_source"

config_file="$work_dir/config.json" # 保存为 config.json 文件

info() {
    printf '%s\n' "${GREEN}[info]:${RESET} $*"
}
warn() {
    printf '%s\n' "${YELLOW}[warn]:${RESET} $*"
}

error() {
    printf '%s\n' "${RED}[error]:${RESET} $*"
}

prompt() {
    printf '%s\n' "${CYAN}[prompt]:${RESET} $*"
}

# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<下载源<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
# 内核二进制是 GitHub release 资产，jsDelivr 不服务这类文件，只能走反代
# 顺序即优先级；SBS_PROXY 指定的排最前；上次成功的源次之
kernel_sources() {
    [ -n "$SBS_PROXY" ] && printf '%s\n' "$SBS_PROXY"
    [ -s "$last_source" ] && cat "$last_source"
    printf '%s\n' "https://gh-proxy.com"
    printf '%s\n' "https://ghfast.top"
    printf '%s\n' "direct"
    return 0
}

# 脚本是仓库内文件。不缓存的源排前面 —— jsDelivr 的 @main 有约 12h TTL，
# push 之后会持续吐旧版（purge 是异步的），所以它只作兜底
script_sources() {
    [ -n "$SBS_MIRROR" ] && printf '%s\n' "$SBS_MIRROR"
    cat <<'EOS'
https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main
https://ghfast.top/https://raw.githubusercontent.com/Oterea/sing-box-shell/main
https://raw.githubusercontent.com/Oterea/sing-box-shell/main
https://testingcf.jsdelivr.net/gh/Oterea/sing-box-shell@main
EOS
    return 0
}

remember_source() {
    printf '%s\n' "$1" >"$last_source" 2>/dev/null
}

# 多源回落取回 release 资产。只有失败才换源，慢不换
sb_fetch() { # $1=目标文件 $2=原始 URL
    local dst="$1" url="$2" src full
    for src in $(kernel_sources | awk '!seen[$0]++'); do
        if [ "$src" = direct ]; then full="$url"; else full="$src/$url"; fi
        info "source: $src"
        if curl -fL --connect-timeout 5 --retry 2 --progress-bar -o "$dst" "$full"; then
            remember_source "$src"
            return 0
        fi
        warn "$src failed, trying next"
    done
    error "all sources failed. 可用 SBS_PROXY=<base-url> 手动指定"
    return 1
}

# 多源回落取回仓库内脚本
script_fetch() { # $1=本地目标路径 $2=远端文件名
    local dst="$1" name="$2" base
    for base in $(script_sources | awk '!seen[$0]++'); do
        info "source: $base"
        if curl -fsSL --connect-timeout 5 --retry 2 -o "$dst" "$base/$name"; then
            return 0
        fi
        warn "$base failed, trying next"
    done
    error "all script sources failed. 可用 SBS_MIRROR=<base-url> 手动指定"
    return 1
}
# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>下载源>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<检查工具<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
missing_tools=""
check_tools() {
    tool_name="$1"
    # 使用 command -v 来检查工具是否存在
    if ! command -v "$tool_name" >/dev/null 2>&1; then
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

# 创建工作目录（如果不存在）
if [ ! -d "$work_dir" ]; then
    mkdir -p "$work_dir"
fi

# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<资产匹配<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
# 探测本机架构与 C 库，拼出 release 资产的文件名后缀
# 只在 -glibc / -musl 之间二选一，主动避开无后缀那个（glibc 动态 + 捆 libcronet，musl 上跑不起来）
detect_target() {
    local m
    m=$(uname -m)
    case "$m" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    armv7l | armv7) arch=armv7 ;;
    i386 | i686) arch=386 ;;
    riscv64) arch=riscv64 ;;
    loongarch64) arch=loong64 ;;
    s390x) arch=s390x ;;
    ppc64le) arch=ppc64le ;;
    *)
        error "unsupported arch: $m"
        return 1
        ;;
    esac

    if ldd --version 2>&1 | grep -qi musl; then libc=musl; else libc=glibc; fi

    asset_suffix="linux-${arch}-${libc}.tar.gz"
    info "target: ${arch}/${libc} (asset: *-${asset_suffix})"
}

# 按命名规则拼出下载地址（规则对 stable / beta 一致，已验证）
#   https://github.com/SagerNet/sing-box/releases/download/<tag>/sing-box-<ver>-<suffix>
asset_url() { # $1=tag
    printf '%s\n' "https://github.com/SagerNet/sing-box/releases/download/$1/sing-box-${1#v}-${asset_suffix}"
}

# 存在性检查：0=存在 1=确认不存在 2=判定不了（网络问题，交给 sb_fetch 兜）
verify_asset() { # $1=url
    local code
    code=$(curl -sI -o /dev/null -w '%{http_code}' -L --connect-timeout 5 --max-time 20 "$1" 2>/dev/null)
    case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *) return 2 ;;
    esac
}

# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>资产匹配>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<版本发现<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
# 不走 GitHub API：单个 release 的 JSON 就有 340KB，国内链路上 per_page=15 要拉 5MB，必超时。
# 改用两条轻量通路，各自输出「tag 列表，最新在前」

# atom：8KB，最快，但窗口只有约 10 条
discover_tags_atom() {
    curl -sfL --connect-timeout 5 --max-time 25 \
        "https://github.com/SagerNet/sing-box/releases.atom" |
        grep -o 'href="[^"]*releases/tag/[^"]*"' | sed 's|.*/tag/||; s|"$||'
}

# jsDelivr：145KB，全量 600+ 条，完全不碰 github.com
discover_tags_jsdelivr() {
    curl -sfL --connect-timeout 5 --max-time 25 \
        "https://data.jsdelivr.com/v1/packages/gh/SagerNet/sing-box" |
        jq -r '.versions[].version' | sed 's/^/v/'
}

pick_stable() { printf '%s\n' "$1" | grep -vE -- '-(alpha|beta|rc)' | head -n 1; }
pick_beta() { printf '%s\n' "$1" | grep -- '-beta' | head -n 1; }

get_latest_version() {
    detect_target || exit 1

    local tags
    tags=$(discover_tags_atom)
    latest_stable_v=$(pick_stable "$tags")
    latest_beta_v=$(pick_beta "$tags")

    # atom 窗口太小或拉不到时，落到全量列表
    if [ -z "$latest_stable_v" ] || [ -z "$latest_beta_v" ]; then
        warn "atom feed 不足，改用 jsDelivr 版本列表"
        tags=$(discover_tags_jsdelivr)
        [ -z "$latest_stable_v" ] && latest_stable_v=$(pick_stable "$tags")
        [ -z "$latest_beta_v" ] && latest_beta_v=$(pick_beta "$tags")
    fi

    if [ -z "$latest_stable_v" ]; then
        error "无法获取版本列表（github.com 与 jsDelivr 都不可达）"
        exit 1
    fi

    latest_stable_url=$(asset_url "$latest_stable_v")
    [ -n "$latest_beta_v" ] && latest_beta_url=$(asset_url "$latest_beta_v")

    verify_asset "$latest_stable_url"
    case $? in
    1)
        error "asset 不存在，上游可能改了命名: $latest_stable_url"
        exit 1
        ;;
    2) warn "无法预检 asset 是否存在，继续（下载时再判）" ;;
    esac

    info "latest stable version: $latest_stable_v"
    info "latest beta version:   ${latest_beta_v:-未找到}"
}
# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>版本发现>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

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

install_singbox() {
    # 提示用户输入
    prompt "install stable version? [Y/n]:"
    read is_stable
    is_stable=${is_stable:-y}

    case "$is_stable" in
    [Nn])
        info "downloading beta version."
        download_url=$latest_beta_url
        ;;
    # 默认稳定版
    *)
        info "downloading stable version."
        download_url=$latest_stable_url
        ;;
    esac

    # ====================================下载解压====================================
    file_name=$(basename "$download_url")
    success=1
    # curl 下载

    info "downloading sing-box."
    if sb_fetch "$work_dir/$file_name" "$download_url"; then
        success=0
    fi

    # 检查下载是否成功
    if [ "$success" -eq 0 ]; then
        info "sing-box downloaded successfully to $work_dir/$file_name."
    else
        error "file download failed."
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
    # ====================================设置sbs.service====================================
    # 提取版本信息
    check_installed_version

    # 检查sbs.service 文件是否存在，若存在则覆盖
    if [ -f "$service" ]; then
        warn "the file $service already exists. it will be overwritten."
    fi

    # 创建 sbs.service 文件并写入内容，直接覆盖内容
    echo "[Unit]
    Description=$version
    After=network.target

    [Service]
    ExecStart=$work_dir/sing-box run
    WorkingDirectory=$work_dir/
    Restart=always

    [Install]
    WantedBy=multi-user.target" | sudo tee "$service" >/dev/null

    # 检查文件是否创建并覆盖成功
    if [ -f "$service" ]; then
        info "service file created successfully at $service."
        # 重新加载 systemd 配置
        sudo systemctl daemon-reload
    else
        error "failed to create sbs.service file."
        break
    fi
}

install_config() {
    # 文件不存在则写入，存在就不管
    if [ ! -e "$share" ]; then
        echo "config_url=$config_url" >>"$share"
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
        http*) ;;
        *)
            error "config_url invalid."
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
            echo "config_url=\"$config_url\"" >$share
            source $share
            ;;
        *)
            error "config_url invalid."
            return
            ;;
        esac

        ;;
    *)
        warn "not a valid input, please input N/n or Y/y"
        return
        ;;
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

remove_sbs() {
    prompt "remove sing-box-shell and other config? [y/N]:"
    read choice
    choice=${choice:-N}
    case "$choice" in
    [Yy])
        cd
        if [ -e "$service" ]; then
            sudo systemctl stop sbs
        fi

        sudo rm -rf $work_dir
        sudo rm -f $service
        sudo rm -f $exec
        info "old sing-box removed successfully."
        ;;
    [Nn]) ;;
    *)
        warn "invalid input, please input 'y' or 'n'."
        ;;
    esac

}

help() {
    info "  Usage:"
    info "  sbs install             # Install sing-box and config"
    info "  sbs update              # Update sing-box"
    info "  sbs update config       # Update config"
    info "  sbs update sbs          # Update sbs"
    info "  sbs start               # Start sing-box"
    info "  sbs stop                # Stop sing-box"
    info "  sbs status              # Check status"
    info "  sbs remove              # Uninstall everything"
}

# 如果没有参数，打印帮助
if [ $# -eq 0 ]; then
    help
    exit 0
fi

cmd="$1"
subcmd="$2"

case "$cmd" in
install)
    info "installing sing-box and config..."
    get_latest_version
    install_singbox
    install_config
    exit
    ;;
update)
    case "$subcmd" in
    config)
        info "updating config..."
        install_config
        ;;
    sbs)
        info "updating sing-box-shell..."
        remove_sbs
        tmpdir=$(mktemp -d) || {
            error "无法创建临时目录"
            exit 1
        }
        # 中转名字放在目标旁边，保证最后一步是同盘改名。
        # 这一步是关键：本脚本自己就是 $exec，bash 边读边执行，
        # 就地覆盖会让它从字节偏移处接着读到新内容，把两个版本串起来跑。
        stage="$(dirname "$exec")/.$(basename "$exec").$$.tmp"
        trap 'rm -rf "$tmpdir"; sudo rm -f "$stage" 2>/dev/null' EXIT

        if ! script_fetch "$tmpdir/sbs.sh" sbs.sh; then
            error "update failed."
            exit 1
        fi
        sudo cp "$tmpdir/sbs.sh" "$stage" || exit 1
        sudo chmod 755 "$stage" || exit 1
        sudo mv -f "$stage" "$exec" || exit 1
        info "sing-box-shell updated successfully."
        ;;
    *)
        info "updating sing-box..."
        get_latest_version
        check_installed_version
        install_singbox
        ;;
    esac
    exit
    ;;
start)
    check_config
    if [ $? -eq 0 ]; then
        sudo systemctl start sbs
        info "sing-box started successfully."
    fi
    exit
    ;;
stop)
    check_config
    if [ $? -eq 0 ]; then
        sudo systemctl stop sbs
        info "sing-box stopped successfully."
    fi
    exit
    ;;
status)
    check_config
    if [ $? -eq 0 ]; then
        sudo systemctl status sbs
        curl ipinfo.io
    fi
    exit
    ;;
remove)
    remove_sbs
    info "sbs removed successfully."
    exit
    ;;
help)
    help
    exit
    ;;
*)
    warn "unknown command: $cmd"
    help
    exit 1
    ;;
esac
