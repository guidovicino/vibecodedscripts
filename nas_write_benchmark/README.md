# NAS Write Monitor

`nas_write_benchmark.sh.sh` is a portable Bash script that measures write performance on NAS or other mounted storage using only coreutils tools (`dd`, `awk`, `date`). It creates temporary files of a configurable size, records the write duration, logs metrics, and removes the test files immediately so the target directory stays clean. The script can also summarize an existing log to provide aggregated insights such as total throughput, min/max/average durations, and success/failure counts.

## Requirements

* Bash 4+
* `dd`, `date`, and `awk` available in `PATH`

## Usage

```
Usage: nas_write_benchmark.sh.sh -s <size> -n <files> -i <interval_seconds> -l <log_path> [-d <target_directory>]

Options:
  -s  Size of each test file (raw bytes or with K/M/G suffix; e.g., 512M).
  -n  Maximum number of files to create per run.
  -i  Seconds between file creations (can be 0).
  -l  Path to the log file; created if missing.
  -d  Directory on the NAS where test files are written (default: current directory).
  -S  Summarize the specified log and print aggregates (can be used alone).
  -h  Show help.
```

### Example

```bash
chmod +x nas_write_benchmark.sh.sh

# Measure 20 writes of 256 MB each, every 30 seconds, logging to /var/log/nas_monitor.log
# and writing files under /mnt/nas_share. After the run, print a summary of the log.
./nas_write_benchmark.sh.sh \
  -s 256M \
  -n 20 \
  -i 30 \
  -l /var/log/nas_monitor.log \
  -d /mnt/nas_share \
  -S /var/log/nas_monitor.log

# Later, summarize the same log without running new tests
./nas_write_benchmark.sh.sh -S /var/log/nas_monitor.log
```

The log format is tab-separated with timestamps, status, iteration counter, file size, duration in seconds, computed throughput (MB/s), and the path of the temporary file that was written. Use any standard tools (tail, grep, awk) or the built-in `-S` flag to review results.
