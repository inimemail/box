#!/usr/bin/env bash

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

CONF_DIR="/etc/sing-box"
CONF_FILE="$CONF_DIR/config.json"
CERT_DIR="$CONF_DIR/certs"
LINK_DB="$CONF_DIR/links.db"
PAUSED_DB="$CONF_DIR/paused-nodes.json"
ACME_DIR="${HOME:-/root}/.acme.sh"
EXPIRY_HELPER="/usr/local/sbin/sing-box-node-manager"
EXPIRY_SERVICE="/etc/systemd/system/sing-box-node-expiry.service"
EXPIRY_TIMER="/etc/systemd/system/sing-box-node-expiry.timer"

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
        elif [[ "$cmd" == "flock" ]]; then
            pkg_name="util-linux"
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

    if [[ ! -s "$PAUSED_DB" ]]; then
        printf '{}\n' > "$PAUSED_DB"
    elif command -v jq >/dev/null 2>&1 && ! jq -e 'type == "object"' "$PAUSED_DB" >/dev/null 2>&1; then
        die "暂停节点数据库格式损坏: $PAUSED_DB"
    fi
    chmod 600 "$PAUSED_DB" 2>/dev/null || true

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

get_core_status() {
    local service_state version

    CORE_VERSION="-"
    if ! command -v sing-box >/dev/null 2>&1; then
        CORE_STATUS="\033[31m未安装\033[0m"
        return
    fi

    version=$(sing-box version 2>/dev/null | awk 'NR == 1 { print $3 }' || true)
    CORE_VERSION=${version:-未知}

    if ! command -v systemctl >/dev/null 2>&1; then
        CORE_STATUS="\033[33m已安装（无法检测服务）\033[0m"
        return
    fi

    service_state=$(systemctl is-active sing-box 2>/dev/null || true)
    case "$service_state" in
        active)       CORE_STATUS="\033[32m运行中\033[0m" ;;
        inactive)     CORE_STATUS="\033[33m已停止\033[0m" ;;
        activating)   CORE_STATUS="\033[33m启动中\033[0m" ;;
        deactivating) CORE_STATUS="\033[33m停止中\033[0m" ;;
        failed)       CORE_STATUS="\033[31m运行失败\033[0m" ;;
        unknown)      CORE_STATUS="\033[33m已安装（服务未配置）\033[0m" ;;
        *)            CORE_STATUS="\033[33m已安装（状态未知）\033[0m" ;;
    esac
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
        
        if jq -e --arg t "$RET_TAG" '.inbounds[] | select(.tag == $t)' "$CONF_FILE" >/dev/null 2>&1 || \
           jq -e --arg t "$RET_TAG" 'has($t)' "$PAUSED_DB" >/dev/null 2>&1; then
            err "当前配置中已存在同名节点 [$RET_TAG]，请换一个名称。"
        else
            break
        fi
    done
}

