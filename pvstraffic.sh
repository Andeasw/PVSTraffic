#!/bin/bash
# ==============================================================================
# VPS Traffic Spirit v1.0.0
# Author: Prince 2025.12
# ==============================================================================

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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
TEMP_DATA_FILE="/tmp/traffic_spirit_2m.dat" 
CRON_MARK="# [VPS_TRAFFIC_SPIRIT_V3]"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

mkdir -p "$LOG_DIR"

PERIOD_DAYS=7
PERIOD_TARGET_GB=9
PERIOD_START_DATE="" 
DAILY_TARGET_MB=1222
DAILY_TIME_MIN=90
CRON_MAX_SPEED_MB=8
BJ_CRON_HOUR=3
BJ_CRON_MIN=30

GLOBAL_MAX_DAILY_GB=5

RANDOM_MODE_ENABLE=0
R_BASE_DAILY_DL_MB=1166
R_BASE_DAILY_UP_MB=20
R_DL_SPEED_MB=6
R_UP_SPEED_MB=2
R_BJ_START=7
R_BJ_END=17
R_SINGLE_MAX_MB=268
R_SKIP_PCT=35
R_DAILY_FLOAT_PCT=15
R_SINGLE_FLOAT_PCT=30

ENABLE_HOURLY=0
HOURLY_INTERVAL_MIN=60
HOURLY_TARGET_MB=150
HOURLY_DURATION_MIN=5
HOURLY_BJ_START=9
HOURLY_BJ_END=19

ENABLE_UPLOAD=1
UPLOAD_RATIO=3
MEM_PROTECT_KB=65536
JITTER_PERCENT=20

check_env() {
    local fix=0
    if ! command -v crontab >/dev/null 2>&1; then fix=1; fi
    if ! command -v curl >/dev/null 2>&1; then fix=1; fi
    if ! date -d "@1700000000" >/dev/null 2>&1; then fix=1; fi

    if [ "$fix" -eq 1 ]; then
        if [ -f /etc/debian_version ]; then apt-get update -y -q && apt-get install -y -q cron curl coreutils; fi
        if [ -f /etc/redhat-release ]; then yum install -y -q cronie curl coreutils; fi
        if [ -f /etc/alpine-release ]; then apk update && apk add cronie curl coreutils; fi
    fi
    
    if ! date -d "@1700000000" >/dev/null 2>&1; then
        if [ -x /usr/bin/date ] && /usr/bin/date -d "@1700000000" >/dev/null 2>&1; then DATE_CMD="/usr/bin/date"; else exit 1; fi
    else
        DATE_CMD="date"
    fi

    if [ -f /etc/alpine-release ]; then pgrep crond >/dev/null || crond; else service cron start 2>/dev/null || systemctl start cron 2>/dev/null; fi
}

now_sec() { $DATE_CMD -u +%s | awk '{print $1 + 28800}'; }
get_bj_time_str() { $DATE_CMD -u -d "@$(now_sec)" "+%F %T"; }
get_bj_hour() { $DATE_CMD -u -d "@$(now_sec)" +%H | sed 's/^0//'; }
get_logic_date() { 
    local offset_hour=${BJ_CRON_HOUR:-3}
    local cur=$(now_sec)
    local log_sec=$(awk "BEGIN{print $cur - $offset_hour*3600}")
    $DATE_CMD -u -d "@$log_sec" +%F
}

reseed_random() {
    local seed
    if [ -r /dev/urandom ]; then seed=$(od -An -N4 -t u4 /dev/urandom | tr -d ' '); else seed=$($DATE_CMD +%s); fi
    RANDOM=$seed
}

# 真实 UA 模拟池
get_random_ua() {
    local uas=(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1"
        "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0"
    )
    echo "${uas[$((RANDOM % ${#uas[@]}))]}"
}

mb_to_kb() { awk "BEGIN{printf \"%.0f\", $1 * 1024}"; }
kb_to_mb() { awk "BEGIN{printf \"%.2f\", $1 / 1024}"; }
kb_to_gb() { awk "BEGIN{printf \"%.2f\", $1 / 1024 / 1024}"; }
gb_to_kb() { awk "BEGIN{printf \"%.0f\", $1 * 1024 * 1024}"; }

log() {
    local ts=$(get_bj_time_str)
    echo -e "[$ts] $*" >> "$LOG_DIR/system.log"
    if [ "$IS_SILENT" != "1" ]; then echo -e "[$ts] $*"; fi
}

