#!/bin/bash

# ========================================
# 全局配置
# ========================================
CURRENT_VERSION="1.1.3"
UPDATE_URL="https://raw.githubusercontent.com/misakaok/EZrealm/main/realm.sh"
VERSION_CHECK_URL="https://raw.githubusercontent.com/misakaok/EZrealm/main/version.txt"
REALM_DIR="/root/realm"
CONFIG_FILE="$REALM_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
LOG_FILE="/var/log/realm_manager.log"
CRON_FILE="/etc/crontab"
CRON_MARK="# ezrealm"
# 匹配本脚本写入的定时任务（含旧版本未加标记的写法），避免误删其他含 realm 的任务
CRON_PATTERN='root /usr/bin/systemctl restart realm( # ezrealm)?$'

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
# 初始化检查
# ========================================
init_check() {
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}✖ 必须使用root权限运行本脚本${NC}"
        exit 1
    fi

    # 检查curl安装
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}▶ 正在安装curl工具...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y curl
        elif command -v yum &> /dev/null; then
            yum install -y curl
        else
            echo -e "${RED}✖ 无法安装curl，请手动安装${NC}"
            exit 1
        fi
    fi

    # 创建必要目录
    mkdir -p "$REALM_DIR"
    if [[ ! -w $(dirname "$LOG_FILE") ]]; then
        echo -e "${RED}✖ 日志目录不可写，请检查权限${NC}"
        exit 1
    fi
    touch "$LOG_FILE" || {
        echo -e "${RED}✖ 无法创建日志文件${NC}"
        exit 1
    }

    log "脚本启动 v$CURRENT_VERSION"
}

# ========================================
# 日志系统
# ========================================
log() {
    local log_msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$log_msg" >> "$LOG_FILE"
}

# ========================================
# 版本比较函数
# ========================================
version_compare() {
    if [[ "$1" == "$2" ]]; then
        return 0  # 版本相同
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1  # 当前版本更高
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2  # 远程版本更高
        fi
    done
    return 0
}

# ========================================
# 自动更新模块
# ========================================
check_update() {
    echo -e "\n${BLUE}▶ 正在检查更新...${NC}"
    
    # 获取远程版本（更严格的过滤）
    remote_version=$(curl -sL $VERSION_CHECK_URL 2>> "$LOG_FILE" | head -n1 | sed 's/[^0-9.]//g')
    if [[ -z "$remote_version" ]]; then
        log "版本检查失败：无法获取远程版本"
        echo -e "${RED}✖ 无法获取远程版本信息，请检查网络连接${NC}"
        return 1
    fi
    
    # 验证版本号格式
    if ! [[ "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "版本检查失败：无效的远程版本号 '$remote_version'"
        echo -e "${RED}✖ 远程版本号格式错误${NC}"
        return 1
    fi

    # 版本比较
    version_compare "$CURRENT_VERSION" "$remote_version"
    case $? in
        0)
            echo -e "${GREEN}✓ 当前已是最新版本 v${CURRENT_VERSION}${NC}"
            return 1
            ;;
        1)
            echo -e "${YELLOW}⚠ 本地版本 v${CURRENT_VERSION} 比远程版本 v${remote_version} 更高${NC}"
            return 1
            ;;
        2)
            echo -e "${YELLOW}▶ 发现新版本 v${remote_version}${NC}"
            return 0
            ;;
    esac
}

perform_update() {
    echo -e "${BLUE}▶ 开始更新...${NC}"
    log "尝试从 $UPDATE_URL 下载更新"
    
    # 下载临时文件
    if ! curl -fsSL "$UPDATE_URL" -o "$0.tmp"; then
        rm -f "$0.tmp"
        log "更新失败：下载脚本失败"
        echo -e "${RED}✖ 下载更新失败，请检查网络${NC}"
        return 1
    fi
    
    # 验证下载内容
    if ! grep -q "CURRENT_VERSION" "$0.tmp"; then
        log "更新失败：下载文件无效"
        echo -e "${RED}✖ 下载文件校验失败${NC}"
        rm -f "$0.tmp"
        return 1
    fi
    
    # 替换脚本
    chmod +x "$0.tmp"
    mv -f "$0.tmp" "$0"
    log "更新完成，重启脚本"
    
    echo -e "${GREEN}✓ 更新成功，重新启动脚本...${NC}"
    # 传递参数跳过更新检查。以 bash realm.sh 启动时 $0 不含路径，
    # 直接 exec "$0" 会去 PATH 中查找而失败，因此显式交给 bash 运行。
    exec bash "$0" "--no-update" "$@"
}

