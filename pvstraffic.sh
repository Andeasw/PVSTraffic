#!/bin/bash
# ==============================================================================
# VPS Traffic Spirit v1.0.0
# Author: Prince 2025.12
# ==============================================================================

SCRIPT_ABS_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_ABS_PATH")
cd "$SCRIPT_DIR" || exit 1

export TZ='Asia/Shanghai'
BASE_DIR="$SCRIPT_DIR/TrafficSpirit_Data"
LOG_DIR="$BASE_DIR/logs"
CONF_FILE="$BASE_DIR/config.ini"
LOCK_FILE="$BASE_DIR/run.lock"
PAYLOAD_FILE="$BASE_DIR/payload.dat"
STATS_FILE="$BASE_DIR/auto_db.bytes"
TEMP_METRIC="/tmp/ts_metric_$$_{RANDOM}.tmp"

DATE_BIN="date"
DATE_STATUS="未知"
UPLOAD_ENABLE=1

readonly URL_DL_POOL=(
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.14.tar.xz"
    "https://releases.ubuntu.com/22.04.3/ubuntu-22.04.3-desktop-amd64.iso"
    "https://nbg1-speed.hetzner.com/10GB.bin"
    "https://fsn1-speed.hetzner.com/10GB.bin"
    "https://hel1-speed.hetzner.com/10GB.bin"
    "https://ash-speed.hetzner.com/10GB.bin"
    "https://speedtest.tele2.net/10GB.zip"
    "http://speedtest-sfo3.digitalocean.com/10gb.test"
    "http://speedtest-nyc1.digitalocean.com/10gb.test"
)

readonly URL_UP_POOL=(
    "http://speedtest.tele2.net/upload.php"
    "http://speedtest.klu.net.pl/upload.php"
    "http://speedtest.cd.estpak.ee/upload.php"
    "http://speedtest.uztelecom.uz/upload.php"
    "https://bouygues.testdebit.info/ul/upload.php"
    "https://scaleway.testdebit.info/ul/upload.php"
    "http://speedtest-nyc1.digitalocean.com/upload"
    "http://speedtest.dallas.linode.com/empty.php"
)

readonly UA_POOL=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
)

check_env_passive() {
    mkdir -p "$BASE_DIR" "$LOG_DIR"
    
    if [ -f "/usr/bin/date" ]; then
        DATE_BIN="/usr/bin/date"
        DATE_STATUS="GNU (正常)"
    elif command -v date >/dev/null 2>&1; then
        # 简单检测 date -d 支持情况
        if date -d "now" >/dev/null 2>&1; then
            DATE_BIN="date"
            DATE_STATUS="System (支持)"
        else
            DATE_BIN="date"
            DATE_STATUS="BusyBox (需修复)"
        fi
    else
        DATE_STATUS="缺失 (严重)"
    fi

    if [ ! -f "$PAYLOAD_FILE" ]; then
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l 10M "$PAYLOAD_FILE" >/dev/null 2>&1
        elif command -v dd >/dev/null 2>&1; then
            dd if=/dev/urandom of="$PAYLOAD_FILE" bs=1M count=10 status=none >/dev/null 2>&1
        fi
    fi
    
    [ -f "$PAYLOAD_FILE" ] && UPLOAD_ENABLE=1 || UPLOAD_ENABLE=0
    find "$LOG_DIR" -name "traffic_cycle_*.log" -type f -mtime +14 -delete
}

install_deps() {
    echo "正在检查并安装依赖 (需要网络)..."
    if [ -f /etc/alpine-release ]; then
        apk update && apk add --no-cache curl coreutils procps grep util-linux findutils cronie bash
        rc-service crond start 2>/dev/null || systemctl start crond 2>/dev/null
    elif [ -f /etc/debian_version ]; then
        apt-get update -qq && apt-get install -y -qq curl coreutils procps util-linux findutils cron
    elif [ -f /etc/redhat-release ]; then
        yum install -y -q curl coreutils procps util-linux findutils cronie
    fi
    echo "依赖安装尝试完成。"
    check_env_passive
    sleep 2
}

init_config() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi

    if [ -z "$TARGET_DL" ]; then
        cat > "$CONF_FILE" <<EOF
