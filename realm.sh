#!/bin/bash

# ========================================
# 全局配置
# ========================================
CURRENT_VERSION="1.2.0"
UPDATE_URL="https://raw.githubusercontent.com/Assute/V2bx-Web/main/realm.sh"
VERSION_CHECK_URL="https://raw.githubusercontent.com/Assute/V2bx-Web/main/version.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REALM_DIR="/root/realm"
CONFIG_FILE="$REALM_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
LOG_FILE="/var/log/realm_manager.log"

PANEL_DIR="$REALM_DIR/panel"
PANEL_ENTRY="$PANEL_DIR/server.py"
PANEL_SERVICE_FILE="/etc/systemd/system/realm-panel.service"
PANEL_DATA_FILE="$PANEL_DIR/panel_data.json"
PANEL_DEFAULT_PORT="3060"
PANEL_REMOTE_BASE="https://raw.githubusercontent.com/Assute/V2bx-Web/main/panel"
PANEL_SOURCE_DIR="$SCRIPT_DIR/panel"

# ========================================
# 颜色定义
# ========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========================================
# 日志系统
# ========================================
log() {
    local log_msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$log_msg" >> "$LOG_FILE"
}

# ========================================
# 初始化检查
# ========================================
ensure_pkg_tool() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    else
        echo ""
    fi
}

install_package_if_missing() {
    local cmd_name="$1"
    local pkg_name="${2:-$1}"
    command -v "$cmd_name" >/dev/null 2>&1 && return 0

    local pkg_tool
    pkg_tool="$(ensure_pkg_tool)"
    if [[ -z "$pkg_tool" ]]; then
        echo -e "${RED}✗ 无法自动安装 ${pkg_name}，请手动安装${NC}"
        return 1
    fi

    echo -e "${YELLOW}• 正在安装 ${pkg_name}...${NC}"
    if [[ "$pkg_tool" == "apt" ]]; then
        apt-get update && apt-get install -y "$pkg_name"
    else
        yum install -y "$pkg_name"
    fi
}

init_check() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}✗ 必须使用 root 权限运行本脚本${NC}"
        exit 1
    fi

    install_package_if_missing curl curl || exit 1
    install_package_if_missing grep grep || exit 1
    install_package_if_missing sed sed || exit 1
    install_package_if_missing tar tar || exit 1

    mkdir -p "$REALM_DIR"
    touch "$LOG_FILE" >/dev/null 2>&1 || {
        echo -e "${RED}✗ 无法创建日志文件：$LOG_FILE${NC}"
        exit 1
    }

    log "脚本启动 v$CURRENT_VERSION"
}

ensure_realm_config() {
    mkdir -p "$REALM_DIR"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<'EOF'
[network]
no_tcp = false
use_udp = true
EOF
    fi
}

# ========================================
# 版本比较 / 更新
# ========================================
version_compare() {
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<${#ver1[@]}; i++)); do
        [[ -z ${ver2[i]} ]] && ver2[i]=0
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done
    return 0
}

check_update() {
    echo -e "\n${BLUE}• 正在检查更新...${NC}"
    local remote_version
    remote_version="$(curl -sL "$VERSION_CHECK_URL" 2>>"$LOG_FILE" | head -n1 | sed 's/[^0-9.]//g')"

    if [[ -z "$remote_version" ]]; then
        log "版本检查失败：无法获取远程版本"
        echo -e "${RED}✗ 无法获取远程版本信息，请检查网络${NC}"
        return 1
    fi

    if ! [[ "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "版本检查失败：无效版本号 $remote_version"
        echo -e "${RED}✗ 远程版本号格式错误${NC}"
        return 1
    fi

    version_compare "$CURRENT_VERSION" "$remote_version"
    case $? in
        0)
            echo -e "${GREEN}✓ 当前已是最新版本 v${CURRENT_VERSION}${NC}"
            return 1
            ;;
        1)
            echo -e "${YELLOW}※ 本地版本 v${CURRENT_VERSION} 高于远程版本 v${remote_version}${NC}"
            return 1
            ;;
        2)
            echo -e "${YELLOW}• 发现新版本 v${remote_version}${NC}"
            return 0
            ;;
    esac
}

