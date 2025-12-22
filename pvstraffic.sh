#!/bin/bash
# ==============================================================================
# VPS Traffic Spirit v1.0.0
# Author: Prince 2025.12
# ==============================================================================

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT_NAME=$(basename "$0")
SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"
CONF_FILE="$SCRIPT_DIR/traffic_config.conf"
STATS_FILE="$SCRIPT_DIR/traffic_stats.conf"
LOG_DIR="$SCRIPT_DIR/logs"
LOCK_DAILY="$SCRIPT_DIR/daily.lock"
LOCK_HOURLY="$SCRIPT_DIR/hourly.lock"
LOCK_RANDOM="$SCRIPT_DIR/random.lock"
STATS_LOCK="$SCRIPT_DIR/stats.lock"
BG_PID_FILE="$SCRIPT_DIR/bg.pid"
TEMP_DATA_FILE="/tmp/traffic_spirit_chunk.dat"
CRON_MARK="# [VPS_TRAFFIC_SPIRIT_V3]"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

mkdir -p "$LOG_DIR"

# ==================== 原有配置 (保持不变) ====================
PERIOD_DAYS=22
PERIOD_TARGET_GB=36
PERIOD_START_DATE="$(date +%F)"
DAILY_TARGET_MB=1210
DAILY_TIME_MIN=120
CRON_MAX_SPEED_MB=8
BJ_CRON_HOUR=3
BJ_CRON_MIN=10
ENABLE_HOURLY=0
HOURLY_INTERVAL_MIN=91
HOURLY_TARGET_MB=150
HOURLY_DURATION_MIN=2
HOURLY_BJ_START=8
HOURLY_BJ_END=18
ENABLE_UPLOAD=1
UPLOAD_RATIO=3
MEM_PROTECT_KB=32768
NODE_STRATEGY=3
JITTER_PERCENT=15

# ==================== 新增：独立模拟模式配置 ====================
RANDOM_MODE_ENABLE=0
R_DAILY_DL_MB=500
R_DAILY_UP_MB=300
R_DL_SPEED_MB=5
R_UP_SPEED_MB=2
R_UTC8_START=8
R_UTC8_END=22

now_sec() { date +%s; }
mb_to_kb() { awk "BEGIN{printf \"%.0f\", $1 * 1024}"; }
kb_to_mb() { awk "BEGIN{printf \"%.2f\", $1 / 1024}"; }
kb_to_gb() { awk "BEGIN{printf \"%.2f\", $1 / 1024 / 1024}"; }
gb_to_kb() { awk "BEGIN{printf \"%.0f\", $1 * 1024 * 1024}"; }

log() {
    local ts="$(date '+%F %T')"
    echo -e "[$ts] $*" >> "$LOG_DIR/system.log"
    if [ "$IS_SILENT" != "1" ]; then echo -e "[$ts] $*"; fi
}

check_env() {
    local fix=0
    if ! command -v crontab >/dev/null 2>&1; then fix=1; fi
    if ! command -v curl >/dev/null 2>&1; then fix=1; fi
    if [ "$fix" -eq 1 ]; then
        if [ -f /etc/debian_version ]; then apt-get update -y -q && apt-get install -y -q cron curl; fi
        if [ -f /etc/redhat-release ]; then yum install -y -q cronie curl; fi
        if [ -f /etc/alpine-release ]; then apk add cronie curl; fi
    fi
    if [ -f /etc/alpine-release ]; then pgrep crond >/dev/null || crond; else
        service cron start 2>/dev/null || systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null
    fi
}

load_config() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
    [ -f "$STATS_FILE" ] && source "$STATS_FILE"
    TODAY_KB=${TODAY_KB:-0}
    PERIOD_KB=${PERIOD_KB:-0}
    TODAY_RUN_SEC=${TODAY_RUN_SEC:-0}
    
    # 确保新变量载入
    RANDOM_MODE_ENABLE=${RANDOM_MODE_ENABLE:-0}
    R_DAILY_DL_MB=${R_DAILY_DL_MB:-500}
    R_DAILY_UP_MB=${R_DAILY_UP_MB:-300}
    R_DL_SPEED_MB=${R_DL_SPEED_MB:-5}
    R_UP_SPEED_MB=${R_UP_SPEED_MB:-2}
    R_UTC8_START=${R_UTC8_START:-8}
    R_UTC8_END=${R_UTC8_END:-22}
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
ENABLE_HOURLY=$ENABLE_HOURLY
HOURLY_INTERVAL_MIN=$HOURLY_INTERVAL_MIN
HOURLY_TARGET_MB=$HOURLY_TARGET_MB
HOURLY_DURATION_MIN=$HOURLY_DURATION_MIN
HOURLY_BJ_START=$HOURLY_BJ_START
HOURLY_BJ_END=$HOURLY_BJ_END
ENABLE_UPLOAD=$ENABLE_UPLOAD
UPLOAD_RATIO=$UPLOAD_RATIO
NODE_STRATEGY=$NODE_STRATEGY
JITTER_PERCENT=$JITTER_PERCENT
MEM_PROTECT_KB=$MEM_PROTECT_KB
RANDOM_MODE_ENABLE=$RANDOM_MODE_ENABLE
R_DAILY_DL_MB=$R_DAILY_DL_MB
R_DAILY_UP_MB=$R_DAILY_UP_MB
R_DL_SPEED_MB=$R_DL_SPEED_MB
R_UP_SPEED_MB=$R_UP_SPEED_MB
R_UTC8_START=$R_UTC8_START
R_UTC8_END=$R_UTC8_END
EOF
}

