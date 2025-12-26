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
TEMP_METRIC="/tmp/ts_metric_$$_${RANDOM}.tmp"

trap 'rm -f "$TEMP_METRIC"; rm -rf "$LOCK_DIR"' EXIT INT TERM

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
    if [ ! -d "$BASE_DIR" ]; then mkdir -p "$BASE_DIR"; fi
    if [ ! -d "$LOG_DIR" ]; then mkdir -p "$LOG_DIR"; fi
    
    local today=$(date +%F)
    local log_file="$LOG_DIR/traffic_cycle_${today}.log"
    
    # 将脚本的标准输出和错误输出重定向到日志文件
    exec 1>>"$log_file"
    exec 2>&1
}

init_base() {
    if [ ! -d "$BASE_DIR" ]; then mkdir -p "$BASE_DIR"; fi
    if [ ! -d "$LOG_DIR" ]; then mkdir -p "$LOG_DIR"; fi
    
    if ! command -v curl >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1; then
        if [ -f /etc/alpine-release ]; then
            apk update && apk add --no-cache curl coreutils procps grep util-linux findutils cronie bash
            rc-service crond start 2>/dev/null || systemctl start crond 2>/dev/null
        elif [ -f /etc/debian_version ]; then
            apt-get update -qq && apt-get install -y -qq curl coreutils procps util-linux findutils cron
        elif [ -f /etc/redhat-release ]; then
            yum install -y -q curl coreutils procps util-linux findutils cronie
        fi
    fi
    find "$LOG_DIR" -name "traffic_cycle_*.log" -type f -mtime +7 -delete 2>/dev/null
}

init_config() {
    init_base
    if [ -f "$CONF_FILE" ]; then source "$CONF_FILE"; fi
    
    if [ -z "$TARGET_DL" ]; then TARGET_DL=1000; fi
    if [ -z "$TARGET_UP" ]; then TARGET_UP=0; fi
    if [ -z "$TARGET_FLOAT" ]; then TARGET_FLOAT=10; fi
    if [ -z "$MAX_SPEED_DL" ]; then MAX_SPEED_DL=10; fi
    if [ -z "$MAX_SPEED_UP" ]; then MAX_SPEED_UP=5; fi
    if [ -z "$SPEED_FLOAT" ]; then SPEED_FLOAT=15; fi
    if [ -z "$ACTIVE_START" ]; then ACTIVE_START=7; fi
    if [ -z "$ACTIVE_END" ]; then ACTIVE_END=23; fi
    if [ -z "$CHUNK_MB" ]; then CHUNK_MB=256; fi
    if [ -z "$CHUNK_FLOAT" ]; then CHUNK_FLOAT=15; fi
    if [ -z "$SKIP_CHANCE" ]; then SKIP_CHANCE=15; fi
    if [ -z "$MAINT_TIME" ]; then MAINT_TIME="04:00"; fi
    if [ -z "$CRON_DELAY_MIN" ]; then CRON_DELAY_MIN=15; fi
    if [ -z "$ROUND_LIMIT_GB" ]; then ROUND_LIMIT_GB=2; fi

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

get_ts() { date -d "$1" +%s 2>/dev/null; }

get_current_cycle_start() {
    local now=$(date +%s)
    local today_maint_str="$(date +%Y-%m-%d) $MAINT_TIME:00"
    local today_maint_ts=$(get_ts "$today_maint_str")
    if [ -z "$today_maint_ts" ]; then echo "0"; return; fi
    if [ "$now" -ge "$today_maint_ts" ]; then echo "$today_maint_ts"; else echo $((today_maint_ts - 86400)); fi
}

log() {
    local level="$1"
    local msg="$2"
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] [$level] $msg"
}

# 核心修复：自动解除陈旧锁
check_and_lock() {
    if [ -d "$LOCK_DIR" ]; then
        # 查找超过60分钟的锁目录并删除 (Self-Healing)
        if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
            log "WARN" "检测到陈旧死锁 (>60min)，正在强制清除..."
            rm -rf "$LOCK_DIR"
        fi
    fi
    
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then return 1; fi
    return 0
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
    if [ ! -f "$PAYLOAD_FILE" ]; then
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l 50M "$PAYLOAD_FILE" >/dev/null 2>&1
        else
            dd if=/dev/urandom of="$PAYLOAD_FILE" bs=1M count=50 status=none >/dev/null 2>&1
        fi
    fi
    [ -s "$PAYLOAD_FILE" ] && return 0 || return 1
}

