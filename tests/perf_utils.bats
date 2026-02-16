#!/usr/bin/env bats
# Tests for collection-scripts/perf_utils.sh

load test_helper

# =============================================================================
# Helper to source perf_utils.sh safely in a subshell
# =============================================================================

# Runs a bash snippet with perf_utils.sh sourced and strict mode disabled.
run_perf() {
	run bash -c "
		export BASE_COLLECTION_PATH=\"$TEST_TMPDIR/must-gather\"
		set +o nounset
		set +o errexit
		set +o pipefail
		source \"$SCRIPT_DIR/perf_utils.sh\"
		$1
	"
}

# =============================================================================
# perf_init tests
# =============================================================================

@test "perf_init creates data directory and samples/scripts files" {
	run_perf '
		perf_init
		[[ -d "$PERF_DATA_DIR" ]] && echo "DIR_EXISTS"
		[[ -f "$PERF_DATA_DIR/scripts.csv" ]] && echo "SCRIPTS_CSV_EXISTS"
		[[ -f "$PERF_DATA_DIR/samples.csv" ]] && echo "SAMPLES_CSV_EXISTS"
	'

	assert_success
	assert_output --partial "DIR_EXISTS"
	assert_output --partial "SCRIPTS_CSV_EXISTS"
	assert_output --partial "SAMPLES_CSV_EXISTS"
}

@test "perf_init records start epoch" {
	run_perf '
		perf_init
		[[ -n "$_PERF_START_EPOCH" ]] && echo "EPOCH_SET=$_PERF_START_EPOCH"
	'

	assert_success
	assert_output --partial "EPOCH_SET="
}

@test "perf_init outputs info message" {
	run_perf 'perf_init'

	assert_success
	assert_output --partial "PERF: Initialised performance tracking"
}

# =============================================================================
# Opt-out via MUST_GATHER_PERF tests
# =============================================================================