perform_update() {
    echo -e "${BLUE}• 开始更新脚本...${NC}"
    log "尝试从 $UPDATE_URL 下载更新"

    if ! curl -sL "$UPDATE_URL" -o "$0.tmp"; then
        log "更新失败：下载脚本失败"
        echo -e "${RED}✗ 下载更新失败，请检查网络${NC}"
        return 1
    fi

    if ! grep -q "CURRENT_VERSION" "$0.tmp"; then
        log "更新失败：下载内容校验失败"
        echo -e "${RED}✗ 下载文件校验失败${NC}"
        rm -f "$0.tmp"
        return 1
    fi

    chmod +x "$0.tmp"
    mv -f "$0.tmp" "$0"
    log "更新完成，重新启动脚本"
    echo -e "${GREEN}✓ 更新成功，正在重新启动脚本...${NC}"
    exec "$0" "--no-update" "$@"
}

# ========================================
# 面板辅助
# ========================================
panel_installed() {
    [[ -f "$PANEL_ENTRY" && -f "$PANEL_SERVICE_FILE" ]]
}

panel_status() {
    if panel_installed && systemctl is-active --quiet realm-panel.service; then
        echo -e "${GREEN}已运行${NC}"
    elif panel_installed; then
        echo -e "${YELLOW}已安装未运行${NC}"
    else
        echo -e "${RED}未安装${NC}"
    fi
}

panel_get_port() {
    if [[ -f "$PANEL_ENTRY" ]]; then
        python3 "$PANEL_ENTRY" --print-port 2>/dev/null || echo "$PANEL_DEFAULT_PORT"
    else
        echo "$PANEL_DEFAULT_PORT"
    fi
}

panel_sync_from_config() {
    if panel_installed && command -v python3 >/dev/null 2>&1; then
        python3 "$PANEL_ENTRY" --sync-from-config >/dev/null 2>&1 || true
    fi
}

panel_register_cli_rule() {
    local remark="$1"
    local listen_addr="$2"
    local remote_addr="$3"
    if panel_installed && command -v python3 >/dev/null 2>&1; then
        python3 "$PANEL_ENTRY" --register-rule "$remark" "$listen_addr" "$remote_addr" >/dev/null 2>&1 || true
    fi
}

panel_remove_cli_rule() {
    local listen_addr="$1"
    local remote_addr="$2"
    if panel_installed && command -v python3 >/dev/null 2>&1; then
        python3 "$PANEL_ENTRY" --remove-rule "$listen_addr" "$remote_addr" >/dev/null 2>&1 || true
    fi
}

copy_panel_assets() {
    mkdir -p "$PANEL_DIR/templates"

    if [[ -f "$PANEL_SOURCE_DIR/server.py" && -f "$PANEL_SOURCE_DIR/templates/index.html" && -f "$PANEL_SOURCE_DIR/templates/login.html" ]]; then
        cp -f "$PANEL_SOURCE_DIR/server.py" "$PANEL_ENTRY"
        cp -f "$PANEL_SOURCE_DIR/templates/index.html" "$PANEL_DIR/templates/index.html"
        cp -f "$PANEL_SOURCE_DIR/templates/login.html" "$PANEL_DIR/templates/login.html"
    else
        curl -fsSL "$PANEL_REMOTE_BASE/server.py" -o "$PANEL_ENTRY" || return 1
        curl -fsSL "$PANEL_REMOTE_BASE/templates/index.html" -o "$PANEL_DIR/templates/index.html" || return 1
        curl -fsSL "$PANEL_REMOTE_BASE/templates/login.html" -o "$PANEL_DIR/templates/login.html" || return 1
    fi

    chmod +x "$PANEL_ENTRY"
}

install_panel() {
    install_package_if_missing python3 python3 || return 1

    echo -e "${BLUE}• 正在安装 Realm 面板...${NC}"
    mkdir -p "$PANEL_DIR/templates"

    if ! copy_panel_assets; then
        echo -e "${RED}✗ 面板文件下载/复制失败${NC}"
        return 1
    fi

    cat > "$PANEL_SERVICE_FILE" <<EOF
[Unit]
Description=Realm Panel Service
After=network.target realm.service
Wants=realm.service

[Service]
Type=simple
WorkingDirectory=$PANEL_DIR
ExecStart=/usr/bin/env python3 $PANEL_ENTRY
Environment=REALM_DIR=$REALM_DIR
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    python3 "$PANEL_ENTRY" --ensure-data >/dev/null 2>&1 || true
    python3 "$PANEL_ENTRY" --sync-from-config >/dev/null 2>&1 || true

    systemctl daemon-reload
    systemctl enable realm-panel.service >/dev/null 2>&1
    systemctl restart realm-panel.service

    local port host_ip
    port="$(panel_get_port)"
    host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -z "$host_ip" ]] && host_ip="服务器IP"

    log "安装/更新面板完成，端口：$port"
    echo -e "${GREEN}✓ 面板安装完成${NC}"
    echo -e "${CYAN}面板地址: http://${host_ip}:${port}${NC}"
    echo -e "${CYAN}默认账号: admin${NC}"
    echo -e "${CYAN}默认密码: 123456${NC}"
}

