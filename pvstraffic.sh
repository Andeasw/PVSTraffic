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
DATE_CMD="date"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

mkdir -p "$LOG_DIR"

PERIOD_DAYS=7
PERIOD_TARGET_GB=9
PERIOD_START_DATE="$(date +%F)"
DAILY_TARGET_MB=1300
DAILY_TIME_MIN=120
CRON_MAX_SPEED_MB=10
BJ_CRON_HOUR=3
BJ_CRON_MIN=10

RANDOM_MODE_ENABLE=0
R_DAILY_DL_MB=500
R_DAILY_UP_MB=300
R_DL_SPEED_MB=5
R_UP_SPEED_MB=2
R_UTC8_START=8
R_UTC8_END=22

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

reseed_random() {
    local seed
    if [ -r /dev/urandom ]; then
        seed=$(od -An -N4 -t u4 /dev/urandom | tr -d ' ')
    else
        seed=$(date +%s%N)
    fi
    RANDOM=$seed
}

now_sec() { $DATE_CMD +%s; }
mb_to_kb() { awk "BEGIN{printf \"%.0f\", $1 * 1024}"; }
kb_to_mb() { awk "BEGIN{printf \"%.2f\", $1 / 1024}"; }
kb_to_gb() { awk "BEGIN{printf \"%.2f\", $1 / 1024 / 1024}"; }
gb_to_kb() { awk "BEGIN{printf \"%.0f\", $1 * 1024 * 1024}"; }

apply_jitter() {
    local val=${1:-0}
    local rnd=$(( RANDOM % (JITTER_PERCENT + 1) ))
    awk "BEGIN{printf \"%.0f\", $val * (1 + $rnd / 100)}"
}

log() {
    local ts="$($DATE_CMD '+%F %T')"
    echo -e "[$ts] $*" >> "$LOG_DIR/system.log"
    if [ "$IS_SILENT" != "1" ]; then echo -e "[$ts] $*"; fi
}

check_env() {
    local fix=0
    if ! command -v crontab >/dev/null 2>&1; then fix=1; fi
    if ! command -v curl >/dev/null 2>&1; then fix=1; fi
    
    if ! date -d "now" >/dev/null 2>&1; then
        if [ -x /usr/bin/date ] && /usr/bin/date -d "now" >/dev/null 2>&1; then
            DATE_CMD="/usr/bin/date"
        else
            fix=1
        fi
    fi

    if [ "$fix" -eq 1 ]; then
        if [ -f /etc/debian_version ]; then apt-get update -y -q && apt-get install -y -q cron curl coreutils; fi
        if [ -f /etc/redhat-release ]; then yum install -y -q cronie curl coreutils; fi
        if [ -f /etc/alpine-release ]; then apk add cronie curl coreutils; fi
    fi
    
    if ! date -d "now" >/dev/null 2>&1; then
        if [ -x /usr/bin/date ]; then DATE_CMD="/usr/bin/date"; fi
    else
        DATE_CMD="date"
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
    R_TODAY_DL=${R_TODAY_DL:-0}
    R_TODAY_UP=${R_TODAY_UP:-0}
    R_LAST_DAY=${R_LAST_DAY:-""}
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

refresh_day_check() {
    local today_str=$($DATE_CMD +%F)
    
    if [ "$R_LAST_DAY" != "$today_str" ]; then
        R_TODAY_DL=0
        R_TODAY_UP=0
        TODAY_KB=0
        TODAY_RUN_SEC=0
        R_LAST_DAY="$today_str"
        
        cat >"$STATS_FILE"<<EOF
TODAY_KB=$TODAY_KB
TODAY_RUN_SEC=$TODAY_RUN_SEC
PERIOD_KB=$PERIOD_KB
LAST_RUN_TIME="$($DATE_CMD '+%F %T')"
LAST_RUN_KB=0
R_TODAY_DL=$R_TODAY_DL
R_TODAY_UP=$R_TODAY_UP
R_LAST_DAY="$R_LAST_DAY"
EOF
    fi
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
        TODAY_RUN_SEC=${TODAY_RUN_SEC:-0}
        
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
LAST_RUN_TIME="$($DATE_CMD '+%F %T')"
LAST_RUN_KB=$add_kb
R_TODAY_DL=$R_TODAY_DL
R_TODAY_UP=$R_TODAY_UP
R_LAST_DAY="$R_LAST_DAY"
EOF
    ) 200>"$STATS_LOCK"
}

