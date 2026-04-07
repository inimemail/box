#!/usr/bin/env bash

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

CONF_DIR="/etc/sing-box"
CONF_FILE="$CONF_DIR/config.json"
CERT_DIR="$CONF_DIR/certs"
LINK_DB="$CONF_DIR/links.db"
ACME_DIR="$HOME/.acme.sh"

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

# ================= 环境与依赖稽核 =================
require_cmd() {
    local cmd=$1
    if ! command -v "$cmd" >/dev/null 2>&1; then
        info "正在装载基础组件: $cmd ..."
        local pkg_name="$cmd"
        
        if [[ "$cmd" == "uuidgen" ]]; then
            if command -v apt-get >/dev/null 2>&1; then pkg_name="uuid-runtime"
            elif command -v yum >/dev/null 2>&1; then pkg_name="util-linux"; fi
        elif [[ "$cmd" == "ss" ]]; then
            if command -v apt-get >/dev/null 2>&1; then pkg_name="iproute2"
            elif command -v yum >/dev/null 2>&1; then pkg_name="iproute"; fi
        fi

        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq "$pkg_name" >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q "$pkg_name" >/dev/null 2>&1
        else
            die "未能识别包管理器，无法安装 $pkg_name。"
        fi
        command -v "$cmd" >/dev/null 2>&1 || die "组件 $cmd 安装失败。"
    fi
}

fetch_public_ip() {
    if [[ -z "${PUBLIC_IP:-}" ]]; then
        PUBLIC_IP=$(curl -s4 --connect-timeout 3 ipv4.icanhazip.com 2>/dev/null || curl -s4 --connect-timeout 3 ifconfig.me 2>/dev/null || true)
        if [[ ! "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            while true; do
                read -r -p "自动获取公网 IPv4 失败，请手动输入: " PUBLIC_IP </dev/tty
                if [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                    break
                else
                    err "IP 格式不合法，请重新输入。"
                fi
            done
        fi
    fi
}

init_env() {
    mkdir -p "$CONF_DIR" "$CERT_DIR"
    touch "$LINK_DB"
    chmod 600 "$LINK_DB" 2>/dev/null || true

    if [[ ! -f "$CONF_FILE" ]]; then
        cat > "$CONF_FILE" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ]
}
EOF
    fi
    chmod 600 "$CONF_FILE" 2>/dev/null || true
}

check_singbox_installed() {
    if ! command -v sing-box >/dev/null 2>&1; then
        err "未检测到 sing-box 内核。请先在主菜单输入 [1] 进行内核与依赖安装。"
        return 1
    fi
    return 0
}

check_singbox_version() {
    local required=$1
    local ver_str
    ver_str=$(sing-box version 2>/dev/null | head -n 1 || true)
    local ver
    ver=$(echo "$ver_str" | awk '{print $3}')
    
    if [[ "$(printf '%s\n' "$required" "$ver" | sort -V | head -n1)" != "$required" ]]; then
        err "协议要求 Sing-box >= $required，当前内核版本过低 ($ver)。"
        return 1
    fi
    return 0
}

check_port_free() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        err "端口格式非法: ${port:-为空}"
        return 1
    fi
    if ss -tuln | grep ":$port " >/dev/null 2>&1; then
        err "底层端口 $port 已被物理占用。"
        return 1
    fi
    return 0
}

ask_for_tag() {
    local default_tag=$1
    while true; do
        read -r -p "请输入自定义节点名称(标签) [回车默认: $default_tag]: " RET_TAG </dev/tty
        [[ -z "$RET_TAG" ]] && RET_TAG="$default_tag"
        
        if [[ "$RET_TAG" == *"|"* ]]; then
            err "节点名称不能包含 '|' 字符，请重新输入。"
            continue
        fi
        
        if jq -e --arg t "$RET_TAG" '.inbounds[] | select(.tag == $t)' "$CONF_FILE" >/dev/null 2>&1; then
            err "当前配置中已存在同名节点 [$RET_TAG]，请换一个名称。"
        else
            break
        fi
    done
}

