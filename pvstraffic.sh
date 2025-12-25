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
CONF_FILE="$BASE_DIR/config.ini"
LOG_FILE="$BASE_DIR/traffic.log"
LOCK_FILE="$BASE_DIR/run.lock"
PAYLOAD_FILE="$BASE_DIR/100mb.dat"
STATS_FILE="$BASE_DIR/auto_24h.bytes"
TEMP_METRIC="/tmp/ts_metric_$$.tmp"

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

log() {
    local level="$1"
    local msg="$2"
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] [$level] $msg" >> "$LOG_FILE"
    if [[ -t 1 ]]; then echo -e "[$level] $msg"; fi
}

check_env() {
    mkdir -p "$BASE_DIR"
    local missing=0
    for cmd in curl date awk grep flock dd readlink; do
        if ! command -v $cmd >/dev/null 2>&1; then missing=1; break; fi
    done
    if [ "$missing" -eq 1 ]; then
        [ -f /etc/alpine-release ] && apk add --no-cache curl coreutils procps grep util-linux
        [ -f /etc/debian_version ] && apt-get update -qq && apt-get install -y -qq curl coreutils procps util-linux
        [ -f /etc/redhat-release ] && yum install -y -q curl coreutils procps util-linux
    fi
    if [ ! -f "$PAYLOAD_FILE" ] || [ $(stat -c%s "$PAYLOAD_FILE" 2>/dev/null || echo 0) -ne 104857600 ]; then
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l 100M "$PAYLOAD_FILE"
        else
            dd if=/dev/urandom of="$PAYLOAD_FILE" bs=1M count=100 status=none
        fi
    fi
}

init_config() {
    if [ ! -f "$CONF_FILE" ]; then
        cat > "$CONF_FILE" <<EOF
TARGET_DL=1666
TARGET_UP=20
TARGET_FLOAT=10
MAX_SPEED_DL=8
MAX_SPEED_UP=2
SPEED_FLOAT=20
ACTIVE_START=8
ACTIVE_END=22
CHUNK_MB=361
CHUNK_FLOAT=20
SKIP_CHANCE=20
MAINT_TIME="03:30"
EOF
    fi
    source "$CONF_FILE"
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
EOF
}

calc_float() {
    awk -v base="$1" -v pct="$2" -v seed="$RANDOM" 'BEGIN {
        srand(seed); range = base * pct / 100;
        val = base - range + (2 * range * rand());
        if (val < 1) val=1; printf "%.0f", val
    }'
}

get_valid_stats() {
    local now=$(date +%s)
    if [ ! -f "$STATS_FILE" ]; then echo "0 0"; return; fi
    awk -v now="$now" '
    $1 > (now - 86400) {
        if ($2 == "DL") dl += $3;
        if ($2 == "UP") up += $3;
    }
    END { printf "%.0f %.0f", dl, up }' "$STATS_FILE"
}

run_speedtest() {
    local type="$1"
    local duration=10
    local start_time=$(date +%s)
    local end_time=$((start_time + duration))
    local total_bytes=0
    
    echo "正在测速 ($type) - 持续 ${duration} 秒..."
    while [ $(date +%s) -lt $end_time ]; do
        local ua="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
        local cmd=("curl" "-4" "-s" "-k" "-L" "-A" "$ua" "--connect-timeout" "3" "--max-time" "8" "-o" "/dev/null")
        if [ "$type" == "DL" ]; then
            local url="${URL_DL_POOL[$((RANDOM % ${#URL_DL_POOL[@]}))]}"
            [[ "$url" == *"?"* ]] && url="$url&r=$RANDOM" || url="$url?r=$RANDOM"
            cmd+=("$url" "-w" "%{size_download}")
        else
            local url="${URL_UP_POOL[$((RANDOM % ${#URL_UP_POOL[@]}))]}"
            cmd+=("-F" "file=@$PAYLOAD_FILE" "$url" "-w" "%{size_upload}")
        fi
        "${cmd[@]}" > "$TEMP_METRIC"
        local bytes=$(cat "$TEMP_METRIC" 2>/dev/null || echo 0)
        [ "$bytes" -gt 0 ] && total_bytes=$((total_bytes + bytes))
    done
    rm -f "$TEMP_METRIC"
    local real_dur=$(( $(date +%s) - start_time ))
    [ "$real_dur" -lt 1 ] && real_dur=1
    local mbps=$(awk "BEGIN {printf \"%.2f\", $total_bytes * 8 / $real_dur / 1000 / 1000}")
    local mbs=$(awk "BEGIN {printf \"%.2f\", $total_bytes / $real_dur / 1024 / 1024}")
    echo -e "测速结果: \033[32m$mbps Mbps\033[0m ($mbs MB/s)"
}