TARGET_DL=1666
TARGET_UP=30
TARGET_FLOAT=10
MAX_SPEED_DL=7
MAX_SPEED_UP=2
SPEED_FLOAT=20
ACTIVE_START=7
ACTIVE_END=11
CHUNK_MB=368
CHUNK_FLOAT=20
SKIP_CHANCE=20
MAINT_TIME="03:00"
CRON_DELAY_MIN=20
ROUND_LIMIT_GB=5
EOF
        source "$CONF_FILE"
    fi
}

save_config() {
    cat > "$CONF_FILE" <<EOF
TARGET_DL=$TARGET_DL
TARGET_UP=$TARGET_UP
TARGET_FLOAT=$TARGET_FLOAT
MAX_SPEED_DL=$MAX_SPEED_DL
MAX_SPEED_UP=$MAX_SPEED_UP
SPEED_FLOAT=$SPEED_FLOAT
ACTIVE_START=$ACTIVE_START
ACTIVE_END=$ACTIVE_END
CHUNK_MB=$CHUNK_MB
CHUNK_FLOAT=$CHUNK_FLOAT
SKIP_CHANCE=$SKIP_CHANCE
MAINT_TIME="$MAINT_TIME"
CRON_DELAY_MIN=$CRON_DELAY_MIN
ROUND_LIMIT_GB=$ROUND_LIMIT_GB
EOF
}

calc_float() {
    awk -v base="$1" -v pct="$2" -v seed="$RANDOM" 'BEGIN {
        srand(seed); 
        range = base * pct / 100;
        val = base - range + (2 * range * rand());
        if (val < 1) val=1; 
        printf "%.0f", val
    }'
}

get_cycle_start() {
    local now=$("$DATE_BIN" +%s 2>/dev/null)
    local today_maint_str="$("$DATE_BIN" +%Y-%m-%d 2>/dev/null) $MAINT_TIME:00"
    local today_maint_ts=$("$DATE_BIN" -d "$today_maint_str" +%s 2>/dev/null)
    
    # 兼容性处理：如果 date 计算失败，返回 0
    if [ -z "$now" ] || [ -z "$today_maint_ts" ]; then
        echo "0"
        return
    fi

    if [ "$now" -ge "$today_maint_ts" ]; then
        echo "$today_maint_ts"
    else
        echo $((today_maint_ts - 86400))
    fi
}

get_cycle_date_str() {
    local ts=$(get_cycle_start)
    if [ "$ts" == "0" ]; then
        echo "Error-Date"
    else
        "$DATE_BIN" -d "@$ts" "+%F" 2>/dev/null
    fi
}

log() {
    local level="$1"
    local tag="$2"
    local msg="$3"
    local cycle_date=$(get_cycle_date_str)
    local logfile="$LOG_DIR/traffic_cycle_$cycle_date.log"
    echo "[$("$DATE_BIN" "+%Y-%m-%d %H:%M:%S")] [$level] [$tag] $msg" >> "$logfile"
    if [[ -t 1 ]]; then echo -e "[$level] $msg"; fi
}

get_valid_stats() {
    local start_ts=$(get_cycle_start)
    if [ ! -f "$STATS_FILE" ] || [ "$start_ts" == "0" ]; then echo "0 0"; return; fi
    awk -v start="$start_ts" '
    $1 >= start {
        if ($2 == "DL") dl += $3;
        if ($2 == "UP") up += $3;
    }
    END { printf "%.0f %.0f", dl, up }' "$STATS_FILE"
}