# ================= 安装与环境装配核心 =================
install_singbox() {
    info "开始装载基础依赖组件..."
    require_cmd curl
    require_cmd jq
    require_cmd openssl
    require_cmd uuidgen
    require_cmd qrencode
    require_cmd socat
    require_cmd ss

    info "开始拉取 Sing-box 内核..."
    local arch
    arch=$(uname -m)
    local s_arch
    case "$arch" in
        x86_64) s_arch="amd64" ;;
        aarch64) s_arch="arm64" ;;
        armv7l) s_arch="armv7" ;;
        *) die "不支持的系统架构: $arch" ;;
    esac

    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name | sed 's/v//')
    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        err "获取 Sing-box 最新版本失败，请检查服务器网络。"
        return 1
    fi

    info "发现最新版本: v$latest_version, 正在下载..."
    local tar_file="sing-box-${latest_version}-linux-${s_arch}.tar.gz"
    local download_url="https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/${tar_file}"

    curl -L -o "/tmp/$tar_file" "$download_url" || { err "下载失败"; return 1; }
    tar -xzf "/tmp/$tar_file" -C "/tmp/" || { err "解压失败"; return 1; }

    systemctl stop sing-box >/dev/null 2>&1 || true
    mv "/tmp/sing-box-${latest_version}-linux-${s_arch}/sing-box" "/usr/local/bin/"
    chmod +x "/usr/local/bin/sing-box"

    rm -rf "/tmp/$tar_file" "/tmp/sing-box-${latest_version}-linux-${s_arch}"

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -c $CONF_FILE
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
    
    info "Sing-box v$latest_version 及依赖环境已成功安装并启动！"
}

# ================= ACME 自动化证书引擎 =================
init_acme() {
    if [[ ! -f "$ACME_DIR/acme.sh" ]]; then
        info "初始化 acme.sh 证书签发环境..."
        fetch_public_ip
        curl -s https://get.acme.sh | sh -s email="admin@${PUBLIC_IP}.com" >/dev/null 2>&1 || true
        
        if [[ ! -x "$ACME_DIR/acme.sh" ]]; then
            err "acme.sh 安装彻底失败，请检查服务器网络连通性。"
            return 1
        fi
    fi
    return 0
}

apply_cert() {
    local domain=$1
    init_acme || return 1
    local acme_bin="$ACME_DIR/acme.sh"
    
    if [[ -s "$CERT_DIR/${domain}.crt" && -s "$CERT_DIR/${domain}.key" ]]; then
        local cert_valid=false
        if openssl x509 -noout -ext subjectAltName -in "$CERT_DIR/${domain}.crt" 2>/dev/null | grep -qi "$domain"; then
            cert_valid=true
        elif openssl x509 -noout -subject -in "$CERT_DIR/${domain}.crt" 2>/dev/null | grep -qi "CN=$domain"; then
            cert_valid=true
        fi

        if $cert_valid; then
            if openssl x509 -checkend 86400 -noout -in "$CERT_DIR/${domain}.crt" >/dev/null 2>&1; then
                info "证书状态健康且匹配，直接复用。"
                return 0
            else
                warn "证书有效期不足 24 小时，触发强制续签..."
            fi
        else
            warn "证书库域名验证未通过，进入覆盖签发流程..."
        fi
    fi

    if ss -tuln | grep ":80 " >/dev/null 2>&1; then
        err "本机 80 端口被占用，Standalone 模式被拦截。请停止占用服务后重试。"
        return 1
    fi

    info "正在与 Let's Encrypt 握手 ($domain)..."
    "$acme_bin" --issue -d "$domain" --standalone -k ec-256 --force || {
        err "签发阻断，请核实 DNS A记录是否命中本机 IP。"
        return 1
    }
    
    "$acme_bin" --install-cert -d "$domain" --ecc \
        --key-file "$CERT_DIR/${domain}.key" \
        --fullchain-file "$CERT_DIR/${domain}.crt" \
        --reloadcmd "systemctl restart sing-box" >/dev/null 2>&1 || {
        err "证书部署挂载或内核热重载失败，链路状态保护触发。"
        return 1
    }
        
    if [[ ! -s "$CERT_DIR/${domain}.crt" || ! -s "$CERT_DIR/${domain}.key" ]]; then
        err "证书物理级写入异常。"
        return 1
    fi
    return 0
}

