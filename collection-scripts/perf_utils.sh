#!/bin/bash
# Performance monitoring utilities for must-gather.
# Provides lightweight instrumentation to track execution time,
# CPU load, and memory usage during a must-gather run.
#
# Usage: source this file from the main gather script, then call
# perf_init, perf_start_monitor, perf_track_script, perf_stop_monitor,
# and perf_generate_report in sequence.
#
# Environment variables:
#   MUST_GATHER_PERF        Set to "0" or "false" to disable all perf tracking.
#   PERF_SAMPLE_INTERVAL    Seconds between resource usage samples (default: 5).

# Allow opt-out via MUST_GATHER_PERF=0 or MUST_GATHER_PERF=false
_PERF_ENABLED=true
if [[ "${MUST_GATHER_PERF:-}" == "0" || "${MUST_GATHER_PERF:-}" == "false" ]]; then
    _PERF_ENABLED=false
fi

# --- Internal state ---
PERF_DATA_DIR=""
_PERF_START_EPOCH=""
_PERF_MONITOR_PID=""
_PERF_TRACKER_PIDS=()

# _perf_cleanup: Clean up the background monitor and temp data directory.
# Registered as an EXIT trap so resources are released even on unexpected
# termination (signals, timeouts, explicit exit).
_perf_cleanup() {
    if [[ "$_PERF_ENABLED" != "true" ]]; then return 0; fi
    if [[ -n "${_PERF_MONITOR_PID:-}" ]]; then
        kill "$_PERF_MONITOR_PID" 2>/dev/null || true
        wait "$_PERF_MONITOR_PID" 2>/dev/null || true
        _PERF_MONITOR_PID=""
    fi
    if [[ -n "${PERF_DATA_DIR:-}" && -d "$PERF_DATA_DIR" ]]; then
        rm -rf "$PERF_DATA_DIR"
    fi
}

# perf_init: Initialise performance tracking.
# Creates a temp directory for data collection and records the start time.
perf_init() {
    if [[ "$_PERF_ENABLED" != "true" ]]; then return 0; fi

    _PERF_START_EPOCH=$(date +%s)
    PERF_DATA_DIR=$(mktemp -d "${TMPDIR:-/tmp}/must-gather-perf.XXXXXX")
    touch "$PERF_DATA_DIR/scripts.csv"
    touch "$PERF_DATA_DIR/samples.csv"
    trap '_perf_cleanup' EXIT
    echo "PERF: Initialised performance tracking (data dir: $PERF_DATA_DIR)"
}

# _perf_get_memory_bytes: Read current memory usage in bytes.
# Tries cgroup v2, then cgroup v1, then /proc/self RSS.
_perf_get_memory_bytes() {
    local mem_bytes=""
    if [[ -r /sys/fs/cgroup/memory.current ]]; then
        mem_bytes=$(< /sys/fs/cgroup/memory.current)
    elif [[ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]]; then
        mem_bytes=$(< /sys/fs/cgroup/memory/memory.usage_in_bytes)
    elif [[ -r /proc/self/status ]]; then
        local vm_rss_kb
        vm_rss_kb=$(awk '/^VmRSS:/{print $2}' /proc/self/status 2>/dev/null || true)
        if [[ -n "$vm_rss_kb" ]]; then
            mem_bytes=$((vm_rss_kb * 1024))
        fi
    fi
    echo "${mem_bytes:-}"
}

# _perf_get_load_avg: Read the 1-minute load average.
# Note: /proc/loadavg reports the host-wide load average, not a
# container-scoped value.  In a containerised must-gather pod the number
# reflects overall node pressure, which is still a useful indicator but
# should not be interpreted as the container's own CPU usage.
_perf_get_load_avg() {
    if [[ -r /proc/loadavg ]]; then
        awk '{print $1}' /proc/loadavg
    else
        echo ""
    fi
}

# perf_start_monitor: Start a background loop that samples CPU load and
# memory usage every PERF_SAMPLE_INTERVAL seconds (default 5).
perf_start_monitor() {
    if [[ "$_PERF_ENABLED" != "true" ]]; then return 0; fi

    local interval="${PERF_SAMPLE_INTERVAL:-5}"
    local samples_file="$PERF_DATA_DIR/samples.csv"

    (
        while true; do
            local ts load_avg mem_bytes
            ts=$(date +%s)
            load_avg=$(_perf_get_load_avg)
            mem_bytes=$(_perf_get_memory_bytes)
            echo "${ts},${load_avg},${mem_bytes}" >> "$samples_file"
            sleep "$interval"
        done
    ) &
    _PERF_MONITOR_PID=$!
    echo "PERF: Background resource monitor started (PID=$_PERF_MONITOR_PID, interval=${interval}s)"
}

# perf_stop_monitor: Stop the background sampling loop and wait for any
# perf_track_pid tracker subshells to finish writing their CSV entries.
perf_stop_monitor() {
    if [[ "$_PERF_ENABLED" != "true" ]]; then return 0; fi

    if [[ -n "${_PERF_MONITOR_PID:-}" ]]; then
        kill "$_PERF_MONITOR_PID" 2>/dev/null || true
        wait "$_PERF_MONITOR_PID" 2>/dev/null || true
        echo "PERF: Background resource monitor stopped"
        _PERF_MONITOR_PID=""
    fi

    # Wait for all perf_track_pid tracker subshells so their CSV entries
    # are flushed before perf_generate_report reads the file.
    local pid
    for pid in "${_PERF_TRACKER_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    _PERF_TRACKER_PIDS=()
}