load_config() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
    [ -f "$STATS_FILE" ] && source "$STATS_FILE"
    [ -z "$PERIOD_START_DATE" ] && PERIOD_START_DATE=$(get_logic_date)
    TODAY_KB=${TODAY_KB:-0}
    PERIOD_KB=${PERIOD_KB:-0}
    TODAY_RUN_SEC=${TODAY_RUN_SEC:-0}
    R_TODAY_DL=${R_TODAY_DL:-0}
    R_TODAY_UP=${R_TODAY_UP:-0}
    R_TARGET_DL=${R_TARGET_DL:-0}
    R_TARGET_UP=${R_TARGET_UP:-0}
    R_LAST_DAY=${R_LAST_DAY:-""}
    TODAY_DONE=${TODAY_DONE:-0}
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
MEM_PROTECT_KB=$MEM_PROTECT_KB
GLOBAL_MAX_DAILY_GB=$GLOBAL_MAX_DAILY_GB
RANDOM_MODE_ENABLE=$RANDOM_MODE_ENABLE
R_BASE_DAILY_DL_MB=$R_BASE_DAILY_DL_MB
R_BASE_DAILY_UP_MB=$R_BASE_DAILY_UP_MB
R_DL_SPEED_MB=$R_DL_SPEED_MB
R_UP_SPEED_MB=$R_UP_SPEED_MB
R_BJ_START=$R_BJ_START
R_BJ_END=$R_BJ_END
R_SINGLE_MAX_MB=$R_SINGLE_MAX_MB
R_SKIP_PCT=$R_SKIP_PCT
R_DAILY_FLOAT_PCT=$R_DAILY_FLOAT_PCT
R_SINGLE_FLOAT_PCT=$R_SINGLE_FLOAT_PCT
EOF
}

refresh_day_check() {
    local logic_today=$(get_logic_date)
    if [ "$R_LAST_DAY" != "$logic_today" ]; then
        R_TODAY_DL=0; R_TODAY_UP=0; TODAY_KB=0; TODAY_RUN_SEC=0; TODAY_DONE=0
        local rnd_dl=$(( RANDOM % (R_DAILY_FLOAT_PCT + 1) ))
        local rnd_up=$(( RANDOM % (R_DAILY_FLOAT_PCT + 1) ))
        R_TARGET_DL=$(awk "BEGIN{printf \"%.0f\", $R_BASE_DAILY_DL_MB * (1 + $rnd_dl / 100)}")
        R_TARGET_UP=$(awk "BEGIN{printf \"%.0f\", $R_BASE_DAILY_UP_MB * (1 + $rnd_up / 100)}")
        R_LAST_DAY="$logic_today"
        cat >"$STATS_FILE"<<EOF
TODAY_KB=0
TODAY_RUN_SEC=0
PERIOD_KB=$PERIOD_KB
LAST_RUN_TIME="$(get_bj_time_str)"
LAST_RUN_KB=0
R_TODAY_DL=0
R_TODAY_UP=0
R_TARGET_DL=$R_TARGET_DL
R_TARGET_UP=$R_TARGET_UP
R_LAST_DAY="$R_LAST_DAY"
TODAY_DONE=0
EOF
    fi
}

mark_today_done() {
    TODAY_DONE=1
    ( flock -x 200; cat >"$STATS_FILE"<<EOF
TODAY_KB=$TODAY_KB
TODAY_RUN_SEC=$TODAY_RUN_SEC
PERIOD_KB=$PERIOD_KB
LAST_RUN_TIME="$(get_bj_time_str)"
LAST_RUN_KB=${LAST_RUN_KB:-0}
R_TODAY_DL=$R_TODAY_DL
R_TODAY_UP=$R_TODAY_UP
R_TARGET_DL=$R_TARGET_DL
R_TARGET_UP=$R_TARGET_UP
R_LAST_DAY="$R_LAST_DAY"
TODAY_DONE=1
EOF
    ) 200>"$STATS_LOCK"
}