# ================= 原子化注入与回滚核心 =================
atomic_inject() {
    local tag=$1
    local safe_json=$2
    local link=$3

    local tmp_conf="${CONF_FILE}.tmp"
    cp -a "$CONF_FILE" "$tmp_conf"

    if ! jq --argjson ext "$safe_json" 'if ($ext | type) == "array" then .inbounds += $ext else .inbounds += [$ext] end' "$CONF_FILE" > "$tmp_conf"; then
        err "JSON 语法树合并异常。"
        rm -f "$tmp_conf"
        return 1
    fi

    if ! sing-box check -c "$tmp_conf" >/dev/null 2>&1; then
        err "内核级审计驳回：参数存在断层。"
        rm -f "$tmp_conf"
        return 1
    fi

    cp -a "$CONF_FILE" "${CONF_FILE}.bak"
    mv "$tmp_conf" "$CONF_FILE"
    chmod 600 "$CONF_FILE"

    systemctl restart sing-box || true
    sleep 1

    if ! systemctl is-active --quiet sing-box; then
        err "内核加载崩毁，触发灾难回滚..."
        mv "${CONF_FILE}.bak" "$CONF_FILE"
        systemctl restart sing-box || true
        return 1
    fi

    echo "$tag|$link" >> "$LINK_DB"
    rm -f "${CONF_FILE}.bak"
    
    echo -e "\n=================================================="
    info "部署完成！"
    echo -e "节点标签: \033[33m$tag\033[0m"
    echo -e "分享链接: \033[36m$link\033[0m"
    if [[ "$link" =~ ^(vless|hysteria2|tuic|trojan|ss|vmess|naive):// ]]; then
        qrencode -t UTF8 "$link" 2>/dev/null || true
    fi
    echo -e "==================================================\n"
}

# ================= 高维协议装载器 =================
deploy_vless_reality() {
    local port
    while true; do
        read -r -p "请输入监听端口: " port </dev/tty
        if check_port_free "$port"; then break; fi
    done
    
    local sni
    while true; do
        read -r -p "请输入 SNI 域名 (如 www.apple.com): " sni </dev/tty
        if [[ -n "$sni" ]]; then break; else err "SNI 不能为空，请重新输入。"; fi
    done

    ask_for_tag "VLESS-Reality-$port"
    local tag="$RET_TAG"

    fetch_public_ip
    local uuid; uuid=$(uuidgen)
    local keypair; keypair=$(sing-box generate reality-keypair)
    local priv; priv=$(echo "$keypair" | awk '/PrivateKey/ {print $2}')
    local pub; pub=$(echo "$keypair" | awk '/PublicKey/ {print $2}')
    local sid; sid=$(openssl rand -hex 8)

    local json; json=$(jq -n \
        --arg tag "$tag" --arg port "$port" --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" \
        '{type: "vless", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{uuid: $uuid, flow: "xtls-rprx-vision"}], tls: {enabled: true, server_name: $sni, reality: {enabled: true, handshake: {server: $sni, server_port: 443}, private_key: $priv, short_id: [$sid]}}}')
    
    local link="vless://${uuid}@${PUBLIC_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp#$(echo -n "$tag" | jq -sRr @uri)"
    atomic_inject "$tag" "$json" "$link"
}

deploy_vless_ws() {
    local port
    while true; do
        read -r -p "请输入监听端口: " port </dev/tty
        if check_port_free "$port"; then break; fi
    done
    
    local domain
    while true; do
        read -r -p "请输入真实域名 (需解析至本机): " domain </dev/tty
        if [[ -n "$domain" ]]; then break; else err "域名不能为空，请重新输入。"; fi
    done

    ask_for_tag "VLESS-WS-$port"
    local tag="$RET_TAG"

    apply_cert "$domain" || return

    local uuid; uuid=$(uuidgen)
    local path="/$(openssl rand -hex 6)"
    info "已自动分配高匿随机路径: $path"

    local crt_path="$CERT_DIR/${domain}.crt"
    local key_path="$CERT_DIR/${domain}.key"

    local json; json=$(jq -n \
        --arg tag "$tag" --arg port "$port" --arg uuid "$uuid" --arg domain "$domain" --arg path "$path" --arg crt "$crt_path" --arg key "$key_path" \
        '{type: "vless", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{uuid: $uuid}], transport: {type: "ws", path: $path, headers: {"Host": $domain}}, tls: {enabled: true, server_name: $domain, certificate_path: $crt, key_path: $key}}')
    
    local link="vless://${uuid}@${domain}:${port}?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=$(echo -n "$path" | jq -sRr @uri)#$(echo -n "$tag" | jq -sRr @uri)"
    atomic_inject "$tag" "$json" "$link"
}

deploy_anytls() {
    check_singbox_version "1.12.0" || return

    local port
    while true; do
        read -r -p "请输入 TLS 监听端口: " port </dev/tty
        if check_port_free "$port"; then break; fi
    done
    
    local domain
    while true; do
        read -r -p "请输入绑定域名 (需解析至本机): " domain </dev/tty
        if [[ -n "$domain" ]]; then break; else err "域名不能为空，请重新输入。"; fi
    done

    ask_for_tag "AnyTLS-$port"
    local tag="$RET_TAG"

    apply_cert "$domain" || return

    local pass; pass=$(openssl rand -hex 12)
    local crt_path="$CERT_DIR/${domain}.crt"
    local key_path="$CERT_DIR/${domain}.key"

    local json; json=$(jq -n \
        --arg tag "$tag" --arg port "$port" --arg pass "$pass" --arg crt "$crt_path" --arg key "$key_path" \
        '{type: "anytls", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{password: $pass}], tls: {enabled: true, certificate_path: $crt, key_path: $key}}')
    
    atomic_inject "$tag" "$json" "[非标准协议] 需客户端手动配置 AnyTLS 出站。鉴权密码: $pass"
}

deploy_hysteria2() {
    local port
    while true; do
        read -r -p "请输入 UDP 监听端口: " port </dev/tty
        if check_port_free "$port"; then break; fi
    done
    
    local domain
    while true; do
        read -r -p "请输入真实域名 (需解析至本机): " domain </dev/tty
        if [[ -n "$domain" ]]; then break; else err "域名不能为空，请重新输入。"; fi
    done

    ask_for_tag "Hysteria2-$port"
    local tag="$RET_TAG"

    apply_cert "$domain" || return

    local pass; pass=$(openssl rand -hex 12)
    local crt_path="$CERT_DIR/${domain}.crt"
    local key_path="$CERT_DIR/${domain}.key"

    local json; json=$(jq -n \
        --arg tag "$tag" --arg port "$port" --arg pass "$pass" --arg crt "$crt_path" --arg key "$key_path" \
        '{type: "hysteria2", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{password: $pass}], tls: {enabled: true, alpn: ["h3"], certificate_path: $crt, key_path: $key}}')
    
    local link="hysteria2://${pass}@${domain}:${port}/?sni=${domain}#$(echo -n "$tag" | jq -sRr @uri)"
    atomic_inject "$tag" "$json" "$link"
}

deploy_tuic() {
    local port
    while true; do
        read -r -p "请输入 UDP 监听端口: " port </dev/tty
        if check_port_free "$port"; then break; fi
    done
    
    local domain
    while true; do
        read -r -p "请输入真实域名 (需解析至本机): " domain </dev/tty
        if [[ -n "$domain" ]]; then break; else err "域名不能为空，请重新输入。"; fi
    done

    ask_for_tag "TUIC-$port"
    local tag="$RET_TAG"

    apply_cert "$domain" || return

    local uuid; uuid=$(uuidgen)
    local pass; pass=$(openssl rand -hex 8)
    local crt_path="$CERT_DIR/${domain}.crt"
    local key_path="$CERT_DIR/${domain}.key"

    local json; json=$(jq -n \
        --arg tag "$tag" --arg port "$port" --arg uuid "$uuid" --arg pass "$pass" --arg crt "$crt_path" --arg key "$key_path" \
        '{type: "tuic", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{uuid: $uuid, password: $pass}], congestion_control: "bbr", tls: {enabled: true, alpn: ["h3"], certificate_path: $crt, key_path: $key}}')
    
    local link="tuic://${uuid}:${pass}@${domain}:${port}/?sni=${domain}&congestion_control=bbr&alpn=h3#$(echo -n "$tag" | jq -sRr @uri)"
    atomic_inject "$tag" "$json" "$link"
}

deploy_trojan() {
    echo -e "请选择网络传输层结构:"
    echo "  1) TCP + TLS"
    echo "  2) WS + TLS"
    local t_choice
    while true; do
        read -r -p "请选择 [1-2]: " t_choice </dev/tty
        if [[ "$t_choice" =~ ^[1-2]$ ]]; then break; else err "输入错误，请重试。"; fi
    done
    
    local port
    while true; do
        read -r -p "请输入监听端口: " port </dev/tty
        if check_port_free "$port"; then break; fi
    done
    
    local domain
    while true; do
        read -r -p "请输入真实域名 (需解析至本机): " domain </dev/tty
        if [[ -n "$domain" ]]; then break; else err "域名不能为空，请重新输入。"; fi
    done

    local default_name="Trojan-$port"
    [[ "$t_choice" == "2" ]] && default_name="Trojan-WS-$port"
    ask_for_tag "$default_name"
    local tag="$RET_TAG"

    apply_cert "$domain" || return

    local pass; pass=$(openssl rand -hex 12)
    local crt_path="$CERT_DIR/${domain}.crt"
    local key_path="$CERT_DIR/${domain}.key"
    local json=""
    local link=""

    if [[ "$t_choice" == "2" ]]; then
        local path="/$(openssl rand -hex 6)"
        info "已自动分配高匿随机路径: $path"
        json=$(jq -n \
            --arg tag "$tag" --arg port "$port" --arg pass "$pass" --arg domain "$domain" --arg path "$path" --arg crt "$crt_path" --arg key "$key_path" \
            '{type: "trojan", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{password: $pass}], transport: {type: "ws", path: $path, headers: {"Host": $domain}}, tls: {enabled: true, server_name: $domain, certificate_path: $crt, key_path: $key}}')
        link="trojan://${pass}@${domain}:${port}?security=tls&sni=${domain}&type=ws&host=${domain}&path=$(echo -n "$path" | jq -sRr @uri)#$(echo -n "$tag" | jq -sRr @uri)"
    else
        json=$(jq -n \
            --arg tag "$tag" --arg port "$port" --arg pass "$pass" --arg crt "$crt_path" --arg key "$key_path" \
            '{type: "trojan", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{password: $pass}], tls: {enabled: true, certificate_path: $crt, key_path: $key}}')
        link="trojan://${pass}@${domain}:${port}?security=tls&sni=${domain}&type=tcp#$(echo -n "$tag" | jq -sRr @uri)"
    fi

    atomic_inject "$tag" "$json" "$link"
}

deploy_shadowsocks() {
    echo -e "请选择加密方式:"
    echo "  1) 2022-blake3-aes-128-gcm (2022推荐)"
    echo "  2) 2022-blake3-aes-256-gcm"
    echo "  3) 2022-blake3-chacha20-poly1305"
    echo "  4) aes-128-gcm"
    echo "  5) aes-256-gcm"
    echo "  6) chacha20-poly1305"
    
    local ss_choice
    while true; do
        read -r -p "请选择 [1-6]: " ss_choice </dev/tty
        if [[ "$ss_choice" =~ ^[1-6]$ ]]; then break; else err "输入错误，请重新选择。"; fi
    done

    local method=""
    local pass=""
    
    case "$ss_choice" in
        1) method="2022-blake3-aes-128-gcm"; pass=$(openssl rand -base64 16) ;;
        2) method="2022-blake3-aes-256-gcm"; pass=$(openssl rand -base64 32) ;;
        3) method="2022-blake3-chacha20-poly1305"; pass=$(openssl rand -base64 32) ;;
        4) method="aes-128-gcm"; pass=$(openssl rand -base64 16) ;;
        5) method="aes-256-gcm"; pass=$(openssl rand -base64 32) ;;
        6) method="chacha20-poly1305"; pass=$(openssl rand -base64 32) ;;
    esac

    local port
    while true; do
        read -r -p "请输入监听端口: " port </dev/tty
        if check_port_free "$port"; then break; fi
    done

    ask_for_tag "SS-$port"
    local tag="$RET_TAG"

    fetch_public_ip

    local json; json=$(jq -n \
        --arg tag "$tag" --arg port "$port" --arg method "$method" --arg pass "$pass" \
        '{type: "shadowsocks", tag: $tag, listen: "::", listen_port: ($port|tonumber), method: $method, password: $pass}')
    
    local link=""
    if [[ "$method" == 2022-* ]]; then
        local m_enc; m_enc=$(jq -nr --arg v "$method" '$v | @uri')
        local p_enc; p_enc=$(jq -nr --arg v "$pass" '$v | @uri')
        link="ss://${m_enc}:${p_enc}@${PUBLIC_IP}:${port}#$(echo -n "$tag" | jq -sRr @uri)"
    else
        local b64; b64=$(echo -n "${method}:${pass}" | base64 -w 0)
        link="ss://${b64}@${PUBLIC_IP}:${port}#$(echo -n "$tag" | jq -sRr @uri)"
    fi

    atomic_inject "$tag" "$json" "$link"
}

