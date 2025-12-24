#!/bin/bash
# ==============================================================================
# VPS Traffic Spirit v1.0.0
# Author: Prince 2025.12
# ==============================================================================

export TZ='Asia/Shanghai'
BASE_DIR="$(cd "$(dirname "$0")" && pwd)/TrafficSpirit_Data"
CONF_FILE="$BASE_DIR/config.ini"
LOG_FILE="$BASE_DIR/traffic.log"
LOCK_FILE="$BASE_DIR/run.lock"
PAYLOAD_FILE="$BASE_DIR/100mb.dat"
TEMP_METRIC="/tmp/ts_metric_$$.tmp"

# 下载源：精选全球大带宽节点
readonly URL_DL_POOL=(
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.14.tar.xz"
    "https://releases.ubuntu.com/22.04.3/ubuntu-22.04.3-desktop-amd64.iso"
    "https://nbg1-speed.hetzner.com/10GB.bin"
    "https://fsn1-speed.hetzner.com/10GB.bin"
    "https://hel1-speed.hetzner.com/10GB.bin"
    "https://ash-speed.hetzner.com/10GB.bin"
    "https://speedtest.tele2.net/10GB.zip"
    "https://lg-sea.fdcservers.net/10GBtest.zip"
    "http://speedtest-sfo3.digitalocean.com/10gb.test"
    "http://speedtest-nyc1.digitalocean.com/10gb.test"
    "http://speedtest.london.linode.com/100MB-london.bin"
)

# [关键] 上传源：扩充兼容性最好的 upload.php 接口
# 这些接口通常接受 multipart/form-data，即使报错也会先接收数据
readonly URL_UP_POOL=(
    "http://speedtest.tele2.net/upload.php"
    "http://speedtest.klu.net.pl/upload.php"
    "http://speedtest.cd.estpak.ee/upload.php"
    "http://speedtest.kenc.net/upload.php"
    "http://speedtest.uztelecom.uz/upload.php"
    "http://speedtest.beotel.rs/upload.php"
    "https://bouygues.testdebit.info/ul/upload.php"
    "https://scaleway.testdebit.info/ul/upload.php"
    "http://speedtest-nyc1.digitalocean.com/upload"
    "http://speedtest.dallas.linode.com/empty.php"
)

# 随机 UA
readonly UA_POOL=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
)

check_env() {
    local missing=0
    for cmd in curl date awk grep sed head tail cut flock dd; do
        if ! command -v $cmd >/dev/null 2>&1; then missing=1; break; fi
    done
    if [ "$missing" -eq 1 ]; then
        if [ -f /etc/alpine-release ]; then apk add --no-cache curl coreutils procps grep util-linux >/dev/null 2>&1; fi
        if [ -f /etc/debian_version ]; then apt-get update -qq && apt-get install -y -qq curl coreutils procps util-linux >/dev/null 2>&1; fi
        if [ -f /etc/redhat-release ]; then yum install -y -q curl coreutils procps util-linux >/dev/null 2>&1; fi
    fi
    mkdir -p "$BASE_DIR"
    
    # [关键] 生成 100MB 实体文件用于上传
    if [ ! -f "$PAYLOAD_FILE" ] || [ $(stat -c%s "$PAYLOAD_FILE" 2>/dev/null || echo 0) -ne 104857600 ]; then
        echo "正在初始化 100MB 数据文件 (仅需一次)..."
        # 优先使用 fallocate (瞬间完成)，失败则用 dd
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l 100M "$PAYLOAD_FILE"
        else
            dd if=/dev/urandom of="$PAYLOAD_FILE" bs=1M count=100 status=none
        fi
        echo "初始化完成。"
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
        srand(seed);
        range = base * pct / 100;
        val = base - range + (2 * range * rand());
        if (val < 1) val=1;
        printf "%.0f", val
    }'
}

get_cycle_start_time() {
    local now=$(date +%s)
    local today_maint_str="$(date +%Y-%m-%d) $MAINT_TIME:00"
    local today_maint_ts=$(date -d "$today_maint_str" +%s)
    if [ "$now" -lt "$today_maint_ts" ]; then
        echo $((today_maint_ts - 86400))
    else
        echo "$today_maint_ts"
    fi
}