calc_smart_target() {
    local start_s=$($DATE_CMD -d "$PERIOD_START_DATE" +%s)
    local cur_s=$(now_sec)
    local passed_days=$(( ( cur_s - start_s ) / 86400 ))
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
    
    echo $(apply_jitter "$final_target_mb")
}

check_random_window_utc8() {
    local utc_h=$($DATE_CMD -u +%H | sed 's/^0//')
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
    [ "${disk_kb:-0}" -lt 51200 ] && log "${YELLOW}[Warn] Low Disk Space${PLAIN}"
    
    if [ "$direction" == "UPLOAD_ONLY" ] || [ "$ENABLE_UPLOAD" == "1" ]; then
        local mem_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
        [ -z "$mem_kb" ] && mem_kb=$(awk '/MemFree/ {print $2}' /proc/meminfo)
        if [ "${mem_kb:-0}" -lt "$MEM_PROTECT_KB" ]; then
             [ "$direction" == "UPLOAD_ONLY" ] && log "${YELLOW}[Skip] Low Memory${PLAIN}" && return
             ENABLE_UPLOAD=0
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
            calculated_speed_kb=$(awk "BEGIN{printf \"%.0f\", $target_kb / $t_sec}")
        else
            calculated_speed_kb=$speed_kb
        fi
        
        if [ "$mode" == "CRON" ] || [ "$mode" == "MANUAL" ]; then
            calculated_speed_kb=$(apply_jitter "$calculated_speed_kb")
        fi

        local cap_kb=$(mb_to_kb "$CRON_MAX_SPEED_MB")
        if [[ "$mode" == "CRON" ]] && [ "${calculated_speed_kb:-0}" -gt "${cap_kb:-0}" ]; then 
            calculated_speed_kb=$cap_kb
        fi
        [ "${calculated_speed_kb:-0}" -lt 512 ] && calculated_speed_kb=512
        speed_kb=$calculated_speed_kb
    else
        speed_kb=$(apply_jitter "$speed_kb")
    fi

    if [ "$direction" == "UPLOAD_ONLY" ] || [ "$ENABLE_UPLOAD" == "1" ]; then
        prepare_upload_data
    fi
    
    local msg="Task[$mode] Dir:$direction"
    log "$msg Limit:$(kb_to_mb $speed_kb)MB/s Target:$val"
    
    local start_ts=$(now_sec)
    local current_kb=0
    local dl_acc=0
    local up_acc=0
    
    trap 'pkill -P $$; rm -f "$BG_PID_FILE"; exit' EXIT INT TERM

    while true; do
        local dl_url=$(get_dl_url)
        local up_url=$(get_up_url) 
        local PID_DL=""
        local PID_UP=""
        local dl_real_speed=0
        local ul_real_speed=0

        if [ "$direction" != "UPLOAD_ONLY" ]; then
            dl_real_speed=$speed_kb
            nice -n 10 curl -4 -sL --max-time 300 --connect-timeout 15 --limit-rate "${dl_real_speed}k" --output /dev/null "$dl_url" &
            PID_DL=$!
        fi

        if [ "$direction" != "DOWNLOAD_ONLY" ]; then
            if [ "$direction" == "UPLOAD_ONLY" ]; then
                 ul_real_speed=$speed_kb
            elif [ "$ENABLE_UPLOAD" == "1" ]; then
                 ul_real_speed=$(awk "BEGIN{printf \"%.0f\", $dl_real_speed * ${UPLOAD_RATIO:-3} / 100}")
            fi
            
            if [ "${ul_real_speed:-0}" -gt 10 ]; then
                (
                    PARENT_PID=$$
                    ulimit -v 65536
                    while kill -0 "$PARENT_PID" 2>/dev/null; do
                        nice -n 15 curl -4 -sL --max-time 60 --connect-timeout 10 \
                            --limit-rate "${ul_real_speed}k" \
                            --data-binary "@$TEMP_DATA_FILE" \
                            "$up_url" --output /dev/null 2>/dev/null
                        sleep 0.1
                    done
                ) &
                PID_UP=$!
            fi
        fi

        local loop_start=$(now_sec)

        while ( [ -n "$PID_DL" ] && kill -0 $PID_DL 2>/dev/null ) || ( [ -n "$PID_UP" ] && kill -0 $PID_UP 2>/dev/null ); do
            sleep 1
            local elapsed=$(( $(now_sec) - start_ts ))
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
                echo -ne "\r[Running] Prog:${pct}% | Total:$(kb_to_mb $current_kb)MB | DL:~$(kb_to_mb $tick_dl)MB/s UL:~$(kb_to_mb $tick_up)MB/s "
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
    local is_rnd=0
    [ "$mode" == "RANDOM" ] && is_rnd=1
    update_stats "$current_kb" "$dur" "$is_rnd" "$dl_acc" "$up_acc"
    if [ "$IS_SILENT" == "0" ]; then echo -e "\n${GREEN}Completed.${PLAIN}"; fi
    log "Done[$mode]: Traffic=$(kb_to_mb $current_kb)MB Time=${dur}s"
    rm -f "$BG_PID_FILE"
}