update_stats() {
    local add_kb=${1:-0}; local add_sec=${2:-0}; local is_random=${3:-0}; local rnd_dl=${4:-0}; local rnd_up=${5:-0}
    ( flock -x 200; [ -f "$STATS_FILE" ] && source "$STATS_FILE"
        TODAY_KB=$(( TODAY_KB + add_kb ))
        PERIOD_KB=$(( PERIOD_KB + add_kb ))
        TODAY_RUN_SEC=$(( TODAY_RUN_SEC + add_sec ))
        if [ "$is_random" -eq 1 ]; then
            R_TODAY_DL=$(( R_TODAY_DL + rnd_dl ))
            R_TODAY_UP=$(( R_TODAY_UP + rnd_up ))
        fi
        cat >"$STATS_FILE"<<EOF
TODAY_KB=$TODAY_KB
TODAY_RUN_SEC=$TODAY_RUN_SEC
PERIOD_KB=$PERIOD_KB
LAST_RUN_TIME="$(get_bj_time_str)"
LAST_RUN_KB=$add_kb
R_TODAY_DL=$R_TODAY_DL
R_TODAY_UP=$R_TODAY_UP
R_TARGET_DL=$R_TARGET_DL
R_TARGET_UP=$R_TARGET_UP
R_LAST_DAY="$R_LAST_DAY"
TODAY_DONE=$TODAY_DONE
EOF
    ) 200>"$STATS_LOCK"
}

check_global_fuse() {
    local today_gb=$(kb_to_gb ${TODAY_KB:-0})
    if [ $(awk "BEGIN{print ($today_gb >= $GLOBAL_MAX_DAILY_GB)?1:0}") -eq 1 ]; then
        log "${RED}[熔断] 今日($today_gb GB)超限($GLOBAL_MAX_DAILY_GB GB)，停机。${PLAIN}"
        [ "$TODAY_DONE" -ne 1 ] && mark_today_done
        return 1
    fi
    return 0
}

calc_smart_target() {
    local start_ts=$($DATE_CMD -u -d "$PERIOD_START_DATE 00:00:00" +%s 2>/dev/null)
    if [ -z "$start_ts" ]; then start_ts=$($DATE_CMD -d "$PERIOD_START_DATE" +%s 2>/dev/null); fi
    local cur_ts=$($DATE_CMD -u -d "$(get_logic_date) 00:00:00" +%s)
    local passed_days=$(( ( cur_ts - start_ts ) / 86400 ))
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
    local rnd=$(( RANDOM % (JITTER_PERCENT + 1) ))
    awk "BEGIN{printf \"%.0f\", $final_target_mb * (1 + $rnd / 100)}"
}

get_dl_url() {
    local u=("https://nbg1-speed.hetzner.com/10GB.bin" "https://fsn1-speed.hetzner.com/10GB.bin" "https://hel1-speed.hetzner.com/10GB.bin" "https://ash-speed.hetzner.com/10GB.bin" "http://speedtest.tele2.net/10GB.zip" "http://ipv4.download.thinkbroadband.com/1GB.zip" "http://mirror.leaseweb.com/speedtest/10000mb.bin")
    echo "${u[$((RANDOM % ${#u[@]}))]}?r=$RANDOM"
}

get_up_url() {
    local u=("http://speedtest.tele2.net/upload.php" "http://ipv4.speedtest.tele2.net/upload.php" "http://bouygues.testdebit.info/ul/upload.php" "http://test.kabeldeutschland.de/upload.php")
    echo "${u[$((RANDOM % ${#u[@]}))]}"
}

prepare_upload_data() {
    if [ ! -f "$TEMP_DATA_FILE" ] || [ $(stat -c%s "$TEMP_DATA_FILE") -ne 2097152 ]; then
        dd if=/dev/urandom of="$TEMP_DATA_FILE" bs=1M count=2 status=none 2>/dev/null
    fi
}

