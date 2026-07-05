#!/usr/bin/env bash
set -Eeuo pipefail

info(){ printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }

need_root(){
  [ "${EUID:-$(id -u)}" -eq 0 ] || { err "请用 root 运行。"; exit 1; }
}

confirm(){
  local msg="$1" def="${2:-n}" ans=""
  if [ "$def" = "y" ]; then
    read -r -p "$msg [Y/n]: " ans
    ans="${ans:-y}"
  else
    read -r -p "$msg [y/N]: " ans
    ans="${ans:-n}"
  fi
  case "$ans" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

stop_docker(){
  command -v docker >/dev/null 2>&1 || return 0
  local names name
  names="mihomo-anytls sing-box-anytls sing-box-hysteria2 sing-box-tuic sing-box-trojan"
  for name in $names; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"; then
      info "删除 Docker 容器：$name"
      docker rm -f "$name" >/dev/null 2>&1 || warn "删除容器失败：$name"
    fi
  done
}

stop_systemd(){
  command -v systemctl >/dev/null 2>&1 || return 0
  local svc
  for svc in mihomo sing-box; do
    if systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
      info "停止 systemd 服务：$svc"
      systemctl disable --now "$svc" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/$svc.service"
    fi
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
}

remove_files(){
  if confirm "是否删除 mihomo/sing-box 配置、证书和客户端文件？" n; then
    for d in /etc/mihomo /etc/sing-box; do
      if [ -d "$d" ]; then
        info "删除目录：$d"
        rm -rf --one-file-system "$d"
      fi
    done
  else
    warn "已保留 /etc/mihomo 和 /etc/sing-box。"
  fi

  if confirm "是否删除 Docker 构建目录 /opt/mihomo-anytls？" n; then
    if [ -d /opt/mihomo-anytls ]; then
      info "删除目录：/opt/mihomo-anytls"
      rm -rf --one-file-system /opt/mihomo-anytls
    fi
  else
    warn "已保留 /opt/mihomo-anytls。"
  fi

  if confirm "是否删除本脚本创建的 Nginx 静态站配置？" n; then
    rm -f /etc/nginx/conf.d/mihomo-anytls-site.conf /etc/nginx/http.d/mihomo-anytls-site.conf
    rm -rf --one-file-system /usr/share/nginx/html/mihomo-anytls 2>/dev/null || true
    if command -v nginx >/dev/null 2>&1; then
      nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1 || true
    fi
    info "已删除静态站配置。"
  fi
}

show_leftovers(){
  echo "------------------------------------------------------------"
  info "卸载流程完成"
  echo "可能仍保留："
  echo "  - Docker 本体"
  echo "  - acme.sh / certbot 证书账户"
  echo "  - 3x-ui / x-ui 原有服务"
  echo "  - 云安全组端口规则"
  echo "------------------------------------------------------------"
}

main(){
  need_root
  echo "============================================================"
  echo " mihomo-anytls 卸载工具"
  echo "============================================================"
  warn "默认只删除本项目容器/服务。配置、证书、Nginx 静态站需要二次确认。"
  confirm "确认开始卸载 mihomo-anytls 相关服务吗？" n || { warn "已取消。"; exit 0; }
  stop_docker
  stop_systemd
  remove_files
  show_leftovers
}

main "$@"