# ========================================
# 配置修改辅助
# ========================================
valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# 本地端口是否已被现有规则占用（不区分监听地址，同端口的不同地址也会冲突）
port_in_use() {
    local port
    [[ -f "$CONFIG_FILE" ]] || return 1
    while read -r port; do
        [[ -n "$port" ]] && (( 10#$port == 10#$1 )) && return 0
    done < <(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*"[^"]*:\([0-9][0-9]*\)".*/\1/p' "$CONFIG_FILE")
    return 1
}

# 修改配置前记录服务状态并备份配置，供 apply_config_change 回滚
begin_config_change() {
    CONFIG_WAS_ACTIVE=false
    systemctl is-active --quiet realm.service && CONFIG_WAS_ACTIVE=true
    if [[ -f "$CONFIG_FILE" ]]; then
        cp -p "$CONFIG_FILE" "$CONFIG_FILE.bak" || return 1
    else
        rm -f "$CONFIG_FILE.bak"
    fi
}

# 重启服务使配置生效；原本运行中的服务因新配置启动失败时，恢复修改前的配置
apply_config_change() {
    if [[ ! -x "$REALM_DIR/realm" ]]; then
        echo -e "${YELLOW}⚠ 尚未安装 Realm，配置已保存，安装后启动服务即可生效${NC}"
        return 0
    fi
    service_control restart
    if systemctl is-active --quiet realm.service; then
        return 0
    fi
    if $CONFIG_WAS_ACTIVE && [[ -f "$CONFIG_FILE.bak" ]]; then
        cp -p "$CONFIG_FILE.bak" "$CONFIG_FILE"
        systemctl restart realm.service
        log "新配置导致服务启动失败，已恢复修改前的配置"
        echo -e "${RED}✖ 新配置导致服务启动失败，已恢复修改前的配置并重启服务${NC}"
    else
        log "配置已保存，但服务未能启动"
        echo -e "${YELLOW}⚠ 配置已保存，但服务未能启动，请检查 $CONFIG_FILE${NC}"
    fi
    return 1
}

# ========================================
# 核心功能模块
# ========================================
write_service_file() {
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
}

deploy_realm() (
    log "开始安装Realm"
    echo -e "${BLUE}▶ 正在安装Realm...${NC}"
    mkdir -p "$REALM_DIR" || return 1

    # musl 静态构建不依赖宿主 GLIBC，避免 Debian 12 上 GLIBC_2.38 缺失。
    local arch stage
    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *)
            echo -e "${RED}✖ 暂不支持此架构: $(uname -m)${NC}"
            return 1
            ;;
    esac

    echo -e "${BLUE}▶ 正在检测最新版本...${NC}"
    LATEST_VERSION=$(curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/zhboner/realm/releases/latest" | sed -n 's/.*"tag_name": *"v\([0-9][0-9.]*\)".*/\1/p' | head -n1)
    if [[ ! "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        LATEST_VERSION="2.9.6"
        log "版本检测失败，使用已确认提供 musl 构建的备用版本 $LATEST_VERSION"
        echo -e "${YELLOW}⚠ 无法获取最新版本，使用备用版本 v${LATEST_VERSION}${NC}"
    fi

    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/v${LATEST_VERSION}/realm-${arch}-unknown-linux-musl.tar.gz"
    stage=$(mktemp -d "$REALM_DIR/.install.XXXXXX") || return 1
    trap 'rm -rf "$stage"' EXIT
    echo -e "${BLUE}▶ 正在下载 Realm v${LATEST_VERSION} ($arch, musl)...${NC}"
    if ! curl -fL --connect-timeout 10 --max-time 300 --retry 3 "$DOWNLOAD_URL" -o "$stage/realm.tar.gz"; then
        log "安装失败：下载错误 $DOWNLOAD_URL"
        echo -e "${RED}✖ 下载失败，现有程序和配置未修改: $DOWNLOAD_URL${NC}"
        return 1
    fi

    # 在临时目录中解压并实际运行，验证兼容性后才替换现有程序。
    if ! tar -xzf "$stage/realm.tar.gz" -C "$stage" ||
       ! chmod +x "$stage/realm" ||
       ! "$stage/realm" --version; then
        log "安装失败：解压或程序运行验证失败"
        echo -e "${RED}✖ 程序验证失败，现有程序和配置未修改${NC}"
        return 1
    fi
    if [[ -f "$REALM_DIR/realm" ]]; then
        cp -p "$REALM_DIR/realm" "$REALM_DIR/realm.bak" || return 1
    fi
    # 同一文件系统内重命名，允许替换仍在运行的旧程序。
    mv -f "$stage/realm" "$REALM_DIR/realm" || return 1

    if [[ ! -f "$CONFIG_FILE" ]]; then
        printf '[network]\nno_tcp = false\nuse_udp = true\n' > "$CONFIG_FILE" || return 1
    fi

    write_service_file || return 1
    systemctl daemon-reload || return 1
    log "安装成功：Realm v$LATEST_VERSION ($arch, musl)"
    echo -e "${GREEN}✔ 安装完成！请选择启动/重启服务以使用新程序。${NC}"
)

# 查看转发规则
show_rules() {
  echo -e "                   ${YELLOW}当前 Realm 转发规则${NC}                   "
  echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}${YELLOW}"
  printf "%-5s| %-30s| %-40s| %-20s\n" "序号" "   本地地址:端口 " "   目标地址:端口 " "备注"
  echo -e "${NC}${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
    local IFS=$'\n' # 设置IFS仅以换行符作为分隔符
    # 搜索所有包含 listen 的行，表示转发规则的起始行
    local lines=($(grep -n 'listen =' "$CONFIG_FILE" 2>/dev/null))
    
    if [ ${#lines[@]} -eq 0 ]; then
  echo -e "没有发现任何转发规则。"
        return
    fi

    local index=1
    for line in "${lines[@]}"; do
        local line_number=$(echo $line | cut -d ':' -f 1)
        local listen_info=$(sed -n "${line_number}p" "$CONFIG_FILE" | cut -d '"' -f 2)
        local remote_info=$(sed -n "$((line_number + 1))p" "$CONFIG_FILE" | cut -d '"' -f 2)
        local remark=$(sed -n "$((line_number-1))p" "$CONFIG_FILE" | grep "^# 备注:" | cut -d ':' -f 2)
        
        local listen_ip_port=$listen_info
        local remote_ip_port=$remote_info
        
    printf "%-4s| %-24s| %-34s| %-20s\n" " $index" "$listen_info" "$remote_info" "$remark"
    echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
        let index+=1
    done
}

# 添加转发规则
add_rule() {
    log "添加转发规则"
    while : ; do
        echo -e "\n${BLUE}▶ 添加新规则（输入 q 退出）${NC}"
        
        # 获取输入
        read -rp "本地监听端口: " local_port || break
        [ "$local_port" = "q" ] && break
        read -rp "目标服务器IP: " remote_ip
        read -rp "目标端口: " remote_port
        read -rp "规则备注: " remark

        # 输入验证
        if ! valid_port "$local_port" || ! valid_port "$remote_port"; then
            echo -e "${RED}✖ 端口必须为 1-65535 之间的数字！${NC}"
            continue
        fi
        local_port=$((10#$local_port))
        remote_port=$((10#$remote_port))

        # 目标地址：域名/IPv4，或 IPv6（自动加方括号，否则 Realm 无法区分地址和端口）
        local bracketed_v6='^\[[0-9A-Fa-f:.]+\]$' bare_v6='^[0-9A-Fa-f:.]+$' hostname='^[A-Za-z0-9._-]+$'
        if [[ "$remote_ip" =~ $bracketed_v6 ]]; then
            :
        elif [[ "$remote_ip" =~ $bare_v6 && "$remote_ip" == *:*:* ]]; then
            remote_ip="[$remote_ip]"
        elif ! [[ "$remote_ip" =~ $hostname ]]; then
            echo -e "${RED}✖ 目标地址无效！请输入域名、IPv4 或 IPv6 地址（不含端口）${NC}"
            continue
        fi

        # 监听模式选择
        echo -e "\n${YELLOW}请选择监听模式：${NC}"
        echo "1) 双栈监听 [::]:${local_port} (默认)"
        echo "2) 仅IPv4监听 0.0.0.0:${local_port}"
        echo "3) 自定义监听地址"
        read -rp "请输入选项 [1-3] (默认1): " ip_choice
        ip_choice=${ip_choice:-1}

        case $ip_choice in
            1)
                listen_addr="[::]:$local_port"
                desc="双栈监听"
                ;;
            2)
                listen_addr="0.0.0.0:$local_port"
                desc="仅IPv4"
                ;;
            3)
                while : ; do
                    read -rp "请输入完整监听地址(格式如 0.0.0.0:80 或 [::]:443): " listen_addr
                    # 格式验证
                    if ! [[ "$listen_addr" =~ ^([0-9a-fA-F.:]+|\[.*\]):[0-9]+$ ]] || ! valid_port "${listen_addr##*:}"; then
                        echo -e "${RED}✖ 格式错误！示例: 0.0.0.0:80 或 [::]:443${NC}"
                        continue
                    fi
                    break
                done
                desc="自定义监听"
                ;;
            *)
                echo -e "${RED}无效选择，使用默认值！${NC}"
                listen_addr="[::]:$local_port"
                desc="双栈监听"
                ;;
        esac

        # 同一端口重复监听会导致 Realm 整体无法启动
        if port_in_use "${listen_addr##*:}"; then
            echo -e "${RED}✖ 本地端口 ${listen_addr##*:} 已被现有规则使用，请换一个端口或先删除旧规则${NC}"
            continue
        fi

        begin_config_change || {
            echo -e "${RED}✖ 无法备份配置文件，未做修改${NC}"
            continue
        }

        # 写入配置文件
        tee -a "$CONFIG_FILE" > /dev/null <<EOF

[[endpoints]]
# 备注: $remark
listen = "$listen_addr"
remote = "$remote_ip:$remote_port"
EOF

        # 双栈提示
        if [[ "$listen_addr" == "[::]:"* ]]; then
            echo -e "\n${CYAN}ℹ 双栈监听需要确保：${NC}"
            echo -e "${CYAN}   - Realm 配置中 [network] 段的 ipv6_only = false${NC}"
            echo -e "${CYAN}   - 系统已启用 IPv6 双栈支持 (sysctl net.ipv6.bindv6only=0)${NC}"
        fi

        # 重启服务，失败时回滚
        if apply_config_change; then
            log "规则已添加: $listen_addr → $remote_ip:$remote_port"
            echo -e "${GREEN}✔ 添加成功！${NC}"
        else
            log "规则添加后服务未能启动: $listen_addr → $remote_ip:$remote_port"
        fi
        
        read -rp "继续添加？(y/n): " cont
        [[ "$cont" != "y" ]] && break
    done
}

delete_rule() {
  echo -e "                   ${YELLOW}当前 Realm 转发规则${NC}                   "
  echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}${YELLOW}"
  printf "%-5s| %-30s| %-40s| %-20s\n" "序号" "   本地地址:端口 " "   目标地址:端口 " "备注"
  echo -e "${NC}${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
    local IFS=$'\n' # 设置IFS仅以换行符作为分隔符
    # 搜索所有包含 [[endpoints]] 的行，表示转发规则的起始行
    local lines=($(grep -n '^\[\[endpoints\]\]' "$CONFIG_FILE" 2>/dev/null))
    
    if [ ${#lines[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return
    fi

    local index=1
    for line in "${lines[@]}"; do
        local line_number=$(echo $line | cut -d ':' -f 1)
        local remark_line=$((line_number + 1))
        local listen_line=$((line_number + 2))
        local remote_line=$((line_number + 3))

        local remark=$(sed -n "${remark_line}p" "$CONFIG_FILE" | grep "^# 备注:" | cut -d ':' -f 2)
        local listen_info=$(sed -n "${listen_line}p" "$CONFIG_FILE" | cut -d '"' -f 2)
        local remote_info=$(sed -n "${remote_line}p" "$CONFIG_FILE" | cut -d '"' -f 2)

        local listen_ip_port=$listen_info
        local remote_ip_port=$remote_info

    printf "%-4s| %-24s| %-34s| %-20s\n" " $index" "$listen_info" "$remote_info" "$remark"
    echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
        let index+=1
    done


    echo "请输入要删除的转发规则序号，直接按回车返回主菜单。"
    read -rp "选择: " choice
    if [ -z "$choice" ]; then
        echo "返回主菜单。"
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入数字。"
        return
    fi

    if [ $choice -lt 1 ] || [ $choice -gt ${#lines[@]} ]; then
        echo "选择超出范围，请输入有效序号。"
        return
  fi

  local chosen_line=${lines[$((choice-1))]}
  local start_line=$(echo $chosen_line | cut -d ':' -f 1)

  # 找到下一个 [[endpoints]] 行，确定删除范围的结束行
  local next_endpoints_line=$(grep -n '^\[\[endpoints\]\]' "$CONFIG_FILE" | grep -A 1 "^$start_line:" | tail -n 1 | cut -d ':' -f 1)

  if [ -z "$next_endpoints_line" ] || [ "$next_endpoints_line" -le "$start_line" ]; then
    # 如果没有找到下一个 [[endpoints]]，则删除到文件末尾
    end_line=$(wc -l < "$CONFIG_FILE")
  else
    # 如果找到了下一个 [[endpoints]]，则删除到它的前一行
    end_line=$((next_endpoints_line - 1))
  fi

  begin_config_change || {
    echo -e "${RED}✖ 无法备份配置文件，未做修改${NC}"
    return 1
  }

  # 删除指定行范围及多余空行；写回原文件以保留其权限
  local tmp
  tmp=$(mktemp "$CONFIG_FILE.XXXXXX") || return 1
  if ! sed -e "${start_line},${end_line}d" -e '/^[[:space:]]*$/d' "$CONFIG_FILE" > "$tmp" ||
     ! cat "$tmp" > "$CONFIG_FILE"; then
    rm -f "$tmp"
    echo -e "${RED}✖ 写入配置文件失败${NC}"
    return 1
  fi
  rm -f "$tmp"

  echo "转发规则及其备注已删除。"

  # 重启服务，失败时回滚
  apply_config_change
}

service_control() {
    case $1 in
        start|restart)
            if [[ ! -x "$REALM_DIR/realm" || ! -f "$CONFIG_FILE" ]]; then
                echo -e "${RED}✖ 未找到 Realm 程序或配置，请先选择菜单 1 安装/更新 Realm${NC}"
                log "启动失败：Realm 程序或配置不存在"
                return 1
            fi
            if ! systemctl unmask realm.service; then
                echo -e "${RED}✖ 无法解除服务屏蔽，请检查 systemd 状态${NC}"
                return 1
            fi
            if [[ ! -f "$SERVICE_FILE" ]]; then
                echo -e "${YELLOW}▶ 服务文件不存在，正在重建...${NC}"
                if ! write_service_file; then
                    echo -e "${RED}✖ 无法创建服务文件 $SERVICE_FILE${NC}"
                    return 1
                fi
            fi
            if ! systemctl daemon-reload; then
                echo -e "${RED}✖ 无法重新加载 systemd 服务${NC}"
                return 1
            fi

            # 新服务或已被 systemd 回收的服务可能尚未加载；这时没有失败状态需要重置。
            # 即使重置失败，也继续尝试启动，让 systemd 给出实际启动错误。
            if ! systemctl reset-failed realm.service 2>/dev/null; then
                log "无法重置服务失败状态，继续尝试启动"
            fi
            if ! systemctl restart realm.service || ! systemctl is-active --quiet realm.service; then
                log "服务启动失败"
                echo -e "${RED}✖ 服务启动失败，请运行 journalctl -u realm.service -n 60 --no-pager 查看原因${NC}"
                return 1
            fi
            if ! systemctl enable realm.service; then
                log "服务已启动，但设置开机启动失败"
                echo -e "${YELLOW}⚠ 服务已启动，但设置开机启动失败${NC}"
                return 1
            fi
            log "启动/重启服务"
            echo -e "${GREEN}✔ 服务已启动${NC}"
            ;;
        stop)
            systemctl stop realm || return 1
            log "停止服务"
            echo -e "${YELLOW}⚠ 服务已停止${NC}"
            ;;
        status)
            if systemctl is-active --quiet realm; then
                echo -e "${GREEN}● 服务运行中${NC}"
            else
                echo -e "${RED}● 服务未运行${NC}"
            fi
            ;;
    esac
}

# 只删除本脚本写入的定时任务，保留其他内容和文件权限
remove_cron_jobs() {
    [[ -f "$CRON_FILE" ]] || return 0
    local tmp rc
    tmp=$(mktemp) || return 1
    grep -Ev "$CRON_PATTERN" "$CRON_FILE" > "$tmp"
    rc=$?
    # grep 返回 1 只表示没有剩余行；大于 1 是读取错误，不能用空结果覆盖原文件
    if (( rc > 1 )) || ! cat "$tmp" > "$CRON_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

manage_cron() {
    echo -e "\n${YELLOW}定时任务管理：${NC}"
    echo "1. 添加每日重启任务"
    echo "2. 删除所有任务"
    echo "3. 查看当前任务"
    read -rp "请选择: " choice

    case $choice in
        1)
            read -rp "输入每日重启时间 (0-23): " hour
            if [[ "$hour" =~ ^[0-9]+$ ]] && (( 10#$hour >= 0 && 10#$hour <= 23 )); then
                hour=$((10#$hour))
                if grep -Eq "^0 $hour \* \* \* $CRON_PATTERN" "$CRON_FILE" 2>/dev/null; then
                    echo -e "${YELLOW}⚠ 每日 $hour 时重启的任务已存在${NC}"
                elif echo "0 $hour * * * root /usr/bin/systemctl restart realm $CRON_MARK" >>"$CRON_FILE"; then
                    log "添加定时任务：每日 $hour 时重启"
                    echo -e "${GREEN}✔ 定时任务已添加！${NC}"
                else
                    echo -e "${RED}✖ 无法写入 $CRON_FILE${NC}"
                fi
            else
                echo -e "${RED}✖ 无效时间！${NC}"
            fi
            ;;
        2)
            if remove_cron_jobs; then
                log "清除定时任务"
                echo -e "${YELLOW}✔ 定时任务已清除！${NC}"
            else
                echo -e "${RED}✖ 清除定时任务失败${NC}"
            fi
            ;;
        3)
            echo -e "\n${BLUE}当前定时任务：${NC}"
            grep -E "$CRON_PATTERN" "$CRON_FILE" 2>/dev/null || echo "暂无定时任务"
            ;;
        *)
            echo -e "${RED}✖ 无效选择！${NC}"
            ;;
    esac
}

uninstall() {
    log "开始卸载"
    echo -e "${YELLOW}▶ 正在卸载...${NC}"
    
    systemctl stop realm
    systemctl disable realm
    rm -rf "$REALM_DIR"
    rm -f "$SERVICE_FILE"
    remove_cron_jobs
    systemctl daemon-reload
    # 删除脚本自身，而不是当前目录下恰好叫 realm.sh 的文件
    if [[ -f "${BASH_SOURCE[0]}" ]]; then
        rm -f -- "${BASH_SOURCE[0]}"
    fi
    
    log "卸载完成"
    echo -e "${GREEN}✔ 已完全卸载！${NC}"
}

# ========================================
# 安装状态检测
# ========================================
check_installed() {
    if [[ -f "$REALM_DIR/realm" && -f "$SERVICE_FILE" ]]; then
        echo -e "${GREEN}已安装${NC}"
    else
        echo -e "${RED}未安装${NC}"
    fi
}

# ========================================
# 主界面
# ========================================
main_menu() {
    clear
    init_check

    # 处理跳过更新检查参数
    local skip_update=false
    if [[ "$1" == "--no-update" ]]; then
        skip_update=true
        shift
    fi

    # 首次运行检查更新
    if ! $skip_update; then
        check_update && perform_update "$@"
    fi

    while true; do
        echo -e "${YELLOW}▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂${NC}"
        echo -e "  "
        echo -e "                ${BLUE}Realm 高级管理脚本 v$CURRENT_VERSION"
        echo -e "        修改by：Ami    修改日期：2025/4/1"
        echo -e "        修改内容:1.基本重做了脚本"
        echo -e "                 2.新增了自动更新脚本"
        echo -e "                 3.realm支持检测最新版本"
        echo -e "    (1)安装前请先更新系统软件包，缺少命令可能无法安装"
        echo -e "    (2)如果启动失败请检查 /root/realm/config.toml下有无多余配置或者卸载后重新配置"
        echo -e "    (3)该脚本只在debian系统下测试，未做其他系统适配，安装命令有别，可能无法启动。如若遇到问题，请自行解决"
        echo -e "    仓库：https://github.com/misakaok/EZrealm${NC}"
        echo -e "${YELLOW}▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂${NC}"
        echo -e "  "
        echo -e "${YELLOW}服务状态：$(service_control status)${NC}"
        echo -e "${YELLOW}安装状态：$(check_installed)${NC}"
        echo -e "  "
        echo -e "${YELLOW}------------------${NC}"
        echo "1. 安装/更新 Realm"
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
        echo "10. 完全卸载"
        echo -e "${YELLOW}------------------${NC}"
        echo "0. 退出脚本"
        echo -e "${YELLOW}------------------${NC}"

        read -rp "请输入选项: " choice
        case $choice in
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
                tail -n 10 "$LOG_FILE" 
                ;;
            10) 
                read -rp "确认完全卸载？(y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    uninstall
                    read -rp "按回车键继续..."
                    clear
                    exit 0
                fi
                ;;
            0) exit 0 
            ;;
            *) echo -e "${RED}无效选项！${NC}" ;;
        esac
        read -rp "按回车键继续..."
        clear
    done
}

# ========================================
# 脚本入口
# ========================================
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_menu "$@"
fi