run_traffic() {
    local task_tag="$1"
    local direction="$2"
    local target_mb="$3"
    local max_speed="$4"
    
    if [ "$direction" == "UP" ] && ! prepare_payload; then
        log "WARN" "[$task_tag] 跳过上传: Payload 生成失败"
        return
    fi
    
    if [ "$task_tag" != "MANUAL" ]; then sleep $((RANDOM % 5)); fi
    
    local limit_args=()
    local real_kb=0
    if [ "$max_speed" != "0" ]; then
        real_kb=$(calc_float "$((max_speed * 1024))" "$SPEED_FLOAT")
        [ "$real_kb" -lt 100 ] && real_kb=100
        limit_args=("--limit-rate" "${real_kb}k")
    fi
    
    local actual_target_mb=$(calc_float "$target_mb" "$CHUNK_FLOAT")
    local target_bytes=$(awk "BEGIN {printf \"%.0f\", $actual_target_mb * 1024 * 1024}")
    log "INFO" "[$task_tag] 启动 [$direction] 计划: ${actual_target_mb}MB"
    
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
            cmd+=("-H" "Range: bytes=$((RANDOM % 100000))-$((slice_size))" "$url" "-w" "%{size_download}")
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
            
            # 核心逻辑：如果是维护补量任务，时间戳强制为周期结束前1秒
            # 这样这部分流量会永久计入"昨天"的账单
            if [ "$task_tag" == "MAINT" ]; then
                local current_cycle_start=$(get_current_cycle_start)
                record_ts=$((current_cycle_start - 1))
            fi
            
            echo "$record_ts ${task_tag}_${direction} $cur_bytes" >> "$STATS_FILE"
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
    
    if ! check_and_lock; then
        # 被锁住时不需要输出日志污染文件，直接静默退出
        exit 0
    fi
    
    local h=$(date "+%H" | awk '{print int($0)}')
    if [ "$h" -lt "$ACTIVE_START" ] || [ "$h" -ge "$ACTIVE_END" ]; then 
        rm -rf "$LOCK_DIR"; exit 0
    fi
    
    if [ $((RANDOM % 100)) -lt "$SKIP_CHANCE" ]; then 
        log "DEBUG" "[AUTO] 随机跳过"
        rm -rf "$LOCK_DIR"; exit 0
    fi
    
    local cycle_start=$(get_current_cycle_start)
    if [ "$cycle_start" == "0" ]; then rm -rf "$LOCK_DIR"; exit 0; fi

    local now=$(date +%s)
    read ad au md mu <<< $(get_db_stats "$cycle_start" "$now")
    
    local dl_done_mb=$(awk "BEGIN {printf \"%.0f\", $ad/1024/1024}")
    local up_done_mb=$(awk "BEGIN {printf \"%.0f\", $au/1024/1024}")
    local total_round_mb=$(awk "BEGIN {printf \"%.0f\", ($ad+$au+$md+$mu)/1024/1024}")
    local dyn_target_dl=$(calc_float "$TARGET_DL" "$TARGET_FLOAT")
    local dyn_target_up=$(calc_float "$TARGET_UP" "$TARGET_FLOAT")
    
    if [ "$dl_done_mb" -lt "$dyn_target_dl" ]; then
        if check_round_safe "$total_round_mb" "AUTO"; then
            local chunk=$CHUNK_MB
            local left=$((dyn_target_dl - dl_done_mb))
            [ "$chunk" -gt "$left" ] && chunk=$left
            run_traffic "AUTO" "DL" "$chunk" "$MAX_SPEED_DL"
            total_round_mb=$(awk "BEGIN {printf \"%.0f\", $total_round_mb + $chunk}")
        else
            log "WARN" "[AUTO] 暂停: 触发轮次限额"
        fi
    fi
    
    if [ "$dyn_target_up" -gt 0 ] && [ $((RANDOM % 100)) -lt 60 ] && [ "$up_done_mb" -lt "$dyn_target_up" ]; then
        if check_round_safe "$total_round_mb" "AUTO"; then
            local chunk=$((CHUNK_MB / 4))
            local left=$((dyn_target_up - up_done_mb))
            [ "$chunk" -gt "$left" ] && chunk=$left
            run_traffic "AUTO" "UP" "$chunk" "$MAX_SPEED_UP"
        fi
    fi

    rm -rf "$LOCK_DIR"
}