get_stats() {
    local tag_filter="$1"
    local start_ts=$(get_cycle_start_time)
    if [ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE") -gt 5000 ]; then
        local tmp="$LOG_FILE.tmp"
        tail -n 2000 "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
    fi
    awk -v start="$start_ts" -v filter="$tag_filter" -F'|' '
    BEGIN { dl=0; up=0 }
    /^\[DATA\]/ {
        ts=$2; tag=$3; type=$4; bytes=$5;
        if (ts >= start) {
            if (filter == "ALL" || tag == filter) {
                if(type=="DL") dl+=bytes;
                if(type=="UP") up+=bytes;
            }
        }
    }
    END { printf "%.0f %.0f", dl, up }' "$LOG_FILE" 2>/dev/null || echo "0 0"
}

log() {
    local level="$1"
    local tag="$2"
    local msg="$3"
    local ts_unix=$(date +%s)
    local ts_str=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$ts_str] [$level] $msg" >> "$LOG_FILE"
    if [ "$level" == "DATA" ]; then
        echo "[DATA]|$ts_unix|$tag|$msg" >> "$LOG_FILE"
    fi
}

run_speedtest() {
    local type="$1"
    local duration=10
    local ua="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
    
    echo "正在测速 ($type) - 持续 $duration 秒..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + duration))
    local total_bytes=0
    local loop_count=0
    
    while [ $(date +%s) -lt $end_time ]; do
        local url=""
        local cmd_base=("curl" "-4" "-s" "-k" "-L" "-A" "$ua" "--connect-timeout" "3" "--max-time" "8" "-o" "/dev/null")
        
        if [ "$type" == "DL" ]; then
            url="${URL_DL_POOL[$((RANDOM % ${#URL_DL_POOL[@]}))]}"
            if [[ "$url" == *"?"* ]]; then url="$url&r=$RANDOM"; else url="$url?r=$RANDOM"; fi
            cmd_base+=("$url" "-w" "%{size_download}")
        else
            url="${URL_UP_POOL[$((RANDOM % ${#URL_UP_POOL[@]}))]}"
            # 使用表单上传，兼容性最好。指定 file 字段为 100MB 文件
            cmd_base+=("-F" "file=@$PAYLOAD_FILE" "$url" "-w" "%{size_upload}")
        fi

        "${cmd_base[@]}" > "$TEMP_METRIC"
        
        local bytes=0
        if [ -s "$TEMP_METRIC" ]; then
            bytes=$(cat "$TEMP_METRIC")
        fi
        
        # 只要字节数大于0，就计入流量（不管HTTP状态码）
        if [ "${bytes:-0}" -gt 0 ]; then
            total_bytes=$((total_bytes + bytes))
            loop_count=$((loop_count + 1))
        fi
    done
    rm -f "$TEMP_METRIC"
    
    local real_duration=$(( $(date +%s) - start_time ))
    [ "$real_duration" -lt 1 ] && real_duration=1
    
    local mbps=$(awk "BEGIN {printf \"%.2f\", $total_bytes * 8 / $real_duration / 1000 / 1000}")
    local mbs=$(awk "BEGIN {printf \"%.2f\", $total_bytes / $real_duration / 1024 / 1024}")
    local total_mb=$(awk "BEGIN {printf \"%.1f\", $total_bytes / 1024 / 1024}")
    
    echo -e "测速结果: \033[32m$mbps Mbps\033[0m ($mbs MB/s) | 消耗: ${total_mb}MB | 循环: $loop_count"
}