run_traffic() {
    local tag="$1"
    local type="$2"
    local target_mb="$3"
    local max_speed="$4"
    
    if [ "$tag" != "MANUAL" ]; then sleep $((RANDOM % 30 + 1)); fi
    
    local limit_args=()
    if [ "$max_speed" != "0" ]; then
        local real_kb=$(calc_float "$((max_speed * 1024))" "$SPEED_FLOAT")
        [ "$real_kb" -lt 100 ] && real_kb=100
        limit_args=("--limit-rate" "${real_kb}k")
    fi

    local target_bytes=$(awk "BEGIN {printf \"%.0f\", $target_mb * 1024 * 1024}")
    log "INFO" "任务启动 [$tag] $type 目标:${target_mb}MB"

    local start_ts=$(date +%s)
    local cur_bytes=0
    local retry=0
    
    while [ "$cur_bytes" -lt "$target_bytes" ]; do
        if [ "$tag" != "MANUAL" ] && [ $(( $(date +%s) - start_ts )) -gt 1800 ]; then
            log "WARN" "单次运行超时 (30min)，强制停止释放锁"
            break
        fi

        local ua="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
        local cmd=("curl" "-4" "-s" "-k" "-L" "-A" "$ua" "${limit_args[@]}" "--connect-timeout" "5" "--max-time" "60" "-o" "/dev/null")

        if [ "$type" == "DL" ]; then
            local url="${URL_DL_POOL[$((RANDOM % ${#URL_DL_POOL[@]}))]}"
            [[ "$url" == *"?"* ]] && url="$url&r=$RANDOM" || url="$url?r=$RANDOM"
            cmd+=("$url" "-w" "%{size_download}")
        else
            local url="${URL_UP_POOL[$((RANDOM % ${#URL_UP_POOL[@]}))]}"
            cmd+=("-F" "file=@$PAYLOAD_FILE" "$url" "-w" "%{size_upload}")
        fi

        "${cmd[@]}" > "$TEMP_METRIC"
        local bytes=$(cat "$TEMP_METRIC" 2>/dev/null || echo 0)
        
        if [ "$bytes" -lt 1024 ]; then
             retry=$((retry + 1))
             [ "$retry" -ge 10 ] && break
             sleep $((RANDOM % 3 + 1))
        else
             retry=0
             cur_bytes=$((cur_bytes + bytes))
        fi
        
        [ "$tag" == "MANUAL" ] && echo -ne "\r进度: $((cur_bytes/1024/1024)) MB"
    done
    rm -f "$TEMP_METRIC"
    
    if [ "$tag" == "MANUAL" ]; then echo ""; fi
    
    if [ "$cur_bytes" -gt 1024 ]; then
        log "INFO" "完成 $type $(awk "BEGIN {printf \"%.2f\", $cur_bytes/1024/1024}") MB"
        if [ "$tag" != "MANUAL" ]; then
            echo "$(date +%s) $type $cur_bytes" >> "$STATS_FILE"
        fi
    fi
}

