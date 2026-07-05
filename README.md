# mihomo-anytls

作者：**Eianun**

一个简单的一键脚本，用来在 Linux VPS 上安装和管理代理节点。

支持：

- mihomo AnyTLS
- sing-box AnyTLS / Hysteria2 / TUIC / Trojan
- Docker 安装
- systemd 裸机安装
- SSL Manager（参考 3x-ui 的证书管理模型）
- `/root/cert/<domain>/fullchain.pem` + `privkey.pem` 标准证书目录
- 多节点证书池
- 分享链接输出
- 出口代理设置
- 自动更新脚本
- 卸载
- 快捷启动命令：`en-mi`

---

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh)
```

如果不是 root 用户：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh)
```

---

## 快捷命令 en-mi

安装或更新本机命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh) self-update
```

安装后可以直接运行：

```bash
en-mi
```

也可以使用完整命令：

```bash
mihomo-anytls
```

---

## 主菜单

```text
mihomo-anytls 统一管理菜单
作者: Eianun
快捷命令: en-mi

1) 安装 / 更新节点
2) 查看本机已安装节点信息
3) 安装 / 更新 Nginx 静态站
4) 查看服务状态
5) 重启服务
6) SSL Manager（证书申请 / 安装 / 续期 / 同步）
7) 多节点证书池管理
8) 配置 HTTP / SOCKS5 出口代理
9) 自动更新脚本管理
10) 卸载 mihomo-anytls
0) 退出
```

---

## 推荐安装选择

新手推荐：

```text
内核：mihomo
安装方式：Docker
协议：AnyTLS
证书：SSL Manager 申请或已有 /root/cert/<domain>/ 证书
端口：443 / 8443 / 2053 / 自定义端口
```

Cloudflare 域名建议关闭橙色云朵，使用 DNS only。

---

## SSL Manager 证书模型

本项目现在按 3x-ui 的 SSL 管理思路整理证书：

```text
/root/cert/<domain>/
  fullchain.pem
  privkey.pem
```

服务只应该使用：

```text
证书：/root/cert/<domain>/fullchain.pem
私钥：/root/cert/<domain>/privkey.pem
```

不要把下面这些文件当私钥：

```text
ca.cer
fullchain.cer
fullchain.pem
```

真正的私钥必须能被 OpenSSL 识别为 PRIVATE KEY。

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

最重要的是：

```text
分享链接: anytls://...
```

复制它导入客户端即可。

---

## 常用命令

打开主菜单：

```bash
en-mi
```

或：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh)
```

直接安装 / 更新节点：

```bash
en-mi install
```

查看状态：

```bash
en-mi status
```

SSL Manager：

```bash
en-mi ssl-manager
```

证书池管理：

```bash
en-mi cert-pool
```

自动更新脚本：

```bash
en-mi self-update
```

卸载：

```bash
en-mi uninstall
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
/root/cert/
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

### 3. 证书和私钥必须配对

可以用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/tools/cert-pair-check.sh) /root/cert/example.com/fullchain.pem /root/cert/example.com/privkey.pem
```

---

## 免责声明

本项目仅用于学习和自用服务器管理。请遵守当地法律法规和服务商规则。
