#!/bin/bash

(sleep 21600 && echo "⏰ Force shutdown after exactly 360 minutes" && \
 pkill -f "nexus-network" 2>/dev/null && \
 pkill -f "expect .*nexus-network" 2>/dev/null && \
 pkill -f "rnxs.sh" 2>/dev/null && \
 echo "Force shutdown executed" && exit 143) &

trap shutdown SIGINT SIGTERM

NODES_FILE="${NID:-nid.txt}"
if [ ! -f "$NODES_FILE" ]; then
    echo "Error: File $NODES_FILE not found in current directory."
    echo "Please ensure the node ID file exists."
    exit 1
fi

mapfile -t NODES < <(grep -v '^#' "$NODES_FILE" | grep -v '^$' | tr -d '\r')
if [ ${#NODES[@]} -eq 0 ]; then
    echo "Error: No valid Node IDs found in $NODES_FILE."
    exit 1
fi

for node in "${NODES[@]}"; do
    if ! [[ "$node" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid node ID '$node' found in $NODES_FILE."
        exit 1
    fi
done

echo "Successfully loaded ${#NODES[@]} node IDs from $NODES_FILE"
echo "First Node: ${NODES[0]} | Last Node: ${NODES[-1]}"

WEBHOOK_URL="${WEBHOOK_1}"
ALT_WEBHOOK_URL="${WEBHOOK_2}"
SYSTEM_WEBHOOK_URL="${WEBHOOK_3}"
FALLBACK_NEXUS_URL="https://github.com/nexus-xyz/nexus-cli/releases/download/v0.10.18/nexus-network-linux-x86_64"
USERNAME="$(whoami)"
HOSTNAME="$(hostname -s)"
CONCURRENCY=1
DEFAULT_LOG_MODE="logfull"
LOG_MODE="${LOG_MODE:-$DEFAULT_LOG_MODE}"
HEARTBEAT_PID=""
DEFAULT_MODE="refresh"
MODE="${MODE:-$DEFAULT_MODE}"
SYSTEM_INFO_PID=""
DEFAULT_REFRESH_SUCCESS_TARGET=1
REFRESH_SUCCESS_TARGET="${REFRESH_SUCCESS_TARGET:-$DEFAULT_REFRESH_SUCCESS_TARGET}"
export REFRESH_SUCCESS_TARGET
DEFAULT_REFRESH_ACCUMULATE=1
REFRESH_ACCUMULATE="${REFRESH_ACCUMULATE:-$DEFAULT_REFRESH_ACCUMULATE}"
DEFAULT_SEND_DISCORD=1
SEND_DISCORD="${SEND_DISCORD:-$DEFAULT_SEND_DISCORD}"
DEFAULT_LOOP_MODE="once"
LOOP_MODE="${LOOP_MODE:-$DEFAULT_LOOP_MODE}"
DEFAULT_LOOP_DELAY_SEC=300
LOOP_DELAY_SEC="${LOOP_DELAY_SEC:-$DEFAULT_LOOP_DELAY_SEC}"

check_dependencies() {
    local missing_deps=()
    for cmd in expect curl jq wget; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "Installing dependencies: ${missing_deps[*]}"
        sudo apt-get update > /dev/null 2>&1
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_deps[@]}" > /dev/null 2>&1
        for cmd in "${missing_deps[@]}"; do
            if ! command -v "$cmd" &> /dev/null; then
                echo "Error: Failed to install '$cmd'."
                exit 1
            fi
        done
        echo "Dependencies installed successfully."
    fi
}

send_discord_message() {
    [ "$SEND_DISCORD" = "0" ] && return 0
    [ -z "$WEBHOOK_URL" ] && return 0
    local content="$1"
    local payload
    payload=$(jq -n --arg username "${USERNAME}@${HOSTNAME}" --arg content "$content" '{username: $username, content: $content}')
    curl -s -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" > /dev/null
}

send_discord_message_alt() {
    [ "$SEND_DISCORD" = "0" ] && return 0
    local content="$1"
    if [ -z "$ALT_WEBHOOK_URL" ]; then
        return 0
    fi
    local payload
    payload=$(jq -n --arg username "${USERNAME}@${HOSTNAME}" --arg content "$content" '{username: $username, content: $content}')
    curl -s -H "Content-Type: application/json" -d "$payload" "$ALT_WEBHOOK_URL" > /dev/null
}

send_discord_message_system() {
    [ "$SEND_DISCORD" = "0" ] && return 0
    local content="$1"
    if [ -z "$SYSTEM_WEBHOOK_URL" ]; then
        return 0
    fi
    local payload
    payload=$(jq -n --arg username "${USERNAME}@${HOSTNAME}" --arg content "$content" '{username: $username, content: $content}')
    curl -s -H "Content-Type: application/json" -d "$payload" "$SYSTEM_WEBHOOK_URL" > /dev/null
}

send_node_success() {
    [ "$SEND_DISCORD" = "0" ] && return 0
    local node_id="$1"
    local points="$2"
    local line_number="$3"
    local current_success="$4"
    local version_suffix=""
    if [ -n "$NEXUS_VERSION_STR" ]; then
        version_suffix=" ${NEXUS_VERSION_STR}"
    fi
    local content="✅ SUCCESS ${current_success} - Node ${node_id} submitted successfully! User: ${USERNAME}@${HOSTNAME}${version_suffix} (Group ${GROUP_NUMBER})"
    send_discord_message "$content"
}

send_node_error() {
    [ "$SEND_DISCORD" = "0" ] && return 0
    local node_id="$1"
    local error_msg="$2"
    local content="❌ ERROR - Node ${node_id}"$'\n'"User: ${USERNAME}@${HOSTNAME}"$'\n'"Error: ${error_msg}"
    send_discord_message "$content"
}

send_group_startup() {
    [ "$SEND_DISCORD" = "0" ] && return 0
    local content
    local mode_str="$MODE"
    local nodes_info
    if [ ${#NODES[@]} -eq 1 ]; then
        nodes_info="${NODES[0]}"
    else
        nodes_info="First: ${NODES[0]} Last: ${NODES[-1]}"
    fi
    content=$(printf "🚀 Runner Started (Mode: %s)\nℹ️ User: %s@%s\nℹ️ Group %s (%s nodes): %s" \
        "$mode_str" "$USERNAME" "$HOSTNAME" "$GROUP_NUMBER" "${#NODES[@]}" "$nodes_info")
    send_discord_message "$content"
    send_discord_message_alt "$content"
}

send_group_shutdown() {
    [ "$SEND_DISCORD" = "0" ] && return 0
    local content
    content=$(printf "💀 Runner Shutdown\nUser: %s@%s\nGroup %s (%s nodes)" \
        "$USERNAME" "$HOSTNAME" "$GROUP_NUMBER" "${#NODES[@]}")
    send_discord_message "$content"
}

kill_existing_instances() {
    local script_name="rnxs.sh"
    local current_pid=$$
    echo "Checking for existing instances of $script_name..."
    local existing_pids
    existing_pids=$(pgrep -f "$script_name" | grep -v "^$current_pid$")
    if [ -n "$existing_pids" ]; then
        echo "Found existing instances (PIDs: $existing_pids). Terminating..."
        echo "$existing_pids" | xargs kill -TERM 2>/dev/null
        sleep 2
        echo "$existing_pids" | xargs kill -KILL 2>/dev/null
        echo "Existing instances terminated."
    else
        echo "No existing instances found."
    fi
    echo "Cleaning up hanging nexus-network processes..."
    pkill -f "nexus-network" 2>/dev/null || true
    echo "Cleanup complete."
}

shutdown() {
    echo -e "\nShutting down runner..."
    send_group_shutdown
   
    if [ -n "$HEARTBEAT_PID" ] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
        kill -TERM "$HEARTBEAT_PID" 2>/dev/null || true
        sleep 1
        kill -KILL "$HEARTBEAT_PID" 2>/dev/null || true
    fi
   
    if [ -n "$SYSTEM_INFO_PID" ] && kill -0 "$SYSTEM_INFO_PID" 2>/dev/null; then
        kill -TERM "$SYSTEM_INFO_PID" 2>/dev/null || true
        sleep 1
        kill -KILL "$SYSTEM_INFO_PID" 2>/dev/null || true
    fi
   
    if [ ${#ACTIVE_PIDS[@]} -gt 0 ]; then
        for pid in "${ACTIVE_PIDS[@]}"; do
            [ -z "$pid" ] && continue
            kill -TERM "$pid" 2>/dev/null || true
        done
        sleep 2
        for pid in "${ACTIVE_PIDS[@]}"; do
            [ -z "$pid" ] && continue
            kill -KILL "$pid" 2>/dev/null || true
        done
    fi
   
    pkill -f "nexus-network" 2>/dev/null || true
    pkill -f "expect .*nexus-network" 2>/dev/null || true
    pkill -f "tail -n +1 -F" 2>/dev/null || true
   
    echo "Shutdown complete."
    exit 0
}

get_progress_bar() {
    local pct=$1
    local max_blocks=10
    local filled=$(( (pct + 5) / 10 ))
    [ "$filled" -gt "$max_blocks" ] && filled=$max_blocks
    local bar=""
    for ((i=0; i<max_blocks; i++)); do
        if [ "$i" -lt "$filled" ]; then
            bar="${bar}█"
        else
            bar="${bar}░"
        fi
    done
    echo "$bar"
}

start_system_info_reporter() {
    [ "$SEND_DISCORD" = "0" ] && return 0
    (
        while :; do
            local threads cores total_mb used_mb cpu_pct
            threads=$(nproc --all 2>/dev/null || echo 1)
            cores=$(lscpu 2>/dev/null | awk -F: '/Core\(s\) per socket/{gsub(/ /,""); print $2}' | head -1 || echo "$threads")
            total_mb=$(awk '/MemTotal:/ {printf "%d", $2/1024 }' /proc/meminfo 2>/dev/null || echo 1024)
            used_mb=$(awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} END {printf "%d", (t-a)/1024 }' /proc/meminfo 2>/dev/null || echo 512)
            cpu_pct=$(awk '{u=$2+$4; t=$2+$4+$5} END {if (NR==1) {print 0} else {printf "%d", (u*100)/t}}' <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat) 2>/dev/null || echo 0)
            
            local ram_pct=$(( used_mb * 100 / total_mb ))
            local cpu_bar=$(get_progress_bar "$cpu_pct")
            local ram_bar=$(get_progress_bar "$ram_pct")
            
            local content
            content=$(printf "🖥️ System info: %s (Group %s)\n🖥️ CPU: %s cores %s threads, RAM: %sMB\n⚠️ Usage:\n🔄 %s CPU %s%%\n🔄 %s RAM %sMB" \
                "$USERNAME" "$GROUP_NUMBER" "$cores" "$threads" "$total_mb" "$cpu_bar" "$cpu_pct" "$ram_bar" "$used_mb")
            send_discord_message_system "$content"
            sleep 600
        done
    ) & SYSTEM_INFO_PID=$!
}

check_dependencies
kill_existing_instances

if [ "$#" -ne 1 ]; then
    echo "Error: Exactly one argument (group number) required."
    echo "Usage: $0 <group_number>"
    exit 1
fi

if ! [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "Error: Group number must be a positive integer."
    exit 1
fi

GROUP_NUMBER="$1"

if ! command -v nexus-network &> /dev/null; then
    echo "Nexus CLI not found. Installing..."
    mkdir -p "$HOME/.nexus/bin"
    echo "Downloading from $FALLBACK_NEXUS_URL..."
    if wget -O "$HOME/.nexus/bin/nexus-network" "$FALLBACK_NEXUS_URL"; then
        chmod +x "$HOME/.nexus/bin/nexus-network"
        export PATH="$HOME/.nexus/bin:$PATH"
        echo "Nexus CLI installed successfully."
    else
        echo "Error: Failed to download Nexus CLI."
        exit 1
    fi
fi

if command -v nexus-network >/dev/null 2>&1; then
    NEXUS_VERSION_STR="v$(nexus-network -V 2>/dev/null | awk '{print $2}')"
else
    NEXUS_VERSION_STR=""
fi

send_group_startup

echo "Starting runner for group ${GROUP_NUMBER} with ${#NODES[@]} nodes"

if [ "$MODE" = "live" ]; then
    echo "Mode: live - nodes run continuously"
elif [ "$MODE" = "liveauto" ]; then
    echo "Mode: liveauto - continuous with auto-restart on errors"
else
    if [ "$REFRESH_ACCUMULATE" = "1" ]; then
        echo "Mode: refresh - node continues to run to build difficulty"
    else
        echo "Mode: refresh - run until target success or error"
    fi
fi

echo "Concurrency: ${CONCURRENCY}"
echo "Loop mode: ${LOOP_MODE}"
echo -e "\n============================================="
echo " >>> Press Ctrl+C to stop <<<"
echo "============================================="

if [ "$LOG_MODE" = "mini" ]; then
    ( while true; do sleep 150; echo "Still running..."; done ) & HEARTBEAT_PID=$!
fi

start_system_info_reporter

start_node_by_idx_refresh_accumulate() {
    local arr_idx="$1"
    local node="${NODES[$arr_idx]}"
    local line_number=$((arr_idx + 1))
    node_index=$((node_index + 1))
    if [ "$LOG_MODE" = "default" ] || [ "$LOG_MODE" = "logfull" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Group ${GROUP_NUMBER} - Starting node ${node_index}/${#NODES[@]} ($node)"
    fi
   
    (
        fifo="/tmp/nexus_fifo_${GROUP_NUMBER}_${node_index}"
        export NODE_ID="$node"
       
        if [ "$LOG_MODE" = "logfull" ]; then
            log_file="/tmp/nexus_log_${GROUP_NUMBER}_${node_index}.log"
            : > "$log_file"
            ( stdbuf -oL -eL tail -n +1 -F "$log_file" 2>/dev/null | stdbuf -oL -eL tr '\r' '\n' | while IFS= read -r l; do
                case "$l" in
                    SUCCESS_DETECTED:*|ERROR_DETECTED:*|PROCESS_EXITED) ;;
                    *) [ -n "$l" ] && echo "[${line_number}] $l" ;;
                esac
            done ) & TAIL_PID=$!
            disown $TAIL_PID 2>/dev/null || true
            export LOG_FILE="$log_file"
        else
            LOG_FILE=""
            unset LOG_FILE
        fi
       
        successes=0
        errors=0
        done_run=0
       
        while [ "$done_run" -eq 0 ]; do
            rm -f "$fifo"
            mkfifo "$fifo"
           
            expect <<'EOF' > "$fifo" 2>&1 & expect_pid=$!
set timeout -1
if {[info exists env(LOG_FILE)] && $env(LOG_FILE) ne ""} {
    log_user 0
    log_file -a $env(LOG_FILE)
} else {
    log_user 1
}
spawn nexus-network start --node-id $env(NODE_ID) --headless --max-difficulty small_medium --max-threads 2
expect {
    -re {Success \[.*\] Step 4 of 4: Proof submitted.*} {
        puts "SUCCESS_DETECTED:0"
        exp_continue
    }
    -re {Success \[.*\] Step 4 of 4: Submitted!.*\(([0-9]+)\) points} {
        set points $expect_out(1,string)
        puts "SUCCESS_DETECTED:$points"
        exp_continue
    }
    -re {Success \[.*\] Step 4 of 4: Submitted!} {
        puts "SUCCESS_DETECTED:0"
        exp_continue
    }
    -re {Error \[.*\] Failed to check for updates: GitHub API returned status: 403 Forbidden} {
        exp_continue
    }
    -re {Error \[.*\].*} {
        set error_line $expect_out(0,string)
        puts "ERROR_DETECTED:$error_line"
        exp_continue
    }
    eof {
        puts "PROCESS_EXITED"
        exit
    }
}
EOF
            while IFS= read -r line; do
                case "$line" in
                    SUCCESS_DETECTED:*)
                        points="${line#SUCCESS_DETECTED:}"
                        successes=$((successes + 1))
                        send_node_success "$node" "$points" "$line_number" "$successes"
                        echo "[${line_number}] Node ${node} errors: ${errors}, successes: ${successes}"
                        ;;
                    ERROR_DETECTED:*)
                        error_msg="${line#ERROR_DETECTED:}"
                        errors=$((errors + 1))
                        send_node_error "$node" "$error_msg"
                        echo "[${line_number}] Node ${node} errors: ${errors}, successes: ${successes}"
                        ;;
                    PROCESS_EXITED)
                        echo "[${line_number}] Node ${node} process exited, restarting..."
                        break
                        ;;
                    *)
                        ;;
                esac
            done < "$fifo"
           
            wait "$expect_pid" 2>/dev/null
           
            if [ "$done_run" -eq 0 ]; then
                [ "$LOG_MODE" = "default" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - Group ${GROUP_NUMBER} - Node ($node) exited, restarting in 5s..."
                sleep 5
            fi
        done
       
        rm -f "$fifo"
        if [ "$LOG_MODE" = "logfull" ] && [ -n "$TAIL_PID" ]; then
            kill -TERM "$TAIL_PID" 2>/dev/null || true
            sleep 1
            kill -KILL "$TAIL_PID" 2>/dev/null || true
        fi
    ) &
    pid=$!
    ACTIVE_PIDS+=("$pid")
}

wait_any() {
    if wait -n 2>/dev/null; then
        return 0
    fi
    while :; do
        for i in "${!ACTIVE_PIDS[@]}"; do
            pid="${ACTIVE_PIDS[$i]}"
            [ -z "$pid" ] && continue
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null
                unset 'ACTIVE_PIDS[i]'
                return 0
            fi
        done
        sleep 1
    done
}

while true; do
    node_index=0
    next_idx=0
    active=0
    ACTIVE_PIDS=()
   
    while (( active < CONCURRENCY && next_idx < ${#NODES[@]} )); do
        if [ "$MODE" = "live" ]; then
            echo "Live mode not implemented"
        elif [ "$MODE" = "liveauto" ]; then
            echo "Liveauto mode not implemented"
        else
            if [ "$REFRESH_ACCUMULATE" = "1" ]; then
                start_node_by_idx_refresh_accumulate "$next_idx"
            else
                echo "Standard refresh mode not implemented"
            fi
        fi
        next_idx=$((next_idx + 1))
        active=$((active + 1))
    done
   
    while (( active > 0 )); do
        wait_any
        active=$((active - 1))
       
        if (( next_idx < ${#NODES[@]} )); then
            if [ "$MODE" = "live" ]; then
                echo "Live mode not implemented"
            elif [ "$MODE" = "liveauto" ]; then
                echo "Liveauto mode not implemented"
            else
                if [ "$REFRESH_ACCUMULATE" = "1" ]; then
                    start_node_by_idx_refresh_accumulate "$next_idx"
                else
                    echo "Standard refresh mode not implemented"
                fi
            fi
            next_idx=$((next_idx + 1))
            active=$((active + 1))
        fi
    done
   
    if [ "$LOG_MODE" != "mini" ]; then
        if [ "$LOOP_MODE" = "once" ]; then
            echo "Completed full cycle of group ${GROUP_NUMBER} (${#NODES[@]} nodes)."
        elif [ "$LOOP_MODE" = "loop-delay" ]; then
            echo "Cycle complete. Waiting ${LOOP_DELAY_SEC}s before next run..."
        else
            echo "Cycle complete. Restarting..."
        fi
    fi
   
    if [ "$LOOP_MODE" = "once" ]; then
        sleep 5
        break
    elif [ "$LOOP_MODE" = "loop-delay" ]; then
        sleep "$LOOP_DELAY_SEC"
    fi
done

shutdown