# links.db 新格式: 标签|过期时间戳(0 表示永久)|分享链接。
# 旧格式为 标签|分享链接，读取时自动按永久节点兼容。
parse_link_record() {
    local line=$1
    local first_field rest

    RECORD_TAG=${line%%|*}
    if [[ "$line" != *"|"* ]]; then
        RECORD_EXPIRES_AT=0
        RECORD_LINK=""
        return
    fi

    rest=${line#*|}
    first_field=${rest%%|*}
    if [[ "$rest" == *"|"* && "$first_field" =~ ^[0-9]+$ ]]; then
        RECORD_EXPIRES_AT=$first_field
        RECORD_LINK=${rest#*|}
    else
        RECORD_EXPIRES_AT=0
        RECORD_LINK=$rest
    fi
}

format_expiry() {
    local expires_at=${1:-0}
    if [[ "$expires_at" == "0" ]]; then
        printf '永久'
    else
        date -d "@$expires_at" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '时间戳 %s' "$expires_at"
    fi
}

ask_for_expiry() {
    local choice input parsed days target_month last_day current_day target_day
    local target_date expiry_time custom_expiry reference_epoch reference_date reference_time
    while true; do
        target_date=""
        days=""
        custom_expiry=false
        echo "请选择节点有效期:"
        echo "  1) 永久"
        echo "  2) 1 天"
        echo "  3) 7 天"
        echo "  4) 15 天"
        echo "  5) 1 个自然月（下个月同日）"
        echo "  6) 自定义有效天数（可设置时分秒）"
        echo "  7) 指定到期日期（可设置时分秒）"
        read -r -p "请选择 [1-7，回车默认永久]: " choice </dev/tty
        reference_epoch=$(date +%s)
        reference_date=$(date -d "@$reference_epoch" +%Y-%m-%d)
        reference_time=$(date -d "@$reference_epoch" +%H:%M:%S)

        case "${choice:-1}" in
            1)
                RET_EXPIRES_AT=0
                return
                ;;
            2) days=1 ;;
            3) days=7 ;;
            4) days=15 ;;
            5)
                target_month=$(date -d "${reference_date%-??}-01 +1 month" +%Y-%m)
                last_day=$(date -d "${target_month}-01 +1 month -1 day" +%d)
                current_day=$(date -d "@$reference_epoch" +%d)
                current_day=$((10#$current_day))
                last_day=$((10#$last_day))
                if (( current_day > last_day )); then
                    target_day=$last_day
                else
                    target_day=$current_day
                fi
                target_date=$(printf '%s-%02d' "$target_month" "$target_day")
                ;;
            6)
                read -r -p "请输入有效天数 [1-36500]: " input </dev/tty
                if ! [[ "$input" =~ ^[1-9][0-9]*$ ]] || (( input > 36500 )); then
                    err "有效天数必须为 1 到 36500 的整数。"
                    continue
                fi
                days=$input
                custom_expiry=true
                ;;
            7)
                read -r -p "请输入到期日期 (YYYY-MM-DD): " input </dev/tty
                parsed=$(date -d "$input" +%Y-%m-%d 2>/dev/null || true)
                if [[ ! "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || "$parsed" != "$input" ]]; then
                    err "到期日期格式错误。"
                    continue
                fi
                target_date=$input
                custom_expiry=true
                ;;
            *)
                err "输入错误，请选择 1 到 7。"
                continue
                ;;
        esac

        if [[ -z "${target_date:-}" ]]; then
            target_date=$(date -d "$reference_date +$days day" +%Y-%m-%d)
        fi

        if ! $custom_expiry; then
            expiry_time=$reference_time
            RET_EXPIRES_AT=$(date -d "$target_date $expiry_time" +%s)
            return
        fi

        while true; do
            read -r -p "请输入到期时分秒 (HH:MM:SS) [回车默认 00:00:00]: " expiry_time </dev/tty
            expiry_time=${expiry_time:-00:00:00}
            if [[ "$expiry_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$ ]]; then
                parsed=$(date -d "$target_date $expiry_time" +%s 2>/dev/null || true)
                if [[ "$parsed" =~ ^[0-9]+$ ]] && (( parsed > $(date +%s) )); then
                    RET_EXPIRES_AT=$parsed
                    return
                fi
                err "指定的到期时间已经过去。"
                break
            fi
            err "时分秒格式错误，请按 HH:MM:SS 输入。"
        done
    done
}

rewrite_link_expiry() {
    local target_tag=$1
    local expires_at=$2
    local tmp_db="${LINK_DB}.tmp"
    local line

    : > "$tmp_db"
    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_link_record "$line"
        if [[ "$RECORD_TAG" == "$target_tag" ]]; then
            printf '%s|%s|%s\n' "$RECORD_TAG" "$expires_at" "$RECORD_LINK" >> "$tmp_db"
        else
            printf '%s\n' "$line" >> "$tmp_db"
        fi
    done < "$LINK_DB"
    chmod 600 "$tmp_db" 2>/dev/null || true
    mv "$tmp_db" "$LINK_DB"
}

remove_link_record() {
    local target_tag=$1
    local tmp_db="${LINK_DB}.tmp"
    local line

    : > "$tmp_db"
    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_link_record "$line"
        if [[ "$RECORD_TAG" != "$target_tag" ]]; then
            printf '%s\n' "$line" >> "$tmp_db"
        fi
    done < "$LINK_DB"
    chmod 600 "$tmp_db" 2>/dev/null || true
    mv "$tmp_db" "$LINK_DB"
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
    require_cmd flock

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
    setup_expiry_timer
    
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
atomic_inject() (
    exec 9> "$CONF_DIR/node-state.lock"
    flock 9

    local tag=$1
    local safe_json=$2
    local link=$3
    local expires_at

    ask_for_expiry
    expires_at=$RET_EXPIRES_AT

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

    printf '%s|%s|%s\n' "$tag" "$expires_at" "$link" >> "$LINK_DB"
    rm -f "${CONF_FILE}.bak"
    
    echo -e "\n=================================================="
    info "部署完成！"
    echo -e "节点标签: \033[33m$tag\033[0m"
    echo -e "有效期至: \033[33m$(format_expiry "$expires_at")\033[0m"
    echo -e "分享链接: \033[36m$link\033[0m"
    if [[ "$link" =~ ^(vless|hysteria2|tuic|trojan|ss|vmess|naive):// ]]; then
        qrencode -t UTF8 "$link" 2>/dev/null || true
    fi
    echo -e "==================================================\n"
)

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

deploy_hy2() {
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

    ask_for_tag "hy2-$port"
    local tag="$RET_TAG"

    apply_cert "$domain" || return

    local pass; pass=$(openssl rand -hex 12)
    local obfs_type=""
    local obfs_pass=""
    local obfs_choice
    echo "请选择 HY2 混淆模式:"
    echo "  1) 不启用混淆"
    echo "  2) Salamander（推荐）"
    while true; do
        read -r -p "请选择 [1-2，回车默认 2]: " obfs_choice </dev/tty
        case "${obfs_choice:-2}" in
            1)
                break
                ;;
            2)
                obfs_type="salamander"
                while true; do
                    IFS= read -r -p "请输入 Salamander 密码 [回车自动生成]: " obfs_pass </dev/tty
                    if [[ -z "$obfs_pass" ]]; then
                        obfs_pass=$(openssl rand -hex 16)
                        info "已自动生成 Salamander 密码。"
                        break
                    fi
                    if (( ${#obfs_pass} < 8 || ${#obfs_pass} > 128 )); then
                        err "Salamander 密码长度必须为 8 到 128 个字符。"
                        continue
                    fi
                    if [[ ! "$obfs_pass" =~ ^[^[:space:]]+$ ]]; then
                        err "Salamander 密码不能包含空格、制表符或其他空白字符。"
                        continue
                    fi
                    break
                done
                break
                ;;
            *)
                err "输入错误，请选择 1 或 2。"
                ;;
        esac
    done

    local crt_path="$CERT_DIR/${domain}.crt"
    local key_path="$CERT_DIR/${domain}.key"

    local json
    if [[ "$obfs_type" == "salamander" ]]; then
        json=$(jq -n \
            --arg tag "$tag" --arg port "$port" --arg pass "$pass" \
            --arg obfs_pass "$obfs_pass" --arg crt "$crt_path" --arg key "$key_path" \
            '{type: "hysteria2", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{password: $pass}], obfs: {type: "salamander", password: $obfs_pass}, tls: {enabled: true, alpn: ["h3"], certificate_path: $crt, key_path: $key}}')
    else
        json=$(jq -n \
            --arg tag "$tag" --arg port "$port" --arg pass "$pass" --arg crt "$crt_path" --arg key "$key_path" \
            '{type: "hysteria2", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{password: $pass}], tls: {enabled: true, alpn: ["h3"], certificate_path: $crt, key_path: $key}}')
    fi

    local pass_uri sni_uri tag_uri obfs_pass_uri
    pass_uri=$(jq -nr --arg v "$pass" '$v | @uri')
    sni_uri=$(jq -nr --arg v "$domain" '$v | @uri')
    tag_uri=$(jq -nr --arg v "$tag" '$v | @uri')

    local link="hysteria2://${pass_uri}@${domain}:${port}/?sni=${sni_uri}"
    if [[ "$obfs_type" == "salamander" ]]; then
        obfs_pass_uri=$(jq -nr --arg v "$obfs_pass" '$v | @uri')
        link+="&obfs=salamander&obfs-password=${obfs_pass_uri}"
    fi
    link+="#${tag_uri}"
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

deploy_ss() {
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

    ask_for_tag "ss-$port"
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
        link="HTTP/SOCKS5: ${PUBLIC_IP}:${port} (账户: $m_user |密码: $m_pass) [#$tag]"
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
        '{
          type: "naive", 
          tag: $tag, 
          listen: "::", 
          listen_port: ($port|tonumber), 
          users: [{username: $user, password: $pass}], 
          tls: {
            enabled: true, 
            alpn: ["h2", "http/1.1"], 
            certificate_path: $crt, 
            key_path: $key
          }
        }')
    
    local link="naive+https://${user}:${pass}@${domain}:${port}#$(echo -n "$tag" | jq -sRr @uri)"
    atomic_inject "$tag" "$json" "$link"
}

deploy_shadowtls() {
    check_singbox_version "1.8.0" || return
    info "ShadowTLS 为链式协议，将自动在后台构建隐藏的 ss 2022 解密端。"
    
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
    local internal_port inner_tag
    while true; do
        internal_port=$((RANDOM % 10000 + 40000))
        inner_tag="SS-Internal-$internal_port"
        if check_port_free "$internal_port"; then
            if jq -e --arg tag "$inner_tag" \
                '[.[] | .inbounds[]? | select(.tag == $tag)] | length > 0' "$PAUSED_DB" >/dev/null 2>&1; then
                continue
            fi
            break
        fi
    done
    
    local stls_pass; stls_pass=$(openssl rand -hex 8)
    local ss_pass; ss_pass=$(openssl rand -base64 16)
    local ss_method="2022-blake3-aes-128-gcm"
    
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

# ================= 节点过期暂停与恢复 =================
setup_expiry_timer() {
    if ! command -v systemctl >/dev/null 2>&1 || ! command -v sing-box >/dev/null 2>&1; then
        return
    fi

    local script_path
    script_path=$(readlink -f "$0" 2>/dev/null || true)
    if [[ -z "$script_path" || ! -f "$script_path" ]]; then
        warn "无法定位当前脚本，节点过期定时器未安装。"
        return
    fi

    if [[ "$script_path" != "$EXPIRY_HELPER" ]]; then
        install -m 700 "$script_path" "$EXPIRY_HELPER"
    fi

    cat > "$EXPIRY_SERVICE" <<EOF
[Unit]
Description=Pause expired sing-box nodes
After=sing-box.service

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/bin/bash $EXPIRY_HELPER --pause-expired
EOF

    cat > "$EXPIRY_TIMER" <<EOF
[Unit]
Description=Check sing-box node expiration

[Timer]
OnBootSec=10s
OnUnitActiveSec=10s
AccuracySec=1s
Unit=sing-box-node-expiry.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    if ! systemctl enable --now sing-box-node-expiry.timer >/dev/null 2>&1 || \
       ! systemctl restart sing-box-node-expiry.timer >/dev/null 2>&1; then
        warn "节点过期定时器启用失败。"
    fi
}

pause_nodes_unlocked() {
    local reason=$1
    shift
    (( $# > 0 )) || return 0

    local node_json inner_tag tag
    local tmp_conf="${CONF_FILE}.pause.tmp"
    local tmp_paused="${PAUSED_DB}.tmp"
    local backup_conf="${CONF_FILE}.pause.bak"
    local backup_paused="${PAUSED_DB}.bak"
    local -a paused_tags=()

    cp -a "$CONF_FILE" "$tmp_conf"
    cp -a "$PAUSED_DB" "$tmp_paused"

    for tag in "$@"; do
        if ! jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "$tmp_conf" >/dev/null 2>&1; then
            continue
        fi

        inner_tag=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .detour // empty' "$tmp_conf" 2>/dev/null || true)
        node_json=$(jq -c --arg tag "$tag" --arg inner "$inner_tag" \
            '[.inbounds[] | select(.tag == $tag or ($inner != "" and .tag == $inner))]' "$tmp_conf")

        jq --arg tag "$tag" --arg reason "$reason" --argjson nodes "$node_json" \
            '.[$tag] = {inbounds: $nodes, paused_at: (now | floor), reason: $reason}' "$tmp_paused" > "${tmp_paused}.2"
        mv "${tmp_paused}.2" "$tmp_paused"

        jq --arg tag "$tag" --arg inner "$inner_tag" \
            '.inbounds |= map(select(.tag != $tag and ($inner == "" or .tag != $inner)))' "$tmp_conf" > "${tmp_conf}.2"
        mv "${tmp_conf}.2" "$tmp_conf"
        paused_tags+=("$tag")
    done

    if (( ${#paused_tags[@]} == 0 )); then
        rm -f "$tmp_conf" "$tmp_paused"
        return 0
    fi

    if ! sing-box check -c "$tmp_conf" >/dev/null 2>&1; then
        err "暂停节点后的配置校验失败，本次操作已取消。"
        rm -f "$tmp_conf" "$tmp_paused"
        return 1
    fi

    cp -a "$CONF_FILE" "$backup_conf"
    cp -a "$PAUSED_DB" "$backup_paused"
    mv "$tmp_conf" "$CONF_FILE"
    mv "$tmp_paused" "$PAUSED_DB"
    chmod 600 "$CONF_FILE" "$PAUSED_DB" 2>/dev/null || true
    systemctl restart sing-box >/dev/null 2>&1 || true
    sleep 1

    if ! systemctl is-active --quiet sing-box; then
        mv "$backup_conf" "$CONF_FILE"
        mv "$backup_paused" "$PAUSED_DB"
        systemctl restart sing-box >/dev/null 2>&1 || true
        err "暂停节点后服务异常，已回滚。"
        return 1
    fi

    rm -f "$backup_conf" "$backup_paused"
    for tag in "${paused_tags[@]}"; do
        if [[ "$reason" == "expired" ]]; then
            info "节点 [$tag] 已到期并暂停。"
        else
            info "节点 [$tag] 已手动暂停。"
        fi
    done
}

pause_expired_nodes() (
    exec 9> "$CONF_DIR/node-state.lock"
    flock -n 9 || return 0

    [[ -s "$LINK_DB" ]] || return 0

    local now line
    local -a expired_tags=()
    now=$(date +%s)

    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_link_record "$line"
        [[ -n "$RECORD_TAG" ]] || continue
        if [[ "$RECORD_EXPIRES_AT" =~ ^[0-9]+$ ]] && \
           (( RECORD_EXPIRES_AT > 0 && RECORD_EXPIRES_AT <= now )) && \
           jq -e --arg t "$RECORD_TAG" '.inbounds[] | select(.tag == $t)' "$CONF_FILE" >/dev/null 2>&1; then
            local existing_tag already_seen=false
            for existing_tag in "${expired_tags[@]}"; do
                if [[ "$existing_tag" == "$RECORD_TAG" ]]; then
                    already_seen=true
                    break
                fi
            done
            if ! $already_seen; then
                expired_tags+=("$RECORD_TAG")
            fi
        fi
    done < "$LINK_DB"

    (( ${#expired_tags[@]} > 0 )) || return 0
    pause_nodes_unlocked expired "${expired_tags[@]}"
)

resume_node() {
    local tag=$1
    local nodes
    local tmp_conf="${CONF_FILE}.resume.tmp"
    local tmp_paused="${PAUSED_DB}.tmp"

    if ! jq -e --arg tag "$tag" 'has($tag)' "$PAUSED_DB" >/dev/null 2>&1; then
        return 0
    fi

    nodes=$(jq -c --arg tag "$tag" '.[$tag].inbounds' "$PAUSED_DB")
    if [[ "$nodes" == "null" ]] || \
       ! jq -en --argjson nodes "$nodes" \
        '($nodes | type) == "array" and ($nodes | length) > 0 and
         all($nodes[]; type == "object" and (.tag | type) == "string" and (.tag | length > 0)) and
         ([$nodes[].tag] | unique | length) == ($nodes | length)' >/dev/null 2>&1 || \
       ! jq -e --argjson nodes "$nodes" \
        '[.inbounds[].tag] as $existing | all($nodes[].tag; . as $tag | ($existing | index($tag) | not))' "$CONF_FILE" >/dev/null 2>&1; then
        err "节点 [$tag] 的暂停配置缺失或标签已被占用，无法恢复。"
        return 1
    fi

    jq --argjson nodes "$nodes" '.inbounds += $nodes' "$CONF_FILE" > "$tmp_conf"
    if ! sing-box check -c "$tmp_conf" >/dev/null 2>&1; then
        err "节点 [$tag] 恢复配置校验失败。"
        rm -f "$tmp_conf"
        return 1
    fi

    jq --arg tag "$tag" 'del(.[$tag])' "$PAUSED_DB" > "$tmp_paused"
    cp -a "$CONF_FILE" "${CONF_FILE}.resume.bak"
    cp -a "$PAUSED_DB" "${PAUSED_DB}.bak"
    mv "$tmp_conf" "$CONF_FILE"
    mv "$tmp_paused" "$PAUSED_DB"
    chmod 600 "$CONF_FILE" "$PAUSED_DB" 2>/dev/null || true
    systemctl restart sing-box >/dev/null 2>&1 || true
    sleep 1

    if ! systemctl is-active --quiet sing-box; then
        mv "${CONF_FILE}.resume.bak" "$CONF_FILE"
        mv "${PAUSED_DB}.bak" "$PAUSED_DB"
        systemctl restart sing-box >/dev/null 2>&1 || true
        err "节点 [$tag] 恢复后服务异常，已回滚。"
        return 1
    fi

    rm -f "${CONF_FILE}.resume.bak" "${PAUSED_DB}.bak"
    return 0
}

# ================= 状态控制与生命周期管理 =================
list_nodes() {
    if [[ ! -s "$LINK_DB" ]]; then
        warn "当前无节点记录可查看。"
        sleep 1.5
        return
    fi

    while true; do
        clear
        echo "==================================================="
        echo "                 请选择要查看的节点                "
        echo "==================================================="

        local -a tags_array=()
        local -a links_array=()
        local -a expires_array=()
        local -a states_array=()
        local i=1
        local line state expiry_text pause_reason

        while IFS= read -r line || [[ -n "$line" ]]; do
            parse_link_record "$line"
            local tag="$RECORD_TAG"
            local link="$RECORD_LINK"
            if [[ "$tag" == SS-Internal-* ]]; then continue; fi

            if jq -e --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$CONF_FILE" >/dev/null 2>&1; then
                state="运行中"
            elif jq -e --arg t "$tag" 'has($t)' "$PAUSED_DB" >/dev/null 2>&1; then
                pause_reason=$(jq -r --arg t "$tag" '.[$t].reason // "expired"' "$PAUSED_DB")
                if [[ "$pause_reason" == "manual" ]]; then
                    state="手动暂停"
                else
                    state="到期暂停"
                fi
            else
                continue
            fi
            expiry_text=$(format_expiry "$RECORD_EXPIRES_AT")
            echo "  $i) $tag [$state | $expiry_text]"
            tags_array[$i]="$tag"
            links_array[$i]="$link"
            expires_array[$i]="$RECORD_EXPIRES_AT"
            states_array[$i]="$state"
            ((i++))
        done < "$LINK_DB"

        if [[ ${#tags_array[@]} -eq 0 ]]; then
            warn "未检测到可开放的有效节点。"
            sleep 1.5
            return
        fi
        
        echo "  0) 返回主菜单"
        echo "==================================================="

        local sel
        read -r -p "请输入要查看的节点序号 [0-$((i-1))]: " sel </dev/tty
        
        if [[ "$sel" == "0" ]]; then
            return
        elif [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel < i )); then
            clear
            echo "==================================================="
            echo -e " 标签: \033[33m${tags_array[$sel]}\033[0m"
            echo -e " 状态: \033[33m${states_array[$sel]}\033[0m"
            echo -e " 到期: \033[33m$(format_expiry "${expires_array[$sel]}")\033[0m"
            echo -e " 链接: \033[36m${links_array[$sel]}\033[0m"
            echo "---------------------------------------------------"
            local view_link="${links_array[$sel]}"
            if [[ "$view_link" =~ ^(vless|hysteria2|tuic|trojan|ss|vmess|naive):// ]]; then
                qrencode -t UTF8 "$view_link" 2>/dev/null || true
            fi
            echo "==================================================="
            read -r -p "➤ 按回车键返回节点列表..." </dev/tty
        else
            err "输入的序号无效，请重新输入。"
            sleep 1
        fi
    done
}

set_node_expiry() (
    exec 9> "$CONF_DIR/node-state.lock"
    flock 9

    if [[ ! -s "$LINK_DB" ]]; then
        warn "当前无节点记录可设置。"
        sleep 1.5
        return
    fi

    clear
    echo "==================================================="
    echo "              请选择要设置有效期的节点             "
    echo "==================================================="

    local -a tags_array=()
    local -a expires_array=()
    local -a paused_array=()
    local -a pause_reasons_array=()
    local line state expiry_text pause_reason
    local i=1

    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_link_record "$line"
        if jq -e --arg t "$RECORD_TAG" '.inbounds[] | select(.tag == $t)' "$CONF_FILE" >/dev/null 2>&1; then
            state="运行中"
            paused_array[$i]=0
            pause_reasons_array[$i]=""
        elif jq -e --arg t "$RECORD_TAG" 'has($t)' "$PAUSED_DB" >/dev/null 2>&1; then
            pause_reason=$(jq -r --arg t "$RECORD_TAG" '.[$t].reason // "expired"' "$PAUSED_DB")
            if [[ "$pause_reason" == "manual" ]]; then
                state="手动暂停"
            else
                state="到期暂停"
            fi
            paused_array[$i]=1
            pause_reasons_array[$i]="$pause_reason"
        else
            continue
        fi
        expiry_text=$(format_expiry "$RECORD_EXPIRES_AT")
        echo "  $i) $RECORD_TAG [$state | $expiry_text]"
        tags_array[$i]="$RECORD_TAG"
        expires_array[$i]="$RECORD_EXPIRES_AT"
        ((i++))
    done < "$LINK_DB"

    if [[ ${#tags_array[@]} -eq 0 ]]; then
        warn "未检测到可设置的有效节点。"
        sleep 1.5
        return
    fi

    echo "  0) 返回主菜单"
    echo "==================================================="
    local sel
    while true; do
        read -r -p "请输入节点序号 [0-$((i-1))]: " sel </dev/tty
        [[ "$sel" == "0" ]] && return
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel < i )); then
            break
        fi
        err "输入的序号无效，请重新输入。"
    done

    ask_for_expiry
    local tag="${tags_array[$sel]}"
    local expires_at=$RET_EXPIRES_AT

    if [[ "${paused_array[$sel]}" == "1" && "${pause_reasons_array[$sel]}" != "manual" ]]; then
        rewrite_link_expiry "$tag" "$expires_at"
        if ! resume_node "$tag"; then
            rewrite_link_expiry "$tag" "${expires_array[$sel]}"
            sleep 1.5
            return
        fi
        info "节点 [$tag] 已恢复运行。"
    else
        rewrite_link_expiry "$tag" "$expires_at"
        if [[ "${paused_array[$sel]}" == "1" ]]; then
            info "节点 [$tag] 保持手动暂停，可在节点状态菜单中启动。"
        fi
    fi
    info "节点 [$tag] 的有效期已设置为: $(format_expiry "$expires_at")"
    read -r -p "➤ 按回车键继续..." </dev/tty
)

manage_node_state() (
    exec 9> "$CONF_DIR/node-state.lock"
    flock 9

    if [[ ! -s "$LINK_DB" ]]; then
        warn "当前无节点记录可管理。"
        sleep 1.5
        return
    fi

    clear
    echo "==================================================="
    echo "                请选择要操作的节点                 "
    echo "==================================================="

    local -a tags_array=()
    local -a expires_array=()
    local -a active_array=()
    local line state expiry_text pause_reason
    local i=1

    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_link_record "$line"
        [[ -n "$RECORD_TAG" ]] || continue

        if jq -e --arg t "$RECORD_TAG" '.inbounds[] | select(.tag == $t)' "$CONF_FILE" >/dev/null 2>&1; then
            state="运行中"
            active_array[$i]=1
        elif jq -e --arg t "$RECORD_TAG" 'has($t)' "$PAUSED_DB" >/dev/null 2>&1; then
            pause_reason=$(jq -r --arg t "$RECORD_TAG" '.[$t].reason // "expired"' "$PAUSED_DB")
            if [[ "$pause_reason" == "manual" ]]; then
                state="手动暂停"
            else
                state="到期暂停"
            fi
            active_array[$i]=0
        else
            continue
        fi

        expiry_text=$(format_expiry "$RECORD_EXPIRES_AT")
        echo "  $i) $RECORD_TAG [$state | $expiry_text]"
        tags_array[$i]="$RECORD_TAG"
        expires_array[$i]="$RECORD_EXPIRES_AT"
        ((i++))
    done < "$LINK_DB"

    if [[ ${#tags_array[@]} -eq 0 ]]; then
        warn "未检测到可管理的有效节点。"
        sleep 1.5
        return
    fi

    echo "  0) 返回主菜单"
    echo "==================================================="
    local sel
    while true; do
        read -r -p "请输入节点序号 [0-$((i-1))]: " sel </dev/tty
        [[ "$sel" == "0" ]] && return
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel < i )); then
            break
        fi
        err "输入的序号无效，请重新输入。"
    done

    local tag="${tags_array[$sel]}"
    local expires_at="${expires_array[$sel]}"
    if [[ "${active_array[$sel]}" == "1" ]]; then
        local confirm
        read -r -p "确认暂停节点 [$tag]？(y/N): " confirm </dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "已取消。"
            return
        fi
        pause_nodes_unlocked manual "$tag"
    else
        if [[ "$expires_at" =~ ^[0-9]+$ ]] && \
           (( expires_at > 0 && expires_at <= $(date +%s) )); then
            err "节点 [$tag] 已过期，请先在菜单 [15] 中续期，再启动。"
            read -r -p "➤ 按回车键继续..." </dev/tty
            return
        fi
        if resume_node "$tag"; then
            info "节点 [$tag] 已启动。"
        else
            sleep 1.5
            return
        fi
    fi

    read -r -p "➤ 按回车键继续..." </dev/tty
)

delete_node() (
    exec 9> "$CONF_DIR/node-state.lock"
    flock 9

    if [[ ! -s "$LINK_DB" ]]; then
        warn "当前无节点记录可删除。"
        sleep 1.5
        return
    fi
    
    clear
    echo "==================================================="
    echo "                 请选择要删除的节点                "
    echo "==================================================="
    
    local -a tags_array=()
    local i=1
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_link_record "$line"
        if [[ "$RECORD_TAG" == SS-Internal-* ]]; then continue; fi
        if jq -e --arg t "$RECORD_TAG" '.inbounds[] | select(.tag == $t)' "$CONF_FILE" >/dev/null 2>&1 || \
           jq -e --arg t "$RECORD_TAG" 'has($t)' "$PAUSED_DB" >/dev/null 2>&1; then
            echo "  $i) $RECORD_TAG"
            tags_array[$i]="$RECORD_TAG"
            ((i++))
        fi
    done < "$LINK_DB"
    
    if [[ ${#tags_array[@]} -eq 0 ]]; then
        warn "未检测到可开放的有效节点。"
        sleep 1.5
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
            chmod 600 "$CONF_FILE" 2>/dev/null || true
            systemctl restart sing-box || true
            sleep 1
            
            if ! systemctl is-active --quiet sing-box; then
                err "摘除操作引发内核崩溃，强制回退..."
                mv "${CONF_FILE}.bak" "$CONF_FILE"
                systemctl restart sing-box || true
            else
                remove_link_record "$t"
                rm -f "${CONF_FILE}.bak"
                info "节点 [\033[33m$t\033[0m] 已被彻底移除。"
                read -r -p "➤ 按回车键继续..." </dev/tty
            fi
        else
            err "配置逻辑校验失败，回绝摘除指令。"
            rm -f "$tmp_conf" "${CONF_FILE}.bak"
            sleep 1.5
        fi
    elif jq -e --arg tag "$t" 'has($tag)' "$PAUSED_DB" >/dev/null 2>&1; then
        local tmp_paused="${PAUSED_DB}.tmp"
        if jq --arg tag "$t" 'del(.[$tag])' "$PAUSED_DB" > "$tmp_paused"; then
            chmod 600 "$tmp_paused" 2>/dev/null || true
            mv "$tmp_paused" "$PAUSED_DB"
            remove_link_record "$t"
            info "暂停节点 [\033[33m$t\033[0m] 已被彻底移除。"
            read -r -p "➤ 按回车键继续..." </dev/tty
        else
            rm -f "$tmp_paused"
            err "暂停节点数据库更新失败。"
            sleep 1.5
        fi
    else
        warn "节点配置异常丢失，请检查 config.json。"
        sleep 1.5
    fi
)

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
    systemctl disable --now sing-box-node-expiry.timer >/dev/null 2>&1 || true
    rm -f "$EXPIRY_SERVICE" "$EXPIRY_TIMER" "$EXPIRY_HELPER"
    
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
    get_core_status
    clear
    echo "==================================================="
    echo "                 Sing-box 一键管理                 "
    echo "==================================================="
    echo -e " 核心配置: \033[36m$CONF_FILE\033[0m"
    echo -e " 核心状态: $CORE_STATUS    版本: \033[36m$CORE_VERSION\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 安装/更新 Sing-box 内核与依赖"
    echo "  2) 一键部署 VLESS-Reality"
    echo "  3) 一键部署 VLESS-WS"
    echo "  4) 一键部署 AnyTLS"
    echo "  5) 一键部署 hy2"
    echo "  6) 一键部署 TUIC v5"
    echo "  7) 一键部署 Trojan"
    echo "  8) 一键部署 ss"
    echo "  9) 一键部署 VMess"
    echo " 10) 一键部署 Mixed (HTTP/SOCKS)"
    echo " 11) 一键部署 NaiveProxy"
    echo " 12) 一键部署 ShadowTLS"
    echo " 13) 查看所有节点"
    echo " 14) 删除指定节点"
    echo " 15) 编辑节点有效期"
    echo " 16) 暂停/启动指定节点"
    echo " 17) 完全卸载"
    echo "  0) 退出脚本"
    echo "==================================================="
    
    local choice
    read -r -p "请输入序号 [0-17]: " choice </dev/tty
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
            if check_singbox_installed; then deploy_hy2; fi
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
            if check_singbox_installed; then deploy_ss; fi
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
            ;;
        14) 
            if check_singbox_installed; then delete_node; fi
            ;;
        15) 
            if check_singbox_installed; then set_node_expiry; fi
            ;;
        16) 
            if check_singbox_installed; then manage_node_state; fi
            ;;
        17) 
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

if [[ "${1:-}" == "--pause-expired" ]]; then
    if [[ -s "$CONF_FILE" && -e "$LINK_DB" && -s "$PAUSED_DB" ]] && check_singbox_installed; then
        pause_expired_nodes
    fi
    exit 0
fi

init_env 

if command -v sing-box >/dev/null 2>&1; then
    require_cmd flock
    setup_expiry_timer
    pause_expired_nodes || true
fi

while true; do main_menu; done
