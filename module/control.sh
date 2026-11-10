#!/system/bin/sh
# Use the same applets in the manager, a root shell, and boot/late-load hooks.
BB=/data/adb/ksu/bin/busybox
if [ "$RAM_ADJUSTER_ASH" != 1 ]; then
    [ -x "$BB" ] || { echo "KernelSU BusyBox is missing." >&2; exit 1; }
    export RAM_ADJUSTER_ASH=1 ASH_STANDALONE=1
    exec "$BB" ash "$0" "$@"
fi
set -u
umask 077
MODDIR=$(cd "${0%/*}" && pwd -P) || exit 1
DATA=/data/adb/ram_adjuster
IMAGE=$DATA/swap.img
PENDING=$DATA/swap.img.new
LOG=$DATA/activity.log
SIZE_BYTES=4294967296
SIZE_MIB=4096
RESERVE_KIB=2097152
LOOP=
LOG_READY=0

die() {
    echo "Additional Swap: $*" >&2
    if [ "$LOG_READY" = 1 ]; then
        printf '%s ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"
    fi
    exit 1
}
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

# Resolve ownership from the kernel, never from a saved loop number that can
# belong to an Android APEX or another module on the next boot.
find_loop() {
    LOOP=
    for entry in /sys/block/loop*/loop/backing_file; do
        [ -r "$entry" ] || continue
        [ "$(cat "$entry")" = "$IMAGE" ] || continue
        [ -z "$LOOP" ] || die "Multiple loops reference our image; leaving them intact."
        entry=${entry%/loop/backing_file}
        LOOP=/dev/block/${entry##*/}
        [ -b "$LOOP" ] || die "Missing block node for our loop."
    done
}

active() {
    [ -n "$LOOP" ] || return 1
    # Compare device basenames to also recognize /dev/loopN aliases.
    awk -v dev="${LOOP##*/}" 'NR > 1 { n=split($1,p,"/"); if(p[n]==dev) found=1 }
        END { exit !found }' /proc/swaps
}

zram_ready() {
    awk 'NR > 1 && $1 ~ /\/zram[0-9]+$/ { found=1 } END { exit !found }' /proc/swaps
}

check_enabled() {
    [ ! -e "$MODDIR/disable" ] && [ ! -e "$MODDIR/remove" ] ||
        die "Module is disabled or marked for removal."
}

validate_image() {
    [ ! -L "$IMAGE" ] && [ -f "$IMAGE" ] || die "Image is not a regular file."
    [ "$(stat -c %h "$IMAGE")" = 1 ] || die "Image has multiple hard links."
    [ "$(stat -c %s "$IMAGE")" = "$SIZE_BYTES" ] ||
        die "Existing image has an unexpected size; leaving it intact."
    blocks=$(stat -c %b "$IMAGE") || die "Cannot inspect allocated blocks."
    [ "$((blocks * 512))" -ge "$SIZE_BYTES" ] || die "Image is not fully allocated."
    chown 0:0 "$IMAGE" && chmod 0600 "$IMAGE" || die "Cannot secure image permissions."
}

create_image() {
    [ ! -L "$PENDING" ] || die "Unexpected symlink at the temporary image path."
    # A partial allocation can only exist at this private staging path.
    if [ -e "$PENDING" ]; then
        [ -f "$PENDING" ] && [ "$(stat -c %h "$PENDING")" = 1 ] ||
            die "Unexpected temporary image; leaving it intact."
        rm "$PENDING" || die "Cannot remove interrupted allocation."
    fi
    free_kib=$(df -Pk "$DATA" | awk 'END {print $4}')
    case "$free_kib" in ''|*[!0-9]*) die "Cannot determine free storage." ;; esac
    [ "$free_kib" -ge "$((SIZE_MIB * 1024 + RESERVE_KIB))" ] ||
        die "Need 6 GiB free: 4 GiB swap plus 2 GiB reserve."
    log "Allocating 4 GiB in encrypted /data storage; this may take a minute."
    dd if=/dev/zero of="$PENDING" bs=1048576 count="$SIZE_MIB" conv=fsync >>"$LOG" 2>&1 ||
        die "Allocation failed. See $LOG; a later start will retry."
    [ "$(stat -c %s "$PENDING")" = "$SIZE_BYTES" ] || die "Incomplete allocation."
    mkswap "$PENDING" >>"$LOG" 2>&1 || die "Cannot initialize swap header."
    sync "$PENDING" || die "Cannot sync swap header."
    mv "$PENDING" "$IMAGE" || die "Cannot publish completed image."
}

start_swap() {
    check_enabled
    find_loop
    if active; then
        rm -f "$DATA/paused"
        log "Already active on $LOOP."
        return 0
    fi
    zram_ready || die "Waiting for stock zRAM: start again after Android finishes booting."
    if [ ! -e "$IMAGE" ] && [ ! -L "$IMAGE" ]; then
        [ -z "$LOOP" ] || die "Loop exists without its image; leaving it intact."
        create_image
    fi
    validate_image
    check_enabled
    # BusyBox mkswap can assign desktop Linux's swapfile_t, which is invalid
    # on Android. Give only this image a dedicated type for loop-worker I/O.
    # Applying here also supports NoMount hot install on older ksud versions.
    /data/adb/ksud sepolicy apply "$MODDIR/sepolicy.rule" >>"$LOG" 2>&1 ||
        die "Cannot load the image's SELinux rules."
    /system/bin/chcon u:object_r:ram_adjuster_file:s0 "$IMAGE" >>"$LOG" 2>&1 ||
        die "Cannot label the backing image for kernel loop I/O."
    if [ -z "$LOOP" ]; then
        # Android Toybox supports atomic find-and-attach with -f -s. BusyBox's
        # applet has different flags, so use the absolute Android executable.
        /system/bin/losetup -f -s "$IMAGE" >>"$LOG" 2>&1 || die "Cannot attach swap loop."
        find_loop
        [ -n "$LOOP" ] || die "Cannot identify the newly attached loop."
    fi
    # No -p: the kernel gives this device the next lower automatic priority.
    # Positive priorities would put flash ahead of stock zRAM's negative one.
    if ! swapon "$LOOP" >>"$LOG" 2>&1; then
        active || /system/bin/losetup -d "$LOOP"
        die "swapon failed. Image retained; see $LOG."
    fi
    active || die "Kernel did not report the new swap device."
    rm -f "$DATA/paused"
    log "Enabled $LOOP with 4 GiB backing image."
    if ! awk -v dev="${LOOP##*/}" 'NR > 1 {
        n=split($1,p,"/"); if(p[n]==dev) priority=$5;
        if(p[n] ~ /^zram[0-9]+$/) { z[++count]=$5 }
    } END { for(i=1;i<=count;i++) if(priority>=z[i]) exit 1 }' /proc/swaps; then
        log "Priority changed unexpectedly. Inspect /proc/swaps; existing swap was left running."
        return 1
    fi
}