deploy_vmess() {
    echo -e "请选择网络传输层结构:"
    echo "  1) TCP"
    echo "  2) WS + TLS"
    local v_choice
    while true; do
        read -r -p "请选择 [1-2]: " v_choice </dev/tty
        if [[ "$v_choice" =~ ^[1-2]$ ]]; then break; else err "输入错误，请重试。"; fi
    done

    local port
    while true; do
        read -r -p "请输入监听端口: " port </dev/tty
        if check_port_free "$port"; then break; fi
    done

    local default_name="VMess-$port"
    [[ "$v_choice" == "2" ]] && default_name="VMess-WS-$port"
    ask_for_tag "$default_name"
    local tag="$RET_TAG"

    local uuid; uuid=$(uuidgen)
    local json=""
    local link=""

    if [[ "$v_choice" == "2" ]]; then
        local domain
        while true; do
            read -r -p "请输入绑定域名 (需解析至本机): " domain </dev/tty
            if [[ -n "$domain" ]]; then break; else err "域名不能为空，请重新输入。"; fi
        done
        
        apply_cert "$domain" || return
        
        local path="/$(openssl rand -hex 6)"
        info "已自动分配高匿随机路径: $path"
        
        local crt_path="$CERT_DIR/${domain}.crt"
        local key_path="$CERT_DIR/${domain}.key"

        json=$(jq -n \
            --arg tag "$tag" --arg port "$port" --arg uuid "$uuid" --arg domain "$domain" --arg path "$path" --arg crt "$crt_path" --arg key "$key_path" \
            '{type: "vmess", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{uuid: $uuid, alterId: 0}], transport: {type: "ws", path: $path, headers: {"Host": $domain}}, tls: {enabled: true, server_name: $domain, certificate_path: $crt, key_path: $key}}')
        
        local vjson; vjson=$(jq -nc \
            --arg v "2" --arg ps "$tag" --arg add "$domain" --arg port "$port" --arg id "$uuid" \
            --arg aid "0" --arg net "ws" --arg type "none" --arg host "$domain" --arg path "$path" --arg tls "tls" --arg sni "$domain" \
            '{v:$v, ps:$ps, add:$add, port:$port, id:$id, aid:$aid, net:$net, type:$type, host:$host, path:$path, tls:$tls, sni:$sni}')
        link="vmess://$(echo -n "$vjson" | base64 -w 0)"
    else
        fetch_public_ip
        json=$(jq -n \
            --arg tag "$tag" --arg port "$port" --arg uuid "$uuid" \
            '{type: "vmess", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{uuid: $uuid, alterId: 0}]}')
        
        local vjson; vjson=$(jq -nc \
            --arg v "2" --arg ps "$tag" --arg add "$PUBLIC_IP" --arg port "$port" --arg id "$uuid" \
            --arg aid "0" --arg net "tcp" --arg type "none" \
            '{v:$v, ps:$ps, add:$add, port:$port, id:$id, aid:$aid, net:$net, type:$type}')
        link="vmess://$(echo -n "$vjson" | base64 -w 0)"
    fi

    atomic_inject "$tag" "$json" "$link"
}

