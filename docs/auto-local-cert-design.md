# 自动检测本地证书模式设计

目标是在安装证书步骤增加一个默认选项：

```text
5) 自动检测本地证书（有效则复用，过期则按原方式续期）
```

## 预期菜单

```text
请选择证书方式：
  1) 自签证书
  2) 自定义证书路径
  3) 80 端口申请 Let's Encrypt
  4) Cloudflare DNS 验证证书
  5) 自动检测本地证书（有效则复用，过期则按原方式续期）
输入序号 [5]:
```

## 检测顺序

优先检测当前安装目录，其次检测常见证书目录：

```text
/etc/mihomo/certs/fullchain.pem
/etc/sing-box/certs/fullchain.pem
/root/.acme.sh/<domain>_ecc/fullchain.cer
/root/.acme.sh/<domain>/fullchain.cer
/etc/letsencrypt/live/<domain>/fullchain.pem
```

后续可扩展检测 x-ui / 3x-ui 的证书目录。

## 判断逻辑

1. 证书文件存在。
2. 私钥文件存在。
3. 证书 SAN 或 Subject 匹配当前输入域名。
4. 使用 `openssl x509 -noout -enddate` 判断到期时间。
5. 剩余天数大于 15 天：直接复用。
6. 剩余天数小于等于 15 天或已过期：根据来源提示续期方式。

## 续期策略

### acme.sh 证书

如果证书来自：

```text
/root/.acme.sh/<domain>_ecc/
/root/.acme.sh/<domain>/
```

说明通常由 acme.sh 申请。应优先按 acme.sh 原记录续期。

### certbot 证书

如果证书来自：

```text
/etc/letsencrypt/live/<domain>/
```

说明通常由 certbot 管理。应优先提示使用 certbot renew。

## 写入目标

无论本地证书来自哪里，最终统一写入当前内核目录：

```text
/etc/mihomo/certs/fullchain.pem
/etc/mihomo/certs/key.pem
```

或：

```text
/etc/sing-box/certs/fullchain.pem
/etc/sing-box/certs/key.pem
```

并在 `install.env` 中记录：

```text
CERT_MODE="auto-local"
SKIP_CERT_VERIFY="false"
```

## 失败回退

如果未找到可用证书，或者发现证书过期但无法自动续期，回退到原有证书方式：

```text
1) 自签证书
2) 自定义证书路径
3) 80 端口申请 Let's Encrypt
4) Cloudflare DNS 验证证书
```