# ------------------------------------------------------------------------------
# 修复后的跑流量函数：利用 100MB 文件和重试机制
# ------------------------------------------------------------------------------
run_traffic() {
    local tag="$1"
    local type="$2"
    local target_mb="$3"
    local max_speed="$4"
    
    if [ "$tag" != "MANUAL" ]; then sleep $((RANDOM % 30 + 1)); fi
    
    # 速率计算
    local limit_args=()
    local real_limit_kb=0
    local spd_display="无限制"
    if [ "$max_speed" != "0" ]; then
        local limit_kb=$(awk "BEGIN {printf \"%.0f\", $max_speed * 1024}")
        real_limit_kb=$(awk -v base="$limit_kb" -v pct="$SPEED_FLOAT" -v seed="$RANDOM" 'BEGIN {
            srand(seed);
            drop = base * pct / 100 * rand();
            printf "%.0f", base - drop
        }')
        [ "$real_limit_kb" -lt 100 ] && real_limit_kb=100
        limit_args=("--limit-rate" "${real_limit_kb}k")
        spd_display="${real_limit_kb} KB/s"
    fi

    local target_bytes=$(awk "BEGIN {printf \"%.0f\", $target_mb * 1024 * 1024}")
    
    if [ "$tag" == "MANUAL" ]; then
        echo -e "任务: $type | 目标: ${target_mb}MB | 限速: $spd_display"
    fi

    local start_ts=$(date +%s)
    local cur_bytes=0
    local retry_count=0
    
    while [ "$cur_bytes" -lt "$target_bytes" ]; do
        # 自动模式超时保护 (45分钟)
        if [ "$tag" != "MANUAL" ] && [ $(( $(date +%s) - start_ts )) -gt 2700 ]; then break; fi

        local ua="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
        local url=""
        local cmd_args=()
        
        # 基础 Curl：超时设置放宽到 60s 以便传完大文件
        cmd_args=("curl" "-4" "-s" "-k" "-L" "-A" "$ua" "${limit_args[@]}" "--connect-timeout" "5" "--max-time" "60" "-o" "/dev/null")

        if [ "$type" == "DL" ]; then
            url="${URL_DL_POOL[$((RANDOM % ${#URL_DL_POOL[@]}))]}"
            if [[ "$url" == *"?"* ]]; then url="$url&r=$RANDOM"; else url="$url?r=$RANDOM"; fi
            cmd_args+=("$url" "-w" "%{size_download}")
        else
            url="${URL_UP_POOL[$((RANDOM % ${#URL_UP_POOL[@]}))]}"
            cmd_args+=("-F" "file=@$PAYLOAD_FILE" "$url" "-w" "%{size_upload}")
        fi

        "${cmd_args[@]}" > "$TEMP_METRIC"
        
        local this_bytes=0
        if [ -s "$TEMP_METRIC" ]; then
            this_bytes=$(cat "$TEMP_METRIC")
        fi
        
        # 只要有流量产生就视为成功
        if [ "${this_bytes:-0}" -lt 1024 ]; then
             retry_count=$((retry_count + 1))
             if [ "$retry_count" -ge 10 ]; then
                 if [ "$tag" == "MANUAL" ]; then echo -e "\n错误: 连续连接失败，请检查网络或更换节点。"; fi
                 break
             fi
             sleep $((RANDOM % 3 + 1))
        else
             retry_count=0
             cur_bytes=$((cur_bytes + this_bytes))
        fi
        
        if [ "$tag" == "MANUAL" ]; then
             local pct=$((cur_bytes * 100 / target_bytes))
             [ "$pct" -gt 100 ] && pct=100
             echo -ne "\r进度: $pct% | 已跑: $((cur_bytes/1024/1024)) MB "
        fi
    done
    
    rm -f "$TEMP_METRIC"
    
    if [ "$tag" == "MANUAL" ]; then echo ""; fi
    
    local total_time=$(awk "BEGIN {print $(date +%s) - $start_ts}")
    if [ "${cur_bytes:-0}" -gt 1024 ]; then
        log "DATA" "$tag" "$type|$cur_bytes|$total_time|100MB_FILE"
        if [ "$tag" == "MANUAL" ]; then
            echo -e "完成: $(awk "BEGIN {printf \"%.2f\", $cur_bytes/1024/1024}") MB (耗时 ${total_time}s)"
        fi
    else
        [ "$tag" == "MANUAL" ] && echo "失败或流量过小"
    fi
}

