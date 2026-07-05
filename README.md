# mihomo-anytls

一个交互式 Linux 安装脚本，用于部署 mihomo / sing-box 代理服务端。

## 功能

- 内核选择：`mihomo` / `sing-box`
- 安装方式：Docker / systemd 裸机
- 证书方式：
  - 自签证书
  - 自定义证书路径
  - 80 端口申请 Let's Encrypt
  - Cloudflare DNS API 验证证书
- 自动检测并安装常见依赖
- 支持常见 Linux 包管理器：`apt`、`dnf`、`yum`、`apk`、`pacman`、`zypper`、`opkg`
- sing-box 版本动态协议菜单：
  - sing-box `1.11.x`：Hysteria2 / TUIC / Trojan TLS
  - sing-box `1.12.0+`：AnyTLS / Hysteria2 / TUIC / Trojan TLS
- mihomo：AnyTLS listener

## 快速使用

```bash
curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/mihomo-anytls-install.sh -o mihomo-anytls-install.sh
chmod +x mihomo-anytls-install.sh
sudo bash mihomo-anytls-install.sh
```

## 推荐组合

VPS 服务端推荐：

```text
内核：sing-box latest 或 mihomo latest
安装方式：Docker
证书：Cloudflare DNS 验证
端口：443 或 8443
Cloudflare DNS：关闭橙色云朵，保持 DNS only
```

软路由客户端注意：

- sing-box `1.11.6` 不支持 AnyTLS。
- AnyTLS 需要 sing-box `1.12.0+`。
- 如果软路由暂时不能升级，建议使用 Hysteria2 / TUIC / Trojan TLS。

## 生成文件

mihomo 模式：

```text
/etc/mihomo/config.yaml
/etc/mihomo/client-anytls-mihomo.yaml
/etc/mihomo/client-anytls-sing-box.json
/etc/mihomo/certs/fullchain.pem
/etc/mihomo/certs/key.pem
```

sing-box 模式：

```text
/etc/sing-box/config.json
/etc/sing-box/client-<protocol>-mihomo.yaml
/etc/sing-box/client-<protocol>-sing-box.json
/etc/sing-box/certs/fullchain.pem
/etc/sing-box/certs/key.pem
```

## 查看日志

Docker 模式：

```bash
docker logs -f mihomo-anytls
# 或
docker logs -f sing-box-anytls
```

systemd 模式：

```bash
journalctl -u mihomo -f
# 或
journalctl -u sing-box -f
```

## 说明

脚本会尽量自动安装依赖，但 OpenWrt / iStoreOS / ImmortalWrt 的 Docker 环境差异较大。软路由环境如果 Docker 安装失败，建议先在系统插件或命令行里确认 Docker daemon 正常运行，再重新执行脚本。
