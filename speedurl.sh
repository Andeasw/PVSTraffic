#!/bin/bash
# ==================================================
# VPS Traffic Spirit
# Version: 0.0.1
# Author: Prince 2025.12
# ==================================================

# --- 基础路径配置 ---
BASE_DIR="/root/vps_traffic"
CONF_FILE="$BASE_DIR/config.conf"
STATS_FILE="$BASE_DIR/stats.conf"
LOG_DIR="$BASE_DIR/logs"
LOCK_FILE="$BASE_DIR/run.lock"
BG_PID_FILE="$BASE_DIR/bg_task.pid"
SCRIPT_PATH=$(readlink -f "$0")
CRON_MARK="# VPS_TRAFFIC_SPIRIT_PRINCE"

# --- 颜色定义 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

mkdir -p "$BASE_DIR" "$LOG_DIR"

# ======================
# 1. 默认配置 (Prince 定制版)
# ======================
# 周期策略: 28天跑36GB
PERIOD_DAYS=28
PERIOD_TARGET_GB=36
PERIOD_START_DATE="$(date +%F)"

# 每日策略: 1200MB, 跑120分钟, 最大12MB/s
DAILY_TARGET_MB=1200
DAILY_TIME_MIN=120
CRON_MAX_SPEED_MB=12

# 调度时间: 北京时间 03:20
BJ_CRON_HOUR=3
BJ_CRON_MIN=20

# 系统安全: 默认关闭上传，内存低位保护
ENABLE_UPLOAD=0
UPLOAD_RATIO=10
MEM_PROTECT_KB=262144

# 节点策略: 随机
NODE_STRATEGY=3
FIXED_REGION="nbg1"
ROUND_IDX=0

# ======================
# 2. 工具函数
# ======================
now_sec() { date +%s; }
mb_to_kb() { awk "BEGIN{printf \"%.0f\", $1 * 1024}"; }
kb_to_mb() { awk "BEGIN{printf \"%.2f\", $1 / 1024}"; }
kb_to_gb() { awk "BEGIN{printf \"%.2f\", $1 / 1024 / 1024}"; }

log() {
    local ts="$(date '+%F %T')"
    echo -e "[$ts] $*" >> "$LOG_DIR/traffic.log"
    # 非后台且非Cron模式下，输出到屏幕
    if [ "$IS_BACKGROUND" != "1" ] && [ "$IS_CRON" != "1" ]; then
        echo -e "[$ts] $*"
    fi
}

rotate_logs() { find "$LOG_DIR" -name "*.log" -mtime +5 -delete; }

check_resources() {
    local disk=$(df "$BASE_DIR" | awk 'NR==2 {print $4}')
    [ "$disk" -lt 102400 ] && { log "${RED}磁盘空间不足，停止运行。${PLAIN}"; exit 1; }
    
    if [ "$ENABLE_UPLOAD" = "1" ]; then
        local mem=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
        [ -z "$mem" ] && mem=$(free | awk '/Mem:/ {print $4+$6}')
        if [ "$mem" -lt "$MEM_PROTECT_KB" ]; then
            log "${YELLOW}内存紧张 ($mem KB)，自动关闭上传以防掉线。${PLAIN}"
            ENABLE_UPLOAD=0
        fi
    fi
}

# ======================
# 3. 核心测速功能 (新增)
# ======================
measure_max_speed() {
    echo -e "${YELLOW}正在测试网络极限带宽 (耗时约 10 秒)...${PLAIN}"
    # 使用 Hetzner 10GB 文件测速 10秒，获取平均下载速度
    # -w "%{speed_download}" 输出单位是 bytes/sec
    local speed_bps=$(curl -s -w "%{speed_download}" -o /dev/null --max-time 10 "https://nbg1-speed.hetzner.com/10GB.bin")
    
    # 转换为 MB/s
    local speed_mb=$(awk "BEGIN {printf \"%.2f\", $speed_bps / 1024 / 1024}")
    
    echo -e "${GREEN}>>> 测试完成!${PLAIN}"
    echo -e "当前网络最大平均速度: ${BOLD}${speed_mb} MB/s${PLAIN}"
    echo -e "建议设置的挂机限速:   ${BOLD}$(awk "BEGIN {printf \"%.0f\", $speed_mb * 0.8}") MB/s${PLAIN} (预留20%带宽)"
}