update_stats() {
    local add_kb=${1:-0}
    local add_sec=${2:-0}
    local is_random=${3:-0}
    local rnd_dl=${4:-0}
    local rnd_up=${5:-0}
    
    (
        flock -x 200
        [ -f "$STATS_FILE" ] && source "$STATS_FILE"
        TODAY_KB=${TODAY_KB:-0}
        PERIOD_KB=${PERIOD_KB:-0}
        TODAY_RUN_SEC=${TODAY_RUN_SEC:-0}
        
        # 模拟模式专用统计
        R_TODAY_DL=${R_TODAY_DL:-0}
        R_TODAY_UP=${R_TODAY_UP:-0}
        R_LAST_DAY=${R_LAST_DAY:-""}
        
        local today_str=$(date +%F)
        if [ "$R_LAST_DAY" != "$today_str" ]; then
            R_TODAY_DL=0
            R_TODAY_UP=0
            R_LAST_DAY="$today_str"
        fi
        
        if [ "$is_random" -eq 1 ]; then
            R_TODAY_DL=$(( R_TODAY_DL + rnd_dl ))
            R_TODAY_UP=$(( R_TODAY_UP + rnd_up ))
        fi

        TODAY_KB=$(( TODAY_KB + add_kb ))
        PERIOD_KB=$(( PERIOD_KB + add_kb ))
        TODAY_RUN_SEC=$(( TODAY_RUN_SEC + add_sec ))
        
        cat >"$STATS_FILE"<<EOF
TODAY_KB=$TODAY_KB
TODAY_RUN_SEC=$TODAY_RUN_SEC
PERIOD_KB=$PERIOD_KB
LAST_RUN_TIME="$(date '+%F %T')"
LAST_RUN_KB=$add_kb
R_TODAY_DL=$R_TODAY_DL
R_TODAY_UP=$R_TODAY_UP
R_LAST_DAY="$R_LAST_DAY"
EOF
    ) 200>"$STATS_LOCK"
}

calc_smart_target() {
    local start_s=$(date -d "$PERIOD_START_DATE" +%s)
    local passed_days=$(( ( $(now_sec) - start_s ) / 86400 ))
    [ "$passed_days" -lt 0 ] && passed_days=0
    local left_days=$(( PERIOD_DAYS - passed_days ))
    [ "$left_days" -le 0 ] && left_days=1
    local total_kb=$(gb_to_kb "$PERIOD_TARGET_GB")
    local left_kb=$(( total_kb - PERIOD_KB ))
    [ "$left_kb" -le 0 ] && left_kb=0
    local left_mb=$(kb_to_mb "$left_kb")
    local daily_need_mb=$(awk "BEGIN{printf \"%.0f\", $left_mb / $left_days}")
    local final_target_mb=$DAILY_TARGET_MB
    if [ "$daily_need_mb" -gt "$DAILY_TARGET_MB" ]; then final_target_mb=$daily_need_mb; fi
    local float_pct=$(( RANDOM % (JITTER_PERCENT * 2 + 1) + (100 - JITTER_PERCENT) ))
    final_target_mb=$(awk "BEGIN{printf \"%.0f\", $final_target_mb * $float_pct / 100}")
    echo "$final_target_mb"
}

check_hourly_window() {
    local bj_h=$(date -u -d "+8 hours" +%H | sed 's/^0//')
    [ -z "$bj_h" ] && bj_h=0
    if [ "$bj_h" -ge "$HOURLY_BJ_START" ] && [ "$bj_h" -le "$HOURLY_BJ_END" ]; then return 0; fi
    return 1
}

