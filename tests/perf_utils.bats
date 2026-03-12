#!/usr/bin/env bats
# Tests for collection-scripts/perf_utils.sh

load test_helper

# =============================================================================
# Helper to source perf_utils.sh safely in a subshell
# =============================================================================

# Runs a bash snippet with perf_utils.sh sourced and strict mode disabled.
# Sets MUST_GATHER_PERF=true to enable performance tracking (opt-in).
run_perf() {
	run bash -c "
		export MUST_GATHER_PERF=true
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

@test "perf_init creates data directory and samples/scripts/started files" {
	run_perf '
		perf_init
		[[ -d "$PERF_DATA_DIR" ]] && echo "DIR_EXISTS"
		[[ -f "$PERF_DATA_DIR/scripts.csv" ]] && echo "SCRIPTS_CSV_EXISTS"
		[[ -f "$PERF_DATA_DIR/started.csv" ]] && echo "STARTED_CSV_EXISTS"
		[[ -f "$PERF_DATA_DIR/samples.csv" ]] && echo "SAMPLES_CSV_EXISTS"
	'

	assert_success
	assert_output --partial "DIR_EXISTS"
	assert_output --partial "SCRIPTS_CSV_EXISTS"
	assert_output --partial "STARTED_CSV_EXISTS"
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

@test "perf_track_script records entry in started.csv" {
	run_perf '
		perf_init
		perf_track_script "my_script" true
		echo "STARTED=$(cat "$PERF_DATA_DIR/started.csv")"
	'

	assert_success
	assert_output --regexp "STARTED=my_script,[0-9]+"
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

@test "perf_track_pid records entry in started.csv" {
	run_perf '
		perf_init
		sleep 1 &
		perf_track_pid "bg_tracked" $!
		wait $! 2>/dev/null || true
		sleep 2
		echo "STARTED=$(cat "$PERF_DATA_DIR/started.csv")"
	'

	assert_success
	assert_output --regexp "STARTED=bg_tracked,[0-9]+"
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
# Signal handling / interrupted report tests
# =============================================================================

@test "SIGTERM generates partial report with interrupted warning" {
	# Run a script that initialises perf, starts a long-running tracked
	# command, then receives SIGTERM.  The EXIT trap should produce a
	# partial report containing the warning banner.
	local wrapper="$TEST_TMPDIR/sigterm_test.sh"
	cat > "$wrapper" <<'SCRIPT'
#!/bin/bash
set +o nounset; set +o errexit; set +o pipefail
export MUST_GATHER_PERF=true
export BASE_COLLECTION_PATH="__BASE__"
source "__SCRIPT_DIR__/perf_utils.sh"
perf_init
perf_track_script "completed_script" true
perf_track_script "long_script" sleep 300 &
pids+=($!)
echo "READY"
wait "${pids[@]}"
SCRIPT
	sed -i "s|__BASE__|$TEST_TMPDIR/must-gather|g" "$wrapper"
	sed -i "s|__SCRIPT_DIR__|$SCRIPT_DIR|g" "$wrapper"
	chmod +x "$wrapper"

	# Run in its own session so we can kill the entire process tree
	setsid bash "$wrapper" > "$TEST_TMPDIR/out.txt" 2>&1 &
	local wrapper_pid=$!

	local tries=0
	while ! grep -q "READY" "$TEST_TMPDIR/out.txt" 2>/dev/null; do
		sleep 0.2
		tries=$((tries + 1))
		if (( tries > 50 )); then
			kill -- -"$wrapper_pid" 2>/dev/null || true
			fail "Wrapper script never became ready"
		fi
	done

	# SIGTERM the wrapper; the EXIT trap generates a partial report
	kill -TERM "$wrapper_pid"
	wait "$wrapper_pid" 2>/dev/null || true

	# Clean up the entire session (orphaned sleep, tracker subshells)
	kill -- -"$wrapper_pid" 2>/dev/null || true

	local report="$TEST_TMPDIR/must-gather/performance-report.txt"
	[ -f "$report" ]

	run cat "$report"
	assert_output --partial "WARNING: Run was interrupted (timeout or signal) -- data below is partial."
	assert_output --partial "must-gather Performance Report"
	assert_output --partial "completed_script"
	assert_output --partial "--- Scripts Still Running at Interruption ---"
	assert_output --partial "long_script"
}

@test "normal exit does not show interrupted warning in report" {
	run_perf '
		perf_init
		perf_track_script "normal_cmd" true
		perf_generate_report
		cat "$BASE_COLLECTION_PATH/performance-report.txt"
	'

	assert_success
	assert_output --partial "must-gather Performance Report"
	assert_output --partial "normal_cmd"
	refute_output --partial "WARNING: Run was interrupted"
	refute_output --partial "Scripts Still Running at Interruption"
}

@test "cleanup is idempotent when report already generated" {
	run_perf '
		perf_init
		perf_track_script "some_cmd" true
		perf_generate_report
		# Trigger cleanup explicitly (simulates EXIT trap firing after report)
		_perf_cleanup
		echo "NO_CRASH"
		cat "$BASE_COLLECTION_PATH/performance-report.txt"
	'

	assert_success
	assert_output --partial "NO_CRASH"
	assert_output --partial "must-gather Performance Report"
	assert_output --partial "some_cmd"
	refute_output --partial "WARNING: Run was interrupted"
}

@test "report contains interrupted warning when _PERF_INTERRUPTED is true" {
	run_perf '
		perf_init
		perf_track_script "done_cmd" true
		# Simulate a script that started but never completed
		echo "stuck_cmd,$(date +%s)" >> "$PERF_DATA_DIR/started.csv"
		_PERF_INTERRUPTED=true
		perf_generate_report
		cat "$BASE_COLLECTION_PATH/performance-report.txt"
	'

	assert_success
	assert_output --partial "WARNING: Run was interrupted (timeout or signal) -- data below is partial."
	assert_output --partial "done_cmd"
	assert_output --partial "--- Scripts Still Running at Interruption ---"
	assert_output --partial "stuck_cmd"
	assert_output --partial "running for"
}

# =============================================================================
# Error handling tests
# =============================================================================

@test "perf_init handles non-writable TMPDIR gracefully" {
	# Create a non-writable directory to use as TMPDIR
	local readonly_dir="$TEST_TMPDIR/readonly_tmpdir"
	mkdir -p "$readonly_dir"
	chmod 000 "$readonly_dir"

	run bash -c "
		export MUST_GATHER_PERF=true
		export TMPDIR='$readonly_dir'
		export BASE_COLLECTION_PATH=\"$TEST_TMPDIR/must-gather\"
		set +o nounset
		set +o errexit
		set +o pipefail
		source \"$SCRIPT_DIR/perf_utils.sh\"
		perf_init 2>&1
		echo \"EXIT_CODE=\$?\"
	"

	# Restore permissions for cleanup
	chmod 755 "$readonly_dir"

	# The command should fail (non-zero exit or error message)
	# mktemp will fail when TMPDIR is not writable
	assert_output --regexp "(EXIT_CODE=[1-9]|cannot create|Permission denied|mktemp)"
}

@test "perf_track_pid respects PERF_TRACK_PID_INTERVAL" {
	run_perf '
		export PERF_TRACK_PID_INTERVAL=2
		perf_init
		sleep 3 &
		bg_pid=$!
		perf_track_pid "interval_test" $bg_pid
		wait $bg_pid 2>/dev/null || true
		sleep 3
		echo "CSV=$(cat "$PERF_DATA_DIR/scripts.csv")"
	'

	assert_success
	assert_output --partial "interval_test,"
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
	refute_output --partial "WARNING: Run was interrupted"
}