uninstall_panel() {
    if ! panel_installed; then
        echo -e "${YELLOW}※ 面板未安装${NC}"
        return 0
    fi

    echo -e "${BLUE}• 正在卸载 Realm 面板...${NC}"
    systemctl stop realm-panel.service >/dev/null 2>&1 || true
    systemctl disable realm-panel.service >/dev/null 2>&1 || true
    rm -f "$PANEL_SERVICE_FILE"
    rm -rf "$PANEL_DIR"
    systemctl daemon-reload
    log "面板已卸载"
    echo -e "${GREEN}✓ 面板已卸载${NC}"
}

change_panel_port() {
    if ! panel_installed; then
        echo -e "${RED}✗ 请先安装面板${NC}"
        return 1
    fi

    local current_port new_port
    current_port="$(panel_get_port)"
    echo -e "${CYAN}当前面板端口：${current_port}${NC}"
    read -rp "请输入新的面板端口: " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
        echo -e "${RED}✗ 端口格式错误${NC}"
        return 1
    fi

    python3 "$PANEL_ENTRY" --set-port "$new_port" || {
        echo -e "${RED}✗ 修改面板端口失败${NC}"
        return 1
    }

    systemctl restart realm-panel.service
    log "面板端口已修改为 $new_port"
    echo -e "${GREEN}✓ 面板端口已修改为 ${new_port}${NC}"
}

panel_menu() {
    while true; do
        clear
        echo -e "${BLUE}================ 面板管理 ================${NC}"
        echo -e "面板状态：$(panel_status)"
        if panel_installed; then
            echo -e "面板端口：${CYAN}$(panel_get_port)${NC}"
        fi
        echo -e "${BLUE}------------------------------------------${NC}"
        echo "1. 安装 / 更新面板"
        echo "2. 卸载面板"
        echo "3. 修改面板端口"
        echo "0. 返回"
        echo -e "${BLUE}------------------------------------------${NC}"
        read -rp "请输入选项: " panel_choice

        case "$panel_choice" in
            1) install_panel ;;
            2) uninstall_panel ;;
            3) change_panel_port ;;
            0) break ;;
            *) echo -e "${RED}✗ 无效选项${NC}" ;;
        esac
        read -rp "按回车键继续..."
    done
}