check_random_window_utc8() {
    # 计算 UTC-8 (太平洋时间)
    local utc_h=$(date -u +%H | sed 's/^0//')
    local target_h=$(( utc_h - 8 ))
    if [ "$target_h" -lt 0 ]; then target_h=$(( target_h + 24 )); fi
    
    if [ "$target_h" -ge "$R_UTC8_START" ] && [ "$target_h" -le "$R_UTC8_END" ]; then return 0; fi
    return 1
}

get_dl_url() {
    local n=("nbg1" "fsn1" "hel1" "ash" "hil" "sin")
    echo "https://${n[$((RANDOM % ${#n[@]}))]}-speed.hetzner.com/10GB.bin?r=$RANDOM"
}

get_up_url() {
    local urls=(
        "http://speedtest.tele2.net/upload.php"
        "http://bouygues.testdebit.info/ul/upload.php"
        "http://ipv4.speedtest.tele2.net/upload.php"
    )
    echo "${urls[$((RANDOM % ${#urls[@]}))]}"
}

prepare_upload_data() {
    if [ ! -f "$TEMP_DATA_FILE" ] || [ $(stat -c%s "$TEMP_DATA_FILE") -ne 2097152 ]; then
        dd if=/dev/urandom of="$TEMP_DATA_FILE" bs=1M count=2 status=none 2>/dev/null
        if [ $? -ne 0 ]; then
             TEMP_DATA_FILE="$SCRIPT_DIR/chunk.dat"
             dd if=/dev/urandom of="$TEMP_DATA_FILE" bs=1M count=2 status=none 2>/dev/null
        fi
    fi
}

