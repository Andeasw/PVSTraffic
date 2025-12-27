#!/bin/bash
# ==============================================================================
# VPS Traffic Spirit v1.0.0
# Author: Prince 2025.12
# ==============================================================================

source /etc/profile >/dev/null 2>&1
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

SCRIPT_ABS_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_ABS_PATH")
cd "$SCRIPT_DIR" || exit 1

export TZ='Asia/Shanghai'
BASE_DIR="$SCRIPT_DIR/TrafficSpirit_Data"
LOG_DIR="$BASE_DIR/logs"
CONF_FILE="$BASE_DIR/config.ini"
LOCK_DIR="$BASE_DIR/run.lock.d"
PAYLOAD_FILE="$BASE_DIR/payload.dat"
STATS_FILE="$BASE_DIR/history.db"
STATS_LOCK="$BASE_DIR/history.lock"
TEMP_METRIC="/tmp/ts_metric_$$_${RANDOM}.tmp"

LOCK_ACQUIRED=0

cleanup() {
    rm -f "$TEMP_METRIC"
    if [ "$LOCK_ACQUIRED" -eq 1 ]; then
        rm -rf "$LOCK_DIR"
    fi
}
trap 'cleanup' EXIT INT TERM

readonly URL_DL_POOL=(
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.14.tar.xz"
    "https://releases.ubuntu.com/22.04.3/ubuntu-22.04.3-desktop-amd64.iso"
    "https://nbg1-speed.hetzner.com/10GB.bin"
    "https://fsn1-speed.hetzner.com/10GB.bin"
    "http://speedtest-sfo3.digitalocean.com/10gb.test"
    "http://speedtest-nyc1.digitalocean.com/10gb.test"
)

readonly URL_UP_POOL=(
    "http://speedtest.tele2.net/upload.php"
    "http://speedtest.klu.net.pl/upload.php"
    "https://bouygues.testdebit.info/ul/upload.php"
    "http://speedtest-nyc1.digitalocean.com/upload"
)

readonly UA_POOL=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/121.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/120.0.0.0 Safari/537.36"
    "Mozilla/5.0 (X11; Linux x86_64) Chrome/121.0.0.0 Safari/537.36"
)

init_redirect_logging() {
    if [ ! -d "$BASE_DIR" ]; then mkdir -p "$BASE_DIR" || exit 1; fi
    if [ ! -d "$LOG_DIR" ]; then mkdir -p "$LOG_DIR" || exit 1; fi
    local today=$(date +%F)
    local log_file="$LOG_DIR/traffic_cycle_${today}.log"
    exec 1>>"$log_file"
    exec 2>&1
}

