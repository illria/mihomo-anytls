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

managed_env(){
  local env="$1"
  [ -f "$env" ] || return 1
  grep -Eq '^APP_NAME="?mihomo-anytls"?$' "$env"
}

service_exec_contains_project(){
  local svc="$1"
  systemctl cat "$svc.service" 2>/dev/null | grep -Eq '/etc/mihomo|/etc/sing-box|/opt/mihomo-anytls|mihomo-anytls|sing-box-anytls|sing-box-hysteria2|sing-box-tuic|sing-box-trojan'
}

remove_managed_service(){
  local svc="$1" env="$2"
  if ! systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
    return 0
  fi
  if managed_env "$env" || service_exec_contains_project "$svc"; then
    info "停止本项目 systemd 服务：$svc"
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
    if [ -f "/etc/systemd/system/$svc.service" ] && service_exec_contains_project "$svc"; then
      rm -f "/etc/systemd/system/$svc.service"
    else
      warn "未删除 $svc.service 文件：无法确认是本项目创建，避免误删。"
    fi
  else
    warn "跳过外部 systemd 服务：$svc（未检测到 mihomo-anytls 标记）"
  fi
}

stop_docker(){
  command -v docker >/dev/null 2>&1 || return 0
  local names name
  names="mihomo-anytls sing-box-anytls sing-box-hysteria2 sing-box-tuic sing-box-trojan"
  for name in $names; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"; then
      info "删除本项目 Docker 容器：$name"
      docker rm -f "$name" >/dev/null 2>&1 || warn "删除容器失败：$name"
    fi
  done
}

stop_systemd(){
  command -v systemctl >/dev/null 2>&1 || return 0
  remove_managed_service mihomo /etc/mihomo/install.env
  remove_managed_service sing-box /etc/sing-box/install.env
  systemctl daemon-reload >/dev/null 2>&1 || true
}

remove_files(){
  if confirm "是否删除 mihomo/sing-box 配置、证书和客户端文件？" n; then
    for d in /etc/mihomo /etc/sing-box; do
      if [ -d "$d" ]; then
        if [ "$d" = "/etc/sing-box" ] && ! managed_env /etc/sing-box/install.env; then
          warn "跳过 /etc/sing-box：未检测到 mihomo-anytls 标记，避免删除你原来的 sing-box 配置。"
          continue
        fi
        if [ "$d" = "/etc/mihomo" ] && ! managed_env /etc/mihomo/install.env; then
          warn "跳过 /etc/mihomo：未检测到 mihomo-anytls 标记，避免删除外部配置。"
          continue
        fi
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

  if confirm "是否删除证书自动续期任务 /etc/cron.d/mihomo-anytls-cert-renew？" y; then
    rm -f /etc/cron.d/mihomo-anytls-cert-renew
    info "已删除本项目证书自动续期任务。"
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
  echo "  - 外部 sing-box / x-ui / 3x-ui 原有服务"
  echo "  - 云安全组端口规则"
  echo "------------------------------------------------------------"
}

main(){
  need_root
  echo "============================================================"
  echo " mihomo-anytls 安全卸载工具"
  echo "============================================================"
  warn "只删除带 mihomo-anytls 标记的容器/服务/配置。不会再无条件停用系统原有 sing-box。"
  confirm "确认开始卸载 mihomo-anytls 相关服务吗？" n || { warn "已取消。"; exit 0; }
  stop_docker
  stop_systemd
  remove_files
  show_leftovers
}

main "$@"
