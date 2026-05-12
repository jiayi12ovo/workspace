#!/usr/bin/env bash
# Collect pre-S4 hibernation evidence for cache/image-size analysis.
# Usage:
#   sudo bash collect-s4-precheck.sh
#   sudo bash collect-s4-precheck.sh --deep
#   sudo bash collect-s4-precheck.sh --out /tmp/s4-precheck --sample 10

set -u

DEEP=0
SAMPLE_SECONDS=5
OUT_ROOT="."

while [ "$#" -gt 0 ]; do
	case "$1" in
		--deep)
			DEEP=1
			shift
			;;
		--out)
			OUT_ROOT="${2:-.}"
			shift 2
			;;
		--sample)
			SAMPLE_SECONDS="${2:-5}"
			shift 2
			;;
		-h|--help)
			sed -n '1,12p' "$0"
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 2
			;;
	esac
done

HOST="$(hostname 2>/dev/null || echo unknown-host)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_ROOT%/}/s4-precheck-${HOST}-${STAMP}"
mkdir -p "$OUT_DIR"

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$OUT_DIR/collect.log"
}

have() {
	command -v "$1" >/dev/null 2>&1
}

save_file() {
	local src="$1"
	local dst="$2"
	if [ -r "$src" ]; then
		cp -a "$src" "$OUT_DIR/$dst" 2>>"$OUT_DIR/errors.log" || true
	else
		printf '%s is not readable\n' "$src" >"$OUT_DIR/$dst.unreadable"
	fi
}

run_cmd() {
	local name="$1"
	shift
	{
		printf '$'
		printf ' %q' "$@"
		printf '\n\n'
		"$@"
	} >"$OUT_DIR/$name" 2>&1 || true
}

run_shell() {
	local name="$1"
	local script="$2"
	{
		printf '$ %s\n\n' "$script"
		sh -c "$script"
	} >"$OUT_DIR/$name" 2>&1 || true
}

log "Collecting into $OUT_DIR"
if [ "$(id -u)" -ne 0 ]; then
	log "Not running as root. Some files/commands may be incomplete."
fi

log "Collecting basic system information"
run_cmd "00-date.txt" date --iso-8601=seconds
run_cmd "00-hostname.txt" hostnamectl
run_cmd "00-uname.txt" uname -a
save_file "/etc/os-release" "00-os-release.txt"
save_file "/proc/cmdline" "00-proc-cmdline.txt"
save_file "/proc/uptime" "00-proc-uptime.txt"

log "Collecting hibernation and swap state"
mkdir -p "$OUT_DIR/sys-power"
for f in /sys/power/state /sys/power/disk /sys/power/image_size /sys/power/resume /sys/power/reserved_size /sys/power/pm_async /sys/power/pm_debug_messages /sys/power/mem_sleep; do
	[ -e "$f" ] && save_file "$f" "sys-power/$(basename "$f").txt"
done
save_file "/proc/swaps" "01-proc-swaps.txt"
run_cmd "01-lsblk.txt" lsblk -o NAME,KNAME,TYPE,SIZE,FSTYPE,FSVER,LABEL,UUID,PARTUUID,MOUNTPOINTS
run_shell "01-resume-params.txt" "grep -R . /etc/initramfs-tools/conf.d /etc/default/grub /boot/grub 2>/dev/null | grep -Ei 'resume|hibernate|image_size|swap' || true"

log "Collecting memory/cache state"
save_file "/proc/meminfo" "02-proc-meminfo.txt"
save_file "/proc/vmstat" "02-proc-vmstat.txt"
save_file "/proc/buddyinfo" "02-proc-buddyinfo.txt"
save_file "/proc/pagetypeinfo" "02-proc-pagetypeinfo.txt"
save_file "/proc/slabinfo" "02-proc-slabinfo.txt"
run_shell "02-meminfo-key.txt" "egrep 'MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapCached|Active|Inactive|Active\\(anon\\)|Inactive\\(anon\\)|Active\\(file\\)|Inactive\\(file\\)|Unevictable|Mlocked|Dirty|Writeback|AnonPages|Mapped|Shmem|KReclaimable|Slab|SReclaimable|SUnreclaim|KernelStack|PageTables|Percpu|AnonHugePages|CmaTotal|CmaFree' /proc/meminfo"
run_shell "02-vm-sysctl.txt" "sysctl vm.dirty_background_bytes vm.dirty_background_ratio vm.dirty_bytes vm.dirty_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs vm.min_free_kbytes vm.swappiness vm.vfs_cache_pressure 2>/dev/null"
run_cmd "02-free.txt" free -h