# ========================================
# Realm 核心功能
# ========================================
deploy_realm() {
    log "开始安装/更新 Realm"
    echo -e "${BLUE}• 正在安装/更新 Realm...${NC}"

    install_package_if_missing wget wget || return 1
    ensure_realm_config
    mkdir -p "$REALM_DIR"
    cd "$REALM_DIR" || return 1

    echo -e "${BLUE}• 正在检测 Realm 最新版本...${NC}"
    local latest_version
    latest_version="$(curl -sL https://github.com/zhboner/realm/releases | grep -oE '/zhboner/realm/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d'/' -f6 | tr -d 'v')"

    if [[ -z "$latest_version" || ! "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        latest_version="2.7.0"
        log "获取 Realm 最新版本失败，使用备用版本 $latest_version"
        echo -e "${YELLOW}※ 无法获取最新版本，改用备用版本 v${latest_version}${NC}"
    else
        echo -e "${GREEN}✓ 检测到最新版本 v${latest_version}${NC}"
    fi

    local download_url
    download_url="https://github.com/zhboner/realm/releases/download/v${latest_version}/realm-x86_64-unknown-linux-gnu.tar.gz"
    echo -e "${BLUE}• 正在下载 Realm v${latest_version}...${NC}"
    if ! wget --show-progress -qO realm.tar.gz "$download_url"; then
        log "Realm 下载失败：$download_url"
        echo -e "${RED}✗ 文件下载失败，请检查网络或手动验证地址：${download_url}${NC}"
        return 1
    fi

    tar -xzf realm.tar.gz
    chmod +x realm
    rm -f realm.tar.gz
    ensure_realm_config

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$REALM_DIR/realm -c $CONFIG_FILE
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm.service >/dev/null 2>&1 || true
    systemctl restart realm.service >/dev/null 2>&1 || true

    if panel_installed; then
        panel_sync_from_config
    fi

    log "Realm 安装/更新完成"
    echo -e "${GREEN}✓ Realm 安装/更新完成${NC}"
}

show_rules() {
    ensure_realm_config
    echo -e "                   ${YELLOW}当前 Realm 转发规则${NC}                   "
    echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
    printf "%-5s| %-30s| %-40s| %-20s\n" "序号" "本地地址:端口" "目标地址:端口" "备注"
    echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"

    local IFS=$'\n'
    local lines=($(grep -n '^listen = ' "$CONFIG_FILE"))
    if [[ ${#lines[@]} -eq 0 ]]; then
        echo "没有发现任何转发规则。"
        return
    fi

    local index=1
    local line line_number listen_info remote_info remark
    for line in "${lines[@]}"; do
        line_number="${line%%:*}"
        listen_info="$(sed -n "${line_number}p" "$CONFIG_FILE" | cut -d '"' -f 2)"
        remote_info="$(sed -n "$((line_number + 1))p" "$CONFIG_FILE" | cut -d '"' -f 2)"
        remark="$(sed -n "$((line_number - 1))p" "$CONFIG_FILE" | sed 's/^# 备注:[[:space:]]*//')"
        printf "%-4s| %-24s| %-34s| %-20s\n" " $index" "$listen_info" "$remote_info" "$remark"
        echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
        ((index++))
    done
}

add_rule() {
    ensure_realm_config
    log "开始添加转发规则"

    while true; do
        echo -e "\n${BLUE}• 添加新规则（输入 q 返回）${NC}"
        read -rp "本地监听端口: " local_port
        [[ "$local_port" == "q" ]] && break
        read -rp "目标服务器 IP: " remote_ip
        read -rp "目标端口: " remote_port
        read -rp "规则备注: " remark

        if ! [[ "$local_port" =~ ^[0-9]+$ ]] || ! [[ "$remote_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}✗ 端口必须为数字${NC}"
            continue
        fi

        echo -e "\n${YELLOW}请选择监听模式：${NC}"
        echo "1) 双栈监听 [::]:${local_port}（默认）"
        echo "2) 仅 IPv4 监听 0.0.0.0:${local_port}"
        echo "3) 自定义监听地址"
        read -rp "请输入选项 [1-3]（默认 1）: " ip_choice
        ip_choice="${ip_choice:-1}"

        local listen_addr desc
        case "$ip_choice" in
            1)
                listen_addr="[::]:$local_port"
                desc="双栈监听"
                ;;
            2)
                listen_addr="0.0.0.0:$local_port"
                desc="仅 IPv4"
                ;;
            3)
                while true; do
                    read -rp "请输入完整监听地址（如 0.0.0.0:80 或 [::]:443）: " listen_addr
                    if ! [[ "$listen_addr" =~ ^([0-9a-fA-F.:]+|\[.*\]):[0-9]+$ ]]; then
                        echo -e "${RED}✗ 格式错误，请参考：0.0.0.0:80 或 [::]:443${NC}"
                        continue
                    fi
                    break
                done
                desc="自定义监听"
                ;;
            *)
                echo -e "${RED}※ 无效选择，已使用默认值${NC}"
                listen_addr="[::]:$local_port"
                desc="双栈监听"
                ;;
        esac

        cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
# 备注: $remark
listen = "$listen_addr"
remote = "$remote_ip:$remote_port"
EOF

        if [[ "$ip_choice" == "1" ]]; then
            echo -e "\n${CYAN}ℹ 双栈监听需要确保：${NC}"
            echo -e "${CYAN}   - [network] 中 ipv6_only = false（默认不写即可）${NC}"
            echo -e "${CYAN}   - 系统允许 IPv6 双栈绑定：sysctl net.ipv6.bindv6only=0${NC}"
        fi

        systemctl restart realm.service >/dev/null 2>&1 || true
        panel_register_cli_rule "$remark" "$listen_addr" "$remote_ip:$remote_port"

        log "添加规则成功：$listen_addr -> $remote_ip:$remote_port ($desc)"
        echo -e "${GREEN}✓ 添加成功${NC}"
        read -rp "继续添加？(y/n): " cont
        [[ "$cont" != "y" ]] && break
    done
}

delete_rule() {
    ensure_realm_config
    echo -e "                   ${YELLOW}当前 Realm 转发规则${NC}                   "
    echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
    printf "%-5s| %-30s| %-40s| %-20s\n" "序号" "本地地址:端口" "目标地址:端口" "备注"
    echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"

    local IFS=$'\n'
    local blocks=($(grep -n '^\[\[endpoints\]\]' "$CONFIG_FILE"))
    if [[ ${#blocks[@]} -eq 0 ]]; then
        echo "没有发现任何转发规则。"
        return
    fi

    local index=1
    local block start_line remark_line listen_line remote_line remark listen_info remote_info
    for block in "${blocks[@]}"; do
        start_line="${block%%:*}"
        remark_line=$((start_line + 1))
        listen_line=$((start_line + 2))
        remote_line=$((start_line + 3))
        remark="$(sed -n "${remark_line}p" "$CONFIG_FILE" | sed 's/^# 备注:[[:space:]]*//')"
        listen_info="$(sed -n "${listen_line}p" "$CONFIG_FILE" | cut -d '"' -f 2)"
        remote_info="$(sed -n "${remote_line}p" "$CONFIG_FILE" | cut -d '"' -f 2)"
        printf "%-4s| %-24s| %-34s| %-20s\n" " $index" "$listen_info" "$remote_info" "$remark"
        echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
        ((index++))
    done

    echo "请输入要删除的转发规则序号，直接回车返回主菜单。"
    read -rp "选择: " choice
    [[ -z "$choice" ]] && return

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}✗ 请输入数字${NC}"
        return
    fi

    if (( choice < 1 || choice > ${#blocks[@]} )); then
        echo -e "${RED}✗ 选择超出范围${NC}"
        return
    fi

    local chosen_line start_del end_del next_del removed_listen removed_remote
    chosen_line="${blocks[$((choice - 1))]}"
    start_del="${chosen_line%%:*}"
    removed_listen="$(sed -n "$((start_del + 2))p" "$CONFIG_FILE" | cut -d '"' -f 2)"
    removed_remote="$(sed -n "$((start_del + 3))p" "$CONFIG_FILE" | cut -d '"' -f 2)"

    next_del="$(grep -n '^\[\[endpoints\]\]' "$CONFIG_FILE" | awk -F: -v s="$start_del" '$1>s {print $1; exit}')"
    if [[ -z "$next_del" ]]; then
        end_del="$(wc -l < "$CONFIG_FILE")"
    else
        end_del=$((next_del - 1))
    fi

    sed -i "${start_del},${end_del}d" "$CONFIG_FILE"
    systemctl restart realm.service >/dev/null 2>&1 || true
    panel_remove_cli_rule "$removed_listen" "$removed_remote"

    log "删除规则成功：$removed_listen -> $removed_remote"
    echo -e "${GREEN}✓ 转发规则已删除${NC}"
}

service_control() {
    case "$1" in
        start)
            systemctl unmask realm.service >/dev/null 2>&1 || true
            systemctl daemon-reload
            systemctl restart realm.service
            systemctl enable realm.service >/dev/null 2>&1 || true
            log "启动 Realm 服务"
            echo -e "${GREEN}✓ 服务已启动${NC}"
            ;;
        stop)
            systemctl stop realm.service >/dev/null 2>&1 || true
            log "停止 Realm 服务"
            echo -e "${YELLOW}※ 服务已停止${NC}"
            ;;
        restart)
            systemctl unmask realm.service >/dev/null 2>&1 || true
            systemctl daemon-reload
            systemctl restart realm.service
            systemctl enable realm.service >/dev/null 2>&1 || true
            log "重启 Realm 服务"
            echo -e "${GREEN}✓ 服务已重启${NC}"
            ;;
        status)
            if systemctl is-active --quiet realm.service; then
                echo -e "${GREEN}运行中${NC}"
            else
                echo -e "${RED}未运行${NC}"
            fi
            ;;
    esac
}

manage_cron() {
    echo -e "\n${YELLOW}定时任务管理${NC}"
    echo "1. 添加每日重启任务"
    echo "2. 删除所有 Realm 定时任务"
    echo "3. 查看当前定时任务"
    read -rp "请选择: " choice

    case "$choice" in
        1)
            read -rp "输入每日重启时间（0-23）: " hour
            if [[ "$hour" =~ ^[0-9]+$ ]] && (( hour >= 0 && hour <= 23 )); then
                sed -i '/systemctl restart realm/d' /etc/crontab
                echo "0 $hour * * * root /usr/bin/systemctl restart realm.service" >> /etc/crontab
                log "添加定时任务：每日 $hour 点重启 Realm"
                echo -e "${GREEN}✓ 定时任务已添加${NC}"
            else
                echo -e "${RED}✗ 时间输入无效${NC}"
            fi
            ;;
        2)
            sed -i '/systemctl restart realm/d' /etc/crontab
            log "删除所有 Realm 定时任务"
            echo -e "${YELLOW}✓ 定时任务已清除${NC}"
            ;;
        3)
            echo -e "\n${BLUE}当前 Realm 定时任务：${NC}"
            grep --color=auto 'systemctl restart realm' /etc/crontab || echo "暂无定时任务"
            ;;
        *)
            echo -e "${RED}✗ 无效选项${NC}"
            ;;
    esac
}