install_cron() {
    check_env
    local offset=$($DATE_CMD +%z | sed 's/^+//' | cut -c1-3)
    local svr_h=$(( BJ_CRON_HOUR - 8 + offset ))
    while [ "$svr_h" -lt 0 ]; do svr_h=$(( svr_h + 24 )); done
    while [ "$svr_h" -ge 24 ]; do svr_h=$(( svr_h - 24 )); done
    local tmp="$SCRIPT_DIR/cron.tmp"
    crontab -l 2>/dev/null | grep -F -v "$CRON_MARK" > "$tmp"
    
    echo "$BJ_CRON_MIN $svr_h * * * $SCRIPT_PATH --cron $CRON_MARK" >> "$tmp"
    if [ "$ENABLE_HOURLY" == "1" ]; then
        local intv="*/$HOURLY_INTERVAL_MIN * * * *"; [ "$HOURLY_INTERVAL_MIN" -eq 60 ] && intv="0 * * * *"
        echo "$intv $SCRIPT_PATH --hourly $CRON_MARK" >> "$tmp"
    fi
    if [ "$RANDOM_MODE_ENABLE" == "1" ]; then
        echo "*/10 * * * * $SCRIPT_PATH --random $CRON_MARK" >> "$tmp"
    fi
    
    crontab "$tmp" && rm -f "$tmp"
    echo -e "${GREEN}Cron Updated!${PLAIN} Guarantee Run: Local $svr_h:$BJ_CRON_MIN"
}

uninstall_all() {
    echo -e "${YELLOW}Uninstalling...${PLAIN}"
    crontab -l 2>/dev/null | grep -F -v "$CRON_MARK" > "$SCRIPT_DIR/cron.clean"
    crontab "$SCRIPT_DIR/cron.clean"
    rm -f "$SCRIPT_DIR/cron.clean"
    [ -f "$BG_PID_FILE" ] && kill $(cat "$BG_PID_FILE") 2>/dev/null
    pkill -f "$SCRIPT_NAME" 2>/dev/null
    rm -f "$CONF_FILE" "$STATS_FILE" "$LOCK_DAILY" "$LOCK_HOURLY" "$LOCK_RANDOM" "$STATS_LOCK" "$BG_PID_FILE" "$TEMP_DATA_FILE"
    rm -rf "$LOG_DIR"
    echo -e "${GREEN}Done.${PLAIN}"
    exit 0
}

entry_cron() {
    check_env
    reseed_random
    sleep $(( RANDOM % 120 ))
    exec 9>"$LOCK_DAILY"; flock -n 9 || exit 0
    load_config
    log "[Cron] Guarantee Triggered"
    refresh_day_check
    
    local start_s=$($DATE_CMD -d "$PERIOD_START_DATE" +%s)
    local cur_s=$(now_sec)
    local passed_days=$(( ( cur_s - start_s ) / 86400 ))
    local total_kb=$(gb_to_kb "$PERIOD_TARGET_GB")
    
    if [ "$passed_days" -ge "$PERIOD_DAYS" ] && [ "$PERIOD_KB" -ge "$total_kb" ]; then
        log "[Cycle] Cycle finished. Resetting to today."
        PERIOD_START_DATE=$($DATE_CMD +%F)
        PERIOD_KB=0
        save_config
        load_config
    fi
    
    local target_mb=$(calc_smart_target)
    local target_kb=$(mb_to_kb "$target_mb")
    local current_kb=${TODAY_KB:-0}

    log "[Cron] Check: Done=$(kb_to_mb $current_kb) MB, Target=$target_mb MB"
    
    if [ $(awk "BEGIN{print ($current_kb < $target_kb)?1:0}") -eq 1 ]; then
        local todo_kb=$(( target_kb - current_kb ))
        [ "$todo_kb" -lt 10240 ] && todo_kb=10240
        local todo_mb=$(kb_to_mb "$todo_kb")
        
        run_traffic "CRON" "DATA" "$todo_mb" "0" "MIX"
    else
        log "[Cron] Target met, skipping."
    fi
}