# ======================
# 4. 配置存取
# ======================
load_config() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
    [ -f "$STATS_FILE" ] && source "$STATS_FILE"
    TODAY_KB=${TODAY_KB:-0}
    PERIOD_KB=${PERIOD_KB:-0}
    TODAY_RUN_SEC=${TODAY_RUN_SEC:-0}
    
    # 强制默认值校验
    PERIOD_DAYS=${PERIOD_DAYS:-28}
    CRON_MAX_SPEED_MB=${CRON_MAX_SPEED_MB:-12}
}

save_config() {
cat >"$CONF_FILE"<<EOF
PERIOD_DAYS=$PERIOD_DAYS
PERIOD_TARGET_GB=$PERIOD_TARGET_GB
PERIOD_START_DATE="$PERIOD_START_DATE"
DAILY_TARGET_MB=$DAILY_TARGET_MB
DAILY_TIME_MIN=$DAILY_TIME_MIN
CRON_MAX_SPEED_MB=$CRON_MAX_SPEED_MB
BJ_CRON_HOUR=$BJ_CRON_HOUR
BJ_CRON_MIN=$BJ_CRON_MIN
ENABLE_UPLOAD=$ENABLE_UPLOAD
UPLOAD_RATIO=$UPLOAD_RATIO
NODE_STRATEGY=$NODE_STRATEGY
FIXED_REGION="$FIXED_REGION"
ROUND_IDX=$ROUND_IDX
EOF
}

save_stats() {
cat >"$STATS_FILE"<<EOF
TODAY_KB=$TODAY_KB
TODAY_RUN_SEC=$TODAY_RUN_SEC
PERIOD_KB=$PERIOD_KB
LAST_RUN_TIME="$(date '+%F %T')"
LAST_RUN_KB=$LAST_RUN_KB
EOF
}