install_deps() {
    [ -t 0 ] || return 0
    if ! command -v curl >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1; then
        echo "正在检查并修复依赖..."
        if [ -f /etc/alpine-release ]; then
            apk update && apk add --no-cache curl coreutils procps grep util-linux findutils cronie bash
            rm -rf /var/cache/apk/*
            rc-service crond start 2>/dev/null || systemctl start crond 2>/dev/null
        elif [ -f /etc/debian_version ]; then
            apt-get update -qq && apt-get install -y -qq curl coreutils procps util-linux findutils cron
            rm -rf /var/lib/apt/lists/*
        elif [ -f /etc/redhat-release ]; then
            yum install -y -q curl coreutils procps util-linux findutils cronie
            yum clean all
        fi
    fi
}

init_base() {
    if [ ! -d "$BASE_DIR" ]; then mkdir -p "$BASE_DIR" || exit 1; fi
    if [ ! -d "$LOG_DIR" ]; then mkdir -p "$LOG_DIR" || exit 1; fi
    if [ ! -f "$STATS_FILE" ]; then : > "$STATS_FILE"; fi
    find "$LOG_DIR" -name "traffic_cycle_*.log" -type f -mtime +7 -delete 2>/dev/null
}

init_config() {
    init_base
    if [ -f "$CONF_FILE" ]; then source "$CONF_FILE"; fi
    
    : "${TARGET_DL:=1666}"
    : "${TARGET_UP:=0}"
    : "${TARGET_FLOAT:=25}"
    : "${MAX_SPEED_DL:=7}"
    : "${MAX_SPEED_UP:=2}"
    : "${SPEED_FLOAT:=15}"
    : "${ACTIVE_START:=7}"
    : "${ACTIVE_END:=11}"
    : "${CHUNK_MB:=356}"
    : "${CHUNK_FLOAT:=35}"
    : "${SKIP_CHANCE:=20}"
    : "${MAINT_TIME:=20:30}"
    : "${MAINT_DELAY_MIN:=45}"
    : "${ROUND_LIMIT_GB:=5}"

    if [ ! -f "$CONF_FILE" ]; then save_config; fi
}

save_config() {
    init_base
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
MAINT_DELAY_MIN=$MAINT_DELAY_MIN
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

calc_chunk_size() {
    local rem=$1
    local base=$2
    if [ "$base" -gt "$rem" ]; then echo "$rem"; else echo "$base"; fi
}

get_ts() { 
    date -d "$1" +%s 2>/dev/null || echo 0 
}

get_current_cycle_start() {
    local now=$(date +%s)
    local today_maint_str="$(date +%Y-%m-%d) $MAINT_TIME:00"
    local today_maint_ts=$(get_ts "$today_maint_str")
    if [ "$today_maint_ts" -eq 0 ]; then echo "0"; return; fi
    if [ "$now" -ge "$today_maint_ts" ]; then echo "$today_maint_ts"; else echo $((today_maint_ts - 86400)); fi
}

log() {
    local level="$1"
    local msg="$2"
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] [$level] $msg"
}

check_and_lock() {
    if [ -d "$LOCK_DIR" ]; then
        if [ -f "$LOCK_DIR/pid" ]; then
            local pid=$(cat "$LOCK_DIR/pid")
            if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
                rm -rf "$LOCK_DIR"
            fi
        else
            rm -rf "$LOCK_DIR"
        fi
    fi
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        LOCK_ACQUIRED=1
        return 0
    fi
    return 1
}

get_db_stats() {
    local start_ts=$1
    local end_ts=$2
    if [ ! -f "$STATS_FILE" ] || [ "$start_ts" == "0" ]; then echo "0 0 0 0"; return; fi
    
    tail -n 8000 "$STATS_FILE" 2>/dev/null | awk -v start="$start_ts" -v end="$end_ts" '
    $1 >= start && $1 < end {
        if ($2 == "AUTO_DL") ad += $3;
        if ($2 == "AUTO_UP") au += $3;
        if ($2 == "MAINT_DL") md += $3;
        if ($2 == "MAINT_UP") mu += $3;
    }
    END { printf "%.0f %.0f %.0f %.0f", ad, au, md, mu }'
}

prepare_payload() {
    local task_tag="$1"
    local force="$2"

    if [ "$task_tag" == "AUTO" ]; then
        if [ -s "$PAYLOAD_FILE" ]; then return 0; else return 1; fi
    fi

    local free_kb=$(df -k "$BASE_DIR" 2>/dev/null | awk 'END{print $4}')
    if [ -z "$free_kb" ] || [ "$free_kb" -lt 512000 ]; then
        [ -f "$PAYLOAD_FILE" ] && rm -f "$PAYLOAD_FILE"
        return 1
    fi

    if [ "$TARGET_UP" -gt 0 ] || [ "$force" == "1" ]; then
        if [ ! -f "$PAYLOAD_FILE" ]; then
            if command -v fallocate >/dev/null 2>&1; then
                fallocate -l 50M "$PAYLOAD_FILE" >/dev/null 2>&1
            else
                dd if=/dev/urandom of="$PAYLOAD_FILE" bs=1M count=50 status=none >/dev/null 2>&1
            fi
        fi
        [ -s "$PAYLOAD_FILE" ] && return 0 || return 1
    else
        [ -f "$PAYLOAD_FILE" ] && rm -f "$PAYLOAD_FILE"
        return 1
    fi
}

run_traffic() {
    local task_tag="$1"
    local direction="$2"
    local target_mb="$3"
    local max_speed="$4"
    
    if [ "$direction" == "UP" ]; then
        local force_create="0"
        [ "$task_tag" == "MANUAL" ] && force_create="1"
        if ! prepare_payload "$task_tag" "$force_create"; then
            if [ "$target_mb" -gt 0 ]; then
                log "WARN" "[$task_tag] 上传跳过: 未启用、文件丢失或磁盘空间不足"
            fi
            return
        fi
    fi
    
    local limit_args=()
    local real_kb=0
    if [ "$max_speed" != "0" ]; then
        real_kb=$(calc_float "$((max_speed * 1024))" "$SPEED_FLOAT")
        [ "$real_kb" -lt 100 ] && real_kb=100
        limit_args=("--limit-rate" "${real_kb}k")
    fi
    
    local actual_target_mb=$(calc_float "$target_mb" "$CHUNK_FLOAT")
    local target_bytes=$(awk "BEGIN {printf \"%.0f\", $actual_target_mb * 1024 * 1024}")
    log "INFO" "[$task_tag] 启动 [$direction] 计划: ${actual_target_mb}MB (限速: $(awk "BEGIN {printf \"%.1f\", $real_kb/1024}") MB/s)"
    
    local start_ts=$(date +%s)
    local cur_bytes=0
    local retry=0
    
    while [ "$cur_bytes" -lt "$target_bytes" ]; do
        if [ "$task_tag" != "MANUAL" ] && [ $(( $(date +%s) - start_ts )) -gt 1800 ]; then break; fi
        local left_bytes=$((target_bytes - cur_bytes))
        if [ "$left_bytes" -le 0 ]; then break; fi
        
        local ua="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
        local est_sec=60
        if [ "$real_kb" -gt 0 ]; then est_sec=$(( left_bytes / (real_kb * 1024) + 3 )); fi
        [ "$est_sec" -gt 300 ] && est_sec=300
        
        local cmd=("curl" "-4" "-s" "-k" "-L" "-A" "$ua" "${limit_args[@]}" "--connect-timeout" "4" "--max-time" "$est_sec" "-o" "/dev/null")
        local url=""
        
        if [ "$direction" == "DL" ]; then
            url="${URL_DL_POOL[$((RANDOM % ${#URL_DL_POOL[@]}))]}"
            [[ "$url" == *"?"* ]] && url="$url&r=$RANDOM" || url="$url?r=$RANDOM"
            
            local max_slice=$(( 20 * 1024 * 1024 ))
            local slice_size=$left_bytes
            [ "$slice_size" -gt "$max_slice" ] && slice_size=$max_slice
            
            local range_start=$((RANDOM % (slice_size / 2 + 1)))
            local range_end=$((range_start + slice_size - 1))
            
            cmd+=("-H" "Range: bytes=${range_start}-${range_end}" "$url" "-w" "%{size_download}")
        else
            url="${URL_UP_POOL[$((RANDOM % ${#URL_UP_POOL[@]}))]}"
            cmd+=("-F" "file=@$PAYLOAD_FILE" "$url" "-w" "%{size_upload}")
        fi
        
        "${cmd[@]}" > "$TEMP_METRIC"
        local bytes=$(cat "$TEMP_METRIC" 2>/dev/null || echo 0)
        
        if [ "$bytes" -lt 100 ]; then
             retry=$((retry + 1))
             [ "$retry" -ge 10 ] && break
             sleep 1
        else
             retry=0
             cur_bytes=$((cur_bytes + bytes))
        fi
        [ "$task_tag" == "MANUAL" ] && echo -ne "\r进度: $((cur_bytes/1024/1024)) MB / ${actual_target_mb} MB"
    done
    rm -f "$TEMP_METRIC"
    if [ "$task_tag" == "MANUAL" ]; then echo ""; fi
    
    local final_mb=$(awk "BEGIN {printf \"%.2f\", $cur_bytes/1024/1024}")
    if [ "$cur_bytes" -gt 1024 ]; then
        log "INFO" "[$task_tag] 完成 $direction | 实跑 $final_mb MB"
        if [ "$task_tag" != "MANUAL" ]; then 
            local record_ts=$(date +%s)
            
            if [ "$task_tag" == "MAINT" ]; then
                local current_cycle_start=$(get_current_cycle_start)
                record_ts=$((current_cycle_start - 1))
            fi
            
            (
                flock -x 200
                echo "$record_ts ${task_tag}_${direction} $cur_bytes" >> "$STATS_FILE"
            ) 200>"$STATS_LOCK"
        fi
    else
        log "WARN" "[$task_tag] 失败 $direction | 仅跑 $final_mb MB"
    fi
}

check_round_safe() {
    local current_mb=$1
    local mode=$2
    local limit_mb=$((ROUND_LIMIT_GB * 1024))
    [ "$mode" == "MAINT" ] && limit_mb=$((limit_mb * 2))
    if [ "$current_mb" -ge "$limit_mb" ]; then return 1; fi
    return 0
}

entry_auto() {
    init_redirect_logging
    init_config
    
    local h=$(date "+%H" | awk '{print int($0)}')
    if [ "$h" -lt "$ACTIVE_START" ] || [ "$h" -ge "$ACTIVE_END" ]; then exit 0; fi
    
    sleep $((RANDOM % 120))
    
    if ! check_and_lock; then exit 0; fi
    
    if [ $((RANDOM % 100)) -lt "$SKIP_CHANCE" ]; then 
        log "DEBUG" "[AUTO] 随机跳过本次任务"
        exit 0
    fi
    
    local cycle_start=$(get_current_cycle_start)
    if [ "$cycle_start" == "0" ]; then exit 0; fi

    local now=$(date +%s)
    read ad au md mu <<< $(get_db_stats "$cycle_start" "$now")
    
    local dl_done_mb=$(awk "BEGIN {printf \"%.0f\", $ad/1024/1024}")
    local up_done_mb=$(awk "BEGIN {printf \"%.0f\", $au/1024/1024}")
    local total_round_mb=$(awk "BEGIN {printf \"%.0f\", ($ad+$au+$md+$mu)/1024/1024}")
    local dyn_target_dl=$(calc_float "$TARGET_DL" "$TARGET_FLOAT")
    local dyn_target_up=$(calc_float "$TARGET_UP" "$TARGET_FLOAT")
    
    if [ "$dl_done_mb" -lt "$dyn_target_dl" ]; then
        if check_round_safe "$total_round_mb" "AUTO"; then
            local left=$((dyn_target_dl - dl_done_mb))
            local chunk=$(calc_chunk_size "$left" "$CHUNK_MB")
            run_traffic "AUTO" "DL" "$chunk" "$MAX_SPEED_DL"
            total_round_mb=$(awk "BEGIN {printf \"%.0f\", $total_round_mb + $chunk}")
        else
            log "WARN" "[AUTO] 暂停: 触发轮次限额"
        fi
    fi
    
    if [ "$dyn_target_up" -gt 0 ] && [ $((RANDOM % 100)) -lt 60 ] && [ "$up_done_mb" -lt "$dyn_target_up" ]; then
        if check_round_safe "$total_round_mb" "AUTO"; then
            local left=$((dyn_target_up - up_done_mb))
            local chunk=$(calc_chunk_size "$left" "$((CHUNK_MB / 4))")
            run_traffic "AUTO" "UP" "$chunk" "$MAX_SPEED_UP"
        fi
    fi
}

entry_maint() {
    init_redirect_logging
    init_config
    log "INFO" "[MAINT] 维护任务唤醒"
    
    local delay_sec=$(( RANDOM % (MAINT_DELAY_MIN * 60) ))
    log "INFO" "[MAINT] 随机延迟 $delay_sec 秒..."
    sleep $delay_sec
    
    if ! check_and_lock; then
        log "ERROR" "[MAINT] 锁文件占用，跳过维护"
        exit 0
    fi

    local current_cycle_start=$(get_current_cycle_start)
    local last_cycle_start=$((current_cycle_start - 86400))
    
    read ad au md mu <<< $(get_db_stats "$last_cycle_start" "$current_cycle_start")
    local ad_mb=$(awk "BEGIN {printf \"%.0f\", $ad/1024/1024}")
    local au_mb=$(awk "BEGIN {printf \"%.0f\", $au/1024/1024}")
    
    local limit_dl=$(awk "BEGIN {printf \"%.0f\", $TARGET_DL * 0.95}")
    local limit_up=$(awk "BEGIN {printf \"%.0f\", $TARGET_UP * 0.95}")
    
    log "INFO" "[MAINT] 昨日结算: AutoDL=$ad_mb MB (目标 $limit_dl), AutoUP=$au_mb MB"
    local current_round_total=0 
    
    if [ "$ad_mb" -lt "$limit_dl" ]; then
        local gap=$((TARGET_DL - ad_mb))
        log "INFO" "[MAINT] 启动 DL 补量: 缺口 $gap MB"
        while [ "$gap" -gt 0 ]; do
            if ! check_round_safe "$current_round_total" "MAINT"; then break; fi
            local chunk=$(calc_chunk_size "$gap" "$CHUNK_MB")
            run_traffic "MAINT" "DL" "$chunk" "$MAX_SPEED_DL"
            gap=$((gap - chunk))
            current_round_total=$((current_round_total + chunk))
            sleep 2
        done
    else
        log "INFO" "[MAINT] DL 达标，无需补量"
    fi
    
    if [ "$TARGET_UP" -gt 0 ] && [ "$au_mb" -lt "$limit_up" ]; then
        local gap=$((TARGET_UP - au_mb))
        log "INFO" "[MAINT] 启动 UP 补量: 缺口 $gap MB"
        while [ "$gap" -gt 0 ]; do
            if ! check_round_safe "$current_round_total" "MAINT"; then break; fi
            local chunk=$(calc_chunk_size "$gap" "100")
            run_traffic "MAINT" "UP" "$chunk" "$MAX_SPEED_UP"
            gap=$((gap - chunk))
            current_round_total=$((current_round_total + chunk))
            sleep 2
        done
    fi

    local cutoff_ts=$(( $(date +%s) - 604800 ))
    if [ -f "$STATS_FILE" ]; then
        (
            flock -x 200
            awk -v limit="$cutoff_ts" '$1 > limit' "$STATS_FILE" > "${STATS_FILE}.tmp" && mv "${STATS_FILE}.tmp" "$STATS_FILE"
        ) 200>"$STATS_LOCK"
    fi
    
    log "INFO" "[MAINT] 维护结束"
}

setup_cron() {
    install_deps 
    init_config
    local bash_bin=$(which bash)
    [ -z "$bash_bin" ] && bash_bin="/bin/bash"

    echo "正在配置 Cron..."
    read -p "Routine检测间隔 (默认10分钟): " min
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
    echo "*/$min * * * * $bash_bin $SCRIPT_ABS_PATH --auto >/dev/null 2>&1 # [TrafficSpirit_Routine]" >> /tmp/cron.tmp
    echo "$cm $ch * * * $bash_bin $SCRIPT_ABS_PATH --maint >/dev/null 2>&1 # [TrafficSpirit_Maint]" >> /tmp/cron.tmp
    crontab /tmp/cron.tmp && rm -f /tmp/cron.tmp
    echo "Cron 更新完成。"
}

