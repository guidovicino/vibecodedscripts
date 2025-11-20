#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nas_write_benchmark.sh -s <size> -n <files> -i <interval_seconds> -l <log_path> [-d <target_directory>]

Options:
  -s  Size of each test file (supports raw bytes or K/M/G suffix, e.g., 128M).
  -n  Maximum number of files to create per run (positive integer).
  -i  Interval in seconds between file creations (non-negative integer).
  -l  Path to the log file where measurements are appended.
  -d  Directory on the NAS where test files are created (defaults to current directory).
  -S  Summarize the provided log file and print aggregated metrics (can be used alone).
  -h  Show this help.

The script writes temporary files on the target directory, measures the write
time with dd, logs the metrics, and deletes the files immediately after
measuring so the storage under test remains clean.
EOF
}

require_command() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found in PATH" >&2
    exit 1
  fi
}

parse_size() {
  local input=$1
  if [[ $input =~ ^([0-9]+)([KMGkmg]?)$ ]]; then
    local number=${BASH_REMATCH[1]}
    local unit=${BASH_REMATCH[2]}
    case "${unit^^}" in
      "") echo "$number" ;;
      K) echo $((number * 1024)) ;;
      M) echo $((number * 1024 * 1024)) ;;
      G) echo $((number * 1024 * 1024 * 1024)) ;;
      *) return 1 ;;
    esac
  else
    return 1
  fi
}

size_spec=""
max_files=""
interval_secs=""
log_path=""
target_dir="."
summary_log=""

while getopts ":s:n:i:l:d:S:h" opt; do
  case "$opt" in
    s) size_spec=$OPTARG ;;
    n) max_files=$OPTARG ;;
    i) interval_secs=$OPTARG ;;
    l) log_path=$OPTARG ;;
    d) target_dir=$OPTARG ;;
    S) summary_log=$OPTARG ;;
    h) usage; exit 0 ;;
    :) echo "Error: -$OPTARG requires an argument" >&2; usage; exit 1 ;;
    \?) echo "Error: invalid option -$OPTARG" >&2; usage; exit 1 ;;
  esac
done

summary_only=false
if [[ -n $summary_log && -z $size_spec && -z $max_files && -z $interval_secs && -z $log_path ]]; then
  summary_only=true
fi

if [[ $summary_only == false ]]; then
  if [[ -z $size_spec || -z $max_files || -z $interval_secs || -z $log_path ]]; then
    echo "Error: -s, -n, -i and -l are required when running measurements." >&2
    usage
    exit 1
  fi
fi

if [[ $summary_only == false && ! $max_files =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: -n expects a positive integer." >&2
  exit 1
fi

if [[ $summary_only == false && ! $interval_secs =~ ^[0-9]+$ ]]; then
  echo "Error: -i expects a non-negative integer number of seconds." >&2
  exit 1
fi

if [[ $summary_only == false && ! -d $target_dir ]]; then
  echo "Error: target directory '$target_dir' does not exist." >&2
  exit 1
fi

if [[ $summary_only == false ]]; then
  size_bytes=$(parse_size "$size_spec") || {
    echo "Error: invalid size specification '$size_spec'. Use <number>[K|M|G]." >&2
    exit 1
  }

  mkdir -p "$(dirname "$log_path")"
  touch "$log_path"

  require_command dd
  require_command date
  require_command awk
else
  require_command awk
fi

summarize_log() {
  local logfile=$1
  if [[ -z $logfile ]]; then
    echo "Error: summary log path not provided." >&2
    exit 1
  fi
  if [[ ! -f $logfile ]]; then
    echo "Error: log file '$logfile' not found." >&2
    exit 1
  fi

  awk '
  /status=/ {
    entry_count++
    status=""
    duration=0
    throughput=0
    bytes=0
    if (match($0, /status=([A-Z]+)/, m)) status=m[1]
    if (match($0, /duration_s=([0-9.]+)/, d)) duration=d[1]+0
    if (match($0, /throughput_MBps=([0-9.]+)/, t)) throughput=t[1]+0
    if (match($0, /\(([0-9]+) bytes\)/, b)) bytes=b[1]+0

    total_duration += duration
    if (duration > max_duration) max_duration = duration
    if (min_duration == 0 || duration < min_duration) min_duration = duration

    if (status == "OK") {
      success++
      total_bytes += bytes
      total_throughput += throughput
    } else if (status != "") {
      failures++
    }
  }
  END {
    if (entry_count == 0) {
      printf "Log: %s\n", log_path
      print "No entries found."
      exit 0
    }
    avg_duration = total_duration / entry_count
    avg_throughput = success ? total_throughput / success : 0
    total_mb = total_bytes / 1048576
    printf "Log summary for %s\n", log_path
    printf "Samples: %d (success=%d, fail=%d)\n", entry_count, success, failures
    printf "Total data written (success only): %.3f MB\n", total_mb
    printf "Total measured time: %.6f s\n", total_duration
    printf "Duration avg/min/max: %.6f / %.6f / %.6f s\n", avg_duration, min_duration, max_duration
    printf "Average throughput (success): %.2f MB/s\n", avg_throughput
  }' log_path="$logfile" "$logfile"
}

if [[ $summary_only == true ]]; then
  summarize_log "$summary_log"
  exit 0
fi

log_measurement() {
  local status=$1
  local iteration=$2
  local duration_ns=$3
  local message=$4
  local timestamp
  timestamp=$(date -Iseconds)
  local duration_s
  duration_s=$(awk -v ns="$duration_ns" 'BEGIN { printf "%.6f", ns / 1000000000 }')
  local throughput="-"
  if [[ $status == "OK" && $duration_ns -gt 0 ]]; then
    throughput=$(awk -v bytes="$size_bytes" -v ns="$duration_ns" 'BEGIN { printf "%.2f", (bytes / 1048576) / (ns / 1000000000) }')
  fi

  {
    printf "%s\tstatus=%s\titeration=%d\tsize=%s (%d bytes)\tduration_s=%s\tthroughput_MBps=%s\t%s\n" \
      "$timestamp" "$status" "$iteration" "$size_spec" "$size_bytes" "$duration_s" "$throughput" "$message"
  } >>"$log_path"
}

echo "Starting NAS write monitor: size=$size_spec, files=$max_files, interval=${interval_secs}s, target='$target_dir', log='$log_path'"

for ((i = 1; i <= max_files; i++)); do
  filename="nas_write_test_$(date +%Y%m%d_%H%M%S)_$i"
  filepath="$target_dir/$filename"
  start_ns=$(date +%s%N)
  if dd if=/dev/zero of="$filepath" bs="$size_spec" count=1 conv=fdatasync status=none; then
    end_ns=$(date +%s%N)
    duration_ns=$((end_ns - start_ns))
    log_measurement "OK" "$i" "$duration_ns" "file=$filepath"
    rm -f "$filepath"
  else
    dd_status=$?
    end_ns=$(date +%s%N)
    duration_ns=$((end_ns - start_ns))
    log_measurement "ERROR" "$i" "$duration_ns" "file=$filepath dd_failed=$dd_status"
    rm -f "$filepath"
    echo "Write failed on iteration $i, see log for details." >&2
  fi

  if (( i < max_files )) && (( interval_secs > 0 )); then
    sleep "$interval_secs"
  fi
done

if [[ -n $summary_log ]]; then
  summarize_log "$summary_log"
fi
