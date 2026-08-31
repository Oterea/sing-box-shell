## Install

```
bash -c "$(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main/install.sh)"
```

拉不到时可手动指定源（脚本本身与后续自更新都用它）：

```
SBS_MIRROR=https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main \
  bash -c "$(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main/install.sh)"
```

内核（GitHub release 资产）默认依次尝试 `gh-proxy.com` → `ghfast.top` → 直连，
成功的源会记在 `~/sing-box/.last_source` 下次优先使用。也可手动指定：

```
SBS_PROXY=https://gh-proxy.com sbs
```

## Get Started

装完敲 `sbs` 进菜单，全部操作都在里面按单键完成：

```
╭────────────────────────────────────────────────────────╮
│  ~/sing-box/sing-box                   ● Running  22m  │
│  1.14.0-beta.17   tun0 198.18.0.1/30     config valid  │
│  104.11.86.228  Irvine, US                    21m ago  │
├────────────────────────────────────────────────────────┤
│    s   start            k   update kernel              │
│    x   stop             c   update config              │
│    r   restart          u   update sbs                 │
│    f   refresh          d   remove                     │
│    q   quit                                            │
╰────────────────────────────────────────────────────────╯
```

新机器上第一次进来 `k` 是 install，会依次装内核、写 systemd unit、拉配置。
选版本、填地址这类需要交互的步骤都在底部完成：方向键切换，回车确认，
esc 取消。

配置有两种来源，按 `c` 时选：

- **url** —— 订阅地址，直接 curl 下来（是你自己的服务，不走反代）
- **local file** —— 服务器上已有的一个文件，拷一份改名放进工作目录

两条路取回之后完全一样：都先用 `sing-box check` 校验，通过才覆盖，
旧的留一份 `.backup`。用过的来源会记在 `share.txt` 里，下次按 `c`
第一个选项就是 `keep it`。

## Commands

菜单之外只保留不需要交互的几条，方便脚本和远程调用：

```
sbs start / stop / restart / status
sbs update sbs      更新脚本自身
```

安装、更新内核、更新配置、卸载都要选版本或填地址，只在菜单里做 —— 命令行
再实现一套文字问答，等于同一件事维护两种交互，迟早漂移。这些命令不再被识别，
敲了会报未知命令并打印用法。

## See Log

```
journalctl -u sbs.service -n 50 --no-pager
```

日志走 journald，不落地成文件。
