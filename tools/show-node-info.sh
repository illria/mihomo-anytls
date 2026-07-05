#!/usr/bin/env bash
set -Eeuo pipefail

NODE_DB="/etc/mihomo-anytls/nodes.tsv"

get_env_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  grep -E "^${key}=" "$file" | tail -n1 | sed -E 's/^[^=]+=//; s/^"//; s/"$//' | sed 's/\\"/"/g; s/\\\\/\\/g'
}

urlencode_ascii() {
  local s="$1" i c out="" hex
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

build_share_link() {
  local protocol="$1" domain="$2" port="$3" password="$4" uuid="$5" node="$6" insecure="$7"
  local password_enc uuid_enc node_enc

  [ -n "$protocol" ] || return 1
  [ -n "$domain" ] || return 1
  [ -n "$port" ] || return 1
  [ -n "$password" ] || return 1

  password_enc="$(urlencode_ascii "$password")"
  uuid_enc="$(urlencode_ascii "$uuid")"
  node_enc="$(urlencode_ascii "${node:-$domain-$port}")"
  insecure="${insecure:-0}"

  case "$protocol" in
    anytls)
      printf 'anytls://%s@%s:%s?peer=%s&insecure=%s&sni=%s#%s\n' "$password_enc" "$domain" "$port" "$domain" "$insecure" "$domain" "$node_enc"
      ;;
    hysteria2|hy2)
      printf 'hysteria2://%s@%s:%s?sni=%s&insecure=%s#%s\n' "$password_enc" "$domain" "$port" "$domain" "$insecure" "$node_enc"
      ;;
    tuic)
      [ -n "$uuid" ] || return 1
      printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&sni=%s&allow_insecure=%s#%s\n' "$uuid_enc" "$password_enc" "$domain" "$port" "$domain" "$insecure" "$node_enc"
      ;;
    trojan)
      printf 'trojan://%s@%s:%s?security=tls&sni=%s&allowInsecure=%s#%s\n' "$password_enc" "$domain" "$port" "$domain" "$insecure" "$node_enc"
      ;;
    *) return 1 ;;
  esac
}

show_env_node() {
  local file="$1"
  local core protocol domain port node link mode created config status container password uuid skip insecure inferred

  core="$(get_env_value "$file" CORE || true)"
  protocol="$(get_env_value "$file" PROTOCOL || true)"
  domain="$(get_env_value "$file" DOMAIN || true)"
  port="$(get_env_value "$file" PORT || true)"
  node="$(get_env_value "$file" NODE_NAME || true)"
  link="$(get_env_value "$file" SHARE_LINK || true)"
  mode="$(get_env_value "$file" INSTALL_MODE || true)"
  created="$(get_env_value "$file" CREATED_AT || true)"
  config="$(get_env_value "$file" CONFIG_FILE || true)"
  password="$(get_env_value "$file" PASSWORD || true)"
  uuid="$(get_env_value "$file" UUID_VALUE || true)"
  skip="$(get_env_value "$file" SKIP_CERT_VERIFY || true)"

  [ -n "$core$protocol$domain$link" ] || return 0

  if [ "$skip" = "true" ] || [ "$skip" = "1" ]; then
    insecure=1
  else
    insecure=0
  fi

  echo "------------------------------------------------------------"
  echo "记录文件: $file"
  echo "节点备注: ${node:-$domain-$port}"
  echo "内核/协议: ${core:-未知} / ${protocol:-未知}"
  echo "安装模式: ${mode:-未知}"
  echo "地址端口: ${domain:-未知}:${port:-未知}"
  [ -n "$created" ] && echo "创建时间: $created"
  [ -n "$config" ] && echo "配置文件: $config"

  if [ -n "$link" ]; then
    echo "分享链接: $link"
  elif [ -f "${file%/*}/share-link.txt" ]; then
    echo "分享链接: $(cat "${file%/*}/share-link.txt")"
  else
    inferred="$(build_share_link "$protocol" "$domain" "$port" "$password" "$uuid" "${node:-$domain-$port}" "$insecure" || true)"
    if [ -n "$inferred" ]; then
      echo "分享链接: $inferred"
      echo "提示: 这是从旧安装记录反推出的链接。"
    else
      echo "分享链接: 未记录，且缺少必要字段，无法反推。"
    fi
  fi

  status="未检测到运行中服务，可能已停止或由其他方式管理"
  if [ "$core" = "mihomo" ]; then
    container="mihomo-anytls"
  else
    container="sing-box-$protocol"
  fi

  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    status="Docker 运行中：$container"
  elif command -v systemctl >/dev/null 2>&1 && [ -n "$core" ] && systemctl is-active --quiet "$core" 2>/dev/null; then
    status="systemd 运行中：$core"
  fi

  echo "运行状态: $status"
}

main() {
  local found=0 file
  echo "============================================================"
  echo " 本机已安装节点信息"
  echo "============================================================"

  for file in /etc/mihomo/install.env /etc/sing-box/install.env; do
    if [ -f "$file" ]; then
      show_env_node "$file"
      found=1
    fi
  done

  if [ -f "$NODE_DB" ]; then
    echo "------------------------------------------------------------"
    echo "历史安装记录: $NODE_DB"
    awk -F '\t' 'NF>=8 {printf "[%s] %s/%s %s:%s 备注=%s\n链接=%s\n", $1,$2,$3,$4,$5,$6,$7}' "$NODE_DB" | tail -n 80
    found=1
  fi

  if [ "$found" -eq 0 ]; then
    echo "没有找到安装记录。"
    echo "检查路径：/etc/mihomo/install.env、/etc/sing-box/install.env、$NODE_DB"
  fi
}

main "$@"