main_menu() {
    install_deps 
    while true; do
        init_config
        local cycle_start=$(get_current_cycle_start)
        local now=$(date +%s)
        
        read c_ad c_au c_md c_mu <<< $(get_db_stats "$cycle_start" "$now")
        local c_total_dl=$(awk "BEGIN {printf \"%.1f\", ($c_ad+$c_md)/1024/1024}")
        local c_total_up=$(awk "BEGIN {printf \"%.1f\", ($c_au+$c_mu)/1024/1024}")
        
        local last_cycle_start=$((cycle_start - 86400))
        read l_ad l_au l_md l_mu <<< $(get_db_stats "$last_cycle_start" "$cycle_start")
        local l_total_dl=$(awk "BEGIN {printf \"%.1f\", ($l_ad+$l_md)/1024/1024}")
        local l_total_up=$(awk "BEGIN {printf \"%.1f\", ($l_au+$l_mu)/1024/1024}")
        local l_maint_dl=$(awk "BEGIN {printf \"%.1f\", $l_md/1024/1024}")
        local l_maint_up=$(awk "BEGIN {printf \"%.1f\", $l_mu/1024/1024}")

        clear
        echo "================================================================================"
        echo "                   VPS Traffic Spirit By Prince v1.0.0"
        echo "================================================================================"
        echo " [配置概览]"
        echo " 目标流量: DL ${TARGET_DL}MB | UP ${TARGET_UP}MB (浮动 ${TARGET_FLOAT}%)"
        echo " 速率限制: DL ${MAX_SPEED_DL}MB/s | UP ${MAX_SPEED_UP}MB/s (浮动 ${SPEED_FLOAT}%)"
        echo " 运行时间: ${ACTIVE_START}:00 - ${ACTIVE_END}:00 (跳过率 ${SKIP_CHANCE}%)"
        echo " 维护设定: ${MAINT_TIME} (延迟0-${MAINT_DELAY_MIN}分) | 切片 ${CHUNK_MB}MB (浮${CHUNK_FLOAT}%) | 熔断 ${ROUND_LIMIT_GB}GB"
        echo "--------------------------------------------------------------------------------"
        echo " [上一轮结算] (截止 ${MAINT_TIME})"
        echo " ├─ 下载: ${l_total_dl} MB (含维护补量: ${l_maint_dl} MB)"
        echo " └─ 上传: ${l_total_up} MB (含维护补量: ${l_maint_up} MB)"
        echo "--------------------------------------------------------------------------------"
        echo " [本轮进行中] (起点 ${MAINT_TIME})"
        echo " ├─ 下载: ${c_total_dl} MB"
        echo " └─ 上传: ${c_total_up} MB"
        echo "================================================================================"
        echo " 1. 修改流量目标 (Target)"
        echo " 2. 修改速率限制 (Speed)"
        echo " 3. 修改时间策略 (Time/Delay)"
        echo " 4. 修改高级参数 (Chunk/Skip/Fuse)"
        echo " 5. 手动执行任务 (Manual)"
        echo " 6. 后台执行任务 (Background)"
        echo " 7. 系统 - 更新Cron任务"
        echo " 8. 系统 - 查看运行日志"
        echo " 9. 系统 - 卸载脚本"
        echo " 0. 退出"
        echo "--------------------------------------------------------------------------------"
        read -p "请选择: " opt
        case "$opt" in
            1) 
                read -p "每日下载目标 (MB): " TARGET_DL
                read -p "每日上传目标 (MB): " TARGET_UP
                read -p "目标随机浮动 (%): " TARGET_FLOAT
                save_config ;;
            2) 
                read -p "最大下载速率 (MB/s): " MAX_SPEED_DL
                read -p "最大上传速率 (MB/s): " MAX_SPEED_UP
                read -p "速率随机浮动 (%): " SPEED_FLOAT
                save_config ;;
            3) 
                read -p "每日运行开始时间 (小时 0-23): " ACTIVE_START
                read -p "每日运行结束时间 (小时 0-23): " ACTIVE_END
                read -p "每日维护/结算时间 (HH:MM): " MAINT_TIME
                read -p "维护启动随机延迟 (0-x分钟): " MAINT_DELAY_MIN
                save_config ;;
            4) 
                read -p "单次运行切片大小 (MB): " CHUNK_MB
                read -p "切片大小浮动 (%): " CHUNK_FLOAT
                read -p "常规任务随机跳过率 (%): " SKIP_CHANCE
                read -p "单轮运行流量熔断 (GB): " ROUND_LIMIT_GB
                save_config ;;
            5) read -p "类型(1.DL 2.UP): " d; t="DL"; [ "$d" == "2" ] && t="UP"; read -p "流量(MB): " m; read -p "限速(MB/s): " s; run_traffic "MANUAL" "$t" "$m" "$s"; read -p "按回车..." ;;
            6) read -p "类型(1.DL 2.UP): " d; t="DL"; [ "$d" == "2" ] && t="UP"; read -p "流量(MB): " m; read -p "限速(MB/s): " s; nohup bash "$0" --manual-bg "$t" "$m" "$s" >/dev/null 2>&1 & echo "已后台运行 PID: $!"; sleep 2 ;;
            7) setup_cron ;;
            8) 
                log_f="$LOG_DIR/traffic_cycle_$(date +%F).log"
                echo "--- 日志: $log_f ---"
                if [ -f "$log_f" ]; then tail -n 20 "$log_f"; else echo "无今日日志"; fi
                read -p "按回车..." ;;
            9) crontab -l | grep -v "TrafficSpirit" | crontab -; rm -rf "$BASE_DIR"; echo "已卸载"; exit 0 ;;
            0) exit 0 ;;
        esac
    done
}

case "$1" in
    --auto) entry_auto ;;
    --maint) entry_maint ;;
    --manual-bg) run_traffic "MANUAL" "$2" "$3" "$4" ;;
    *) init_config; main_menu ;;
esac
