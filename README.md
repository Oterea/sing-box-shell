# sing-box-shell

`sing-box-shell`（命令 `sbs`）是 sing-box 的 root 管理脚本。它使用 sing-box 官方软件包和官方 `sing-box.service`，负责配置、服务控制、状态查看和 SSH 隧道提示。

## Install

安装器和后续 `sbs` 操作都需要 root。推荐先进入 root shell：

```sh
sudo -i
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main/install.sh | bash
sbs
```

也可以不进入 root shell，直接执行：

```sh
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main/install.sh | sudo bash
sudo sbs
```

安装器自身会从多个源获取 `sbs.sh`。需要固定脚本源时，可以设置 `SBS_MIRROR`：

```sh
sudo env SBS_MIRROR=https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main \
  bash -c "$(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main/install.sh)"
```

`SBS_MIRROR` 和 `gh-proxy` 只影响 sbs 管理脚本的下载与自更新，不会代理 sing-box 的 APT/DNF 软件包下载。

当前支持：

- Debian / Ubuntu：官方 APT 软件源；
- Fedora / RHEL：官方 DNF 软件源。

其他系统会提示暂不支持。

sing-box 内核不由 sbs 自己下载或替换，而是由系统包管理器安装和升级。安装后的官方路径是：

```text
binary: /usr/bin/sing-box
config: /etc/sing-box/config.json
state:  /var/lib/sing-box
unit:   sing-box.service
```

## Menu

运行：

```sh
sudo sbs
```

菜单按键：

```text
s  start            启动 sing-box
x  stop             停止 sing-box
r  restart          重启 sing-box
k  install/update   安装或更新 stable/beta 内核
c  update config    更新订阅或本地配置
u  update sbs       更新管理脚本自身
d  remove           卸载包、配置、状态和 sbs
f  refresh          刷新出口 IP 信息
t  tunnel           打印 SSH 隧道命令
q  quit             退出菜单
```

第一次使用时按 `k`，流程是：

```text
选择 stable/beta
  ↓
配置官方软件源
  ↓
刷新 APT/DNF 软件索引
  ↓
安装 sing-box 包
  ↓
启用 sing-box.service
  ↓
检查版本和服务文件
```

首次安装 sing-box 后，按 `c` 设置配置，再按 `s` 启动服务。安装过程不会自动启动带有示例配置的 sing-box 服务。

如果 sing-box 尚未安装，按 `s`、`r`、`c` 或 `t` 会提示先按 `k`。

## Configuration

按 `c` 更新配置时，可以选择：

- **keep it**：沿用上次成功使用的来源；
- **new url**：从 HTTP/HTTPS 订阅地址下载；
- **local file**：读取服务器上的本地文件。

配置写入前会运行：

```sh
sing-box check -c /etc/sing-box/config.json
```

只有校验成功才会替换当前配置。旧配置会保存为：

```text
/etc/sing-box/config.json.backup
```

来源记录和出口 IP 缓存保存在 `/var/lib/sing-box`。

## Commands

非交互命令只有服务控制、状态和 sbs 自更新：

```sh
sudo sbs start
sudo sbs stop
sudo sbs restart
sudo sbs status
sudo sbs update sbs
```

`sbs --help` 可以在不具备 root 权限时查看帮助；实际服务、配置和内核操作仍需要 root。

## Dashboard and SSH Tunnel

sing-box 的 Clash API 或 API service 通常绑定在服务器的 `127.0.0.1`，公网不能直接访问。按 `t` 后，sbs 会根据当前配置打印 SSH 本地端口转发命令。

`t` 只负责打印命令，不会在服务器端自动建立隧道。把命令复制到自己的电脑上运行，例如：

```sh
ssh -N \
  -L 19695:127.0.0.1:9695 \
  -L 19696:127.0.0.1:9696 \
  -L 19697:127.0.0.1:9697 \
  ubuntu@服务器公网IP
```

本地端口默认在服务器端口基础上加 `10000`，用于避免和本机其他 sing-box 实例冲突。实际端口以 `t` 输出为准。

隧道保持运行时，在本机浏览器打开输出的 Dashboard 地址。API service 的 Dashboard 路径是 `/dashboard`；配置中的存储目录不会改变这个访问路径。

如果配置启用了 API secret，sbs 会提醒需要认证。直接调用 Clash API 时，需要添加：

```http
Authorization: Bearer <secret>
```

不要把 Clash API 或 Dashboard 直接绑定到公网地址，除非同时配置了可靠的认证和访问控制。

## Logs

日志由 systemd journal 管理：

```sh
sudo journalctl -u sing-box.service -n 50 --no-pager
sudo journalctl -u sing-box.service -f
```

## Remove

菜单中的 `d` 会在确认后依次：

1. 停止并禁用 `sing-box.service`；
2. 卸载 `sing-box` 或 `sing-box-beta` 包；
3. 删除由 sbs 创建的官方软件源文件；
4. 删除 `/etc/sing-box` 和 `/var/lib/sing-box`；
5. 删除 `/usr/local/bin/sbs`。
