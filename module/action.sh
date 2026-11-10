#!/system/bin/sh
MODDIR=${0%/*}
/system/bin/sh "$MODDIR/control.sh" start
result=$?
/system/bin/sh "$MODDIR/control.sh" status
exit "$result"