uninstall() {
    log "开始完全卸载"
    echo -e "${YELLOW}• 正在完全卸载...${NC}"

    uninstall_panel >/dev/null 2>&1 || true
    systemctl stop realm.service >/dev/null 2>&1 || true
    systemctl disable realm.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    rm -rf "$REALM_DIR"
    sed -i '/systemctl restart realm/d' /etc/crontab 2>/dev/null || true
    systemctl daemon-reload

    if [[ -f "$(pwd)/realm.sh" ]]; then
        rm -f "$(pwd)/realm.sh"
    fi

    log "完全卸载完成"
    echo -e "${GREEN}✓ 已完全卸载${NC}"
}

check_installed() {
    if [[ -f "$REALM_DIR/realm" && -f "$SERVICE_FILE" ]]; then
        echo -e "${GREEN}已安装${NC}"
    else
        echo -e "${RED}未安装${NC}"
    fi
}

# ========================================
# 主菜单
# ========================================
main_menu() {
    clear
    init_check

    local skip_update=false
    if [[ "$1" == "--no-update" ]]; then
        skip_update=true
        shift
    fi

    if ! $skip_update; then
        check_update && perform_update "$@"
    fi

    while true; do
        echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
        echo -e "                ${BLUE}Realm 高级管理脚本 v$CURRENT_VERSION${NC}"
        echo -e "        修改 by: Ami   日期: 2026/05/14"
        echo -e "        说明:"
        echo -e "          1. 保留原有 CLI 安装 / 规则 / 服务逻辑"
        echo -e "          2. 新增网页面板管理入口"
        echo -e "          3. 面板支持规则管理、批量导入、备份恢复、背景与账户设置"
        echo -e "    仓库: https://github.com/Assute/V2bx-Web"
        echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
        echo
        echo -e "${YELLOW}服务状态：$(service_control status)${NC}"
        echo -e "${YELLOW}安装状态：$(check_installed)${NC}"
        echo -e "${YELLOW}面板状态：$(panel_status)${NC}"
        if panel_installed; then
            echo -e "${YELLOW}面板端口：${CYAN}$(panel_get_port)${NC}"
        fi
        echo
        echo -e "${YELLOW}------------------${NC}"
        echo "1. 安装 / 更新 Realm"
        echo -e "${YELLOW}------------------${NC}"
        echo "2. 添加转发规则"
        echo "3. 查看转发规则"
        echo "4. 删除转发规则"
        echo -e "${YELLOW}------------------${NC}"
        echo "5. 启动服务"
        echo "6. 停止服务"
        echo "7. 重启服务"
        echo -e "${YELLOW}------------------${NC}"
        echo "8. 定时任务管理"
        echo "9. 查看日志"
        echo -e "${YELLOW}------------------${NC}"
        echo "10. 面板管理"
        echo "11. 完全卸载"
        echo -e "${YELLOW}------------------${NC}"
        echo "0. 退出脚本"
        echo -e "${YELLOW}------------------${NC}"

        read -rp "请输入选项: " choice
        case "$choice" in
            1) deploy_realm ;;
            2) add_rule ;;
            3) show_rules ;;
            4) delete_rule ;;
            5) service_control start ;;
            6) service_control stop ;;
            7) service_control restart ;;
            8) manage_cron ;;
            9)
                echo -e "\n${BLUE}最近日志：${NC}"
                tail -n 20 "$LOG_FILE"
                ;;
            10)
                panel_menu
                clear
                continue
                ;;
            11)
                read -rp "确认完全卸载？(y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    uninstall
                    read -rp "按回车键退出..."
                    clear
                    exit 0
                fi
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}✗ 无效选项${NC}"
                ;;
        esac
        read -rp "按回车键继续..."
        clear
    done
}

main_menu "$@"