entry_auto() {
    check_env; init_config
    sleep $((RANDOM % 300))
    local bj_h=$(date "+%H" | awk '{print int($0)}')
    if [ "$bj_h" -lt "$ACTIVE_START" ] || [ "$bj_h" -ge "$ACTIVE_END" ]; then exit 0; fi
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0
    if [ $((RANDOM % 100)) -lt "$SKIP_CHANCE" ]; then
        log "INFO" "AUTO" "SKIP_DICE"
        exit 0
    fi
    local dyn_dl=$(calc_float "$TARGET_DL" "$TARGET_FLOAT")
    local dyn_up=$(calc_float "$TARGET_UP" "$TARGET_FLOAT")
    read c_dl c_up <<< $(get_stats "AUTO")
    local c_dl_mb=$(awk "BEGIN {printf \"%.0f\", $c_dl/1024/1024}")
    local c_up_mb=$(awk "BEGIN {printf \"%.0f\", $c_up/1024/1024}")
    if [ "$c_dl_mb" -lt "$dyn_dl" ]; then
        local chunk=$(calc_float "$CHUNK_MB" "$CHUNK_FLOAT")
        local left=$((dyn_dl - c_dl_mb))
        [ "$chunk" -gt "$left" ] && chunk=$left
        [ "$chunk" -lt 10 ] && chunk=10
        run_traffic "AUTO" "DL" "$chunk" "$MAX_SPEED_DL"
    fi
    if [ $((RANDOM % 100)) -lt 70 ] && [ "$c_up_mb" -lt "$dyn_up" ]; then
        local chunk_up=$(calc_float "$((CHUNK_MB/4))" "$CHUNK_FLOAT")
        local left=$((dyn_up - c_up_mb))
        [ "$chunk_up" -gt "$left" ] && chunk_up=$left
        [ "$chunk_up" -lt 5 ] && chunk_up=5
        run_traffic "AUTO" "UP" "$chunk_up" "$MAX_SPEED_UP"
    fi
}

entry_maint() {
    check_env; init_config
    local wait_s=$((RANDOM % 3540 + 60))
    log "INFO" "MAINT" "WAIT ${wait_s}s"
    sleep $wait_s
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0
    read c_dl c_up <<< $(get_stats "AUTO")
    local c_dl_mb=$(awk "BEGIN {printf \"%.0f\", $c_dl/1024/1024}")
    local c_up_mb=$(awk "BEGIN {printf \"%.0f\", $c_up/1024/1024}")
    
    local thresh_dl=$(awk "BEGIN {printf \"%.0f\", $TARGET_DL * 0.95}")
    local thresh_up=$(awk "BEGIN {printf \"%.0f\", $TARGET_UP * 0.95}")
    log "INFO" "MAINT" "CHECK DL:$c_dl_mb/$thresh_dl UP:$c_up_mb/$thresh_up"
    local gap_dl=$((thresh_dl - c_dl_mb))
    while [ "$gap_dl" -gt 0 ]; do
        local chunk=$(calc_float "$CHUNK_MB" "$CHUNK_FLOAT")
        [ "$chunk" -gt "$gap_dl" ] && chunk=$gap_dl
        run_traffic "MAINT" "DL" "$chunk" "$MAX_SPEED_DL"
        gap_dl=$((gap_dl - chunk))
        sleep 5
    done
    local gap_up=$((thresh_up - c_up_mb))
    while [ "$gap_up" -gt 0 ]; do
        local chunk=50
        [ "$chunk" -gt "$gap_up" ] && chunk=$gap_up
        run_traffic "MAINT" "UP" "$chunk" "$MAX_SPEED_UP"
        gap_up=$((gap_up - chunk))
        sleep 5
    done
    log "INFO" "MAINT" "DONE"
}