entry_auto() {
    check_env; init_config
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0
    
    sleep $((RANDOM % 300))
    
    local h=$(date "+%H" | awk '{print int($0)}')
    if [ "$h" -lt "$ACTIVE_START" ] || [ "$h" -ge "$ACTIVE_END" ]; then exit 0; fi
    if [ $((RANDOM % 100)) -lt "$SKIP_CHANCE" ]; then log "INFO" "随机跳过"; exit 0; fi
    
    local dyn_dl=$(calc_float "$TARGET_DL" "$TARGET_FLOAT")
    local dyn_up=$(calc_float "$TARGET_UP" "$TARGET_FLOAT")
    
    read c_dl c_up <<< $(get_valid_stats)
    local c_dl_mb=$(awk "BEGIN {printf \"%.0f\", $c_dl/1024/1024}")
    local c_up_mb=$(awk "BEGIN {printf \"%.0f\", $c_up/1024/1024}")
    
    log "INFO" "检查状态: DL:$c_dl_mb/$dyn_dl UP:$c_up_mb/$dyn_up"
    
    if [ "$c_dl_mb" -lt "$dyn_dl" ]; then
        local chunk=$(calc_float "$CHUNK_MB" "$CHUNK_FLOAT")
        local left=$((dyn_dl - c_dl_mb))
        [ "$chunk" -gt "$left" ] && chunk=$left
        [ "$chunk" -lt 10 ] && chunk=10
        run_traffic "AUTO" "DL" "$chunk" "$MAX_SPEED_DL"
    fi
    
    if [ $((RANDOM % 100)) -lt 70 ] && [ "$c_up_mb" -lt "$dyn_up" ]; then
        local chunk=$(calc_float "$((CHUNK_MB/4))" "$CHUNK_FLOAT")
        local left=$((dyn_up - c_up_mb))
        [ "$chunk" -gt "$left" ] && chunk=$left
        [ "$chunk" -lt 5 ] && chunk=5
        run_traffic "AUTO" "UP" "$chunk" "$MAX_SPEED_UP"
    fi
    
    if [ $(wc -l < "$STATS_FILE" 2>/dev/null || echo 0) -gt 2000 ]; then
        local now=$(date +%s)
        awk -v now="$now" '$1 > (now - 86400) {print $0}' "$STATS_FILE" > "$STATS_FILE.tmp" && mv "$STATS_FILE.tmp" "$STATS_FILE"
    fi
}

entry_maint() {
    check_env; init_config
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0
    
    sleep $((RANDOM % 3540 + 60))
    
    read c_dl c_up <<< $(get_valid_stats)
    local c_dl_mb=$(awk "BEGIN {printf \"%.0f\", $c_dl/1024/1024}")
    local c_up_mb=$(awk "BEGIN {printf \"%.0f\", $c_up/1024/1024}")
    
    local t_dl=$(awk "BEGIN {printf \"%.0f\", $TARGET_DL * 0.95}")
    local t_up=$(awk "BEGIN {printf \"%.0f\", $TARGET_UP * 0.95}")
    
    local gap=$((t_dl - c_dl_mb))
    while [ "$gap" -gt 0 ]; do
        local chunk=$(calc_float "$CHUNK_MB" "$CHUNK_FLOAT")
        [ "$chunk" -gt "$gap" ] && chunk=$gap
        run_traffic "MAINT" "DL" "$chunk" "$MAX_SPEED_DL"
        gap=$((gap - chunk))
        sleep 5
    done
    
    gap=$((t_up - c_up_mb))
    while [ "$gap" -gt 0 ]; do
        local chunk=50
        [ "$chunk" -gt "$gap" ] && chunk=$gap
        run_traffic "MAINT" "UP" "$chunk" "$MAX_SPEED_UP"
        gap=$((gap - chunk))
        sleep 5
    done
}