run_speedtest() {
    local type="$1"
    if [ "$type" == "UP" ] && [ "$UPLOAD_ENABLE" -eq 0 ]; then
        echo "错误: 磁盘空间不足。"
        return
    fi
    local duration=10
    local start_time=$("$DATE_BIN" +%s 2>/dev/null || date +%s)
    local end_time=$((start_time + duration))
    local total_bytes=0
    
    echo "正在测速 ($type) - 持续 ${duration} 秒..."
    local tested_urls=""
    while [ $(date +%s) -lt $end_time ]; do
        local ua="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
        local cmd=("curl" "-4" "-s" "-k" "-L" "-A" "$ua" "--connect-timeout" "3" "--max-time" "8" "-o" "/dev/null")
        local url=""
        if [ "$type" == "DL" ]; then
            url="${URL_DL_POOL[$((RANDOM % ${#URL_DL_POOL[@]}))]}"
            [[ "$url" == *"?"* ]] && url="$url&r=$RANDOM" || url="$url?r=$RANDOM"
            cmd+=("$url" "-w" "%{size_download}")
        else
            url="${URL_UP_POOL[$((RANDOM % ${#URL_UP_POOL[@]}))]}"
            cmd+=("-F" "file=@$PAYLOAD_FILE" "$url" "-w" "%{size_upload}")
        fi
        "${cmd[@]}" > "$TEMP_METRIC"
        local bytes=$(cat "$TEMP_METRIC" 2>/dev/null || echo 0)
        [ "$bytes" -gt 0 ] && total_bytes=$((total_bytes + bytes))
        tested_urls="$url, $tested_urls"
    done
    rm -f "$TEMP_METRIC"
    local real_dur=$(( $(date +%s) - start_time ))
    [ "$real_dur" -lt 1 ] && real_dur=1
    local mbps=$(awk "BEGIN {printf \"%.2f\", $total_bytes * 8 / $real_dur / 1000 / 1000}")
    local mbs=$(awk "BEGIN {printf \"%.2f\", $total_bytes / $real_dur / 1024 / 1024}")
    echo -e "测速结果: \033[32m$mbps Mbps\033[0m ($mbs MB/s)"
    log "INFO" "TEST" "测速 $type | $mbps Mbps | 耗时 ${real_dur}s"
}

run_traffic() {
    local tag="$1"
    local type="$2"
    local target_mb="$3"
    local max_speed="$4"
    
    if [ "$type" == "UP" ] && [ "$UPLOAD_ENABLE" -eq 0 ]; then
        log "WARN" "$tag" "跳过上传: 磁盘不足"
        return
    fi
    
    if [ "$tag" != "MANUAL" ]; then sleep $((RANDOM % 15 + 1)); fi
    local limit_args=()
    local real_kb=0
    if [ "$max_speed" != "0" ]; then
        real_kb=$(calc_float "$((max_speed * 1024))" "$SPEED_FLOAT")
        [ "$real_kb" -lt 100 ] && real_kb=100
        limit_args=("--limit-rate" "${real_kb}k")
    fi
    local actual_target_mb=$(calc_float "$target_mb" "$CHUNK_FLOAT")
    local target_bytes=$(awk "BEGIN {printf \"%.0f\", $actual_target_mb * 1024 * 1024}")
    
    local spd_desc="无限制"
    if [ "$max_speed" != "0" ]; then spd_desc="$(awk "BEGIN {printf \"%.2f\", $real_kb/1024}") MB/s"; fi
    
    log "INFO" "$tag" "开始 [$type] 计划:${actual_target_mb}MB | 限速:$spd_desc"
    local start_ts=$(date +%s)
    local cur_bytes=0
    local retry=0
    local last_url=""
    
    while [ "$cur_bytes" -lt "$target_bytes" ]; do
        if [ "$tag" != "MANUAL" ] && [ $(( $(date +%s) - start_ts )) -gt 1800 ]; then break; fi
        local left_bytes=$((target_bytes - cur_bytes))
        if [ "$left_bytes" -le 0 ]; then break; fi
        
        local ua="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
        local est_sec=60
        if [ "$real_kb" -gt 0 ]; then est_sec=$(( left_bytes / (real_kb * 1024) + 2 )); fi
        [ "$est_sec" -lt 5 ] && est_sec=5
        [ "$est_sec" -gt 300 ] && est_sec=300
        
        local cmd=("curl" "-4" "-s" "-k" "-L" "-A" "$ua" "${limit_args[@]}" "--connect-timeout" "5" "--max-time" "$est_sec" "-o" "/dev/null")
        local url=""
        if [ "$type" == "DL" ]; then
            url="${URL_DL_POOL[$((RANDOM % ${#URL_DL_POOL[@]}))]}"
            [[ "$url" == *"?"* ]] && url="$url&r=$RANDOM" || url="$url?r=$RANDOM"
            local range_end=$((left_bytes - 1))
            cmd+=("-H" "Range: bytes=0-$range_end" "$url" "-w" "%{size_download}")
        else
            url="${URL_UP_POOL[$((RANDOM % ${#URL_UP_POOL[@]}))]}"
            cmd+=("-F" "file=@$PAYLOAD_FILE" "$url" "-w" "%{size_upload}")
        fi
        
        last_url="$url"
        "${cmd[@]}" > "$TEMP_METRIC"
        local bytes=$(cat "$TEMP_METRIC" 2>/dev/null || echo 0)
        
        if [ "$bytes" -lt 100 ]; then
             retry=$((retry + 1))
             [ "$retry" -ge 10 ] && break
             sleep $((RANDOM % 3 + 1))
        else
             retry=0
             cur_bytes=$((cur_bytes + bytes))
        fi
        [ "$tag" == "MANUAL" ] && echo -ne "\r进度: $((cur_bytes/1024/1024)) MB / ${actual_target_mb} MB"
    done
    rm -f "$TEMP_METRIC"
    if [ "$tag" == "MANUAL" ]; then echo ""; fi
    
    local dur=$(( $(date +%s) - start_ts ))
    local final_mb=$(awk "BEGIN {printf \"%.2f\", $cur_bytes/1024/1024}")
    if [ "$cur_bytes" -gt 1024 ]; then
        log "INFO" "$tag" "完成 $type | $final_mb MB | 耗时 ${dur}s"
        if [ "$tag" != "MANUAL" ]; then echo "$(date +%s) $type $cur_bytes" >> "$STATS_FILE"; fi
    else
        log "ERROR" "$tag" "失败 $type | $final_mb MB"
    fi
}