# perf_track_script <label> <command...>
# Execute a command and record its timing to scripts.csv.
# Designed to be used with & for backgrounding:
#   perf_track_script "gather_etcd" /usr/bin/gather_etcd &
#   pids+=($!)
perf_track_script() {
    if [[ "$_PERF_ENABLED" != "true" ]]; then
        shift
        "$@"
        return $?
    fi

    local label="$1"
    shift

    local start_time end_time duration exit_code
    start_time=$(date +%s)

    # Save and restore errexit so we don't leak set -e into the caller
    local prev_errexit=0
    [[ $- == *e* ]] && prev_errexit=1

    set +e
    "$@"
    exit_code=$?

    if (( prev_errexit )); then set -e; fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo "${label},${start_time},${end_time},${duration},${exit_code}" >> "$PERF_DATA_DIR/scripts.csv"
    return "$exit_code"
}

# perf_track_pid <label> <pid>
# Track timing of an already-backgrounded process by PID.
# Spawns a lightweight background poller that records timing when the
# target PID exits. This avoids wrapping the original command, keeping
# complex invocations (e.g. oc adm inspect) untouched.
# Note: exit code is not available via this method (recorded as "-").
# Usage:
#   some_command --with-many-args &
#   pids+=($!)
#   perf_track_pid "some_command" $!
perf_track_pid() {
    if [[ "$_PERF_ENABLED" != "true" ]]; then return 0; fi

    local label="$1"
    local pid="$2"
    local start_time
    start_time=$(date +%s)

    (
        while kill -0 "$pid" 2>/dev/null; do
            sleep 1
        done
        local end_time
        end_time=$(date +%s)
        local duration=$(( end_time - start_time ))
        echo "${label},${start_time},${end_time},${duration},-" >> "$PERF_DATA_DIR/scripts.csv"
    ) &
    _PERF_TRACKER_PIDS+=($!)
}

# _perf_format_duration: Convert seconds to a human-readable string.
# E.g. 263 -> "4m 23s"
_perf_format_duration() {
    local total_secs=$1
    if (( total_secs >= 60 )); then
        local mins=$((total_secs / 60))
        local secs=$((total_secs % 60))
        echo "${mins}m ${secs}s"
    else
        echo "${total_secs}s"
    fi
}

# _perf_bytes_to_mib: Convert bytes to MiB (integer).
_perf_bytes_to_mib() {
    local bytes="${1:-0}"
    if [[ -z "$bytes" || "$bytes" == "0" ]]; then
        echo "0"
        return
    fi
    echo $(( bytes / 1048576 ))
}

# perf_generate_report: Produce a human-readable performance report.
# Writes to $BASE_COLLECTION_PATH/performance-report.txt
perf_generate_report() {
    if [[ "$_PERF_ENABLED" != "true" ]]; then return 0; fi

    local base_path="${BASE_COLLECTION_PATH:-/must-gather}"
    local report_file="${base_path}/performance-report.txt"
    local end_epoch
    end_epoch=$(date +%s)
    local total_duration=$(( end_epoch - _PERF_START_EPOCH ))

    {
        echo "===== must-gather Performance Report ====="
        echo "Generated: $(date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
        echo ""

        # --- Overall timing ---
        echo "--- Overall ---"
        echo "Total execution time: $(_perf_format_duration $total_duration) (${total_duration}s)"
        echo ""

        # --- Per-script timing ---
        echo "--- Per-Script Timing (sorted by duration) ---"
        if [[ -s "$PERF_DATA_DIR/scripts.csv" ]]; then
            sort -t',' -k4 -rn "$PERF_DATA_DIR/scripts.csv" | while IFS=',' read -r label start end dur ec; do
                printf "%-45s %10s  exit=%s\n" "$label" "$(_perf_format_duration "$dur") (${dur}s)" "$ec"
            done
        else
            echo "(no per-script timing data collected)"
        fi
        echo ""

        # --- Resource usage ---
        echo "--- Resource Usage ---"
        local samples_file="$PERF_DATA_DIR/samples.csv"
        if [[ -s "$samples_file" ]]; then
            # Compute all statistics in a single awk pass
            local stats_line
            stats_line=$(awk -F',' '
                {
                    sc++
                }
                $2 != "" {
                    lsum += $2; lc++;
                    if (lc == 1 || $2 < lmin) lmin = $2;
                    if (lc == 1 || $2 > lmax) lmax = $2;
                }
                $3 != "" && $3+0 > 0 {
                    msum += $3; mc++;
                    if ($3+0 > mpeak) mpeak = $3+0;
                }
                END {
                    load_str = (lc > 0) ? sprintf("avg=%.2f  min=%.2f  max=%.2f", lsum/lc, lmin, lmax) : "N/A";
                    mavg = (mc > 0) ? int(msum/mc) : 0;
                    printf "%d\t%s\t%d\t%d\n", sc, load_str, mavg, int(mpeak);
                }
            ' "$samples_file")

            local sample_count load_stats mem_avg_bytes mem_peak_bytes
            IFS=$'\t' read -r sample_count load_stats mem_avg_bytes mem_peak_bytes <<< "$stats_line"

            echo "CPU Load (1-min avg):  ${load_stats}  (host-wide, not container-scoped)"
            echo "Memory Usage:          avg=$(_perf_bytes_to_mib "$mem_avg_bytes") MiB  peak=$(_perf_bytes_to_mib "$mem_peak_bytes") MiB"
            echo "Samples collected:     ${sample_count} (every ${PERF_SAMPLE_INTERVAL:-5}s)"
        else
            echo "CPU Load (1-min avg):  N/A  (host-wide, not container-scoped)"
            echo "Memory Usage:          N/A"
            echo "Samples collected:     0"
        fi
        echo "=========================================="
    } > "$report_file"

    echo "PERF: Performance report written to $report_file"

    # Clean up temp data directory
    rm -rf "$PERF_DATA_DIR"
}
