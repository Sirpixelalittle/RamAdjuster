#!/system/bin/sh
MODDIR=${0%/*}
# Never force pages back into RAM during a live uninstall.
exec /system/bin/sh "$MODDIR/control.sh" cleanup