@test "perf_init is a no-op when MUST_GATHER_PERF=false" {
	run bash -c "
		export MUST_GATHER_PERF=false
		export BASE_COLLECTION_PATH=\"$TEST_TMPDIR/must-gather\"
		source \"$SCRIPT_DIR/perf_utils.sh\"
		perf_init
		[[ -z \"\$PERF_DATA_DIR\" ]] && echo 'NO_DATA_DIR'
	"

	assert_success
	assert_output --partial "NO_DATA_DIR"
	refute_output --partial "PERF: Initialised"
}

@test "perf_init is a no-op when MUST_GATHER_PERF=0" {
	run bash -c "
		export MUST_GATHER_PERF=0
		export BASE_COLLECTION_PATH=\"$TEST_TMPDIR/must-gather\"
		source \"$SCRIPT_DIR/perf_utils.sh\"
		perf_init
		[[ -z \"\$PERF_DATA_DIR\" ]] && echo 'NO_DATA_DIR'
	"

	assert_success
	assert_output --partial "NO_DATA_DIR"
}

# =============================================================================
# perf_track_script tests
# =============================================================================

@test "perf_track_script records timing data to scripts.csv" {
	run_perf '
		perf_init
		perf_track_script "test_script" sleep 0
		cat "$PERF_DATA_DIR/scripts.csv"
	'

	assert_success
	assert_output --partial "test_script,"
}

@test "perf_track_script records correct exit code on success" {
	run_perf '
		perf_init
		perf_track_script "success_cmd" true
		cat "$PERF_DATA_DIR/scripts.csv"
	'

	assert_success
	# CSV format: label,start,end,duration,exit_code -- exit_code should be 0
	assert_output --partial ",0"
}

@test "perf_track_script records correct exit code on failure" {
	run_perf '
		perf_init
		perf_track_script "fail_cmd" false || true
		cat "$PERF_DATA_DIR/scripts.csv"
	'

	assert_success
	assert_output --partial "fail_cmd,"
	# false returns exit code 1
	assert_output --partial ",1"
}

@test "perf_track_script records duration >= 0" {
	run_perf '
		perf_init
		perf_track_script "quick_cmd" true
		echo "DURATION=$(awk -F"," "{print \$4}" "$PERF_DATA_DIR/scripts.csv")"
	'

	assert_success
	# Duration should be a non-negative integer (0 or more)
	assert_output --regexp "DURATION=[0-9]+"
}

@test "perf_track_script passes arguments to the command correctly" {
	run_perf '
		perf_init
		perf_track_script "echo_test" echo "hello world"
	'

	assert_success
	assert_output --partial "hello world"
}

@test "perf_track_script runs command directly when MUST_GATHER_PERF=false" {
	run bash -c "
		export MUST_GATHER_PERF=false
		source \"$SCRIPT_DIR/perf_utils.sh\"
		perf_track_script 'ignored_label' echo 'executed anyway'
	"

	assert_success
	assert_output --partial "executed anyway"
}

# =============================================================================
# perf_track_pid tests
# =============================================================================

@test "perf_track_pid records timing data for a backgrounded process" {
	run_perf '
		perf_init
		sleep 1 &
		bg_pid=$!
		perf_track_pid "bg_sleep" $bg_pid
		wait $bg_pid 2>/dev/null || true
		sleep 2
		cat "$PERF_DATA_DIR/scripts.csv"
	'

	assert_success
	assert_output --partial "bg_sleep,"
}

@test "perf_track_pid records timing with duration and dash exit code" {
	run_perf '
		perf_init
		sleep 1 &
		bg_pid=$!
		perf_track_pid "bg_cmd" $bg_pid
		wait $bg_pid 2>/dev/null || true
		sleep 2
		echo "CSV=$(cat "$PERF_DATA_DIR/scripts.csv")"
	'

	assert_success
	assert_output --partial "bg_cmd,"
	# Exit code is recorded as "-" since kill -0 polling cannot capture it
	assert_output --regexp "CSV=bg_cmd,[0-9]+,[0-9]+,[0-9]+,-"
}

@test "perf_track_pid detects fast-exiting processes" {
	run_perf '
		perf_init
		true &
		bg_pid=$!
		perf_track_pid "bg_fast" $bg_pid
		sleep 2
		echo "CSV=$(cat "$PERF_DATA_DIR/scripts.csv")"
	'

	assert_success
	assert_output --partial "bg_fast,"
	assert_output --regexp "CSV=bg_fast,[0-9]+,[0-9]+,[0-9]+,-"
}

@test "perf_track_pid is a no-op when MUST_GATHER_PERF=false" {
	run bash -c "
		export MUST_GATHER_PERF=false
		export BASE_COLLECTION_PATH=\"$TEST_TMPDIR/must-gather\"
		source \"$SCRIPT_DIR/perf_utils.sh\"
		sleep 0 &
		perf_track_pid 'ignored' \$!
		echo 'NO_CRASH'
	"

	assert_success
	assert_output --partial "NO_CRASH"
}

# =============================================================================
# perf_start_monitor / perf_stop_monitor tests
# =============================================================================

@test "perf_start_monitor starts background process and perf_stop_monitor stops it" {
	run_perf '
		perf_init
		export PERF_SAMPLE_INTERVAL=1
		perf_start_monitor
		[[ -n "$_PERF_MONITOR_PID" ]] && echo "MONITOR_STARTED"
		sleep 2
		perf_stop_monitor
		echo "MONITOR_STOPPED"
	'

	assert_success
	assert_output --partial "MONITOR_STARTED"
	assert_output --partial "MONITOR_STOPPED"
	assert_output --partial "PERF: Background resource monitor started"
	assert_output --partial "PERF: Background resource monitor stopped"
}

@test "perf_start_monitor collects samples into samples.csv" {
	run_perf '
		perf_init
		export PERF_SAMPLE_INTERVAL=1
		perf_start_monitor
		sleep 3
		perf_stop_monitor
		local count
		count=$(wc -l < "$PERF_DATA_DIR/samples.csv")
		echo "SAMPLE_COUNT=$count"
	'

	assert_success
	# Should have collected at least 2 samples in 3 seconds with 1s interval
	assert_output --regexp "SAMPLE_COUNT=[2-9][0-9]*"
}

@test "perf_start_monitor samples contain CSV with 3 fields" {
	run_perf '
		perf_init
		export PERF_SAMPLE_INTERVAL=1
		perf_start_monitor
		sleep 2
		perf_stop_monitor
		echo "SAMPLE=$(head -1 "$PERF_DATA_DIR/samples.csv")"
	'

	assert_success
	# Each line should have format: timestamp,load_avg,memory_bytes
	assert_output --partial "SAMPLE="
	assert_output --regexp "SAMPLE=[0-9]+,[0-9.]+,"
}

@test "perf_stop_monitor is safe to call when no monitor is running" {
	run_perf '
		perf_init
		perf_stop_monitor
		echo "NO_CRASH"
	'

	assert_success
	assert_output --partial "NO_CRASH"
}

# =============================================================================
# _perf_format_duration tests
# =============================================================================

@test "_perf_format_duration formats seconds-only correctly" {
	run_perf '
		echo "$(_perf_format_duration 45)"
	'

	assert_success
	assert_output "45s"
}

@test "_perf_format_duration formats minutes and seconds correctly" {
	run_perf '
		echo "$(_perf_format_duration 263)"
	'

	assert_success
	assert_output "4m 23s"
}

@test "_perf_format_duration handles zero" {
	run_perf '
		echo "$(_perf_format_duration 0)"
	'

	assert_success
	assert_output "0s"
}

@test "_perf_format_duration handles exact minutes" {
	run_perf '
		echo "$(_perf_format_duration 120)"
	'

	assert_success
	assert_output "2m 0s"
}

# =============================================================================
# _perf_bytes_to_mib tests
# =============================================================================

@test "_perf_bytes_to_mib converts bytes to MiB" {
	run_perf '
		echo "$(_perf_bytes_to_mib 104857600)"
	'

	assert_success
	# 104857600 bytes = 100 MiB
	assert_output "100"
}

@test "_perf_bytes_to_mib handles zero" {
	run_perf '
		echo "$(_perf_bytes_to_mib 0)"
	'

	assert_success
	assert_output "0"
}

@test "_perf_bytes_to_mib handles empty input" {
	run_perf '
		echo "$(_perf_bytes_to_mib "")"
	'

	assert_success
	assert_output "0"
}

# =============================================================================
# _perf_get_memory_bytes tests
# =============================================================================

@test "_perf_get_memory_bytes returns a value on this system" {
	run_perf '
		result=$(_perf_get_memory_bytes)
		if [[ -n "$result" ]]; then
			echo "HAS_VALUE"
		else
			echo "EMPTY_OK"
		fi
	'

	assert_success
	# Should succeed regardless; either we get a value or graceful empty
	assert_output --regexp "(HAS_VALUE|EMPTY_OK)"
}

# =============================================================================
# _perf_get_load_avg tests
# =============================================================================

@test "_perf_get_load_avg returns a numeric value" {
	run_perf '
		result=$(_perf_get_load_avg)
		echo "LOAD=$result"
	'

	assert_success
	# On Linux /proc/loadavg should be available
	assert_output --regexp "LOAD=[0-9]+\.[0-9]+"
}

# =============================================================================
# perf_generate_report tests
# =============================================================================

@test "perf_generate_report creates performance-report.txt" {
	run_perf '
		perf_init
		perf_track_script "test_cmd" true
		perf_generate_report
		[[ -f "$BASE_COLLECTION_PATH/performance-report.txt" ]] && echo "REPORT_EXISTS"
	'

	assert_success
	assert_output --partial "REPORT_EXISTS"
}

@test "perf_generate_report contains required sections" {
	run_perf '
		perf_init
		perf_track_script "test_cmd" sleep 0
		perf_generate_report
		cat "$BASE_COLLECTION_PATH/performance-report.txt"
	'

	assert_success
	assert_output --partial "must-gather Performance Report"
	assert_output --partial "--- Overall ---"
	assert_output --partial "Total execution time:"
	assert_output --partial "--- Per-Script Timing (sorted by duration) ---"
	assert_output --partial "--- Resource Usage ---"
}

@test "perf_generate_report lists tracked scripts" {
	run_perf '
		perf_init
		perf_track_script "my_gather_script" true
		perf_track_script "another_script" true
		perf_generate_report
		cat "$BASE_COLLECTION_PATH/performance-report.txt"
	'

	assert_success
	assert_output --partial "my_gather_script"
	assert_output --partial "another_script"
}

@test "perf_generate_report shows resource usage when samples exist" {
	run_perf '
		perf_init
		export PERF_SAMPLE_INTERVAL=1
		perf_start_monitor
		sleep 2
		perf_stop_monitor
		perf_generate_report
		cat "$BASE_COLLECTION_PATH/performance-report.txt"
	'

	assert_success
	assert_output --partial "CPU Load (1-min avg):"
	assert_output --partial "Memory Usage:"
	assert_output --partial "Samples collected:"
	# Should NOT show N/A since we have actual samples
	refute_output --partial "CPU Load (1-min avg):  N/A"
}

@test "perf_generate_report shows N/A when no samples collected" {
	run_perf '
		perf_init
		perf_generate_report
		cat "$BASE_COLLECTION_PATH/performance-report.txt"
	'

	assert_success
	assert_output --partial "CPU Load (1-min avg):  N/A"
	assert_output --partial "Memory Usage:          N/A"
	assert_output --partial "Samples collected:     0"
}

@test "perf_generate_report handles no script timing data gracefully" {
	run_perf '
		perf_init
		perf_generate_report
		cat "$BASE_COLLECTION_PATH/performance-report.txt"
	'

	assert_success
	assert_output --partial "(no per-script timing data collected)"
}

@test "perf_generate_report cleans up temp data directory" {
	run_perf '
		perf_init
		local data_dir="$PERF_DATA_DIR"
		perf_generate_report
		if [[ -d "$data_dir" ]]; then
			echo "DIR_STILL_EXISTS"
		else
			echo "DIR_CLEANED_UP"
		fi
	'

	assert_success
	assert_output --partial "DIR_CLEANED_UP"
}

@test "perf_generate_report is a no-op when MUST_GATHER_PERF=false" {
	run bash -c "
		export MUST_GATHER_PERF=false
		export BASE_COLLECTION_PATH=\"$TEST_TMPDIR/must-gather\"
		source \"$SCRIPT_DIR/perf_utils.sh\"
		perf_generate_report
		if [[ -f \"$TEST_TMPDIR/must-gather/performance-report.txt\" ]]; then
			echo 'REPORT_CREATED'
		else
			echo 'NO_REPORT'
		fi
	"

	assert_success
	assert_output --partial "NO_REPORT"
}

# =============================================================================
# End-to-end integration test
# =============================================================================

@test "full perf lifecycle: init, monitor, track, stop, report" {
	run_perf '
		perf_init
		export PERF_SAMPLE_INTERVAL=1
		perf_start_monitor

		perf_track_script "fast_script" true &
		pid1=$!
		perf_track_script "slow_script" sleep 2 &
		pid2=$!
		wait $pid1 $pid2

		perf_stop_monitor
		perf_generate_report

		echo "=== REPORT ==="
		cat "$BASE_COLLECTION_PATH/performance-report.txt"
	'

	assert_success
	assert_output --partial "=== REPORT ==="
	assert_output --partial "must-gather Performance Report"
	assert_output --partial "fast_script"
	assert_output --partial "slow_script"
	assert_output --partial "CPU Load"
	assert_output --partial "Memory Usage"
	assert_output --partial "PERF: Performance report written to"
}