entry_hourly() {
    check_env
    reseed_random
    sleep $(( RANDOM % 60 ))
    exec 8>"$LOCK_HOURLY"; flock -n 8 || exit 0
    load_config
    refresh_day_check
    if [ "$ENABLE_HOURLY" != "1" ]; then exit 0; fi
    local bj_h=$($DATE_CMD -u -d "+8 hours" +%H | sed 's/^0//')
    if [ "$bj_h" -ge "$HOURLY_BJ_START" ] && [ "$bj_h" -le "$HOURLY_BJ_END" ]; then
        run_traffic "HOURLY" "DATA" "$HOURLY_TARGET_MB" "0" "MIX"
    fi
}

entry_random() {
    check_env
    reseed_random
    sleep $(( RANDOM % 120 ))
    exec 7>"$LOCK_RANDOM"; flock -n 7 || exit 0
    load_config
    refresh_day_check
    
    if [ "$RANDOM_MODE_ENABLE" != "1" ]; then exit 0; fi
    if ! check_random_window_utc8; then exit 0; fi
    
    if [ $(( RANDOM % 100 )) -lt 30 ]; then exit 0; fi
    log "[Random] Triggered"
    
    local cur_dl=$(kb_to_mb $R_TODAY_DL)
    local cur_up=$(kb_to_mb $R_TODAY_UP)
    local can_dl=0
    local can_up=0
    
    if [ $(awk "BEGIN{print ($cur_dl < $R_DAILY_DL_MB)?1:0}") -eq 1 ]; then can_dl=1; fi
    if [ $(awk "BEGIN{print ($cur_up < $R_DAILY_UP_MB)?1:0}") -eq 1 ]; then can_up=1; fi
    
    if [ "$can_dl" -eq 0 ] && [ "$can_up" -eq 0 ]; then
        exit 0
    fi
    
    local base_min=$(( RANDOM % 11 + 5 ))
    local run_sec=$(apply_jitter $(( base_min * 60 )) )
    local mode_dir=""
    local run_speed=0
    
    if [ "$can_dl" -eq 1 ] && [ "$can_up" -eq 1 ]; then
        local r=$(( RANDOM % 3 ))
        if [ $r -eq 0 ]; then mode_dir="DOWNLOAD_ONLY"; run_speed=$R_DL_SPEED_MB
        elif [ $r -eq 1 ]; then mode_dir="UPLOAD_ONLY"; run_speed=$R_UP_SPEED_MB
        else mode_dir="DOWNLOAD_ONLY"; run_speed=$R_DL_SPEED_MB; fi
    elif [ "$can_dl" -eq 1 ]; then
        mode_dir="DOWNLOAD_ONLY"
        run_speed=$R_DL_SPEED_MB
    elif [ "$can_up" -eq 1 ]; then
        mode_dir="UPLOAD_ONLY"
        run_speed=$R_UP_SPEED_MB
    fi
    
    run_traffic "RANDOM" "TIME" "$run_sec" "$run_speed" "$mode_dir"
}