deploy_mixed() {
    warn "Mixed (SOCKS/HTTP) 协议直接暴露于公网具有极高的风险。"
    echo "系统将强制附加鉴权机制或限制为本地监听。"
    echo "  1) 绑定至 localhost (127.0.0.1) 仅供内部进程调用"
    echo "  2) 开放至公网 (::) 但强制要求用户名/密码"
    
    local m_choice
    while true; do
        read -r -p "请选择策略 [1-2]: " m_choice </dev/tty
        if [[ "$m_choice" =~ ^[1-2]$ ]]; then break; else err "输入错误，请重新选择。"; fi
    done
    
    local port
    while true; do
        read -r -p "请输入监听端口: " port </dev/tty
        if check_port_free "$port"; then break; fi
    done

    ask_for_tag "Mixed-$port"
    local tag="$RET_TAG"

    local json=""
    local link=""

    if [[ "$m_choice" == "2" ]]; then
        local m_user
        while true; do
            read -r -p "请输入鉴权用户名: " m_user </dev/tty
            if [[ -n "$m_user" ]]; then break; else err "用户名不能为空。"; fi
        done
        
        local m_pass; m_pass=$(openssl rand -hex 6)
        info "已为您自动生成随机鉴权密码: $m_pass"
        fetch_public_ip
        
        json=$(jq -n \
            --arg tag "$tag" --arg port "$port" --arg user "$m_user" --arg pass "$m_pass" \
            '{type: "mixed", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{username: $user, password: $pass}]}')
        link="HTTP/SOCKS5: ${PUBLIC_IP}:${port} (账户: $m_user | 密码: $m_pass) [#$tag]"
    else
        json=$(jq -n \
            --arg tag "$tag" --arg port "$port" \
            '{type: "mixed", tag: $tag, listen: "127.0.0.1", listen_port: ($port|tonumber)}')
        link="内网 HTTP/SOCKS5: 127.0.0.1:${port} [#$tag]"
    fi

    atomic_inject "$tag" "$json" "$link"
}