setup_cron() {
    echo -e "\n[Cron 配置]"
    read -p "日常检测间隔 (分钟, 默认10): " min
    [ -z "$min" ] && min=10
    local sys_offset=$(unset TZ; date +%z | awk '{h=substr($0,2,2); m=substr($0,4,2); s=h*3600+m*60; if(substr($0,1,1)=="-") s=-s; print s}')
    local maint_h=$(echo $MAINT_TIME | cut -d: -f1)
    local maint_m=$(echo $MAINT_TIME | cut -d: -f2)
    local target_bj_sec=$((maint_h * 3600 + maint_m * 60))
    local diff=$((sys_offset - 28800))
    local local_target=$((target_bj_sec + diff))
    
    while [ "$local_target" -lt 0 ]; do local_target=$((local_target + 86400)); done
    while [ "$local_target" -ge 86400 ]; do local_target=$((local_target - 86400)); done
    
    local cron_h=$((local_target / 3600))
    local cron_m=$(( (local_target % 3600) / 60 ))
    crontab -l 2>/dev/null | grep -v "TrafficSpirit" > /tmp/cron.tmp
    echo "*/$min * * * * /bin/bash $0 --auto >>/dev/null 2>&1 # [TrafficSpirit_Routine]" >> /tmp/cron.tmp
    echo "$cron_m $cron_h * * * /bin/bash $0 --maint >>/dev/null 2>&1 # [TrafficSpirit_Maint]" >> /tmp/cron.tmp
    crontab /tmp/cron.tmp
    rm -f /tmp/cron.tmp
    echo "日常: */$min 分 | 维护: 本地 $cron_h:$cron_m (BJ $MAINT_TIME)"
    sleep 2
}

main_menu() {
    while true; do
        check_env; init_config
        read c_dl c_up <<< $(get_stats "AUTO")
        read t_dl t_up <<< $(get_stats "ALL")
        
        local c_dl_mb=$(awk "BEGIN {printf \"%.1f\", $c_dl/1024/1024}")
        local c_up_mb=$(awk "BEGIN {printf \"%.1f\", $c_up/1024/1024}")
        local t_dl_mb=$(awk "BEGIN {printf \"%.1f\", $t_dl/1024/1024}")
        local t_up_mb=$(awk "BEGIN {printf \"%.1f\", $t_up/1024/1024}")
        clear
        echo "========================================================"
        echo "   VPS Traffic Spirit By Prince"
        echo "   北京时间: $(date "+%Y-%m-%d %H:%M:%S")"
        echo "   当前周期: $(date -d @$(get_cycle_start_time) "+%m-%d %H:%M") 至 明日 $(echo $MAINT_TIME)"
        echo "========================================================"
        echo " [进度] 自动任务: DL $c_dl_mb/$TARGET_DL MB | UP $c_up_mb/$TARGET_UP MB"
        echo " [总览] 物理消耗: DL $t_dl_mb MB | UP $t_up_mb MB"
        echo "--------------------------------------------------------"
        echo " 1. 设置 - 每日目标"
        echo " 2. 设置 - 速率限制"
        echo " 3. 设置 - 维护时间/切片/时段"
        echo " 4. 运行 - 手动前台"
        echo " 5. 运行 - 手动后台"
        echo " 6. 工具 - 10s极速测速"
        echo " 7. 系统 - 更新 Cron"
        echo " 8. 审计 - 查看日志"
        echo " 9. 卸载 - 删除脚本"
        echo " 0. 退出"
        echo "--------------------------------------------------------"
        read -p "选择: " opt
        case "$opt" in
            1) read -p "DL MB: " TARGET_DL; read -p "UP MB: " TARGET_UP; save_config ;;
            2) read -p "DL Max(MB/s): " MAX_SPEED_DL; read -p "UP Max: " MAX_SPEED_UP; save_config ;;
            3) read -p "维护时间(HH:MM): " MAINT_TIME; read -p "活跃起始: " ACTIVE_START; read -p "活跃结束: " ACTIVE_END; read -p "切片MB: " CHUNK_MB; save_config ;;
            4) read -p "1.DL 2.UP: " d; t="DL"; [ "$d" == "2" ] && t="UP"; read -p "MB: " m; read -p "Speed: " s; run_traffic "MANUAL" "$t" "$m" "$s"; read -p "..." ;;
            5) read -p "1.DL 2.UP: " d; t="DL"; [ "$d" == "2" ] && t="UP"; read -p "MB: " m; read -p "Speed: " s; nohup bash "$0" --manual-bg "$t" "$m" "$s" >/dev/null 2>&1 & echo "PID: $!"; sleep 2 ;;
            6) read -p "1.DL 2.UP: " d; t="DL"; [ "$d" == "2" ] && t="UP"; run_speedtest "$t"; read -p "..." ;;
            7) setup_cron ;;
            8) echo ""; tail -n 10 "$LOG_FILE"; read -p "..." ;;
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