# ======================
# 5. 流量执行引擎
# ======================
pick_region() {
    local list="nbg1 fsn1 hel1 ash hil sin"
    case "$NODE_STRATEGY" in
        1) echo "$FIXED_REGION" ;;
        2)
            local arr=($list)
            local r=${arr[$ROUND_IDX]}
            ROUND_IDX=$(( (ROUND_IDX + 1) % ${#arr[@]} ))
            save_config
            echo "$r"
            ;;
        *) echo "$list" | tr ' ' '\n' | shuf -n1 ;;
    esac
}

run_traffic_task() {
    local mode="$1"
    local target_type="$2" # TIME / DATA
    local target_val="$3"
    local max_speed_mb="$4"

    [ "$mode" == "BG" ] && IS_BACKGROUND=1 || IS_BACKGROUND=0
    [ "$mode" == "CRON" ] && IS_CRON=1 || IS_CRON=0
    
    check_resources
    rotate_logs

    # 计算基础速率
    local base_speed_kb=0
    local jitter_pct=$(( RANDOM % 40 + 80 )) # 速率波动 80%-120%

    if [ "$IS_CRON" == "1" ]; then
        # Cron 模式：智能计算温和速率
        local target_kb=$(mb_to_kb "$DAILY_TARGET_MB")
        local target_sec=$(( DAILY_TIME_MIN * 60 ))
        [ "$target_sec" -lt 1 ] && target_sec=1
        
        # 理论平均速度
        base_speed_kb=$(awk "BEGIN{printf \"%.0f\", $target_kb / $target_sec}")
        
        # 限制硬顶
        local cap_kb=$(mb_to_kb "$CRON_MAX_SPEED_MB")
        [ "$base_speed_kb" -gt "$cap_kb" ] && base_speed_kb=$cap_kb
        # 限制地板 (最小 1MB/s)
        [ "$base_speed_kb" -lt 1024 ] && base_speed_kb=1024
    else
        # 手动/后台模式：直接使用指定速度
        base_speed_kb=$(mb_to_kb "$max_speed_mb")
    fi

    # 应用随机抖动
    local run_speed_kb=$(awk "BEGIN{printf \"%.0f\", $base_speed_kb * $jitter_pct / 100}")
    
    # 准备连接
    local region=$(pick_region)
    local dl_url="https://$region-speed.hetzner.com/10GB.bin?r=$RANDOM"
    local up_url="https://$region-speed.hetzner.com/upload"
    
    local up_speed_kb=0
    if [ "$ENABLE_UPLOAD" == "1" ]; then
        up_speed_kb=$(awk "BEGIN{printf \"%.0f\", $run_speed_kb * $UPLOAD_RATIO / 100}")
        # 上传硬限制 5MB/s
        [ "$up_speed_kb" -gt 5120 ] && up_speed_kb=5120
    fi

    log "任务启动 [$mode]: 目标 ${target_type}=${target_val} | 限速 $(kb_to_mb $run_speed_kb)MB/s | 节点 $region"

    trap 'kill $PID_DL $PID_UP 2>/dev/null; rm -f "$BG_PID_FILE"; exit' EXIT INT TERM

    # 启动下载 (nice -n 10 低优先级)
    nice -n 10 curl -4 -sL --limit-rate "${run_speed_kb}k" --output /dev/null "$dl_url" &
    PID_DL=$!

    if [ "$up_speed_kb" -gt 0 ]; then
        nice -n 15 curl -4 -sL -X POST --limit-rate "${up_speed_kb}k" --data-binary @/dev/zero "$up_url" --output /dev/null &
        PID_UP=$!
    fi

    local start_ts=$(now_sec)
    local cycle_kb=0
    
    # 监控循环
    while true; do
        sleep 2
        local now=$(now_sec)
        local elapsed=$(( now - start_ts ))

        if ! kill -0 $PID_DL 2>/dev/null; then
            log "${RED}下载进程意外结束。${PLAIN}"
            break
        fi
        
        # 估算流量 (每2秒)
        local tick_kb=$(( (run_speed_kb + up_speed_kb) * 2 ))
        cycle_kb=$(( cycle_kb + tick_kb ))

        # 检查结束条件
        local is_done=0
        local percent=0
        
        if [ "$target_type" == "TIME" ]; then
            [ "$elapsed" -ge "$target_val" ] && is_done=1
            percent=$(( elapsed * 100 / target_val ))
        elif [ "$target_type" == "DATA" ]; then
            local target_kb=$(mb_to_kb "$target_val")
            [ "$cycle_kb" -ge "$target_kb" ] && is_done=1
            percent=$(( cycle_kb * 100 / target_kb ))
        fi
        [ "$percent" -gt 100 ] && percent=100

        # 前台显示进度
        if [ "$IS_BACKGROUND" != "1" ] && [ "$IS_CRON" != "1" ]; then
             local mb_run=$(kb_to_mb $cycle_kb)
             echo -ne "\r[Running] 进度: ${percent}% | 已跑: ${mb_run} MB | 时间: ${elapsed}s | 瞬时: ~$(kb_to_mb $run_speed_kb) MB/s  "
        fi

        if [ "$is_done" -eq 1 ]; then
            [ "$IS_BACKGROUND" != "1" ] && [ "$IS_CRON" != "1" ] && echo -e "\n${GREEN}目标达成，任务结束。${PLAIN}"
            break
        fi
    done

    # 结算
    kill $PID_DL $PID_UP 2>/dev/null
    wait $PID_DL $PID_UP 2>/dev/null
    trap - EXIT INT TERM
    
    TODAY_KB=$(( TODAY_KB + cycle_kb ))
    PERIOD_KB=$(( PERIOD_KB + cycle_kb ))
    TODAY_RUN_SEC=$(( TODAY_RUN_SEC + (now_sec - start_ts) ))
    LAST_RUN_KB=$cycle_kb
    
    save_stats
    log "任务完成: 产生流量 $(kb_to_mb $cycle_kb) MB"
    rm -f "$BG_PID_FILE"
}

# ======================
# 6. Cron 调度 (时区自适应)
# ======================
calc_cron_time() {
    local bj_h=$1
    local bj_m=$2
    # 获取本地时区偏移
    local tz_offset=$(date +%z) # 例如 +0800
    local svr_offset_h=$(echo ${tz_offset:0:3} | sed 's/^+//')
    
    # 算法: 本地时间 = 北京时间(UTC+8) - 8 + 本地偏移
    local svr_h=$(( bj_h - 8 + svr_offset_h ))
    
    # 循环修正 0-23
    while [ "$svr_h" -lt 0 ]; do svr_h=$(( svr_h + 24 )); done
    while [ "$svr_h" -ge 24 ]; do svr_h=$(( svr_h - 24 )); done
    
    echo "$svr_h $bj_m"
}

install_cron() {
    read -r s_h s_m <<< $(calc_cron_time $BJ_CRON_HOUR $BJ_CRON_MIN)
    
    crontab -l 2>/dev/null | grep -v "$CRON_MARK" > /tmp/cron.tmp
    echo "0 0 * * * $SCRIPT_PATH --daily-reset $CRON_MARK" >> /tmp/cron.tmp
    echo "$s_m $s_h * * * $SCRIPT_PATH --cron $CRON_MARK" >> /tmp/cron.tmp
    crontab /tmp/cron.tmp
    rm -f /tmp/cron.tmp
    
    echo -e "${GREEN}Cron 已更新！${PLAIN}"
    echo -e "设定触发 (北京时间): ${YELLOW}$BJ_CRON_HOUR:$BJ_CRON_MIN${PLAIN}"
    echo -e "实际触发 (本地时间): ${YELLOW}$s_h:$s_m${PLAIN}"
}

entry_cron() {
    # 随机延迟 0-10分钟
    local delay=$(( RANDOM % 600 ))
    sleep $delay
    
    exec 9>"$LOCK_FILE"; flock -n 9 || exit 0
    load_config
    
    # 检查配额
    if [ "$TODAY_KB" -ge $(mb_to_kb "$DAILY_TARGET_MB") ]; then
        exit 0
    fi
    
    # Cron 模式运行：类型=DATA, 值=每日目标MB, 速率=0(自动计算)
    run_traffic_task "CRON" "DATA" "$DAILY_TARGET_MB" "0"
}

entry_reset() {
    TODAY_KB=0
    TODAY_RUN_SEC=0
    save_stats
    log "每日统计重置完成"
}

# ======================
# 7. 菜单界面 (UI)
# ======================
run_bg_wrapper() {
    nohup "$SCRIPT_PATH" --bg-run "$1" "$2" >/dev/null 2>&1 &
    echo $! > "$BG_PID_FILE"
    echo -e "${GREEN}后台任务已启动! PID: $!${PLAIN}"
}

menu_settings() {
    while true; do
        echo -e "\n${BOLD}--- ⚙️ 参数设置 (By Prince) ---${PLAIN}"
        echo -e "1. 周期天数     : ${GREEN}$PERIOD_DAYS${PLAIN} 天"
        echo -e "2. 周期流量目标 : ${GREEN}$PERIOD_TARGET_GB${PLAIN} GB"
        echo -e "3. 每日流量目标 : ${GREEN}$DAILY_TARGET_MB${PLAIN} MB"
        echo -e "4. 每日运行时间 : ${GREEN}$DAILY_TIME_MIN${PLAIN} 分钟"
        echo -e "5. 挂机最大限速 : ${GREEN}$CRON_MAX_SPEED_MB${PLAIN} MB/s (Cron)"
        echo -e "6. 启动时间(BJ) : ${GREEN}$BJ_CRON_HOUR:$BJ_CRON_MIN${PLAIN}"
        echo -e "7. 上传开关     : $( [ $ENABLE_UPLOAD -eq 1 ] && echo "${RED}开启${PLAIN}" || echo "${GREEN}关闭${PLAIN}" )"
        echo -e "----------------------------------"
        echo -e "T. ⚡ 测试当前最大网速 (辅助设置)"
        echo -e "0. 保存并返回"
        echo -e "----------------------------------"
        read -p "请输入序号修改: " c
        case "$c" in
            1) read -p "输入周期天数: " v; [ -n "$v" ] && PERIOD_DAYS=$v ;;
            2) read -p "输入周期目标(GB): " v; [ -n "$v" ] && PERIOD_TARGET_GB=$v ;;
            3) read -p "输入每日目标(MB): " v; [ -n "$v" ] && DAILY_TARGET_MB=$v ;;
            4) read -p "输入每日时长(分): " v; [ -n "$v" ] && DAILY_TIME_MIN=$v ;;
            5) read -p "输入最大限速(MB/s): " v; [ -n "$v" ] && CRON_MAX_SPEED_MB=$v ;;
            6) 
               read -p "北京时间-小时 (0-23): " h; [ -n "$h" ] && BJ_CRON_HOUR=$h
               read -p "北京时间-分钟 (0-59): " m; [ -n "$m" ] && BJ_CRON_MIN=$m 
               ;;
            7) read -p "开启上传 (0=关, 1=开): " v; [ -n "$v" ] && ENABLE_UPLOAD=$v ;;
            t|T) measure_max_speed; read -p "按回车继续..." ;;
            0) break ;;
            *) ;;
        esac
    done
    save_config
    install_cron
    echo -e "${GREEN}配置已保存并更新 Cron 任务!${PLAIN}"
    sleep 1
}

