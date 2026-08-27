## Install
```
bash -c "$(curl -fsSL https://testingcf.jsdelivr.net/gh/Oterea/sing-box-shell@main/install.sh)"
```

拉不到时可手动指定源（脚本本身与后续自更新都用它）：
```
SBS_MIRROR=https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main \
  bash -c "$(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Oterea/sing-box-shell/main/install.sh)"
```

内核（GitHub release 资产）默认依次尝试 `gh-proxy.com` → `ghfast.top` → 直连，
成功的源会记在 `~/sing-box/.last_source` 下次优先使用。也可手动指定：
```
SBS_PROXY=https://gh-proxy.com sbs install
```

## Get Started
#### sb install
install sing-box and config (see memo)

## See Log
journalctl -u sbs.service -n 10

tail -f singbox.log

## Help
sb




