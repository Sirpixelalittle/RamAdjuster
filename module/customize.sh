#!/system/bin/sh
[ "$KSU" = true ] || abort "This module requires KernelSU."
[ -x /data/adb/ksu/bin/busybox ] || abort "KernelSU BusyBox is missing."
[ -x /system/bin/losetup ] || abort "Android losetup is missing."
set_perm_recursive "$MODPATH" 0 0 0755 0644
for script in "$MODPATH"/*.sh; do
    set_perm "$script" 0 0 0755
done
export MODULE_HOT_INSTALL_REQUEST=true
export MODULE_HOT_RUN_SCRIPT=hotinstall.sh
ui_print "- Adds a 4 GiB image under /data/adb/ram_adjuster."
ui_print "- zRAM stays first in swap priority."
ui_print "- Initial allocation runs in the background; Action shows status."
ui_print "- With temporary root, restore KernelSU after each reboot."