menu() {
    exec < /dev/tty
    check_env
    while true; do
        clear
        load_config
        echo -e "${BLUE}=== VPS Traffic Spirit v1.0.0 ===${PLAIN}"
        echo -e "${BOLD}[A] Guarantee Mode${PLAIN}"
        echo -e " 1. Cycle: ${GREEN}$PERIOD_DAYS${PLAIN} Days / ${GREEN}$PERIOD_TARGET_GB${PLAIN} GB"
        echo -e " 2. Start: $PERIOD_START_DATE"
        echo -e " 3. Start Time: BJ ${GREEN}$BJ_CRON_HOUR:$BJ_CRON_MIN${PLAIN}"
        echo -e "${BOLD}[B] Simulation Mode${PLAIN}"
        echo -e " 4. Status: $( [ $RANDOM_MODE_ENABLE -eq 1 ] && echo "${RED}ON${PLAIN}" || echo "OFF" )"
        echo -e " 5. Limits: DL ${GREEN}$R_DAILY_DL_MB${PLAIN} / UL ${GREEN}$R_DAILY_UP_MB${PLAIN} MB"
        echo -e " 6. Speed: DL ${GREEN}$R_DL_SPEED_MB${PLAIN} / UL ${GREEN}$R_UP_SPEED_MB${PLAIN} MB/s"
        echo -e " 7. Time: UTC-8 ${GREEN}$R_UTC8_START - $R_UTC8_END${PLAIN}"
        echo -e "${BOLD}[C] System${PLAIN}"
        echo -e " 8. Settings: Jitter ${GREEN}$JITTER_PERCENT${PLAIN}% | MemGuard ${GREEN}$((MEM_PROTECT_KB/1024))${PLAIN}MB"
        echo -e "----------------------------------------------"
        echo -e " S. Save | 0. Exit"
        read -p "Opt: " c
        case "$c" in
            1) read -p "Days: " d; [ -n "$d" ] && PERIOD_DAYS=$d; read -p "GB: " g; [ -n "$g" ] && PERIOD_TARGET_GB=$g ;;
            2) read -p "Date(YYYY-MM-DD): " v; [ -n "$v" ] && PERIOD_START_DATE=$v ;;
            3) read -p "Hour: " h; [ -n "$h" ] && BJ_CRON_HOUR=$h; read -p "Min: " m; [ -n "$m" ] && BJ_CRON_MIN=$m ;;
            4) read -p "1=On, 0=Off: " v; [ -n "$v" ] && RANDOM_MODE_ENABLE=$v ;;
            5) read -p "DL Max(MB): " d; [ -n "$d" ] && R_DAILY_DL_MB=$d; read -p "UL Max(MB): " u; [ -n "$u" ] && R_DAILY_UP_MB=$u ;;
            6) read -p "DL Speed: " d; [ -n "$d" ] && R_DL_SPEED_MB=$d; read -p "UL Speed: " u; [ -n "$u" ] && R_UP_SPEED_MB=$u ;;
            7) read -p "Start Hr: " s; [ -n "$s" ] && R_UTC8_START=$s; read -p "End Hr: " e; [ -n "$e" ] && R_UTC8_END=$e ;;
            8) read -p "Jitter %: " j; [ -n "$j" ] && JITTER_PERCENT=$j ;;
            s|S) save_config; install_cron; echo -e "${GREEN}Saved!${PLAIN}"; sleep 1 ;;
            0) break ;;
        esac
    done
}

dashboard() {
    exec < /dev/tty
    check_env
    clear
    load_config
    local bg_s="${RED}No${PLAIN}"
    [ -f "$BG_PID_FILE" ] && kill -0 $(cat "$BG_PID_FILE") 2>/dev/null && bg_s="${GREEN}Yes${PLAIN}"
    local smart=$(calc_smart_target)
    echo -e "${BLUE}=== VPS Traffic Spirit v2.5.0 ===${PLAIN}"
    echo -e " [Guarantee] $(kb_to_gb $PERIOD_KB)/$PERIOD_TARGET_GB GB | Today Target: ${YELLOW}$smart MB${PLAIN}"
    echo -e " [Simulate] $( [ $RANDOM_MODE_ENABLE -eq 1 ] && echo "${RED}ON${PLAIN}" || echo "OFF" ) | Today: DL $(kb_to_mb $R_TODAY_DL) / UP $(kb_to_mb $R_TODAY_UP) MB"
    echo -e " [Status] BG: $bg_s | DateCmd: ${GREEN}$DATE_CMD${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e " 1. Manual / Speedtest"
    echo -e " 2. Menu"
    echo -e " 3. Logs"
    echo -e " 4. Uninstall"
    echo -e " 0. Exit"
    echo -n " Select: "
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
                    echo -e "\n1.Test 2.FgRun 3.BgRun 4.UploadOnly"
                    read -p "Opt: " s
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
