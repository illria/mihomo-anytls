# mihomo-anytls

一个简单的一键脚本，用来在 Linux VPS 上安装和管理代理节点。

支持：

- mihomo AnyTLS
- sing-box AnyTLS / Hysteria2 / TUIC / Trojan
- Docker 安装
- systemd 裸机安装
- 自动证书检测、续期、同步
- 多节点证书池
- 分享链接输出
- 出口代理设置
- 自动更新脚本
- 卸载

---

## 适合谁用？

适合想快速搭建节点的人：

```text
买一台 VPS
准备一个域名
执行一行命令
按照菜单选择
安装完成后复制分享链接
```

---

## 一键运行

推荐使用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh)
```

如果不是 root 用户：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh)
```

---

## 主菜单

运行脚本后会看到统一菜单：

```text
1) 安装 / 更新节点
2) 查看本机已安装节点信息
3) 安装 / 更新 Nginx 静态站
4) 查看服务状态
5) 重启服务
6) 检测本地证书并自动使用 / 续期 / 同步
7) 多节点证书池管理
8) 配置 HTTP / SOCKS5 出口代理
9) 自动更新脚本管理
10) 卸载 mihomo-anytls
0) 退出
```

---

## 推荐安装选择

新手推荐这样选：

```text
内核：mihomo
安装方式：Docker
协议：AnyTLS
证书：Cloudflare DNS 验证证书 或 检测本地证书
端口：443 / 8443 / 2053 / 自定义端口
```

如果你用的是 Cloudflare 域名，建议：

```text
DNS 记录关闭橙色云朵
保持 DNS only
```

---

## 安装完成后会得到什么？

安装完成后会显示：

```text
内核
协议
模式
域名
端口
用户
密码
分享链接
服务端配置路径
客户端配置路径
证书路径
日志命令
```

最重要的是这一行：

```text
分享链接: anytls://...
```

复制它导入客户端即可。

---

## 证书怎么处理？

脚本支持几种证书方式：

```text
1) 自签证书
2) 自定义证书路径
3) 80 端口申请 Let's Encrypt
4) Cloudflare DNS 验证证书
5) 检测本地证书并自动使用 / 续期 / 同步
```

第 5 项的逻辑是：

```text
检测本地证书
  ↓
证书存在且没过期：直接使用
  ↓
证书快过期或已过期：按来源续期
  ↓
续期成功：同步到运行目录
  ↓
写入多节点证书池
```

当前会检测这些位置：

```text
/etc/mihomo/certs/
/etc/sing-box/certs/
/root/.acme.sh/<domain>_ecc/
/root/.acme.sh/<domain>/
/etc/letsencrypt/live/<domain>/
```

---

## 自动续期证书

安装完成后，脚本会写入定时任务：

```text
/etc/cron.d/mihomo-anytls-cert-renew
```

默认每天检查一次证书。

如果证书剩余时间小于等于 15 天，会尝试自动续期并同步到运行目录。

查看状态：

```bash
cat /etc/cron.d/mihomo-anytls-cert-renew
```

查看日志：

```bash
cat /var/log/mihomo-anytls-cert-renew.log
```

---

## 多节点证书池

证书池目录：

```text
/etc/mihomo-anytls/cert-pool/
```

每个域名一个目录，例如：

```text
/etc/mihomo-anytls/cert-pool/example.com/
  fullchain.pem
  key.pem
  meta.env
```

作用：

```text
保存多个域名证书
记录证书来源
记录过期时间
方便同步到 mihomo 或 sing-box
```

---

## 常用命令

打开主菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh)
```

直接安装 / 更新节点：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh) install
```

查看状态：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh) status
```

检测并修复证书：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh) cert
```

管理证书池：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh) cert-pool
```

自动更新脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh) self-update
```

卸载：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh) uninstall
```

---

## 配置文件位置

mihomo：

```text
/etc/mihomo/config.yaml
/etc/mihomo/client-anytls-mihomo.yaml
/etc/mihomo/client-anytls-sing-box.json
/etc/mihomo/install.env
/etc/mihomo/certs/fullchain.pem
/etc/mihomo/certs/key.pem
```

sing-box：

```text
/etc/sing-box/config.json
/etc/sing-box/client-<protocol>-mihomo.yaml
/etc/sing-box/client-<protocol>-sing-box.json
/etc/sing-box/install.env
/etc/sing-box/certs/fullchain.pem
/etc/sing-box/certs/key.pem
```

全局目录：

```text
/etc/mihomo-anytls/
/etc/mihomo-anytls/cert-pool/
```

---

## 查看日志

Docker 模式：

```bash
docker logs -f mihomo-anytls
```

sing-box Docker：

```bash
docker logs -f sing-box-anytls
```

systemd 模式：

```bash
journalctl -u mihomo -f
journalctl -u sing-box -f
```

---

## 常见注意事项

### 1. 云服务器安全组要放行端口

例如你安装时填写了 `3224`，就需要放行：

```text
3224/tcp
```

Hysteria2 / TUIC 通常还需要放行 UDP。

### 2. Cloudflare 不要开橙色云朵

代理节点域名建议使用：

```text
DNS only
```

不要使用 Cloudflare 代理模式。

### 3. 80 端口申请证书失败怎么办？

可能是：

```text
80 端口被占用
安全组没放行 80
域名没有解析到当前 VPS
```

可以改用 Cloudflare DNS 验证证书。

### 4. 软路由环境可能需要手动处理 Docker

OpenWrt / iStoreOS / ImmortalWrt 的 Docker 环境差异比较大。

如果 Docker 安装失败，先确认 Docker daemon 已经正常运行。

---

## 免责声明

本项目仅用于学习和自用服务器管理。请遵守当地法律法规和服务商规则。
