#!/bin/bash

# =========================================================
# VPS SSH 密钥与登录自动化管理脚本
# =========================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ======================== 系统检测模块 ========================
# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：此脚本需要 root 权限运行。请使用 sudo ./vps_manager.sh 执行。${NC}"
        exit 1
    fi
}

# 自动检测操作系统以决定重启 SSH 服务的命令
detect_os_and_restart_ssh() {
    echo -e "${YELLOW}正在应用配置并重启 SSH 服务...${NC}"
    if grep -q -i "alpine" /etc/os-release 2>/dev/null; then
        rc-service sshd restart
    elif systemctl >/dev/null 2>&1; then
        systemctl restart sshd || systemctl restart ssh
    else
        service sshd restart || service ssh restart
    fi
    echo -e "${GREEN}SSH 服务已成功重启！${NC}"
}

# ======================== 辅助功能模块 ========================
# 初始化 SSH 目录权限
setup_ssh_dir() {
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
}

# 安全修改 sshd_config 配置项
set_sshd_config() {
    local key=$1
    local value=$2
    local config_file="/etc/ssh/sshd_config"
    
    # 如果存在被注释的或已有的配置项，则替换；否则在文件末尾追加
    if grep -E -q "^#?${key}\s+" "$config_file"; then
        sed -i -E "s/^#?${key}\s+.*/${key} ${value}/" "$config_file"
    else
        echo "${key} ${value}" >> "$config_file"
    fi
}

# ======================== 核心功能模块 ========================

# 1. 一键生成并部署 SSH 密钥
generate_and_deploy_key() {
    echo -e "\n${YELLOW}--- 生成与部署 SSH 密钥 ---${NC}"
    
    # 获取 VPS 名称
    read -p "请输入 VPS 名称 (用于生成文件名，默认 vps1): " vps_name
    vps_name=${vps_name:-vps1}

    # 选择密钥类型
    echo "请选择密钥类型："
    echo "1) ED25519 (默认，推荐，更安全高效)"
    echo "2) RSA 2048"
    read -p "请输入序号 [1/2]: " type_choice
    
    if [[ "$type_choice" == "2" ]]; then
        key_type="rsa"
        key_args="-t rsa -b 2048"
    else
        key_type="ed25519"
        key_args="-t ed25519"
    fi

    # 设置密码策略
    read -p "请输入密钥密码 (直接回车默认使用 '123'，输入 'none' 为无密码): " key_pass_input
    if [[ -z "$key_pass_input" ]]; then
        key_pass="123"
        pass_label="123"
    elif [[ "$key_pass_input" == "none" ]]; then
        key_pass=""
        pass_label="nopass"
    else
        key_pass="$key_pass_input"
        pass_label="$key_pass_input"
    fi

    # 组合文件名：vps名称_密钥类型_密码标签
    filename="${vps_name}_${key_type}_${pass_label}"

    if [[ -f "$filename" ]]; then
        echo -e "${RED}错误：当前目录下已存在同名密钥文件 ($filename)，请先删除或重命名。${NC}"
        return
    fi

    # 生成密钥
    echo -e "${YELLOW}正在生成密钥对...${NC}"
    ssh-keygen $key_args -N "$key_pass" -f "$filename" -C "$filename" >/dev/null 2>&1

    # 部署公钥
    if [[ -f "${filename}.pub" ]]; then
        setup_ssh_dir
        cat "${filename}.pub" >> ~/.ssh/authorized_keys
        echo -e "${GREEN}成功：密钥对已生成并保存在当前目录！${NC}"
        echo -e "私钥文件：${GREEN}${filename}${NC} (请妥善下载并保管)"
        echo -e "公钥文件：${GREEN}${filename}.pub${NC}"
        echo -e "${GREEN}状态：已成功一键部署到 ~/.ssh/authorized_keys${NC}"
    else
        echo -e "${RED}错误：密钥生成失败！${NC}"
    fi
}