check_round_limit() {
    local current_mb=$1
    local limit_mb=$((ROUND_LIMIT_GB * 1024))
    if [ "$current_mb" -ge "$limit_mb" ]; then return 1; fi
    return 0
}

entry_auto() {
    check_env_passive; init_config
    log "INFO" "AUTO" "Cron 唤醒"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then exit 0; fi
    sleep $((RANDOM % 60))
    local h=$("$DATE_BIN" "+%H" | awk '{print int($0)}')
    if [ "$h" -lt "$ACTIVE_START" ] || [ "$h" -ge "$ACTIVE_END" ]; then exit 0; fi
    if [ $((RANDOM % 100)) -lt "$SKIP_CHANCE" ]; then exit 0; fi
    
    local dyn_dl=$(calc_float "$TARGET_DL" "$TARGET_FLOAT")
    local dyn_up=$(calc_float "$TARGET_UP" "$TARGET_FLOAT")
    read c_dl c_up <<< $(get_valid_stats)
    local c_dl_mb=$(awk "BEGIN {printf \"%.0f\", $c_dl/1024/1024}")
    local c_up_mb=$(awk "BEGIN {printf \"%.0f\", $c_up/1024/1024}")
    local round_total_mb=0
    
    if [ "$c_dl_mb" -lt "$dyn_dl" ]; then
        local chunk=$CHUNK_MB
        local left=$((dyn_dl - c_dl_mb))
        [ "$chunk" -gt "$left" ] && chunk=$left
        [ "$chunk" -lt 10 ] && chunk=10
        if [ $((round_total_mb + chunk)) -gt $((ROUND_LIMIT_GB * 1024)) ]; then chunk=$((ROUND_LIMIT_GB * 1024 - round_total_mb)); fi
        if [ "$chunk" -gt 0 ]; then
             run_traffic "AUTO" "DL" "$chunk" "$MAX_SPEED_DL"
             round_total_mb=$((round_total_mb + chunk))
        fi
    fi
    if [ $((RANDOM % 100)) -lt 70 ] && [ "$c_up_mb" -lt "$dyn_up" ]; then
        if check_round_limit "$round_total_mb"; then
            local chunk=$((CHUNK_MB / 4))
            local left=$((dyn_up - c_up_mb))
            [ "$chunk" -gt "$left" ] && chunk=$left
            [ "$chunk" -lt 5 ] && chunk=5
            if [ $((round_total_mb + chunk)) -gt $((ROUND_LIMIT_GB * 1024)) ]; then chunk=$((ROUND_LIMIT_GB * 1024 - round_total_mb)); fi
            if [ "$chunk" -gt 0 ]; then run_traffic "AUTO" "UP" "$chunk" "$MAX_SPEED_UP"; fi
        fi
    fi
    if [ $(wc -l < "$STATS_FILE" 2>/dev/null || echo 0) -gt 10000 ]; then
        local cycle_start=$(get_cycle_start)
        awk -v start="$cycle_start" '$1 >= start {print $0}' "$STATS_FILE" > "$STATS_FILE.tmp" && mv "$STATS_FILE.tmp" "$STATS_FILE"
    fi
}