run_traffic() {
    local mode="$1"        
    local type="$2"        
    local val="$3"         
    local limit_speed="$4" 
    local direction="$5"   
    [ -z "$direction" ] && direction="MIX"

    IS_SILENT=0
    if [[ "$mode" == "CRON" || "$mode" == "HOURLY" || "$mode" == "BG" || "$mode" == "RANDOM" ]]; then IS_SILENT=1; fi

    local disk_kb=$(df -P "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    [ -z "$disk_kb" ] && disk_kb=99999999
    if [ "${disk_kb:-0}" -lt 51200 ]; then
        log "${YELLOW}[警告] 磁盘不足${PLAIN}"
    fi
    
    # 内存保护检查
    if [ "$ENABLE_UPLOAD" = "1" ] || [ "$direction" == "UPLOAD_ONLY" ] || [ "$mode" == "RANDOM" ]; then
        local mem_kb=0
        if [ -f /proc/meminfo ]; then
            mem_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
            [ -z "$mem_kb" ] && mem_kb=$(awk '/MemFree/ {print $2}' /proc/meminfo)
        else
            mem_kb=$(free -k 2>/dev/null | awk '/Mem:/ {print $4}')
        fi
        [ -z "$mem_kb" ] && mem_kb=99999999
        if [ "${mem_kb:-0}" -lt "$MEM_PROTECT_KB" ]; then
            if [ "$direction" == "UPLOAD_ONLY" ]; then
                log "${YELLOW}[警告] 内存低${PLAIN}"
            else
                ENABLE_UPLOAD=0
            fi
        fi
    fi

    local speed_kb=$(mb_to_kb "${limit_speed:-1}")
    local calculated_speed_kb=0

    if [ "$type" == "DATA" ]; then
        local target_kb=$(mb_to_kb "${val:-10}")
        if [ "$mode" == "CRON" ]; then
            local t_sec=$(( DAILY_TIME_MIN * 60 ))
            [ "$t_sec" -lt 60 ] && t_sec=60
            calculated_speed_kb=$(awk "BEGIN{printf \"%.0f\", $target_kb / $t_sec}")
        elif [ "$mode" == "HOURLY" ]; then
            local t_sec=$(( HOURLY_DURATION_MIN * 60 ))
            [ "$t_sec" -lt 60 ] && t_sec=60
            calculated_speed_kb=$(awk "BEGIN{printf \"%.0f\", $target_kb / $t_sec}")
        elif [ "$mode" == "MANUAL" ] || [ "$mode" == "BG" ]; then
            calculated_speed_kb=$speed_kb
        elif [ "$mode" == "RANDOM" ]; then
            calculated_speed_kb=$speed_kb
        fi

        if [[ "$mode" == "CRON" || "$mode" == "HOURLY" ]]; then
            local cap_kb=$(mb_to_kb "$CRON_MAX_SPEED_MB")
            if [ "${calculated_speed_kb:-0}" -gt "${cap_kb:-0}" ]; then calculated_speed_kb=$cap_kb; fi
        fi
        [ "${calculated_speed_kb:-0}" -lt 1024 ] && calculated_speed_kb=1024
        if [ "$mode" != "RANDOM" ]; then speed_kb=$calculated_speed_kb; fi
    fi

    local msg="任务[$mode]: 目标=$val$( [ "$type" == "DATA" ] && echo "MB" || echo "s" )"
    if [ "$direction" == "UPLOAD_ONLY" ]; then
        prepare_upload_data
        msg="$msg | 纯上传 | 限速=$(kb_to_mb $speed_kb)MB/s"
    elif [ "$direction" == "DOWNLOAD_ONLY" ]; then
        msg="$msg | 纯下载 | 限速=$(kb_to_mb $speed_kb)MB/s"
    else
        msg="$msg | 下载限速=$(kb_to_mb $speed_kb)MB/s"
        if [ "$ENABLE_UPLOAD" == "1" ]; then 
            prepare_upload_data
            msg="$msg | 上传开启"
        fi
    fi
    log "$msg"
    
    local start_ts=$(now_sec)
    local current_kb=0
    local dl_acc=0
    local up_acc=0
    local fail_multiplier=1
    
    trap 'pkill -P $$; rm -f "$BG_PID_FILE" "$TEMP_DATA_FILE"; exit' EXIT INT TERM

    while true; do
        local dl_url=$(get_dl_url)
        local up_url=$(get_up_url) 
        local PID_DL=""
        local PID_UP=""
        local dl_real_speed=0
        local ul_real_speed=0

        # 下载启动
        if [ "$direction" != "UPLOAD_ONLY" ]; then
            dl_real_speed=$(awk "BEGIN{printf \"%.0f\", $speed_kb * $(( RANDOM % 21 + 90 )) / 100}")
            if [ "$fail_multiplier" -gt 1 ]; then dl_real_speed=$(( dl_real_speed / fail_multiplier )); fi
            nice -n 10 curl -4 -sL --max-time 300 --connect-timeout 15 --limit-rate "${dl_real_speed}k" --output /dev/null "$dl_url" &
            PID_DL=$!
        fi

        # 上传启动
        if [ "$direction" != "DOWNLOAD_ONLY" ]; then
            if [ "$mode" == "RANDOM" ]; then
                 ul_real_speed=$(mb_to_kb "$R_UP_SPEED_MB")
            elif [ "$direction" == "UPLOAD_ONLY" ]; then
                 ul_real_speed=$(awk "BEGIN{printf \"%.0f\", $speed_kb * $(( RANDOM % 21 + 90 )) / 100}")
            elif [ "$ENABLE_UPLOAD" == "1" ]; then
                 ul_real_speed=$(awk "BEGIN{printf \"%.0f\", $dl_real_speed * ${UPLOAD_RATIO:-3} / 100}")
            fi
            
            if [ "${ul_real_speed:-0}" -gt 10 ]; then
                if [ "$fail_multiplier" -gt 1 ]; then ul_real_speed=$(( ul_real_speed / fail_multiplier )); fi
                (
                    ulimit -v 32768
                    while true; do
                        nice -n 15 curl -4 -sL --max-time 60 --connect-timeout 10 \
                            --limit-rate "${ul_real_speed}k" \
                            --data-binary "@$TEMP_DATA_FILE" \
                            "$up_url" --output /dev/null 2>/dev/null
                        sleep 0.2
                    done
                ) &
                PID_UP=$!
            fi
        fi

        local loop_start=$(now_sec)

        while ( [ -n "$PID_DL" ] && kill -0 $PID_DL 2>/dev/null ) || ( [ -n "$PID_UP" ] && kill -0 $PID_UP 2>/dev/null ); do
            sleep 1
            local elapsed=$(( $(now_sec) - start_ts ))
            
            if [ "$direction" == "UPLOAD_ONLY" ] && [ -n "$PID_UP" ] && ! kill -0 $PID_UP 2>/dev/null; then break; fi

            local tick_dl=0
            local tick_up=0
            if [ -n "$PID_DL" ] && kill -0 $PID_DL 2>/dev/null; then tick_dl=$dl_real_speed; fi
            if [ -n "$PID_UP" ] && kill -0 $PID_UP 2>/dev/null; then tick_up=$ul_real_speed; fi
            
            current_kb=$(( current_kb + tick_dl + tick_up ))
            dl_acc=$(( dl_acc + tick_dl ))
            up_acc=$(( up_acc + tick_up ))
            
            local done=0
            local pct=0
            if [ "$type" == "TIME" ]; then
                [ "$elapsed" -ge "$val" ] && done=1
                pct=$(( elapsed * 100 / val ))
            else
                local target_kb=$(mb_to_kb "$val")
                [ "$current_kb" -ge "$target_kb" ] && done=1
                pct=$(( current_kb * 100 / target_kb ))
            fi
            [ "$pct" -gt 100 ] && pct=100

            if [ "$IS_SILENT" == "0" ]; then
                local info_str=""
                if [ "$direction" == "UPLOAD_ONLY" ]; then
                    info_str="UL:~$(kb_to_mb $ul_real_speed)MB/s"
                elif [ "$direction" == "DOWNLOAD_ONLY" ]; then
                    info_str="DL:~$(kb_to_mb $dl_real_speed)MB/s"
                else
                    info_str="DL:~$(kb_to_mb $dl_real_speed)MB/s | UL:~$(kb_to_mb $ul_real_speed)MB/s"
                fi
                echo -ne "\r[Running] 进度:${pct}% | 总量:$(kb_to_mb $current_kb)MB | $info_str  "
            fi
            
            if [ "$done" -eq 1 ]; then
                [ -n "$PID_DL" ] && kill $PID_DL 2>/dev/null
                [ -n "$PID_UP" ] && kill $PID_UP 2>/dev/null
                break 2
            fi
        done
        
        [ -n "$PID_DL" ] && kill $PID_DL 2>/dev/null
        [ -n "$PID_UP" ] && kill $PID_UP 2>/dev/null
        wait $PID_DL $PID_UP 2>/dev/null

        local loop_dur=$(( $(now_sec) - loop_start ))
        if [ "$loop_dur" -lt 3 ]; then
            fail_multiplier=$(( fail_multiplier + 1 ))
            if [ "$IS_SILENT" == "0" ]; then echo -ne "\n${YELLOW}[!] 重试...${PLAIN} "; fi
            sleep 2
        elif [ "$IS_SILENT" == "1" ]; then 
            sleep $(( RANDOM % 20 + 5 ))
        fi
    done

    local dur=$(( $(now_sec) - start_ts ))
    local is_rnd=0
    [ "$mode" == "RANDOM" ] && is_rnd=1
    update_stats "$current_kb" "$dur" "$is_rnd" "$dl_acc" "$up_acc"
    if [ "$IS_SILENT" == "0" ]; then echo -e "\n${GREEN}任务完成。${PLAIN}"; fi
    log "完成[$mode]: 总流量=$(kb_to_mb $current_kb)MB 耗时=${dur}s"
    rm -f "$BG_PID_FILE" "$TEMP_DATA_FILE"
}

install_cron() {
    check_env
    local offset=$(date +%z | sed 's/^+//' | cut -c1-3)
    local svr_h=$(( BJ_CRON_HOUR - 8 + offset ))
    while [ "$svr_h" -lt 0 ]; do svr_h=$(( svr_h + 24 )); done
    while [ "$svr_h" -ge 24 ]; do svr_h=$(( svr_h - 24 )); done
    local tmp="$SCRIPT_DIR/cron.tmp"
    crontab -l 2>/dev/null | grep -F -v "$CRON_MARK" > "$tmp"
    
    # 1. 每日保底
    echo "$BJ_CRON_MIN $svr_h * * * $SCRIPT_PATH --cron $CRON_MARK" >> "$tmp"
    # 2. 小时任务
    if [ "$ENABLE_HOURLY" == "1" ]; then
        local intv=""
        if [ "$HOURLY_INTERVAL_MIN" -eq 60 ]; then intv="0 * * * *"; else intv="*/$HOURLY_INTERVAL_MIN * * * *"; fi
        echo "$intv $SCRIPT_PATH --hourly $CRON_MARK" >> "$tmp"
    fi
    # 3. 独立模拟模式 (每10分钟检测一次，实现碎片化运行)
    if [ "$RANDOM_MODE_ENABLE" == "1" ]; then
        echo "*/10 * * * * $SCRIPT_PATH --random $CRON_MARK" >> "$tmp"
    fi
    
    crontab "$tmp" && rm -f "$tmp"
    echo -e "${GREEN}Cron 更新成功!${PLAIN} 保底任务: 本地$svr_h:$BJ_CRON_MIN"
}

uninstall_all() {
    echo -e "${YELLOW}正在安全卸载...${PLAIN}"
    crontab -l 2>/dev/null | grep -F -v "$CRON_MARK" > "$SCRIPT_DIR/cron.clean"
    crontab "$SCRIPT_DIR/cron.clean"
    rm -f "$SCRIPT_DIR/cron.clean"
    [ -f "$BG_PID_FILE" ] && kill $(cat "$BG_PID_FILE") 2>/dev/null
    pkill -f "$SCRIPT_NAME" 2>/dev/null
    rm -f "$CONF_FILE" "$STATS_FILE" "$LOCK_DAILY" "$LOCK_HOURLY" "$LOCK_RANDOM" "$STATS_LOCK" "$BG_PID_FILE"
    rm -rf "$LOG_DIR"
    echo -e "${GREEN}卸载完成。${PLAIN}"
    exit 0
}

entry_cron() {
    sleep $(( RANDOM % 1800 ))
    exec 9>"$LOCK_DAILY"; flock -n 9 || exit 0
    load_config
    UPLOAD_RATIO=3
    local target=$(calc_smart_target)
    local ran_mb=$(kb_to_mb "$TODAY_KB")
    if [ $(awk "BEGIN{print ($ran_mb < $target)?1:0}") -eq 1 ]; then
        local todo_mb=$(( target - ran_mb ))
        [ "$todo_mb" -lt 10 ] && todo_mb=10
        run_traffic "CRON" "DATA" "$todo_mb" "0"
    else
        log "[Cron] 周期保底已达标。"
    fi
}

entry_hourly() {
    sleep $(( RANDOM % 60 ))
    exec 8>"$LOCK_HOURLY"; flock -n 8 || exit 0
    load_config
    if [ "$ENABLE_HOURLY" != "1" ]; then exit 0; fi
    if ! check_hourly_window; then exit 0; fi
    UPLOAD_RATIO=3
    run_traffic "HOURLY" "DATA" "$HOURLY_TARGET_MB" "0"
}

entry_random() {
    sleep $(( RANDOM % 120 ))
    exec 7>"$LOCK_RANDOM"; flock -n 7 || exit 0
    load_config
    if [ "$RANDOM_MODE_ENABLE" != "1" ]; then exit 0; fi
    if ! check_random_window_utc8; then exit 0; fi
    
    # 模拟真实：30%概率跳过本次执行，实现时断时续
    if [ $(( RANDOM % 100 )) -lt 30 ]; then exit 0; fi
    
    # 检查限额
    R_TODAY_DL=${R_TODAY_DL:-0}
    R_TODAY_UP=${R_TODAY_UP:-0}
    
    local cur_dl=$(kb_to_mb $R_TODAY_DL)
    local cur_up=$(kb_to_mb $R_TODAY_UP)
    local can_dl=0
    local can_up=0
    
    if [ $(awk "BEGIN{print ($cur_dl < $R_DAILY_DL_MB)?1:0}") -eq 1 ]; then can_dl=1; fi
    if [ $(awk "BEGIN{print ($cur_up < $R_DAILY_UP_MB)?1:0}") -eq 1 ]; then can_up=1; fi
    
    if [ "$can_dl" -eq 0 ] && [ "$can_up" -eq 0 ]; then
        log "[Random] 今日随机任务额度已满。"
        exit 0
    fi
    
    # 随机运行 5-15 分钟
    local run_min=$(( RANDOM % 11 + 5 ))
    local run_sec=$(( run_min * 60 ))
    
    # 决策模式
    if [ "$can_dl" -eq 1 ] && [ "$can_up" -eq 1 ]; then
        # 混合模式，但受限于设置的速率
        run_traffic "RANDOM" "TIME" "$run_sec" "$R_DL_SPEED_MB" "MIX"
    elif [ "$can_dl" -eq 1 ]; then
        run_traffic "RANDOM" "TIME" "$run_sec" "$R_DL_SPEED_MB" "DOWNLOAD_ONLY"
    elif [ "$can_up" -eq 1 ]; then
        run_traffic "RANDOM" "TIME" "$run_sec" "$R_UP_SPEED_MB" "UPLOAD_ONLY"
    fi
}

menu() {
    # 修复 curl | bash 闪屏的关键
    exec < /dev/tty
    
    while true; do
        clear
        load_config
        echo -e "${BLUE}=== VPS Traffic Spirit v2.0.0 ===${PLAIN}"
        echo -e "${BOLD}[A] 周期保底${PLAIN}"
        echo -e " 1. 周期天数 : ${GREEN}$PERIOD_DAYS${PLAIN} 天"
        echo -e " 2. 周期目标 : ${GREEN}$PERIOD_TARGET_GB${PLAIN} GB"
        echo -e " 3. 周期开始 : $PERIOD_START_DATE"
        echo -e "${BOLD}[B] 每日任务${PLAIN}"
        echo -e " 4. 每日目标 : ${GREEN}$DAILY_TARGET_MB${PLAIN} MB"
        echo -e " 5. 运行时长 : ${GREEN}$DAILY_TIME_MIN${PLAIN} 分"
        echo -e " 6. 启动时间 : BJ ${GREEN}$BJ_CRON_HOUR:$BJ_CRON_MIN${PLAIN}"
        echo -e "${BOLD}[C] 小时任务${PLAIN}"
        echo -e " 7. 任务开关 : $( [ $ENABLE_HOURLY -eq 1 ] && echo "${RED}开启${PLAIN}" || echo "关闭" )"
        echo -e " 8. 触发间隔 : ${GREEN}$HOURLY_INTERVAL_MIN${PLAIN} 分 | 围栏: BJ ${GREEN}$HOURLY_BJ_START-${HOURLY_BJ_END}${PLAIN}点"
        echo -e " 9. 每次跑量 : ${GREEN}$HOURLY_TARGET_MB${PLAIN} MB | 耗时: ${GREEN}$HOURLY_DURATION_MIN${PLAIN} 分"
        echo -e "${BOLD}[D] 模拟模式 (独立新增)${PLAIN}"
        echo -e "10. 模式配置 : $( [ $RANDOM_MODE_ENABLE -eq 1 ] && echo "${RED}运行中${PLAIN}" || echo "已停止" ) [点击进入设置]"
        echo -e "${BOLD}[E] 系统参数${PLAIN}"
        echo -e "11. 挂机上限 : ${GREEN}$CRON_MAX_SPEED_MB${PLAIN} MB/s | 上传开关: $( [ $ENABLE_UPLOAD -eq 1 ] && echo "${RED}ON${PLAIN}" || echo "OFF" )"
        echo -e "12. 上传比例 : ${GREEN}$UPLOAD_RATIO${PLAIN}% (自动任务默认为3%)"
        echo -e "----------------------------------------------"
        echo -e " S. 💾 保存配置 | 0. 退出"
        read -p "选项: " c
        case "$c" in
            1) read -p "天数: " v; [ -n "$v" ] && PERIOD_DAYS=$v ;;
            2) read -p "GB: " v; [ -n "$v" ] && PERIOD_TARGET_GB=$v ;;
            3) read -p "日期(YYYY-MM-DD): " v; [ -n "$v" ] && PERIOD_START_DATE=$v ;;
            4) read -p "MB: " v; [ -n "$v" ] && DAILY_TARGET_MB=$v ;;
            5) read -p "分: " v; [ -n "$v" ] && DAILY_TIME_MIN=$v ;;
            6) read -p "时: " h; [ -n "$h" ] && BJ_CRON_HOUR=$h; read -p "分: " m; [ -n "$m" ] && BJ_CRON_MIN=$m ;;
            7) read -p "1=开, 0=关: " v; [ -n "$v" ] && ENABLE_HOURLY=$v ;;
            8) read -p "间隔(分): " i; [ -n "$i" ] && HOURLY_INTERVAL_MIN=$i 
               read -p "开始时: " s; [ -n "$s" ] && HOURLY_BJ_START=$s
               read -p "结束时: " e; [ -n "$e" ] && HOURLY_BJ_END=$e ;;
            9) read -p "流量(MB): " t; [ -n "$t" ] && HOURLY_TARGET_MB=$t 
               read -p "耗时(分): " d; [ -n "$d" ] && HOURLY_DURATION_MIN=$d ;;
            10) 
                clear
                echo -e "${BLUE}=== 独立模拟模式设置 (UTC-8) ===${PLAIN}"
                echo -e "说明: 此模式完全独立，每日自动模拟正常使用流量。"
                echo -e "-----------------------------------"
                echo -e "1. 模式开关: $( [ $RANDOM_MODE_ENABLE -eq 1 ] && echo "${RED}开启${PLAIN}" || echo "关闭" )"
                echo -e "2. 每日下载上限: ${GREEN}$R_DAILY_DL_MB${PLAIN} MB"
                echo -e "3. 每日上传上限: ${GREEN}$R_DAILY_UP_MB${PLAIN} MB"
                echo -e "4. 模拟下载速率: ${GREEN}$R_DL_SPEED_MB${PLAIN} MB/s"
                echo -e "5. 模拟上传速率: ${GREEN}$R_UP_SPEED_MB${PLAIN} MB/s"
                echo -e "6. UTC-8运行时间: ${GREEN}$R_UTC8_START点${PLAIN} 到 ${GREEN}$R_UTC8_END点${PLAIN}"
                echo -e "-----------------------------------"
                read -p "输入子选项 (回车返回): " rc
                case "$rc" in
                    1) read -p "1=开启, 0=关闭: " v; [ -n "$v" ] && RANDOM_MODE_ENABLE=$v ;;
                    2) read -p "MB: " v; [ -n "$v" ] && R_DAILY_DL_MB=$v ;;
                    3) read -p "MB: " v; [ -n "$v" ] && R_DAILY_UP_MB=$v ;;
                    4) read -p "MB/s: " v; [ -n "$v" ] && R_DL_SPEED_MB=$v ;;
                    5) read -p "MB/s: " v; [ -n "$v" ] && R_UP_SPEED_MB=$v ;;
                    6) read -p "开始点(0-23): " s; [ -n "$s" ] && R_UTC8_START=$s
                       read -p "结束点(0-23): " e; [ -n "$e" ] && R_UTC8_END=$e ;;
                esac
                ;;
            11) read -p "MB/s: " v; [ -n "$v" ] && CRON_MAX_SPEED_MB=$v 
                read -p "上传开关 (1=开, 0=关): " u; [ -n "$u" ] && ENABLE_UPLOAD=$u ;;
            12) read -p "上传比例 (1-100%): " r; [ -n "$r" ] && UPLOAD_RATIO=$r ;;
            s|S) save_config; install_cron; echo -e "${GREEN}保存并重载Cron!${PLAIN}"; sleep 1 ;;
            0) break ;;
        esac
    done
}