deploy_naive() {
    local port
    while true; do
        read -r -p "请输入监听端口: " port </dev/tty
        if check_port_free "$port"; then break; fi
    done
    
    local domain
    while true; do
        read -r -p "请输入绑定域名 (需解析至本机): " domain </dev/tty
        if [[ -n "$domain" ]]; then break; else err "域名不能为空。"; fi
    done

    ask_for_tag "Naive-$port"
    local tag="$RET_TAG"

    apply_cert "$domain" || return

    local user; user=$(openssl rand -hex 4)
    local pass; pass=$(openssl rand -hex 8)
    local crt_path="$CERT_DIR/${domain}.crt"
    local key_path="$CERT_DIR/${domain}.key"

    local json; json=$(jq -n \
        --arg tag "$tag" --arg port "$port" --arg user "$user" --arg pass "$pass" --arg crt "$crt_path" --arg key "$key_path" \
        '{type: "naive", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{username: $user, password: $pass}], tls: {enabled: true, certificate_path: $crt, key_path: $key}}')
    
    local link="naive+https://${user}:${pass}@${domain}:${port}#$(echo -n "$tag" | jq -sRr @uri)"
    atomic_inject "$tag" "$json" "$link"
}

deploy_shadowtls() {
    check_singbox_version "1.8.0" || return
    info "ShadowTLS 为链式协议，将自动在后台构建隐藏的 SS 2022 解密端。"
    
    local port
    while true; do
        read -r -p "请输入 ShadowTLS 公网监听端口: " port </dev/tty
        if check_port_free "$port"; then break; fi
    done
    
    local sni
    while true; do
        read -r -p "请输入待寄生的白名单目标 (如 www.apple.com): " sni </dev/tty
        if [[ -n "$sni" ]]; then break; else err "寄生目标不能为空。"; fi
    done

    ask_for_tag "ShadowTLS-$port"
    local tag="$RET_TAG"

    fetch_public_ip
    local internal_port
    while true; do
        internal_port=$((RANDOM % 10000 + 40000))
        if check_port_free "$internal_port"; then break; fi
    done
    
    local stls_pass; stls_pass=$(openssl rand -hex 8)
    local ss_pass; ss_pass=$(openssl rand -base64 16)
    local ss_method="2022-blake3-aes-128-gcm"
    
    local inner_tag="SS-Internal-$internal_port"

    local json; json=$(jq -n \
        --arg tag "$tag" --arg port "$port" --arg stls_pass "$stls_pass" --arg sni "$sni" --arg inner "$inner_tag" \
        --arg ss_port "$internal_port" --arg ss_method "$ss_method" --arg ss_pass "$ss_pass" \
        '[
          {type: "shadowtls", tag: $tag, listen: "::", listen_port: ($port|tonumber), version: 3, password: $stls_pass, handshake: {server: $sni, server_port: 443}, detour: $inner},
          {type: "shadowsocks", tag: $inner, listen: "127.0.0.1", listen_port: ($ss_port|tonumber), method: $ss_method, password: $ss_pass}
        ]')
    
    local m_enc; m_enc=$(jq -nr --arg v "$ss_method" '$v | @uri')
    local p_enc; p_enc=$(jq -nr --arg v "$ss_pass" '$v | @uri')
    local link="ss://${m_enc}:${p_enc}@${PUBLIC_IP}:${port}?plugin=shadowtls&shadowtls-password=${stls_pass}&shadowtls-sni=${sni}#$(echo -n "$tag" | jq -sRr @uri)"
    
    atomic_inject "$tag" "$json" "$link"
}