run_traffic() {
    local mode="$1" type="$2" val="$3" input_limit_speed="$4" direction="$5"
    [ -z "$direction" ] && direction="MIX"
    IS_SILENT=0; [[ "$mode" == "CRON" || "$mode" == "HOURLY" || "$mode" == "BG" || "$mode" == "RANDOM" ]] && IS_SILENT=1

    local disk_kb=$(df -P "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    [ "${disk_kb:-0}" -lt 51200 ] && log "${YELLOW}[警告] 磁盘不足${PLAIN}"
    
    if [ "$direction" == "UPLOAD_ONLY" ] || [ "$ENABLE_UPLOAD" == "1" ]; then
        local mem_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
        [ -z "$mem_kb" ] && mem_kb=$(awk '/MemFree/ {print $2}' /proc/meminfo)
        if [ "${mem_kb:-0}" -lt "$MEM_PROTECT_KB" ]; then
             [ "$direction" == "UPLOAD_ONLY" ] && log "${YELLOW}[跳过] 内存低${PLAIN}" && return
             ENABLE_UPLOAD=0
        fi
    fi

    local input_speed_kb=$(mb_to_kb "${input_limit_speed:-1}")
    local calc_dl_kb=0; local calc_ul_kb=0

    if [ "$mode" == "CRON" ]; then
        local t_sec=$(( DAILY_TIME_MIN * 60 )); [ "$t_sec" -lt 60 ] && t_sec=60
        local target_kb=$(mb_to_kb "$val")
        local base_speed=$(awk "BEGIN{printf \"%.0f\", $target_kb / $t_sec}")
        local rnd=$(( RANDOM % (JITTER_PERCENT + 1) ))
        calc_dl_kb=$(awk "BEGIN{printf \"%.0f\", $base_speed * (1 + $rnd / 100)}")
        local cap_kb=$(mb_to_kb "$CRON_MAX_SPEED_MB")
        if [ "$calc_dl_kb" -gt "$cap_kb" ]; then calc_dl_kb=$cap_kb; fi
        calc_ul_kb=$(awk "BEGIN{printf \"%.0f\", $calc_dl_kb * ${UPLOAD_RATIO:-3} / 100}")
    elif [ "$mode" == "HOURLY" ]; then
        local t_sec=$(( HOURLY_DURATION_MIN * 60 ))
        local target_kb=$(mb_to_kb "$val")
        calc_dl_kb=$(awk "BEGIN{printf \"%.0f\", $target_kb / $t_sec}")
        calc_ul_kb=$(awk "BEGIN{printf \"%.0f\", $calc_dl_kb * ${UPLOAD_RATIO:-3} / 100}")
    elif [ "$mode" == "RANDOM" ]; then
        local dl_base=$(mb_to_kb "$R_DL_SPEED_MB")
        local rnd_dl=$(( RANDOM % 41 + 80 )) 
        calc_dl_kb=$(awk "BEGIN{printf \"%.0f\", $dl_base * $rnd_dl / 100}")
        local ul_base=$(mb_to_kb "$R_UP_SPEED_MB")
        local rnd_ul=$(( RANDOM % 41 + 80 ))
        calc_ul_kb=$(awk "BEGIN{printf \"%.0f\", $ul_base * $rnd_ul / 100}")
    else
        calc_dl_kb=$input_speed_kb
        if [ "$direction" == "UPLOAD_ONLY" ]; then calc_ul_kb=$input_speed_kb;
        else calc_ul_kb=$(awk "BEGIN{printf \"%.0f\", $calc_dl_kb * ${UPLOAD_RATIO:-3} / 100}"); fi
    fi

    [ "${calc_dl_kb:-0}" -lt 512 ] && calc_dl_kb=512
    [ "${calc_ul_kb:-0}" -lt 512 ] && calc_ul_kb=512

    if [ "$direction" == "UPLOAD_ONLY" ] || [ "$ENABLE_UPLOAD" == "1" ]; then prepare_upload_data; fi
    
    local speed_log=""
    if [ "$direction" == "DOWNLOAD_ONLY" ]; then speed_log="DL:$(kb_to_mb $calc_dl_kb)MB/s"
    elif [ "$direction" == "UPLOAD_ONLY" ]; then speed_log="UL:$(kb_to_mb $calc_ul_kb)MB/s"
    else speed_log="DL:$(kb_to_mb $calc_dl_kb) | UL:$(kb_to_mb $calc_ul_kb) MB/s"; fi
    
    log "任务[$mode] 方向:$direction 速率:$speed_log 目标:${val}MB"
    
    local start_ts=$(now_sec); local current_kb=0; local dl_acc=0; local up_acc=0
    trap 'pkill -P $$; rm -f "$BG_PID_FILE"; exit' EXIT INT TERM

    while true; do
        local dl_url=$(get_dl_url); local up_url=$(get_up_url) 
        local PID_DL=""; local PID_UP=""; local tick_dl=0; local tick_up=0
        local ua=$(get_random_ua)

        if [ "$direction" != "UPLOAD_ONLY" ]; then
            nice -n 10 curl -4 -sL -A "$ua" --max-time 300 --connect-timeout 15 --limit-rate "${calc_dl_kb}k" --output /dev/null "$dl_url" &
            PID_DL=$!
        fi

        if [ "$direction" != "DOWNLOAD_ONLY" ]; then
            if [ "${calc_ul_kb:-0}" -gt 10 ]; then
                (
                    PARENT_PID=$$; ulimit -v 32768
                    while kill -0 "$PARENT_PID" 2>/dev/null; do
                        nice -n 15 curl -4 -sL -A "$ua" --max-time 60 --connect-timeout 10 --limit-rate "${calc_ul_kb}k" --data-binary "@$TEMP_DATA_FILE" "$up_url" --output /dev/null 2>/dev/null
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
            tick_dl=0; tick_up=0
            if [ -n "$PID_DL" ] && kill -0 $PID_DL 2>/dev/null; then tick_dl=$calc_dl_kb; fi
            if [ -n "$PID_UP" ] && kill -0 $PID_UP 2>/dev/null; then tick_up=$calc_ul_kb; fi
            
            current_kb=$(( current_kb + tick_dl + tick_up ))
            dl_acc=$(( dl_acc + tick_dl ))
            up_acc=$(( up_acc + tick_up ))
            
            local done=0; local pct=0
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
                echo -ne "\r[运行] 进度:${pct}% | 总量:$(kb_to_mb $current_kb)MB | DL:~$(kb_to_mb $tick_dl)MB/s UL:~$(kb_to_mb $tick_up)MB/s "
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
        if [ "$IS_SILENT" == "1" ]; then sleep $(( RANDOM % 5 + 1 )); fi
    done
    
    local dur=$(( $(now_sec) - start_ts ))
    local is_rnd=0; [ "$mode" == "RANDOM" ] && is_rnd=1
    update_stats "$current_kb" "$dur" "$is_rnd" "$dl_acc" "$up_acc"
    if [ "$IS_SILENT" == "0" ]; then echo -e "\n${GREEN}任务完成。${PLAIN}"; fi
    log "完成[$mode]: 流量=$(kb_to_mb $current_kb)MB 耗时=${dur}s"
    rm -f "$BG_PID_FILE"
}

install_cron() {
    check_env
    local bj_now_h=$($DATE_CMD -u -d "@$(now_sec)" +%H | sed 's/^0//')
    local local_now_h=$(date +%H | sed 's/^0//')
    local diff=$(( local_now_h - bj_now_h ))
    local svr_h=$(( BJ_CRON_HOUR + diff ))
    while [ "$svr_h" -lt 0 ]; do svr_h=$(( svr_h + 24 )); done
    while [ "$svr_h" -ge 24 ]; do svr_h=$(( svr_h - 24 )); done
    local tmp="$SCRIPT_DIR/cron.tmp"
    crontab -l 2>/dev/null | grep -F -v "$CRON_MARK" > "$tmp"
    echo "$BJ_CRON_MIN $svr_h * * * $SCRIPT_PATH --cron $CRON_MARK" >> "$tmp"
    if [ "$ENABLE_HOURLY" == "1" ]; then
        local intv="*/$HOURLY_INTERVAL_MIN * * * *"; [ "$HOURLY_INTERVAL_MIN" -eq 60 ] && intv="0 * * * *"
        echo "$intv $SCRIPT_PATH --hourly $CRON_MARK" >> "$tmp"
    fi
    if [ "$RANDOM_MODE_ENABLE" == "1" ]; then echo "*/10 * * * * $SCRIPT_PATH --random $CRON_MARK" >> "$tmp"; fi
    crontab "$tmp" && rm -f "$tmp"
    echo -e "${GREEN}Cron 更新成功!${PLAIN} 保底任务: 北京时间 $BJ_CRON_HOUR:$BJ_CRON_MIN"
}

uninstall_all() {
    echo -e "${YELLOW}正在卸载...${PLAIN}"
    crontab -l 2>/dev/null | grep -F -v "$CRON_MARK" > "$SCRIPT_DIR/cron.clean"
    crontab "$SCRIPT_DIR/cron.clean" && rm -f "$SCRIPT_DIR/cron.clean"
    [ -f "$BG_PID_FILE" ] && kill $(cat "$BG_PID_FILE") 2>/dev/null
    pkill -f "$SCRIPT_NAME" 2>/dev/null
    rm -f "$CONF_FILE" "$STATS_FILE" "$LOCK_DAILY" "$LOCK_HOURLY" "$LOCK_RANDOM" "$STATS_LOCK" "$BG_PID_FILE" "$TEMP_DATA_FILE"
    rm -rf "$LOG_DIR"
    echo -e "${GREEN}卸载完成。${PLAIN}"
    exit 0
}

entry_cron() {
    check_env; reseed_random
    sleep $(( RANDOM % 120 ))
    exec 9>"$LOCK_DAILY"; flock -n 9 || exit 0
    load_config; refresh_day_check
    if ! check_global_fuse; then exit 0; fi
    log "[Cron] 触发保底任务检查"
    
    local start_ts=$($DATE_CMD -u -d "$PERIOD_START_DATE 00:00:00" +%s 2>/dev/null)
    if [ -z "$start_ts" ]; then start_ts=$($DATE_CMD -d "$PERIOD_START_DATE" +%s 2>/dev/null); fi
    local cur_ts=$($DATE_CMD -u -d "$(get_logic_date) 00:00:00" +%s)
    local passed_days=$(( ( cur_ts - start_ts ) / 86400 ))
    local total_kb=$(gb_to_kb "$PERIOD_TARGET_GB")
    
    if [ "$passed_days" -ge "$PERIOD_DAYS" ] && [ "$PERIOD_KB" -ge "$total_kb" ]; then
        log "[Cycle] 周期重置。"
        PERIOD_START_DATE=$(get_logic_date)
        PERIOD_KB=0
        save_config; load_config
    fi
    
    local target_mb=$(calc_smart_target)
    local target_kb=$(mb_to_kb "$target_mb")
    local current_kb=${TODAY_KB:-0}
    
    if [ $(awk "BEGIN{print ($current_kb < $target_kb)?1:0}") -eq 1 ]; then
        local todo_kb=$(( target_kb - current_kb ))
        [ "$todo_kb" -lt 10240 ] && todo_kb=10240
        log "[Cron] 补齐缺口: $(kb_to_mb $todo_kb) MB"
        
        while [ "$todo_kb" -gt 0 ]; do
            if ! check_global_fuse; then break; fi
            local base_rnd=$(( RANDOM % 50 + 50 )) 
            local chunk_mb=$(awk "BEGIN{printf \"%.0f\", $R_SINGLE_MAX_MB * $base_rnd / 100}")
            local chunk_kb=$(mb_to_kb "$chunk_mb")
            
            if [ "$chunk_kb" -gt "$todo_kb" ]; then chunk_kb=$todo_kb; chunk_mb=$(kb_to_mb "$chunk_kb"); fi
            
            run_traffic "CRON" "DATA" "$chunk_mb" "0" "MIX"
            todo_kb=$(( todo_kb - chunk_kb ))
            
            if [ "$todo_kb" -gt 0 ]; then
                local slp=$(( RANDOM % 30 + 10 ))
                sleep "$slp"
            fi
        done
        mark_today_done
    else
        log "[Cron] 达标，跳过。"
    fi
}

entry_hourly() {
    check_env; reseed_random
    sleep $(( RANDOM % 60 ))
    exec 8>"$LOCK_HOURLY"; flock -n 8 || exit 0
    load_config; refresh_day_check
    if ! check_global_fuse; then exit 0; fi
    if [ "$TODAY_DONE" -eq 1 ]; then exit 0; fi
    if [ "$ENABLE_HOURLY" != "1" ]; then exit 0; fi
    local bj_h=$(get_bj_hour)
    if [ "$bj_h" -ge "$HOURLY_BJ_START" ] && [ "$bj_h" -le "$HOURLY_BJ_END" ]; then
        run_traffic "HOURLY" "DATA" "$HOURLY_TARGET_MB" "0" "MIX"
    fi
}

entry_random() {
    check_env; reseed_random
    local delay=$(( RANDOM % 120 + 1 ))
    sleep "$delay"
    
    exec 7>"$LOCK_RANDOM"; flock -n 7 || exit 0
    load_config; refresh_day_check
    if ! check_global_fuse; then exit 0; fi
    if [ "$RANDOM_MODE_ENABLE" != "1" ]; then exit 0; fi
    if [ "$TODAY_DONE" -eq 1 ]; then exit 0; fi
    
    local bj_h=$(get_bj_hour)
    if [ "$bj_h" -lt "$R_BJ_START" ] || [ "$bj_h" -gt "$R_BJ_END" ]; then exit 0; fi
    
    if [ $(( RANDOM % 100 )) -lt "$R_SKIP_PCT" ]; then 
        log "[Random] 随机跳过"
        exit 0
    fi
    
    local cur_dl=$(kb_to_mb $R_TODAY_DL)
    local cur_up=$(kb_to_mb $R_TODAY_UP)
    
    local dl_left=$(( R_TARGET_DL - ${cur_dl%.*} ))
    local up_left=$(( R_TARGET_UP - ${cur_up%.*} ))
    
    if [ "$dl_left" -le 0 ] && [ "$up_left" -le 0 ]; then
        mark_today_done
        exit 0
    fi
    
    local target_mb=0; local mode_dir=""; local choice=""
    if [ "$dl_left" -gt 0 ] && [ "$up_left" -gt 0 ]; then
        [ $(( RANDOM % 2 )) -eq 0 ] && choice="DL" || choice="UP"
    elif [ "$dl_left" -gt 0 ]; then choice="DL"
    else choice="UP"; fi
    
    if [ "$choice" == "DL" ]; then mode_dir="DOWNLOAD_ONLY"; target_mb=$dl_left
    else mode_dir="UPLOAD_ONLY"; target_mb=$up_left; fi
    
    local base_rnd=$(( RANDOM % 50 + 50 )) 
    local chunk_mb=$(awk "BEGIN{printf \"%.0f\", $R_SINGLE_MAX_MB * $base_rnd / 100}")
    local float_rnd=$(( RANDOM % (R_SINGLE_FLOAT_PCT * 2 + 1) - R_SINGLE_FLOAT_PCT ))
    chunk_mb=$(awk "BEGIN{printf \"%.0f\", $chunk_mb * (1 + $float_rnd / 100)}")
    
    [ "$chunk_mb" -lt 10 ] && chunk_mb=10
    if [ "$chunk_mb" -gt "$target_mb" ]; then chunk_mb=$target_mb; fi
    
    run_traffic "RANDOM" "DATA" "$chunk_mb" "0" "$mode_dir"
}

menu() {
    exec < /dev/tty
    check_env
    while true; do
        clear
        load_config
        echo -e "${BLUE}=== VPS Traffic Spirit v4.3.0 ===${PLAIN}"
        echo -e "${RED}[安全] 每日硬顶: ${GLOBAL_MAX_DAILY_GB} GB${PLAIN}"
        echo -e "${BOLD}[A] 周期保底${PLAIN}"
        echo -e " 1. 周期: ${GREEN}$PERIOD_DAYS${PLAIN}天 / ${GREEN}$PERIOD_TARGET_GB${PLAIN}GB"
        echo -e " 2. 时间: 北京 ${GREEN}$BJ_CRON_HOUR:$BJ_CRON_MIN${PLAIN}"
        echo -e "${BOLD}[B] 真实模拟 (今日DL:${R_TARGET_DL} / UP:${R_TARGET_UP} MB)${PLAIN}"
        echo -e " 3. 开关: $( [ $RANDOM_MODE_ENABLE -eq 1 ] && echo "${RED}ON${PLAIN}" || echo "OFF" )"
        echo -e " 4. 基准: 下 ${GREEN}$R_BASE_DAILY_DL_MB${PLAIN} / 上 ${GREEN}$R_BASE_DAILY_UP_MB${PLAIN} MB (浮动${R_DAILY_FLOAT_PCT}%)"
        echo -e " 5. 行为: 北京 ${GREEN}$R_BJ_START-${R_BJ_END}点${PLAIN} | 跳过${GREEN}$R_SKIP_PCT${PLAIN}% | 切片${GREEN}$R_SINGLE_MAX_MB${PLAIN}MB"
        echo -e " 6. 速率: 下 ${GREEN}$R_DL_SPEED_MB${PLAIN} / 上 ${GREEN}$R_UP_SPEED_MB${PLAIN} MB/s"
        echo -e "${BOLD}[C] 系统${PLAIN}"
        echo -e " 7. 设置: 全局限额 | 浮动 | 内存保护"
        echo -e "----------------------------------------------"
        echo -e " S. 保存 | 0. 退出"
        read -p "选项: " c
        case "$c" in
            1) read -p "天数: " d; [ -n "$d" ] && PERIOD_DAYS=$d; read -p "GB: " g; [ -n "$g" ] && PERIOD_TARGET_GB=$g ;;
            2) read -p "时(0-23): " h; [ -n "$h" ] && BJ_CRON_HOUR=$h; read -p "分: " m; [ -n "$m" ] && BJ_CRON_MIN=$m ;;
            3) read -p "1=开, 0=关: " v; [ -n "$v" ] && RANDOM_MODE_ENABLE=$v ;;
            4) read -p "DL基准(MB): " d; [ -n "$d" ] && R_BASE_DAILY_DL_MB=$d; read -p "UL基准(MB): " u; [ -n "$u" ] && R_BASE_DAILY_UP_MB=$u 
               read -p "每日浮动%: " f; [ -n "$f" ] && R_DAILY_FLOAT_PCT=$f ;;
            5) read -p "开始点: " s; [ -n "$s" ] && R_BJ_START=$s; read -p "结束点: " e; [ -n "$e" ] && R_BJ_END=$e
               read -p "跳过率%: " p; [ -n "$p" ] && R_SKIP_PCT=$p
               read -p "切片Max(MB): " m; [ -n "$m" ] && R_SINGLE_MAX_MB=$m; read -p "切片浮动%: " f; [ -n "$f" ] && R_SINGLE_FLOAT_PCT=$f ;;
            6) read -p "下载速: " d; [ -n "$d" ] && R_DL_SPEED_MB=$d; read -p "上传速: " u; [ -n "$u" ] && R_UP_SPEED_MB=$u ;;
            7) read -p "全局硬顶(GB): " g; [ -n "$g" ] && GLOBAL_MAX_DAILY_GB=$g; read -p "系统浮动%: " j; [ -n "$j" ] && JITTER_PERCENT=$j ;;
            s|S) save_config; install_cron; echo -e "${GREEN}保存成功!${PLAIN}"; sleep 1 ;;
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
    [ -f "$BG_PID_FILE" ] && kill -0 $(cat "$BG_PID_FILE") 2>/dev/null && bg_s="${GREEN}运行${PLAIN}"
    echo -e "${BLUE}=== VPS Traffic Spirit v4.3.0 ===${PLAIN}"
    echo -e " [保底] $(kb_to_gb $PERIOD_KB)/$PERIOD_TARGET_GB GB | 缺口: $(calc_smart_target) MB"
    echo -e " [模拟] $( [ $RANDOM_MODE_ENABLE -eq 1 ] && echo "${RED}ON${PLAIN}" || echo "OFF" ) | 今日: DL $(kb_to_mb $R_TODAY_DL) / UP $(kb_to_mb $R_TODAY_UP) MB"
    echo -e " [状态] 后台: $bg_s | 北京时间: $(get_bj_time_str)"
    echo -e "----------------------------------------------"
    echo -e " 1. 手动/测速"
    echo -e " 2. 菜单"
    echo -e " 3. 日志"
    echo -e " 4. 卸载"
    echo -e " 0. 退出"
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
                    echo -e "\n1.下载测速 2.前台跑 3.后台跑 4.纯上传"
                    read -p "选: " s
                    case "$s" in
                        1) echo "Testing..."; s=$(curl -s -w "%{speed_download}" -o /dev/null --max-time 10 "https://nbg1-speed.hetzner.com/10GB.bin"); echo "Speed: $(awk "BEGIN {printf \"%.2f\", $s/1048576}") MB/s"; read -p "..." ;;
                        2) read -p "MB: " d; read -p "MB/s: " sp; run_traffic "MANUAL" "DATA" "$d" "$sp" "MIX" ;;
                        3) read -p "MB: " d; read -p "MB/s: " sp; nohup "$SCRIPT_PATH" --bg-run "$d" "$sp" >/dev/null 2>&1 & echo $! > "$BG_PID_FILE"; read -p "Started..." ;;
                        4) read -p "MB: " d; read -p "MB/s: " sp; run_traffic "MANUAL" "DATA" "$d" "$sp" "UPLOAD_ONLY" ;;
                    esac ;;
                2) menu ;;
                3) tail -n 10 "$LOG_DIR/system.log"; read -p "..." ;;
                4) uninstall_all ;;
                0) exit 0 ;;
            esac
        done
        ;;
esac