dashboard() {
    exec < /dev/tty
    check_env
    clear
    load_config
    local bg_s="${RED}无${PLAIN}"
    [ -f "$BG_PID_FILE" ] && kill -0 $(cat "$BG_PID_FILE") 2>/dev/null && bg_s="${GREEN}运行中${PLAIN}"
    local smart=$(calc_smart_target)
    
    R_TODAY_DL=${R_TODAY_DL:-0}
    R_TODAY_UP=${R_TODAY_UP:-0}

    echo -e "${BLUE}=== VPS Traffic Spirit v2.0.0 ===${PLAIN}"
    echo -e " [周期] $(kb_to_gb $PERIOD_KB)/$PERIOD_TARGET_GB GB | 今日: $(kb_to_mb $TODAY_KB) MB"
    echo -e " [模拟] $( [ $RANDOM_MODE_ENABLE -eq 1 ] && echo "${RED}ON${PLAIN}" || echo "OFF" ) | 今日: DL $(kb_to_mb $R_TODAY_DL) / UP $(kb_to_mb $R_TODAY_UP) MB"
    echo -e " [小时] $( [ $ENABLE_HOURLY -eq 1 ] && echo "${RED}ON${PLAIN}" || echo "关闭" ) | [智能] 保底目标: ${YELLOW}$smart MB${PLAIN}"
    echo -e " [后台] $bg_s"
    echo -e "----------------------------------------------"
    echo -e " 1. 🚀 手动任务 (独立控速)"
    echo -e " 2. ⚙️  配置菜单 (完整设置)"
    echo -e " 3. 📄 运行日志"
    echo -e " 4. 🗑️  安全卸载"
    echo -e " 0. 退出"
    echo -e "----------------------------------------------"
    echo -n " 选择: "
}