stop_swap() {
    # Pause survives a later service invocation; an explicit start resumes it.
    touch "$DATA/paused" || die "Cannot record pause."
    find_loop
    if active; then
        used=$(awk -v dev="${LOOP##*/}" 'NR > 1 {n=split($1,p,"/"); if(p[n]==dev) print $4}' /proc/swaps)
        available=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)
        [ -n "$available" ] && [ "$available" -ge "$((used + 524288))" ] ||
            die "Too little free RAM to stop safely. Paused for future starts; reboot to clear active swap."
        log "Stopping only $LOOP ($used KiB used)."
        swapoff "$LOOP" >>"$LOG" 2>&1 || die "swapoff failed; image and loop retained."
    fi
    if [ -n "$LOOP" ]; then
        active && die "Swap is still active; image and loop retained."
        /system/bin/losetup -d "$LOOP" || die "Cannot detach loop; image retained."
    fi
    log "Stopped. Image retained; Action or control.sh start resumes swap."
}

cleanup_swap() {
    touch "$DATA/paused" || die "Cannot record pause."
    find_loop
    if active; then
        log "Uninstall: active swap retained. Reboot, restore root, then run $DATA/cleanup.sh."
        # Keep a cleanup entry point if the manager removes the module itself.
        cp "$0" "$DATA/cleanup.sh" && chmod 0700 "$DATA/cleanup.sh"
        return 1
    fi
    if [ -n "$LOOP" ]; then
        /system/bin/losetup -d "$LOOP" || die "Cannot detach loop; image retained."
    fi
    [ ! -L "$IMAGE" ] && [ ! -L "$PENDING" ] || die "Unexpected image symlink; cleanup refused."
    rm -f "$IMAGE" "$PENDING" "$DATA/cleanup.sh" "$DATA/paused" || die "Cannot remove inactive image."
    log "Inactive swap image removed."
    # Keep the small log and lock inode: deleting a held flock file causes races.
}

show_status() {
    find_loop
    if active; then echo "Additional Swap: ACTIVE ($LOOP)"
    else echo "Additional Swap: INACTIVE"; fi
    [ ! -e "$DATA/paused" ] || echo "Automatic startup is paused. Action resumes it."
    [ ! -e "$MODDIR/disable" ] || echo "Module is disabled; active swap lasts until stopped or rebooted."
    [ ! -e "$MODDIR/remove" ] || echo "Module is marked for removal."
    if [ -f "$IMAGE" ]; then
        echo "Backing image: $IMAGE ($(stat -c %s "$IMAGE") bytes)"
    elif [ -f "$PENDING" ]; then
        echo "Allocation pending: $(stat -c %s "$PENDING") / $SIZE_BYTES bytes"
    fi
    cat /proc/swaps
    awk '/^(MemAvailable|SwapTotal|SwapFree):/' /proc/meminfo
    if [ -f "$LOG" ]; then echo "Recent log:"; tail -n 8 "$LOG"; fi
}

[ "$(id -u)" = 0 ] || die "Run as root."
command=${1:-status}
# The saved cleanup entry point defaults to cleanup instead of status.
if [ "${0##*/}" = cleanup.sh ] && [ "$#" = 0 ]; then command=cleanup; fi
case "$command" in start|auto|stop|status|cleanup) ;; *) die "Usage: $0 {start|stop|status|cleanup}" ;; esac
[ ! -L "$DATA" ] || die "Data directory must not be a symlink."
mkdir -p "$DATA" && chmod 0700 "$DATA" && chown 0:0 "$DATA" || die "Cannot secure data directory."
if [ "$command" = status ]; then show_status; exit 0; fi
[ ! -L "$DATA/lock" ] && [ ! -L "$LOG" ] || die "Unexpected state symlink."
exec 9>"$DATA/lock"
flock -n 9 || { echo "Another swap operation is running; use status to check progress."; exit 2; }
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 131072 ]; then
    mv "$LOG" "$LOG.previous" || die "Cannot rotate log."
fi
LOG_READY=1
case "$command" in
    start) start_swap ;;
    auto)
        [ ! -e "$DATA/paused" ] || exit 0
        attempts=0
        until zram_ready && [ "$(/system/bin/getprop sys.boot_completed)" = 1 ]; do
            check_enabled
            attempts=$((attempts + 1))
            [ "$attempts" -lt 60 ] || die "Stock zRAM/boot readiness timed out. Use Action to retry."
            sleep 2
        done
        start_swap
        ;;
    stop) stop_swap ;;
    cleanup) cleanup_swap ;;
esac