# 2. 删除已有密钥并从 authorized_keys 移除
delete_key() {
    echo -e "\n${YELLOW}--- 删除已有密钥 ---${NC}"
    
    # 查找当前目录下的所有公钥文件
    shopt -s nullglob
    pub_keys=(*.pub)
    shopt -u nullglob

    if [[ ${#pub_keys[@]} -eq 0 ]]; then
        echo -e "${RED}当前目录下未找到任何密钥 (.pub) 文件。${NC}"
        return
    fi

    # 列表展示
    for i in "${!pub_keys[@]}"; do
        echo "[$i] ${pub_keys[$i]%.pub}"
    done

    read -p "请输入要彻底删除的密钥编号 (按 Ctrl+C 取消): " del_idx
    if [[ -n "${pub_keys[$del_idx]}" ]]; then
        base_name="${pub_keys[$del_idx]%.pub}"
        
        # 提取公钥主体(Base64部分)，用于在 authorized_keys 中精准匹配并删除
        key_body=$(awk '{print $2}' "${base_name}.pub")
        
        if [[ -n "$key_body" ]]; then
            setup_ssh_dir
            # 使用 grep -v 过滤掉包含该公钥主体的行
            grep -v "$key_body" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp
            mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys
            chmod 600 ~/.ssh/authorized_keys
        fi
        
        # 删除本地文件
        rm -f "$base_name" "${base_name}.pub"
        echo -e "${GREEN}成功：密钥 $base_name 已从本地删除，并已从 authorized_keys 中注销！${NC}"
    else
        echo -e "${RED}输入无效，取消操作。${NC}"
    fi
}

# 3. 修改密钥密码并同步文件与配置
change_key_password() {
    echo -e "\n${YELLOW}--- 修改密钥密码 ---${NC}"
    
    shopt -s nullglob
    pub_keys=(*.pub)
    shopt -u nullglob

    if [[ ${#pub_keys[@]} -eq 0 ]]; then
        echo -e "${RED}当前目录下未找到任何密钥文件。${NC}"
        return
    fi

    for i in "${!pub_keys[@]}"; do
        echo "[$i] ${pub_keys[$i]%.pub}"
    done

    read -p "请输入要修改密码的密钥编号: " mod_idx
    if [[ -z "${pub_keys[$mod_idx]}" ]]; then
        echo -e "${RED}输入无效。${NC}"
        return
    fi
    
    old_base="${pub_keys[$mod_idx]%.pub}"
    read -p "请输入旧密码 (无密码直接回车): " old_pass
    read -p "请输入新密码 (无密码直接回车): " new_pass
    
    # 尝试修改私钥密码
    echo -e "${YELLOW}正在修改私钥加密密码...${NC}"
    if ssh-keygen -p -P "$old_pass" -N "$new_pass" -f "$old_base" >/dev/null 2>&1; then
        new_pass_label=${new_pass:-nopass}
        # 解析旧文件名，截取最后一部分下划线前的内容，拼接新密码标签
        # 例如 vps1_ed25519_123 -> vps1_ed25519_newpass
        prefix="${old_base%_*}" 
        new_base="${prefix}_${new_pass_label}"
        
        if [[ "$old_base" != "$new_base" ]]; then
            # 重命名文件
            mv "$old_base" "$new_base"
            
            # 更新公钥文件中的注释，并重命名公钥文件
            old_pub_core=$(awk '{print $1" "$2}' "${old_base}.pub")
            echo "$old_pub_core $new_base" > "${new_base}.pub"
            rm -f "${old_base}.pub"
            
            # 同步更新 authorized_keys
            setup_ssh_dir
            key_body=$(echo "$old_pub_core" | awk '{print $2}')
            grep -v "$key_body" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp
            cat "${new_base}.pub" >> ~/.ssh/authorized_keys.tmp
            mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys
            chmod 600 ~/.ssh/authorized_keys
        fi
        echo -e "${GREEN}成功：密码修改完毕！文件名与部署信息已同步更新为 $new_base${NC}"
    else
        echo -e "${RED}错误：密码修改失败！请检查旧密码是否输入正确。${NC}"
    fi
}

# 4. 查看当前目录下已有密钥列表及其部署状态
list_keys() {
    echo -e "\n${YELLOW}--- 本地密钥与部署状态列表 ---${NC}"
    shopt -s nullglob
    pub_keys=(*.pub)
    shopt -u nullglob

    if [[ ${#pub_keys[@]} -eq 0 ]]; then
        echo "当前目录为空，暂无管理的密钥。"
        return
    fi

    for pubkey in "${pub_keys[@]}"; do
        base="${pubkey%.pub}"
        if [[ -f "$base" ]]; then
            echo -e "密钥名称: ${GREEN}$base${NC}"
            
            # 检查 authorized_keys 中是否存在该公钥主体
            key_body=$(awk '{print $2}' "$pubkey")
            if [[ -f ~/.ssh/authorized_keys ]] && grep -q "$key_body" ~/.ssh/authorized_keys; then
                echo -e "  => 状态: ${GREEN}[已部署在 VPS 中]${NC}"
            else
                echo -e "  => 状态: ${RED}[未部署]${NC}"
            fi
        fi
    done
}

# 5. 修改 SSH 守护进程配置
modify_ssh_config() {
    echo -e "\n${YELLOW}--- SSH 登录配置管理 ---${NC}"
    echo "1) 开启/关闭 密码登录"
    echo "2) 修改 SSH 登录端口"
    read -p "请选择操作 [1/2]: " ssh_choice
    
    if [[ "$ssh_choice" == "1" ]]; then
        read -p "是否允许使用密码登录 VPS (强烈建议使用密钥并在测试无误后关闭)? [y/N]: " allow_pass
        if [[ "${allow_pass,,}" == "y" ]]; then
            set_sshd_config "PasswordAuthentication" "yes"
            echo -e "${GREEN}已配置：开启密码登录。${NC}"
        else
            set_sshd_config "PasswordAuthentication" "no"
            echo -e "${GREEN}已配置：关闭密码登录 (仅限密钥登录)。${NC}"
        fi
        detect_os_and_restart_ssh

    elif [[ "$ssh_choice" == "2" ]]; then
        read -p "请输入新的 SSH 端口 (1-65535，默认22): " new_port
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
            set_sshd_config "Port" "$new_port"
            echo -e "${GREEN}已配置：SSH 端口修改为 $new_port。${NC}"
            echo -e "${YELLOW}提示：请确保您的防火墙(UFW/iptables/安全组)已放行端口 $new_port！${NC}"
            detect_os_and_restart_ssh
        else
            echo -e "${RED}错误：端口号无效！${NC}"
        fi
    else
        echo -e "${RED}无效选择。${NC}"
    fi
}

# 6. 修改 VPS 用户登录密码
change_user_password() {
    echo -e "\n${YELLOW}--- 修改系统用户密码 ---${NC}"
    read -p "请输入要修改密码的用户名 (直接回车默认修改 root 密码): " uname
    uname=${uname:-root}
    
    if id "$uname" &>/dev/null; then
        echo "正在修改用户 $uname 的密码："
        passwd "$uname"
        if [ $? -eq 0 ]; then
             echo -e "${GREEN}成功：用户 $uname 密码已更新！${NC}"
        else
             echo -e "${RED}错误：密码修改被取消或失败。${NC}"
        fi
    else
        echo -e "${RED}错误：用户 $uname 不存在于此系统中！${NC}"
    fi
}

# ======================== 主程序入口 ========================

check_root

while true; do
    echo -e "\n=============================================="
    echo -e "       ${GREEN}VPS SSH 密钥与登录管理工具${NC}"
    echo -e "=============================================="
    echo "  1. 一键生成并部署 SSH 密钥"
    echo "  2. 删除已有密钥并从服务器注销"
    echo "  3. 修改本地密钥密码 (自动同步状态)"
    echo "  4. 查看当前拥有的密钥列表及状态"
    echo "  5. 修改 SSH 登录配置 (密码登录开关、端口)"
    echo "  6. 修改系统用户登录密码"
    echo "  7. 退出脚本"
    echo -e "=============================================="
    read -p "请输入对应的数字选项: " choice

    case $choice in
        1) generate_and_deploy_key ;;
        2) delete_key ;;
        3) change_key_password ;;
        4) list_keys ;;
        5) modify_ssh_config ;;
        6) change_user_password ;;
        7) 
            echo -e "${GREEN}感谢使用，再见！${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}输入无效，请重新选择 [1-7]。${NC}" 
            ;;
    esac
done