case "$1" in
    --cron) entry_cron ;;
    --hourly) entry_hourly ;;
    --random) entry_random ;;
    --bg-run) run_traffic "BG" "DATA" "$2" "$3" "MIX" ;;
    *)
        while true; do
            dashboard
            read opt
            case "$opt" in
                1) 
                    echo -e "\n1.下载测速 2.下载流量(前台) 3.下载流量(后台) 4.纯上传(前台) 5.停后台"
                    read -p "选: " s
                    case "$s" in
                        1) echo "测速中..."; s=$(curl -s -w "%{speed_download}" -o /dev/null --max-time 10 "https://nbg1-speed.hetzner.com/10GB.bin"); echo "极速: $(awk "BEGIN {printf \"%.2f\", $s/1048576}") MB/s"; read -p "..." ;;
                        2) 
                           read -p "目标MB: " d
                           read -p "限速MB/s (回车默认max): " sp
                           [ -z "$sp" ] && sp=$CRON_MAX_SPEED_MB
                           run_traffic "MANUAL" "DATA" "$d" "$sp" "MIX" ;;
                        3) 
                           read -p "目标MB: " d
                           read -p "限速MB/s (回车默认max): " sp
                           [ -z "$sp" ] && sp=$CRON_MAX_SPEED_MB
                           nohup "$SCRIPT_PATH" --bg-run "$d" "$sp" >/dev/null 2>&1 & 
                           echo $! > "$BG_PID_FILE"; read -p "已启动..." ;;
                        4) 
                           read -p "上传目标MB: " d
                           read -p "上传限速MB/s: " sp
                           [ -z "$sp" ] && sp=1
                           run_traffic "MANUAL" "DATA" "$d" "$sp" "UPLOAD_ONLY" ;;
                        5) [ -f "$BG_PID_FILE" ] && kill $(cat "$BG_PID_FILE") 2>/dev/null && rm -f "$BG_PID_FILE" ;;
                    esac ;;
                2) menu ;;
                3) tail -n 10 "$LOG_DIR/system.log"; read -p "..." ;;
                4) uninstall_all ;;
                0) exit 0 ;;
            esac
        done
        ;;
esac