entry_maint() {
    init_redirect_logging
    init_config
    log "INFO" "[MAINT] 维护任务唤醒"
    
    if ! check_and_lock; then
        log "ERROR" "[MAINT] 锁文件占用，跳过维护"
        exit 0
    fi

    local delay_sec=$(( RANDOM % (CRON_DELAY_MIN * 60) ))
    log "INFO" "[MAINT] 随机延迟 $delay_sec 秒..."
    sleep $delay_sec
    
    local current_cycle_start=$(get_current_cycle_start)
    # 计算上一周期：当前周期起点的前24小时 ~ 当前周期起点
    local last_cycle_start=$((current_cycle_start - 86400))
    
    read ad au md mu <<< $(get_db_stats "$last_cycle_start" "$current_cycle_start")
    local ad_mb=$(awk "BEGIN {printf \"%.0f\", $ad/1024/1024}")
    local au_mb=$(awk "BEGIN {printf \"%.0f\", $au/1024/1024}")
    
    # 设定补量阈值 (95% 达标率)
    local limit_dl=$(awk "BEGIN {printf \"%.0f\", $TARGET_DL * 0.95}")
    local limit_up=$(awk "BEGIN {printf \"%.0f\", $TARGET_UP * 0.95}")
    
    log "INFO" "[MAINT] 昨日结算: AutoDL=$ad_mb MB (目标 $limit_dl), AutoUP=$au_mb MB"
    local current_round_total=0 
    
    # 流量补齐逻辑
    if [ "$ad_mb" -lt "$limit_dl" ]; then
        local gap=$((TARGET_DL - ad_mb))
        log "INFO" "[MAINT] 启动 DL 补量: 缺口 $gap MB"
        while [ "$gap" -gt 0 ]; do
            if ! check_round_safe "$current_round_total" "MAINT"; then break; fi
            local chunk=$CHUNK_MB
            [ "$chunk" -gt "$gap" ] && chunk=$gap
            
            # 这里调用 run_traffic 时，内部会自动将时间戳改写为 current_cycle_start - 1
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
            local chunk=100
            [ "$chunk" -gt "$gap" ] && chunk=$gap
            run_traffic "MAINT" "UP" "$chunk" "$MAX_SPEED_UP"
            gap=$((gap - chunk))
            current_round_total=$((current_round_total + chunk))
            sleep 2
        done
    fi

    # 清理30天前的旧数据
    local cutoff_ts=$(( $(date +%s) - 2592000 ))
    if [ -f "$STATS_FILE" ]; then
        awk -v limit="$cutoff_ts" '$1 > limit' "$STATS_FILE" > "${STATS_FILE}.tmp" && mv "${STATS_FILE}.tmp" "$STATS_FILE"
    fi
    
    log "INFO" "[MAINT] 维护结束"
    rm -rf "$LOCK_DIR"
}