log "Collecting process and service state"
run_cmd "03-ps-rss-top.txt" ps -eo pid,ppid,user,comm,rss,vsz,stat,etime,args --sort=-rss
run_cmd "03-ps-start-time.txt" ps -eo pid,lstart,etime,user,comm,args
if have systemctl; then
	run_cmd "03-system-services-running.txt" systemctl --no-pager --type=service --state=running
	run_cmd "03-system-timers.txt" systemctl --no-pager list-timers --all
	run_cmd "03-system-failed.txt" systemctl --no-pager --failed
fi
run_shell "03-wps-kingsoft-processes.txt" "ps auxww | grep -Ei 'wps|kingsoft|kso|et|wpp|office' | grep -v grep || true"
run_shell "03-index-scan-security-processes.txt" "ps auxww | grep -Ei 'tracker|baloo|updatedb|locate|audit|scan|clam|kysec|security|antivirus|kiran|kylin' | grep -v grep || true"

log "Collecting package and startup integration clues"
run_shell "04-packages-wps-kingsoft.txt" "(dpkg -l 2>/dev/null || true; rpm -qa 2>/dev/null || true) | grep -Ei 'wps|kingsoft|kso|office' || true"
run_shell "04-autostart-wps-kingsoft.txt" "find /etc/xdg/autostart /usr/share/applications /usr/local/share/applications /opt -maxdepth 4 -type f 2>/dev/null | grep -Ei 'wps|kingsoft|kso|office' || true"
run_shell "04-wps-paths.txt" "find /opt /usr/share /usr/lib /usr/local -maxdepth 5 \\( -iname '*wps*' -o -iname '*kingsoft*' -o -iname '*kso*' \\) 2>/dev/null | head -1000"

log "Sampling IO activity for ${SAMPLE_SECONDS}s"
if have vmstat; then
	run_cmd "05-vmstat-sample.txt" vmstat 1 "$SAMPLE_SECONDS"
fi
if have iostat; then
	run_cmd "05-iostat-sample.txt" iostat -xz 1 "$SAMPLE_SECONDS"
else
	echo "iostat not found" >"$OUT_DIR/05-iostat-sample.txt"
fi
if have pidstat; then
	run_cmd "05-pidstat-io-sample.txt" pidstat -d 1 "$SAMPLE_SECONDS"
else
	echo "pidstat not found" >"$OUT_DIR/05-pidstat-io-sample.txt"
fi

log "Collecting recent boot journal snippets"
if have journalctl; then
	run_cmd "06-journal-kernel-tail.txt" journalctl -k -b --no-pager -n 1500
	run_shell "06-journal-cache-wps-index-security.txt" "journalctl -b --no-pager 2>/dev/null | grep -Ei 'wps|kingsoft|kso|tracker|baloo|updatedb|locate|audit|scan|kysec|hibernate|suspend|drop_caches|image_size' | tail -1000"
else
	echo "journalctl not found" >"$OUT_DIR/06-journal-kernel-tail.txt"
fi

if [ "$DEEP" -eq 1 ]; then
	log "Running deep file-cache attribution scan"
	if have vmtouch; then
		run_shell "07-vmtouch-likely-cache.txt" "for d in /opt/kingsoft /opt/apps /opt /usr/share/applications /usr/share/mime /usr/share/icons /usr/share/fonts /usr/lib /var/log; do [ -e \"\$d\" ] && vmtouch -v \"\$d\" 2>/dev/null; done"
	else
		echo "vmtouch not found" >"$OUT_DIR/07-vmtouch-likely-cache.txt"
	fi
	if have fincore; then
		run_shell "07-fincore-wps-files.txt" "find /opt /usr/share /usr/lib -type f \\( -iname '*wps*' -o -iname '*kingsoft*' -o -iname '*kso*' \\) 2>/dev/null | head -5000 | xargs -r fincore 2>/dev/null"
	else
		echo "fincore not found" >"$OUT_DIR/07-fincore-wps-files.txt"
	fi
else
	log "Skipping deep scan. Re-run with --deep to use vmtouch/fincore if installed."
fi

log "Creating archive"
tar -czf "${OUT_DIR}.tgz" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")" 2>>"$OUT_DIR/errors.log" || true
log "Done: $OUT_DIR"
log "Archive: ${OUT_DIR}.tgz"
