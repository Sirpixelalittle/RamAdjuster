# Additional Swap

A KernelSU module that adds **4 GiB of storage-backed swap** on an Android
phone with stock zRAM already active. Built for KernelSU Next late load. Module ID: `ram_adjuster`.

## Install and use

Install [`dist/additional-swap.zip`](dist/additional-swap.zip) in KernelSU
Manager. With the tested KernelSU Next / NoMount combination, installation
starts allocation immediately and does not require a reboot. Allow about a
minute for the initial 4 GiB allocation, then tap **Action** to start/check it.
Action is safe to repeat: it shows existing swap instead of creating another
device. It also resumes startup after a manual stop.

On an installer without hot-install support, the module takes effect at the
next normal module startup. Once its files are in `/data/adb/modules/ram_adjuster`,
Action can start it immediately.

With temporary root, a reboot clears the active swap device. The image remains
on storage. Restore KernelSU using your existing late-load procedure; its
`service.sh` stage starts the module again. The module does not restore root.

## What it does

- Creates `/data/adb/ram_adjuster/swap.img`, exactly 4,294,967,296 bytes.
  Usable swap is one header page smaller than 4 GiB.
- Requires at least 6 GiB free before initial allocation, leaving a 2 GiB
  starting reserve. The runtime data directory is mode 0700, image mode 0600.
- Fully writes and syncs the image before attaching a dynamically allocated
  loop device. Device names can change across boots.
- Enables the loop as swap with the kernel's next lower automatic priority.
  On the tested Pixel, zRAM is priority `-2` and this swap is `-3`. Higher
  numbers are preferred, so stock zRAM fills first.
- Uses filesystem I/O for the encrypted backing image. Direct `swapon` on an
  fscrypt-encrypted file is unsuitable; a loop device preserves filesystem
  encryption. See the [kernel fscrypt documentation](https://www.kernel.org/doc/html/next/filesystems/fscrypt.html).
- Assigns the image a dedicated SELinux type and permits kernel loop workers
  to read/write that type. KernelSU's root domain can manage the file. This
  avoids BusyBox `mkswap`'s desktop `swapfile_t` label, which Android rejects.
  These module rules live in memory; SELinux stays enforcing.
  
Storage swap is slower than RAM/zRAM and adds flash writes. Its purpose is
extra capacity under memory pressure; it does not add physical RAM or
guarantee faster apps. Android can still kill apps through its memory manager.
This module's space checks and stop guard are conservative checks, not a
guarantee against memory/storage pressure from other activity.

## Root-shell commands

Run these from an already-rooted shell, or prefix them with `su -c`:

```sh
sh /data/adb/modules/ram_adjuster/control.sh status
sh /data/adb/modules/ram_adjuster/control.sh start
sh /data/adb/modules/ram_adjuster/control.sh stop
```

`stop` only targets the loop backed by this module's image. It records a pause
for future service starts and requires `MemAvailable` to cover its used swap
plus 512 MiB before attempting `swapoff`. If memory is insufficient or
`swapoff` fails, the active image is retained. Explicit `start` or Action
clears the pause after activation. Disabling the module prevents future starts;
it does not immediately deactivate already active swap.

The log is `/data/adb/ram_adjuster/activity.log`; status displays its last
eight lines. A start already in progress returns a busy message. Failed
allocations remain at `swap.img.new` and are retried on the next start.
An existing image with the wrong size, holes, hard links, or a symlink is
rejected instead of overwritten.

## Remove

To reclaim space immediately, run `stop`, confirm status is **INACTIVE**,
then run:

```sh
sh /data/adb/modules/ram_adjuster/control.sh cleanup
```

Then uninstall the module in KernelSU Manager. Cleanup never forces active
swap off. If uninstall runs while the image is active, it preserves the image
and a small cleanup script. After a reboot and restoration of root, run:

```sh
sh /data/adb/ram_adjuster/cleanup.sh
```

Normal uninstall after reboot removes the inactive image automatically.
A small log and lock file may remain. Do not delete the image or detach its
loop while `/proc/swaps` shows that device in use.

## Build and validation

Only building/testing on a computer requires Python; installing the ZIP does
not. Build with `python3 tools/build.py`. The ZIP includes the small module
scripts, not the 4 GiB runtime image. Its initial module version is `1.0`.

```sh
python3 -m unittest discover -s tests -v
for script in module/*.sh; do sh -n "$script" || exit; done
```

The isolated tests cover idempotent startup, disabled/missing-zRAM startup,
free-space refusal, preservation of unexpected images, sparse-file rejection,
low-memory stop refusal, and cleanup behavior with active/inactive swap.
The controller uses KernelSU's BusyBox; loop attachment explicitly uses
Android Toybox's `losetup -f -s` interface.


Lifecycle references: [KernelSU Next late-load execution](https://github.com/KernelSU-Next/KernelSU-Next/blob/dev/website/docs/guide/metamodule.md#late-load-mode),
[KernelSU Next installer hot-install support](https://github.com/KernelSU-Next/KernelSU-Next/blob/dev/userspace/ksud/src/installer.sh).
