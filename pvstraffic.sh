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
STATS_FILE="$BASE_DIR/history.db"
TEMP_METRIC="/tmp/ts_metric_$$_${RANDOM}.tmp"

DATE_BIN="date"

readonly URL_DL_POOL=(
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.14.tar.xz"
    "https://releases.ubuntu.com/22.04.3/ubuntu-22.04.3-desktop-amd64.iso"
    "https://nbg1-speed.hetzner.com/10GB.bin"
    "https://fsn1-speed.hetzner.com/10GB.bin"
    "https://hel1-speed.hetzner.com/10GB.bin"
    "https://ash-speed.hetzner.com/10GB.bin"
    "http://speedtest-sfo3.digitalocean.com/10gb.test"
    "http://speedtest-nyc1.digitalocean.com/10gb.test"
)

readonly URL_UP_POOL=(
    "http://speedtest.tele2.net/upload.php"
    "http://speedtest.klu.net.pl/upload.php"
    "http://speedtest.cd.estpak.ee/upload.php"
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

check_basic_env() {
    mkdir -p "$BASE_DIR" "$LOG_DIR"
    
    if [ -f "/usr/bin/date" ]; then DATE_BIN="/usr/bin/date"
    elif command -v date >/dev/null 2>&1; then
        if ! date -d "now" >/dev/null 2>&1; then
            echo "警告: 系统 date 不兼容 (BusyBox)。请手动安装 coreutils。"
        fi
    fi
    find "$LOG_DIR" -name "traffic_cycle_*.log" -type f -mtime +14 -delete
}

check_system_health() {
    # 保护机制：检查负载和内存
    local load=$(cat /proc/loadavg | awk '{print $1}')
    local is_overload=$(awk -v l="$load" 'BEGIN {if (l > 4.0) print 1; else print 0}')
    
    if [ "$is_overload" -eq 1 ]; then
        echo "High Load"
        return 1
    fi
    return 0
}

ensure_upload_capability() {
    # 保护机制：卡顿熔断
    if ! check_system_health; then
        rm -f "$PAYLOAD_FILE"
        return 2
    fi

    if [ -f "$PAYLOAD_FILE" ]; then return 0; fi

    # 空间检查 (需 > 200MB)
    local avail_kb=$(df -k "$BASE_DIR" | awk 'NR==2 {print $4}')
    if [ "$avail_kb" -lt 204800 ]; then
        return 1
    fi

    # 创建文件
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l 100M "$PAYLOAD_FILE" >/dev/null 2>&1
    elif command -v dd >/dev/null 2>&1; then
        dd if=/dev/urandom of="$PAYLOAD_FILE" bs=1M count=100 status=none >/dev/null 2>&1
    fi

    if [ -f "$PAYLOAD_FILE" ]; then return 0; else return 1; fi
}

init_config() {
    if [ -f "$CONF_FILE" ]; then source "$CONF_FILE"; fi
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

get_ts() {
    "$DATE_BIN" -d "$1" +%s 2>/dev/null
}

get_current_cycle_start() {
    local now=$("$DATE_BIN" +%s 2>/dev/null)
    if [ -z "$now" ]; then echo "0"; return; fi
    local today_maint_str="$("$DATE_BIN" +%Y-%m-%d 2>/dev/null) $MAINT_TIME:00"
    local today_maint_ts=$(get_ts "$today_maint_str")
    if [ -z "$today_maint_ts" ]; then echo "0"; return; fi
    if [ "$now" -ge "$today_maint_ts" ]; then
        echo "$today_maint_ts"
    else
        echo $((today_maint_ts - 86400))
    fi
}

get_cycle_date_str() {
    local ts=$(get_current_cycle_start)
    if [ "$ts" == "0" ]; then echo "Wait-Fix"; else "$DATE_BIN" -d "@$ts" "+%F" 2>/dev/null; fi
}

log() {
    local level="$1"
    local tag="$2"
    local msg="$3"
    local cycle_date=$(get_cycle_date_str)
    local logfile="$LOG_DIR/traffic_cycle_$cycle_date.log"
    local now_str=$("$DATE_BIN" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
    [ -z "$now_str" ] && now_str="Time-Error"
    echo "[$now_str] [$level] [$tag] $msg" >> "$logfile"
    if [[ -t 1 ]]; then echo -e "[$level] $msg"; fi
}

get_db_stats() {
    local start_ts=$1
    local end_ts=$2
    if [ ! -f "$STATS_FILE" ] || [ "$start_ts" == "0" ]; then echo "0 0 0 0"; return; fi
    awk -v start="$start_ts" -v end="$end_ts" '
    $1 >= start && $1 < end {
        if ($2 == "AUTO_DL") ad += $3;
        if ($2 == "AUTO_UP") au += $3;
        if ($2 == "MAINT_DL") md += $3;
        if ($2 == "MAINT_UP") mu += $3;
    }
    END { printf "%.0f %.0f %.0f %.0f", ad, au, md, mu }' "$STATS_FILE"
}

run_speedtest() {
    local type="$1"
    if [ "$type" == "UP" ]; then
        ensure_upload_capability
        local res=$?
        if [ "$res" -eq 1 ]; then echo "错误: 空间不足，无法创建测试文件。"; return; fi
        if [ "$res" -eq 2 ]; then echo "警告: 系统负载过高，强制取消上传。"; return; fi
    fi
    
    local start_time=$(date +%s)
    local end_time=$((start_time + 10))
    local total_bytes=0
    echo "正在测速 ($type)..."
    while [ $(date +%s) -lt $end_time ]; do
        local ua="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
        local cmd=("curl" "-4" "-s" "-k" "-L" "-A" "$ua" "--max-time" "8" "-o" "/dev/null")
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
    done
    rm -f "$TEMP_METRIC"
    local mbps=$(awk "BEGIN {printf \"%.2f\", $total_bytes * 8 / 10 / 1000 / 1000}")
    echo -e "测速结果: \033[32m$mbps Mbps\033[0m"
}

run_traffic() {
    local task_tag="$1"
    local direction="$2"
    local target_mb="$3"
    local max_speed="$4"
    
    if [ "$direction" == "UP" ]; then
        ensure_upload_capability
        local res=$?
        if [ "$res" -ne 0 ]; then
            log "WARN" "$task_tag" "上传受限 (代码 $res: 1=空间不足, 2=高负载)"
            return
        fi
    fi
    
    if [ "$task_tag" != "MANUAL" ]; then sleep $((RANDOM % 15 + 1)); fi
    
    local limit_args=()
    local real_kb=0
    if [ "$max_speed" != "0" ]; then
        real_kb=$(calc_float "$((max_speed * 1024))" "$SPEED_FLOAT")
        [ "$real_kb" -lt 100 ] && real_kb=100
        limit_args=("--limit-rate" "${real_kb}k")
    fi
    
    local actual_target_mb=$(calc_float "$target_mb" "$CHUNK_FLOAT")
    local target_bytes=$(awk "BEGIN {printf \"%.0f\", $actual_target_mb * 1024 * 1024}")
    
    log "INFO" "$task_tag" "开始 [$direction] 目标:${actual_target_mb}MB"
    
    local start_ts=$(date +%s)
    local cur_bytes=0
    
    while [ "$cur_bytes" -lt "$target_bytes" ]; do
        if [ "$task_tag" != "MANUAL" ] && [ $(( $(date +%s) - start_ts )) -gt 1800 ]; then break; fi
        
        # 实时熔断检测
        if ! check_system_health; then
            log "WARN" "$task_tag" "系统负载过高，中断任务"
            [ "$direction" == "UP" ] && rm -f "$PAYLOAD_FILE"
            break
        fi

        local left_bytes=$((target_bytes - cur_bytes))
        if [ "$left_bytes" -le 0 ]; then break; fi
        
        local ua="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
        local est_sec=60
        if [ "$real_kb" -gt 0 ]; then est_sec=$(( left_bytes / (real_kb * 1024) + 2 )); fi
        [ "$est_sec" -lt 5 ] && est_sec=5
        [ "$est_sec" -gt 300 ] && est_sec=300
        
        local cmd=("curl" "-4" "-s" "-k" "-L" "-A" "$ua" "${limit_args[@]}" "--connect-timeout" "5" "--max-time" "$est_sec" "-o" "/dev/null")
        local url=""
        if [ "$direction" == "DL" ]; then
            url="${URL_DL_POOL[$((RANDOM % ${#URL_DL_POOL[@]}))]}"
            [[ "$url" == *"?"* ]] && url="$url&r=$RANDOM" || url="$url?r=$RANDOM"
            local range_end=$((left_bytes - 1))
            cmd+=("-H" "Range: bytes=0-$range_end" "$url" "-w" "%{size_download}")
        else
            url="${URL_UP_POOL[$((RANDOM % ${#URL_UP_POOL[@]}))]}"
            cmd+=("-F" "file=@$PAYLOAD_FILE" "$url" "-w" "%{size_upload}")
        fi
        
        "${cmd[@]}" > "$TEMP_METRIC"
        local bytes=$(cat "$TEMP_METRIC" 2>/dev/null || echo 0)
        
        if [ "$bytes" -lt 100 ]; then
             sleep $((RANDOM % 3 + 1))
        else
             cur_bytes=$((cur_bytes + bytes))
        fi
        [ "$task_tag" == "MANUAL" ] && echo -ne "\r进度: $((cur_bytes/1024/1024)) MB / ${actual_target_mb} MB"
    done
    rm -f "$TEMP_METRIC"
    if [ "$task_tag" == "MANUAL" ]; then echo ""; fi
    
    local final_mb=$(awk "BEGIN {printf \"%.2f\", $cur_bytes/1024/1024}")
    if [ "$cur_bytes" -gt 1024 ]; then
        log "INFO" "$task_tag" "完成 $direction | $final_mb MB"
        if [ "$task_tag" != "MANUAL" ]; then 
            local record_ts=$(date +%s)
            if [ "$task_tag" == "MAINT" ]; then
                local current_cycle_start=$(get_current_cycle_start)
                record_ts=$((current_cycle_start - 1))
            fi
            echo "$record_ts ${task_tag}_${direction} $cur_bytes" >> "$STATS_FILE"
        fi
    else
        log "ERROR" "$task_tag" "失败 $direction | $final_mb MB"
    fi
}

check_round_safe() {
    local current_mb=$1
    local limit_mb=$((ROUND_LIMIT_GB * 1024))
    if [ "$current_mb" -ge "$limit_mb" ]; then return 1; fi
    return 0
}

entry_auto() {
    check_basic_env; init_config
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then exit 0; fi
    
    local h=$("$DATE_BIN" "+%H" | awk '{print int($0)}')
    if [ "$h" -lt "$ACTIVE_START" ] || [ "$h" -ge "$ACTIVE_END" ]; then exit 0; fi
    sleep $((RANDOM % 60))
    if [ $((RANDOM % 100)) -lt "$SKIP_CHANCE" ]; then exit 0; fi
    
    local cycle_start=$(get_current_cycle_start)
    local now=$(date +%s)
    read ad au md mu <<< $(get_db_stats "$cycle_start" "$now")
    
    local dl_done_mb=$(awk "BEGIN {printf \"%.0f\", $ad/1024/1024}")
    local up_done_mb=$(awk "BEGIN {printf \"%.0f\", $au/1024/1024}")
    local total_round_mb=$(awk "BEGIN {printf \"%.0f\", ($ad+$au+$md+$mu)/1024/1024}")
    
    local dyn_target_dl=$(calc_float "$TARGET_DL" "$TARGET_FLOAT")
    local dyn_target_up=$(calc_float "$TARGET_UP" "$TARGET_FLOAT")
    
    if [ "$dl_done_mb" -lt "$dyn_target_dl" ]; then
        if check_round_safe "$total_round_mb"; then
            local chunk=$CHUNK_MB
            local left=$((dyn_target_dl - dl_done_mb))
            [ "$chunk" -gt "$left" ] && chunk=$left
            run_traffic "AUTO" "DL" "$chunk" "$MAX_SPEED_DL"
            total_round_mb=$(awk "BEGIN {printf \"%.0f\", $total_round_mb + $chunk}") 
        fi
    fi
    
    if [ $((RANDOM % 100)) -lt 70 ] && [ "$up_done_mb" -lt "$dyn_target_up" ]; then
        if check_round_safe "$total_round_mb"; then
            local chunk=$((CHUNK_MB / 4))
            local left=$((dyn_target_up - up_done_mb))
            [ "$chunk" -gt "$left" ] && chunk=$left
            run_traffic "AUTO" "UP" "$chunk" "$MAX_SPEED_UP"
        fi
    fi
}

entry_maint() {
    check_basic_env; init_config
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then exit 0; fi
    
    log "INFO" "MAINT" "维护唤醒: 结算上一轮..."
    sleep $(( RANDOM % (CRON_DELAY_MIN * 60) ))
    
    local current_cycle_start=$(get_current_cycle_start)
    local last_cycle_start=$((current_cycle_start - 86400))
    
    read ad au md mu <<< $(get_db_stats "$last_cycle_start" "$current_cycle_start")
    local ad_mb=$(awk "BEGIN {printf \"%.0f\", $ad/1024/1024}")
    local au_mb=$(awk "BEGIN {printf \"%.0f\", $au/1024/1024}")
    
    local limit_dl=$(awk "BEGIN {printf \"%.0f\", $TARGET_DL * 0.9}")
    local limit_up=$(awk "BEGIN {printf \"%.0f\", $TARGET_UP * 0.9}")
    
    log "INFO" "MAINT" "上轮结算: AUTO_DL=$ad_mb/$limit_dl"
    
    local current_round_total=0 
    
    if [ "$ad_mb" -lt "$limit_dl" ]; then
        local gap=$((TARGET_DL - ad_mb))
        local rand_gap=$(calc_float "$gap" "$TARGET_FLOAT")
        log "INFO" "MAINT" "补量启动 DL: 缺口$gap -> 计划$rand_gap MB"
        
        while [ "$rand_gap" -gt 0 ]; do
            if ! check_round_safe "$current_round_total"; then break; fi
            local chunk=$CHUNK_MB
            [ "$chunk" -gt "$rand_gap" ] && chunk=$rand_gap
            run_traffic "MAINT" "DL" "$chunk" "$MAX_SPEED_DL"
            rand_gap=$((rand_gap - chunk))
            current_round_total=$((current_round_total + chunk))
            sleep $((RANDOM % 10 + 2))
        done
    fi
    
    if [ "$au_mb" -lt "$limit_up" ]; then
        local gap=$((TARGET_UP - au_mb))
        local rand_gap=$(calc_float "$gap" "$TARGET_FLOAT")
        log "INFO" "MAINT" "补量启动 UP: 缺口$gap -> 计划$rand_gap MB"
        
        while [ "$rand_gap" -gt 0 ]; do
            if ! check_round_safe "$current_round_total"; then break; fi
            local chunk=50
            [ "$chunk" -gt "$rand_gap" ] && chunk=$rand_gap
            run_traffic "MAINT" "UP" "$chunk" "$MAX_SPEED_UP"
            rand_gap=$((rand_gap - chunk))
            current_round_total=$((current_round_total + chunk))
            sleep $((RANDOM % 10 + 2))
        done
    fi
}

setup_cron() {
    check_basic_env
    echo "正在配置 Cron..."
    read -p "检测间隔 (分钟, 默认10): " min
    [ -z "$min" ] && min=10
    
    read cm ch <<< $(awk -v time="$MAINT_TIME" -v offset="$(unset TZ; date +%z)" 'BEGIN {
        split(time, t, ":"); h = t[1]; m = t[2];
        sign = (substr(offset,1,1)=="-") ? -1 : 1;
        oh = substr(offset,2,2); om = substr(offset,4,2);
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
        check_basic_env; init_config
        local cycle_start=$(get_current_cycle_start)
        local now=$(date +%s)
        local last_cycle_start=$((cycle_start - 86400))
        
        read c_ad c_au c_md c_mu <<< $(get_db_stats "$cycle_start" "$now")
        local c_total_dl=$(awk "BEGIN {printf \"%.1f\", ($c_ad+$c_md)/1024/1024}")
        local c_total_up=$(awk "BEGIN {printf \"%.1f\", ($c_au+$c_mu)/1024/1024}")
        
        read l_ad l_au l_md l_mu <<< $(get_db_stats "$last_cycle_start" "$cycle_start")
        local l_auto_dl=$(awk "BEGIN {printf \"%.1f\", $l_ad/1024/1024}")
        local l_maint_dl=$(awk "BEGIN {printf \"%.1f\", $l_md/1024/1024}")
        local l_total_dl=$(awk "BEGIN {printf \"%.1f\", ($l_ad+$l_md)/1024/1024}")
        local l_total_up=$(awk "BEGIN {printf \"%.1f\", ($l_au+$l_mu)/1024/1024}")
        
        local cycle_date_str=$(get_cycle_date_str)
        
        clear
        echo "================================================================"
        echo "           VPS Traffic Spirit By Prince v1.0.0"
        echo "================================================================"
        echo " [环境设置]"
        echo " 每日目标: DL $TARGET_DL MB | UP $TARGET_UP MB (浮动 $TARGET_FLOAT%)"
        echo " 运行策略: $ACTIVE_START点-$ACTIVE_END点 | 偷懒率 $SKIP_CHANCE%"
        echo " 维护结算: 每日 $MAINT_TIME (UTC+8)"
        echo "----------------------------------------------------------------"
        echo " [上一轮结算] (周期结束于 $cycle_date_str $MAINT_TIME)"
        echo " DL详情: AUTO $l_auto_dl + MAINT $l_maint_dl = 总 $l_total_dl MB"
        echo " UP详情: 总 $l_total_up MB"
        echo "----------------------------------------------------------------"
        echo " [本轮进行中] (下次结算: 明日 $MAINT_TIME)"
        echo " 实时统计: DL $c_total_dl MB | UP $c_total_up MB"
        echo "================================================================"
        echo " 1. 设置 - 流量目标"
        echo " 2. 设置 - 速率限制"
        echo " 3. 设置 - 维护策略"
        echo " 4. 运行 - 手动前台"
        echo " 5. 运行 - 手动后台"
        echo " 6. 工具 - 极速测速"
        echo " 7. 系统 - 更新 Cron"
        echo " 8. 审计 - 查看日志"
        echo " 9. 卸载 - 删除脚本"
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
            8) echo ""; tail -n 20 "$LOG_DIR/traffic_cycle_$cycle_date_str.log"; read -p "..." ;;
            9) crontab -l | grep -v "TrafficSpirit" | crontab -; rm -rf "$BASE_DIR"; exit 0 ;;
            0) exit 0 ;;
        esac
    done
}

case "$1" in
    --auto) entry_auto ;;
    --maint) entry_maint ;;
    --manual-bg) run_traffic "MANUAL" "$2" "$3" "$4" ;;
    *) check_basic_env; main_menu ;;
esac