entry_maint() {
    check_env_passive; init_config
    log "INFO" "MAINT" "维护唤醒"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then exit 0; fi
    sleep $(( RANDOM % (CRON_DELAY_MIN * 60) ))
    
    read c_dl c_up <<< $(get_valid_stats)
    local c_dl_mb=$(awk "BEGIN {printf \"%.0f\", $c_dl/1024/1024}")
    local c_up_mb=$(awk "BEGIN {printf \"%.0f\", $c_up/1024/1024}")
    local t_dl=$(awk "BEGIN {printf \"%.0f\", $TARGET_DL * 0.95}")
    local t_up=$(awk "BEGIN {printf \"%.0f\", $TARGET_UP * 0.95}")
    local round_total_mb=0
    
    local gap=$((t_dl - c_dl_mb))
    while [ "$gap" -gt 0 ]; do
        if ! check_round_limit "$round_total_mb"; then break; fi
        local chunk=$CHUNK_MB
        [ "$chunk" -gt "$gap" ] && chunk=$gap
        run_traffic "MAINT" "DL" "$chunk" "$MAX_SPEED_DL"
        gap=$((gap - chunk))
        round_total_mb=$((round_total_mb + chunk))
        sleep 5
    done
    gap=$((t_up - c_up_mb))
    while [ "$gap" -gt 0 ]; do
        if ! check_round_limit "$round_total_mb"; then break; fi
        local chunk=50
        [ "$chunk" -gt "$gap" ] && chunk=$gap
        run_traffic "MAINT" "UP" "$chunk" "$MAX_SPEED_UP"
        gap=$((gap - chunk))
        round_total_mb=$((round_total_mb + chunk))
        sleep 5
    done
}

setup_cron() {
    check_env_passive
    echo "正在配置 Cron..."
    read -p "检测间隔 (分钟, 默认10): " min
    [ -z "$min" ] && min=10
    
    read cm ch <<< $(awk -v time="$MAINT_TIME" -v offset="$(unset TZ; date +%z)" 'BEGIN {
        split(time, t, ":");
        h = t[1]; m = t[2];
        sign = (substr(offset,1,1)=="-") ? -1 : 1;
        oh = substr(offset,2,2);
        om = substr(offset,4,2);
        sys_off = sign * (oh*3600 + om*60);
        target_sec = h*3600 + m*60;
        final = target_sec - 28800 + sys_off;
        while (final < 0) final += 86400;
        while (final >= 86400) final -= 86400;
        printf "%d %d", int((final%3600)/60), int(final/3600);
    }')
    
    crontab -l 2>/dev/null | grep -v "TrafficSpirit" > /tmp/cron.tmp
    echo "*/$min * * * * /bin/bash $SCRIPT_ABS_PATH --auto >>/dev/null 2>&1 # [TrafficSpirit_Routine]" >> /tmp/cron.tmp
    echo "$cm $ch * * * /bin/bash $SCRIPT_ABS_PATH --maint >>/dev/null 2>&1 # [TrafficSpirit_Maint]" >> /tmp/cron.tmp
    crontab /tmp/cron.tmp && rm -f /tmp/cron.tmp
    echo "配置完成。"
}