# ================= 状态控制与生命周期管理 =================
list_nodes() {
    clear
    echo "==================================================="
    echo "                 查看所有节点                      "
    echo "==================================================="
    if [[ ! -s "$LINK_DB" ]]; then
        echo " 当前无节点记录。"
    else
        while IFS="|" read -r tag link; do
            if [[ "$tag" == SS-Internal-* ]]; then
                continue
            fi
            
            if jq -e --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$CONF_FILE" >/dev/null 2>&1; then
                echo -e " 标签: \033[33m$tag\033[0m"
                echo -e " 链接: \033[36m$link\033[0m"
                if [[ "$link" =~ ^(vless|hysteria2|tuic|trojan|ss|vmess|naive):// ]]; then
                    qrencode -t UTF8 "$link" 2>/dev/null || true
                fi
                echo "---------------------------------------------------"
            fi
        done < "$LINK_DB"
    fi
}

delete_node() {
    if [[ ! -s "$LINK_DB" ]]; then
        warn "当前无节点记录可删除。"
        return
    fi
    
    clear
    echo "==================================================="
    echo "                 请选择要删除的节点                "
    echo "==================================================="
    
    local -a tags_array=()
    local i=1
    while IFS="|" read -r tag link; do
        if [[ "$tag" == SS-Internal-* ]]; then continue; fi
        if jq -e --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$CONF_FILE" >/dev/null 2>&1; then
            echo "  $i) $tag"
            tags_array[$i]="$tag"
            ((i++))
        fi
    done < "$LINK_DB"
    
    if [[ ${#tags_array[@]} -eq 0 ]]; then
        warn "未检测到可开放的有效节点。"
        return
    fi
    echo "  0) 返回主菜单"
    echo "==================================================="
    
    local sel
    while true; do
        read -r -p "请输入要删除的节点序号 [0-$((i-1))]: " sel </dev/tty
        if [[ "$sel" == "0" ]]; then return; fi
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel < i )); then
            break
        else
            err "输入的序号无效，请重新输入。"
        fi
    done
    
    local t="${tags_array[$sel]}"
    
    if jq -e --arg tag "$t" '.inbounds[] | select(.tag == $tag)' "$CONF_FILE" >/dev/null 2>&1; then
        local tmp_conf="${CONF_FILE}.tmp"
        cp -a "$CONF_FILE" "${CONF_FILE}.bak"
        
        jq --arg tag "$t" 'del(.inbounds[] | select(.tag == $tag))' "$CONF_FILE" > "$tmp_conf"
        
        local inner_tag
        inner_tag=$(jq -r --arg tag "$t" '.inbounds[] | select(.tag == $tag) | .detour // empty' "$CONF_FILE" 2>/dev/null || true)
        if [[ -n "$inner_tag" ]]; then
            jq --arg tag "$inner_tag" 'del(.inbounds[] | select(.tag == $tag))' "$tmp_conf" > "${tmp_conf}.2" && mv "${tmp_conf}.2" "$tmp_conf"
        fi

        if sing-box check -c "$tmp_conf" >/dev/null 2>&1; then
            mv "$tmp_conf" "$CONF_FILE"
            systemctl restart sing-box || true
            sleep 1
            
            if ! systemctl is-active --quiet sing-box; then
                err "摘除操作引发内核崩溃，强制回退..."
                mv "${CONF_FILE}.bak" "$CONF_FILE"
                systemctl restart sing-box || true
            else
                sed -i "/^$t|/d" "$LINK_DB" 2>/dev/null || true
                rm -f "${CONF_FILE}.bak"
                info "节点 [\033[33m$t\033[0m] 已被彻底移除。"
            fi
        else
            err "配置逻辑校验失败，回绝摘除指令。"
            rm -f "$tmp_conf" "${CONF_FILE}.bak"
        fi
    else
        warn "节点配置异常丢失，请检查 config.json。"
    fi
}

uninstall_core() {
    echo -e "\033[31m⚠️ 警告：这将彻底抹除 Sing-box 配置、证书、运行库与系统级守护进程。\033[0m"
    local confirm
    read -r -p "确认执行灾难级清理？(y/N): " confirm </dev/tty
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消。"
        return
    fi
    
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    
    local bin_path
    bin_path=$(command -v sing-box || true)
    if [[ -n "$bin_path" ]]; then
        rm -f "$bin_path"
    fi
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload >/dev/null 2>&1 || true

    rm -rf "$CONF_DIR"
    
    local acme_confirm
    read -r -p "是否同步卸载 acme.sh 自动化引擎？(本机有其他业务请选N) (y/N): " acme_confirm </dev/tty
    if [[ "$acme_confirm" =~ ^[Yy]$ && -f "$ACME_DIR/acme.sh" ]]; then
        "$ACME_DIR/acme.sh" --uninstall >/dev/null 2>&1 || true
        rm -rf "$ACME_DIR"
    fi

    local dep_confirm
    read -r -p "是否同步卸载 jq, qrencode, socat, uuidgen 等基础依赖？(若其他软件需要请选N) (y/N): " dep_confirm </dev/tty
    if [[ "$dep_confirm" =~ ^[Yy]$ ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get remove -y jq qrencode socat uuid-runtime >/dev/null 2>&1 || true
            apt-get autoremove -y >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum remove -y jq qrencode socat util-linux >/dev/null 2>&1 || true
        fi
        info "基础依赖组件已被清理。"
    fi
    
    info "基础设施已彻底销毁，系统已恢复洁净。"
    exit 0
}

# ================= 交互菜单 =================
main_menu() {
    clear
    echo "==================================================="
    echo "                 Sing-box 一键管理                 "
    echo "==================================================="
    echo -e " 核心配置: \033[36m$CONF_FILE\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 安装/更新 Sing-box"
    echo "  2) 一键部署 VLESS-Reality"
    echo "  3) 一键部署 VLESS-WS"
    echo "  4) 一键部署 AnyTLS"
    echo "  5) 一键部署 Hysteria2"
    echo "  6) 一键部署 TUIC v5"
    echo "  7) 一键部署 Trojan"
    echo "  8) 一键部署 Shadowsocks"
    echo "  9) 一键部署 VMess"
    echo " 10) 一键部署 Mixed (HTTP/SOCKS)"
    echo " 11) 一键部署 NaiveProxy"
    echo " 12) 一键部署 ShadowTLS"
    echo " 13) 查看所有节点"
    echo " 14) 删除指定节点"
    echo " 15) 完全卸载"
    echo "  0) 退出脚本"
    echo "==================================================="
    
    local choice
    read -r -p "请输入序号 [0-15]: " choice </dev/tty
    case "$choice" in
        1) 
            install_singbox 
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        2) 
            if check_singbox_installed; then deploy_vless_reality; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        3) 
            if check_singbox_installed; then deploy_vless_ws; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        4) 
            if check_singbox_installed; then deploy_anytls; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        5) 
            if check_singbox_installed; then deploy_hysteria2; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        6) 
            if check_singbox_installed; then deploy_tuic; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        7) 
            if check_singbox_installed; then deploy_trojan; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        8) 
            if check_singbox_installed; then deploy_shadowsocks; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        9) 
            if check_singbox_installed; then deploy_vmess; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        10) 
            if check_singbox_installed; then deploy_mixed; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        11) 
            if check_singbox_installed; then deploy_naive; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        12) 
            if check_singbox_installed; then deploy_shadowtls; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        13) 
            if check_singbox_installed; then list_nodes; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        14) 
            if check_singbox_installed; then delete_node; fi
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        15) 
            uninstall_core 
            read -r -p "➤ 按回车键返回..." </dev/tty 
            ;;
        0) 
            exit 0 
            ;;
        *) 
            warn "无效输入" 
            sleep 1 
            ;;
    esac
}

if [[ $EUID -ne 0 ]]; then die "权限不足：请使用 root 权限。"; fi

init_env 

while true; do main_menu; done