show_dashboard() {
    clear
    load_config
    local bg_s="${RED}无${PLAIN}"
    if [ -f "$BG_PID_FILE" ] && kill -0 $(cat "$BG_PID_FILE") 2>/dev/null; then
        bg_s="${GREEN}运行中 (PID $(cat "$BG_PID_FILE"))${PLAIN}"
    fi
    
    echo -e "${BLUE}==============================================${PLAIN}"
    echo -e "    VPS Traffic Spirit v0.0.1 ${BOLD}(By Prince)${PLAIN}"
    echo -e "${BLUE}==============================================${PLAIN}"
    echo -e " [周期进度] $(kb_to_gb $PERIOD_KB) / $PERIOD_TARGET_GB GB (共 $PERIOD_DAYS 天)"
    echo -e " [今日进度] $(kb_to_mb $TODAY_KB) / $DAILY_TARGET_MB MB"
    echo -e " [Cron计划] 北京 ${YELLOW}$BJ_CRON_HOUR:$BJ_CRON_MIN${PLAIN} 启动 | 限速 $CRON_MAX_SPEED_MB MB/s"
    echo -e " [后台任务] $bg_s"
    echo -e "----------------------------------------------"
    echo -e " 1. 🚀 手动测速 / 定量运行"
    echo -e " 2. ⚙️  完整参数设置 (含自动测速)"
    echo -e " 3. 📄 查看运行日志"
    echo -e " 4. 🗑️  卸载脚本"
    echo -e " 0. 退出"
    echo -e "----------------------------------------------"
    echo -n " 请选择: "
}

