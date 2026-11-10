"""Exercise controller failure paths without making real swap/device changes."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "module/control.sh").read_text()
# Load production functions only; skip the Android root/dispatch entry point.
FUNCTIONS = SOURCE.split('\n[ "$(id -u)" = 0 ]', 1)[0]


class Safeguards(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.data = self.path / "data"
        self.data.mkdir()
        self.mod = self.path / "module"
        self.mod.mkdir()
        self.swaps = self.path / "swaps"
        self.swaps.write_text("Filename Type Size Used Priority\n/dev/block/zram0 partition 6000000 5000000 -2\n")
        self.meminfo = self.path / "meminfo"
        self.meminfo.write_text("MemAvailable: 100000 kB\n")

    def run_controller(self, commands):
        q = shlex.quote
        functions = FUNCTIONS.replace("/proc/swaps", str(self.swaps)).replace("/proc/meminfo", str(self.meminfo))
        script = self.path / "test.sh"
        script.write_text(functions + f'''
DATA={q(str(self.data))}
MODDIR={q(str(self.mod))}
IMAGE=$DATA/swap.img
PENDING=$DATA/swap.img.new
LOG=$DATA/activity.log
# Tests must never reach a real swap operation.
swapon() {{ echo UNSAFE_SWAPON; exit 90; }}
swapoff() {{ echo UNSAFE_SWAPOFF; exit 91; }}
mkswap() {{ echo UNSAFE_MKSWAP; exit 92; }}
dd() {{ echo UNEXPECTED_ALLOCATION; exit 93; }}
find_loop() {{ LOOP=; }}
''' + commands)
        env = dict(os.environ, RAM_ADJUSTER_ASH="1")
        return subprocess.run(["sh", str(script)], env=env, capture_output=True, text=True)

    def test_active_start_is_idempotent(self):
        (self.data / "paused").touch()
        result = self.run_controller('find_loop() { LOOP=/dev/block/loop99; }; active() { return 0; }; start_swap\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Already active", result.stdout)
        self.assertFalse((self.data / "paused").exists())
        self.assertFalse((self.data / "swap.img").exists())

    def test_disabled_module_never_starts(self):
        (self.mod / "disable").touch()
        result = self.run_controller("start_swap\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("disabled", result.stderr)

    def test_no_zram_never_allocates(self):
        self.swaps.write_text("Filename Type Size Used Priority\n")
        result = self.run_controller("start_swap\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Waiting for stock zRAM", result.stderr)
        self.assertFalse((self.data / "swap.img.new").exists())

    def test_insufficient_storage_never_allocates(self):
        result = self.run_controller('df() { printf "Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/test 9000000 4000000 5000000 44%% /data\\n"; }; create_image\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn("Need 6 GiB", result.stderr)
        self.assertNotIn("UNEXPECTED_ALLOCATION", result.stdout)

    def test_foreign_size_is_preserved(self):
        image = self.data / "swap.img"
        image.write_text("existing content")
        result = self.run_controller("start_swap\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected size", result.stderr)
        self.assertEqual(image.read_text(), "existing content")

    def test_sparse_image_is_rejected(self):
        image = self.data / "swap.img"
        with image.open("wb") as stream:
            stream.truncate(4294967296)
        result = self.run_controller("validate_image\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not fully allocated", result.stderr)

    def test_symlink_is_preserved(self):
        victim = self.path / "unrelated"
        victim.write_text("keep me")
        (self.data / "swap.img").symlink_to(victim)
        result = self.run_controller("start_swap\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a regular file", result.stderr)
        self.assertEqual(victim.read_text(), "keep me")

    def test_stop_refuses_low_memory_and_records_pause(self):
        self.swaps.write_text("Filename Type Size Used Priority\n/dev/block/zram0 partition 6000000 5000000 -2\n/dev/loop99 partition 4194300 1000000 -3\n")
        result = self.run_controller('find_loop() { LOOP=/dev/block/loop99; }; stop_swap\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn("Too little free RAM", result.stderr)
        self.assertTrue((self.data / "paused").exists())
        self.assertNotIn("UNSAFE_SWAPOFF", result.stdout)

    def test_uninstall_preserves_active_image(self):
        image = self.data / "swap.img"
        image.write_text("active data")
        result = self.run_controller('find_loop() { LOOP=/dev/block/loop99; }; active() { return 0; }; cleanup_swap\n')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(image.read_text(), "active data")
        self.assertTrue((self.data / "cleanup.sh").exists())
        self.assertTrue((self.data / "paused").exists())
        self.assertNotIn("UNSAFE_SWAPOFF", result.stdout)

    def test_uninstall_removes_inactive_image(self):
        (self.data / "swap.img").write_text("inactive data")
        result = self.run_controller("cleanup_swap\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.data / "swap.img").exists())


if __name__ == "__main__":
    unittest.main()