setup_cron() {
    echo "正在配置 Cron..."
    read -p "检测间隔 (分钟, 默认10): " min
    [ -z "$min" ] && min=10
    
    local sys_off=$(unset TZ; date +%z | awk '{h=substr($0,2,2); m=substr($0,4,2); s=h*3600+m*60; if(substr($0,1,1)=="-") s=-s; print s}')
    local mh=$(echo $MAINT_TIME | cut -d: -f1); local mm=$(echo $MAINT_TIME | cut -d: -f2)
    local target=$((mh*3600 + mm*60 + sys_off - 28800))
    while [ "$target" -lt 0 ]; do target=$((target + 86400)); done
    while [ "$target" -ge 86400 ]; do target=$((target - 86400)); done
    local ch=$((target / 3600)); local cm=$(( (target % 3600) / 60 ))
    
    crontab -l 2>/dev/null | grep -v "TrafficSpirit" > /tmp/cron.tmp
    echo "*/$min * * * * /bin/bash $SCRIPT_ABS_PATH --auto >>/dev/null 2>&1 # [TrafficSpirit_Routine]" >> /tmp/cron.tmp
    echo "$cm $ch * * * /bin/bash $SCRIPT_ABS_PATH --maint >>/dev/null 2>&1 # [TrafficSpirit_Maint]" >> /tmp/cron.tmp
    crontab /tmp/cron.tmp && rm -f /tmp/cron.tmp
    echo "配置完成。"
}

main_menu() {
    while true; do
        check_env; init_config
        read c_dl c_up <<< $(get_valid_stats)
        local c_dl_mb=$(awk "BEGIN {printf \"%.1f\", $c_dl/1024/1024}")
        local c_up_mb=$(awk "BEGIN {printf \"%.1f\", $c_up/1024/1024}")
        
        clear
        echo "VPS Traffic Spirit By Prince"
        echo "过去24小时: DL $c_dl_mb/$TARGET_DL MB | UP $c_up_mb/$TARGET_UP MB"
        echo "--------------------------------------------------------"
        echo " 1. 设置 - 每日目标"
        echo " 2. 设置 - 速率限制"
        echo " 3. 设置 - 维护时间/切片/时段"
        echo " 4. 运行 - 手动前台"
        echo " 5. 运行 - 手动后台"
        echo " 6. 工具 - 10s 极速测速"
        echo " 7. 系统 - 更新 Cron (安装)"
        echo " 8. 审计 - 查看日志"
        echo " 9. 卸载 - 删除脚本"
        echo " 0. 退出"
        echo "--------------------------------------------------------"
        read -p "选择: " opt
        case "$opt" in
            1) read -p "DL MB: " TARGET_DL; read -p "UP MB: " TARGET_UP; save_config ;;
            2) read -p "DL MB/s: " MAX_SPEED_DL; read -p "UP MB/s: " MAX_SPEED_UP; save_config ;;
            3) read -p "维护时间: " MAINT_TIME; read -p "起始点: " ACTIVE_START; read -p "结束点: " ACTIVE_END; read -p "切片MB: " CHUNK_MB; save_config ;;
            4) read -p "1.DL 2.UP: " d; t="DL"; [ "$d" == "2" ] && t="UP"; read -p "MB: " m; read -p "MB/s: " s; run_traffic "MANUAL" "$t" "$m" "$s"; read -p "..." ;;
            5) read -p "1.DL 2.UP: " d; t="DL"; [ "$d" == "2" ] && t="UP"; read -p "MB: " m; read -p "MB/s: " s; nohup bash "$0" --manual-bg "$t" "$m" "$s" >/dev/null 2>&1 & echo "PID: $!"; sleep 2 ;;
            6) read -p "1.DL 2.UP: " d; t="DL"; [ "$d" == "2" ] && t="UP"; run_speedtest "$t"; read -p "..." ;;
            7) setup_cron ;;
            8) tail -n 20 "$LOG_FILE"; read -p "..." ;;
            9) crontab -l | grep -v "TrafficSpirit" | crontab -; rm -rf "$BASE_DIR"; exit 0 ;;
            0) exit 0 ;;
        esac
    done
}

case "$1" in
    --auto) entry_auto ;;
    --maint) entry_maint ;;
    --manual-bg) run_traffic "MANUAL" "$2" "$3" "$4" ;;
    *) check_env; main_menu ;;
esac