# ======================
# 8. 入口路由
# ======================
case "$1" in
    --cron) entry_cron ;;
    --daily-reset) entry_reset ;;
    --bg-run) run_traffic_task "BG" "DATA" "$2" "$3" ;;
    *)
        while true; do
            show_dashboard
            read opt
            case "$opt" in
                1) 
                    echo -e "\n${BOLD}--- 🚀 手动模式 ---${PLAIN}"
                    echo "1. ⚡ 极限测速 (跑 10 秒看速度)"
                    echo "2. ⏳ 限时运行 (跑 X 秒)"
                    echo "3. 📦 定量运行-前台 (跑 X MB)"
                    echo "4. ☁️  定量运行-后台 (跑 X MB, 可关SSH)"
                    echo "5. 🛑 停止后台任务"
                    echo "0. 返回"
                    read -p "选择: " sc
                    case "$sc" in
                        1) measure_max_speed; read -p "..." ;;
                        2) 
                           read -p "运行秒数: " t; [ -n "$t" ] || continue
                           read -p "限速 (MB/s) [默认$CRON_MAX_SPEED_MB]: " s; s=${s:-$CRON_MAX_SPEED_MB}
                           run_traffic_task "MANUAL" "TIME" "$t" "$s" ;;
                        3) 
                           read -p "目标流量 (MB): " d; [ -n "$d" ] || continue
                           read -p "限速 (MB/s) [默认$CRON_MAX_SPEED_MB]: " s; s=${s:-$CRON_MAX_SPEED_MB}
                           run_traffic_task "MANUAL" "DATA" "$d" "$s" ;;
                        4) 
                           read -p "目标流量 (MB): " d; [ -n "$d" ] || continue
                           read -p "限速 (MB/s) [默认$CRON_MAX_SPEED_MB]: " s; s=${s:-$CRON_MAX_SPEED_MB}
                           run_bg_wrapper "$d" "$s" ;;
                        5) 
                           [ -f "$BG_PID_FILE" ] && kill $(cat "$BG_PID_FILE") 2>/dev/null && rm -f "$BG_PID_FILE" && echo "已停止"
                           ;;
                    esac
                    ;;
                2) menu_settings ;;
                3) tail -n 15 "$LOG_DIR/traffic.log"; read -p "按回车继续..." ;;
                4) 
                   crontab -l | grep -v "$CRON_MARK" | crontab -
                   rm -rf "$BASE_DIR"
                   echo "卸载完成"; exit 0 ;;
                0) exit 0 ;;
            esac
        done
        ;;
esac