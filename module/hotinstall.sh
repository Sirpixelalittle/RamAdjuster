#!/system/bin/sh
MODDIR=${0%/*}
# The installer has a short timeout. Allocation belongs in the service.
/system/bin/sh "$MODDIR/service.sh" </dev/null >/dev/null 2>&1 &
echo "Additional Swap: startup requested. Use Action to check progress."