main_menu() {
    while true; do
        check_env_passive; init_config
        local cycle_date=$(get_cycle_date_str)
        read c_dl c_up <<< $(get_valid_stats)
        local c_dl_mb=$(awk "BEGIN {printf \"%.1f\", $c_dl/1024/1024}")
        local c_up_mb=$(awk "BEGIN {printf \"%.1f\", $c_up/1024/1024}")
        
        clear
        echo "================================================================"
        echo "           VPS Traffic Spirit By Prince v1.0.0"
        echo "================================================================"
        echo " [环境设置]"
        echo " 每日目标: DL $TARGET_DL MB | UP $TARGET_UP MB (浮动 $TARGET_FLOAT%)"
        echo " 速率限制: DL $MAX_SPEED_DL MB/s | UP $MAX_SPEED_UP MB/s (浮动 $SPEED_FLOAT%)"
        echo " 运行时间: $ACTIVE_START点-$ACTIVE_END点 | 切片 $CHUNK_MB MB (浮动 $CHUNK_FLOAT%)"
        echo " 维护策略: $MAINT_TIME (UTC+8) | 延迟 0-$CRON_DELAY_MIN 分 | 偷懒率 $SKIP_CHANCE%"
        echo " 安全熔断: 每轮任务最大消耗 $ROUND_LIMIT_GB GB"
        echo " 依赖状态: $DATE_STATUS (若显示需修复，请选 10)"
        echo "----------------------------------------------------------------"
        echo " [本轮状态: $cycle_date]"
        echo " 周期定义: 今日 $MAINT_TIME 至 明日 $MAINT_TIME"
        echo " 已跑流量: DL $c_dl_mb MB | UP $c_up_mb MB"
        echo " 日志文件: $LOG_DIR/traffic_cycle_$cycle_date.log"
        echo "================================================================"
        echo " 1. 设置 - 每日目标"
        echo " 2. 设置 - 速率限制"
        echo " 3. 设置 - 维护策略"
        echo " 4. 运行 - 手动前台"
        echo " 5. 运行 - 手动后台"
        echo " 6. 工具 - 极速测速"
        echo " 7. 系统 - 更新 Cron（必点）"
        echo " 8. 审计 - 查看日志"
        echo " 9. 卸载 - 删除脚本"
        echo " 10. 环境 - 检查依赖（必点）"
        echo " 0. 退出"
        echo "----------------------------------------------------------------"
        read -p "选择: " opt
        case "$opt" in
            1) read -p "下载目标(MB): " TARGET_DL; read -p "上传目标(MB): " TARGET_UP; read -p "目标浮动(%): " TARGET_FLOAT; save_config ;;
            2) read -p "下载限速(MB/s): " MAX_SPEED_DL; read -p "上传限速(MB/s): " MAX_SPEED_UP; read -p "速率浮动(%): " SPEED_FLOAT; save_config ;;
            3) read -p "维护时间: " MAINT_TIME; read -p "随机延迟(分): " CRON_DELAY_MIN; read -p "偷懒率(%): " SKIP_CHANCE; read -p "起始点: " ACTIVE_START; read -p "结束点: " ACTIVE_END; read -p "单次切片(MB): " CHUNK_MB; read -p "每轮限额(GB): " ROUND_LIMIT_GB; save_config ;;
            4) read -p "1.DL 2.UP: " d; t="DL"; [ "$d" == "2" ] && t="UP"; read -p "MB: " m; read -p "MB/s: " s; run_traffic "MANUAL" "$t" "$m" "$s"; read -p "..." ;;
            5) read -p "1.DL 2.UP: " d; t="DL"; [ "$d" == "2" ] && t="UP"; read -p "MB: " m; read -p "MB/s: " s; nohup bash "$0" --manual-bg "$t" "$m" "$s" >/dev/null 2>&1 & echo "PID: $!"; sleep 2 ;;
            6) read -p "1.DL 2.UP: " d; t="DL"; [ "$d" == "2" ] && t="UP"; run_speedtest "$t"; read -p "..." ;;
            7) setup_cron ;;
            8) echo ""; tail -n 20 "$LOG_DIR/traffic_cycle_$cycle_date.log"; read -p "..." ;;
            9) crontab -l | grep -v "TrafficSpirit" | crontab -; rm -rf "$BASE_DIR"; exit 0 ;;
            10) install_deps ;;
            0) exit 0 ;;
        esac
    done
}

case "$1" in
    --auto) entry_auto ;;
    --maint) entry_maint ;;
    --manual-bg) run_traffic "MANUAL" "$2" "$3" "$4" ;;
    *) check_env_passive; main_menu ;;
esac
