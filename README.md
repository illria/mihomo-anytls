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
- 目标输出：安装完成后应输出 URI 分享链接，例如 `anytls://password@example.com:443?peer=example.com&insecure=0&sni=example.com#node-name`
- 节点信息查看：支持读取本机历史安装记录、配置文件路径、分享链接和运行状态

## 快速使用

推荐一行命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh)
```

如果你的系统不支持 bash 进程替换，可以用管道方式：

```bash
curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh | bash
```

如果当前不是 root，请加 `sudo`：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh)"
```

## 查看本机已安装节点

```bash
curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/tools/show-node-info.sh | bash
```

如果你已经克隆仓库，也可以运行：

```bash
bash tools/show-node-info.sh
```

节点查看脚本会优先读取：

```text
/etc/mihomo/install.env
/etc/sing-box/install.env
/etc/mihomo-anytls/nodes.tsv
```

## 分享链接格式

AnyTLS 目标输出格式：

```text
anytls://PASSWORD@DOMAIN:PORT?peer=DOMAIN&insecure=0&sni=DOMAIN#NODE_NAME
```

示例：

```text
anytls://96a8a7b5-4c4c-4f57-af2c-ecff73fdcd38@hostdzire.2004103.xyz:22064?peer=hostdzire.2004103.xyz&insecure=0&sni=hostdzire.2004103.xyz#hostdzire-20u-印度
```

说明：

- `PASSWORD` 对应 AnyTLS 密码。
- `DOMAIN` 是你的域名。
- `PORT` 是监听端口。
- `peer` 和 `sni` 默认等于域名。
- `insecure=0` 表示正常校验证书。
- 使用自签证书时应为 `insecure=1`。
- `NODE_NAME` 是节点备注。

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
/etc/mihomo/share-link.txt
/etc/mihomo/certs/fullchain.pem
/etc/mihomo/certs/key.pem
```

sing-box 模式：

```text
/etc/sing-box/config.json
/etc/sing-box/client-<protocol>-mihomo.yaml
/etc/sing-box/client-<protocol>-sing-box.json
/etc/sing-box/share-link.txt
/etc/sing-box/certs/fullchain.pem
/etc/sing-box/certs/key.pem
```

全局历史记录：

```text
/etc/mihomo-anytls/nodes.tsv
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
