#!/bin/bash
# =========================================================
# NaiveProxy (Caddy v2) 工业级自动化部署脚本
# 适用系统: Debian / Ubuntu
# =========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[错误] 必须使用 root 用户运行此脚本！${PLAIN}"
   exit 1
fi

# 安装基础依赖
install_dependencies() {
    echo -e "${GREEN}[INFO] 正在更新系统并安装基础依赖...${PLAIN}"
    apt-get update -y
    apt-get install -y curl wget tar jq git sudo setcap
}

# 部署 Go 环境
install_go() {
    echo -e "${GREEN}[INFO] 正在部署 Go 编译环境...${PLAIN}"
    GO_VERSION=$(curl -s https://go.dev/VERSION?m=text | head -n 1)
    if [[ -z "$GO_VERSION" ]]; then
        GO_VERSION="go1.21.0"
    fi
    wget "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "${GO_VERSION}.linux-amd64.tar.gz"
    rm -f "${GO_VERSION}.linux-amd64.tar.gz"
    
    export PATH=$PATH:/usr/local/go/bin
    if ! grep -q "/usr/local/go/bin" /etc/profile; then
        echo "export PATH=\$PATH:/usr/local/go/bin" >> /etc/profile
    fi
    echo -e "${GREEN}[INFO] Go 环境部署完成！$(go version)${PLAIN}"
}

# 编译 Caddy + NaiveProxy (forwardproxy) 插件
compile_caddy() {
    echo -e "${YELLOW}[INFO] 正在通过 xcaddy 编译带有 NaiveProxy 模块的 Caddy，由于需要拉取源码，此过程可能需要几分钟，请耐心等待...${PLAIN}"
    install_go
    export PATH=$PATH:/usr/local/go/bin
    
    # 安装 xcaddy
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
    export PATH=$PATH:~/go/bin
    
    # 编译
    xcaddy build --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive
    
    if [[ -f "./caddy" ]]; then
        mv ./caddy /usr/local/bin/caddy
        chmod +x /usr/local/bin/caddy
        setcap cap_net_bind_service=+ep /usr/local/bin/caddy
        echo -e "${GREEN}[INFO] Caddy 核心编译成功！${PLAIN}"
    else
        echo -e "${RED}[错误] Caddy 编译失败，请检查网络或内存是否充足。${PLAIN}"
        exit 1
    fi
}

# 配置生成器
generate_config() {
    read -p "请输入您的域名 (需已解析到本服务器IP): " DOMAIN
    read -p "请输入接收 TLS 证书通知的邮箱: " EMAIL
    read -p "请设置 NaiveProxy 用户名 (默认: admin): " USERNAME
    USERNAME=${USERNAME:-admin}
    read -p "请设置 NaiveProxy 密码: " PASSWORD
    if [[ -z "$PASSWORD" ]]; then
        echo -e "${RED}[错误] 密码不能为空！${PLAIN}"
        exit 1
    fi

    echo -e "${GREEN}[INFO] 正在生成 Caddy 配置文件...${PLAIN}"
    mkdir -p /etc/caddy /var/log/caddy /var/www/html
    
    # 创建一个伪装站点主页
    echo "<h1>Welcome to Nginx</h1><p>The server is running smoothly.</p>" > /var/www/html/index.html

    cat > /etc/caddy/Caddyfile <<EOF
{
    order forward_proxy before file_server
}

:443, $DOMAIN {
    tls $EMAIL
    route {
        forward_proxy {
            basic_auth $USERNAME $PASSWORD
            hide_ip
            hide_via
            probe_resistance
        }
        file_server {
            root /var/www/html
        }
    }
}
EOF

    # 配置 Systemd 守护进程
    cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable caddy
    systemctl restart caddy

    echo -e "${GREEN}[INFO] NaiveProxy 部署完成并已启动服务！${PLAIN}"
    echo -e "========================================================="
    echo -e " 您的 NaiveProxy 客户端配置参数如下："
    echo -e " 代理协议: ${BLUE}HTTPS${PLAIN}"
    echo -e " 代理地址: ${BLUE}$DOMAIN${PLAIN}"
    echo -e " 代理端口: ${BLUE}443${PLAIN}"
    echo -e " 用户名  : ${BLUE}$USERNAME${PLAIN}"
    echo -e " 密  码  : ${BLUE}$PASSWORD${PLAIN}"
    echo -e ""
    echo -e " 客户端 (config.json) 示例:"
    echo -e " {"
    echo -e "   \"listen\": \"socks://127.0.0.1:1080\","
    echo -e "   \"proxy\": \"https://$USERNAME:$PASSWORD@$DOMAIN\""
    echo -e " }"
    echo -e "========================================================="
}

# 查看日志
show_logs() {
    echo -e "${YELLOW}正在输出 Caddy 运行日志 (按 Ctrl+C 退出):${PLAIN}"
    journalctl -u caddy.service -f
}

# 卸载脚本
uninstall() {
    echo -e "${RED}[警告] 正在卸载 NaiveProxy 和 Caddy...${PLAIN}"
    systemctl stop caddy
    systemctl disable caddy
    rm -rf /usr/local/bin/caddy
    rm -rf /etc/caddy
    rm -rf /etc/systemd/system/caddy.service
    systemctl daemon-reload
    echo -e "${GREEN}[INFO] 卸载完成。${PLAIN}"
}

# 主菜单引擎
menu() {
    clear
    echo -e "========================================================="
    echo -e " ${GREEN}NaiveProxy 一键管理面板${PLAIN}"
    echo -e "========================================================="
    echo -e " ${GREEN}1.${PLAIN} 全新安装 NaiveProxy (编译安装环境配置)"
    echo -e " ${GREEN}2.${PLAIN} 查看运行状态与日志"
    echo -e " ${GREEN}3.${PLAIN} 重启 NaiveProxy 服务"
    echo -e " ${GREEN}4.${PLAIN} 彻底卸载面板及服务"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo -e "========================================================="
    read -p "请输入数字选择功能 [0-4]: " choice

    case $choice in
        1)
            install_dependencies
            compile_caddy
            generate_config
            ;;
        2)
            show_logs
            ;;
        3)
            systemctl restart caddy
            echo -e "${GREEN}[INFO] 服务已重启。${PLAIN}"
            ;;
        4)
            read -p "确定要卸载吗? [y/N]: " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                uninstall
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}[错误] 输入无效，请输入 0-4 之间的数字。${PLAIN}"
            sleep 2
            menu
            ;;
    esac
}

# 启动主菜单
menu