setup_cron() {
    init_config
    local bash_bin=$(which bash)
    [ -z "$bash_bin" ] && bash_bin="/bin/bash"

    echo "正在配置 Cron..."
    read -p "检测间隔 (分钟, 默认10): " min
    [ -z "$min" ] && min=10
    
    # 计算 Cron 时间格式，自动处理时区
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
    while true; do
        init_config
        local cycle_start=$(get_current_cycle_start)
        local now=$(date +%s)
        # 实时数据 (今天)
        read c_ad c_au c_md c_mu <<< $(get_db_stats "$cycle_start" "$now")
        local c_total_dl=$(awk "BEGIN {printf \"%.1f\", ($c_ad+$c_md)/1024/1024}")
        local c_total_up=$(awk "BEGIN {printf \"%.1f\", ($c_au+$c_mu)/1024/1024}")
        
        # 历史数据 (昨天)
        local last_cycle_start=$((cycle_start - 86400))
        read l_ad l_au l_md l_mu <<< $(get_db_stats "$last_cycle_start" "$cycle_start")
        local l_total_dl=$(awk "BEGIN {printf \"%.1f\", ($l_ad+$l_md)/1024/1024}")
        local l_total_up=$(awk "BEGIN {printf \"%.1f\", ($l_au+$l_mu)/1024/1024}")
        local l_maint_dl=$(awk "BEGIN {printf \"%.1f\", $l_md/1024/1024}")
        
        clear
        echo "================================================================"
        echo "             VPS Traffic Spirit By Prince v1.0.0"
        echo "================================================================"
        echo " [运行状态]"
        echo " 每日目标: DL $TARGET_DL MB | UP $TARGET_UP MB (浮动 $TARGET_FLOAT%)"
        echo " 运行时间: $ACTIVE_START:00 - $ACTIVE_END:59 | 维护: $MAINT_TIME"
        echo "----------------------------------------------------------------"
        echo " [昨日结算] (已归档)"
        echo " 总计下载: $l_total_dl MB (其中维护补量: $l_maint_dl MB)"
        echo " 总计上传: $l_total_up MB"
        echo "----------------------------------------------------------------"
        echo " [今日实时] (进行中)"
        echo " 累计下载: $c_total_dl MB"
        echo " 累计上传: $c_total_up MB"
        echo "================================================================"
        echo " 1. 设置 - 流量目标"
        echo " 2. 设置 - 速率限制"
        echo " 3. 设置 - 运行策略"
        echo " 4. 运行 - 手动执行"
        echo " 5. 运行 - 后台执行"
        echo " 6. 工具 - 网络测速"
        echo " 7. 系统 - 更新 Cron"
        echo " 8. 审计 - 查看日志"
        echo " 9. 卸载 - 删除脚本"
        echo " 0. 退出"
        echo "----------------------------------------------------------------"
        read -p "选择: " opt
        case "$opt" in
            1) read -p "下载目标(MB): " TARGET_DL; read -p "上传目标(MB): " TARGET_UP; read -p "目标浮动(%): " TARGET_FLOAT; save_config ;;
            2) read -p "下载限速(MB/s): " MAX_SPEED_DL; read -p "上传限速(MB/s): " MAX_SPEED_UP; read -p "速率浮动(%): " SPEED_FLOAT; save_config ;;
            3) read -p "维护时间(HH:MM): " MAINT_TIME; read -p "运行起点(0-23): " ACTIVE_START; read -p "运行终点(0-23): " ACTIVE_END; read -p "单次切片(MB): " CHUNK_MB; read -p "每轮限额(GB): " ROUND_LIMIT_GB; save_config ;;
            4) read -p "1.DL 2.UP: " d; t="DL"; [ "$d" == "2" ] && t="UP"; read -p "MB: " m; read -p "MB/s: " s; run_traffic "MANUAL" "$t" "$m" "$s"; read -p "..." ;;
            5) read -p "1.DL 2.UP: " d; t="DL"; [ "$d" == "2" ] && t="UP"; read -p "MB: " m; read -p "MB/s: " s; nohup bash "$0" --manual-bg "$t" "$m" "$s" >/dev/null 2>&1 & echo "PID: $!"; sleep 2 ;;
            6) read -p "1.DL 2.UP: " d; t="DL"; [ "$d" == "2" ] && t="UP"; run_traffic "MANUAL" "$t" "500" "0"; read -p "..." ;;
            7) setup_cron ;;
            8) 
                log_f="$LOG_DIR/traffic_cycle_$(date +%F).log"
                echo "--- 最新日志 ($log_f) ---"
                if [ -f "$log_f" ]; then tail -n 20 "$log_f"; else echo "今日暂无日志"; fi
                read -p "按回车返回..." ;;
            9) crontab -l | grep -v "TrafficSpirit" | crontab -; rm -rf "$BASE_DIR"; echo "卸载完成"; exit 0 ;;
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
