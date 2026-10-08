#!/usr/bin/env python3
"""Fixture-only coverage for native driver commands, migration and USB binding."""

import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

import yaml

ADDON = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ADDON))
from tuner_commands import CHANNEL, px4_command, siano_command

spec = importlib.util.spec_from_file_location("gr_scan", ADDON / "gr-scan.py")
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)

Q3 = "px4-px_q3u4-00001205000960"
M1 = "px4-px_m1ur-000012050009603"
S1 = "px4-px_s1ur-000012050009603"


class NativeTunerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mirakc-native-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = os.environ.copy()
        for key in ("PX_S1UD_FIRMWARE", "PX_S1UD_SETTLE_SECONDS", "PX4_RUNTIME_DIR",
                    "PX4_TS_BIN", "SIANO_TS_BIN", "PX4_INSTANCE", "PX4_DEVICE",
                    "PX4_RECEIVER"):
            self.env.pop(key, None)
        self.runtime = str(self.root / "runtime with spaces")
        self.firmware = str(self.root / "firmware with spaces.inp")
        self.argv_log = self.root / "argv.json"
        self.env["ARGV_LOG"] = str(self.argv_log)
        self.driver = self.root / "recording driver"
        self.driver.write_text(
            "#!/usr/bin/env python3\nimport json, os, sys\n"
            "with open(os.environ['ARGV_LOG'], 'w') as f: json.dump(sys.argv[1:], f)\n"
            "sys.stdout.buffer.write(bytes([0x47]) + bytes(187))\n"
        )
        self.driver.chmod(0o755)
        self.source = self.root / "user.yml"
        self.output = self.root / "effective.yml"
        self.plan = self.root / "plan.txt"
        self.siano_list = self.root / "siano.txt"
        self.slots = [("px_q3u4", "PX-Q3U4", Q3, "00001205000960", str(n),
                       "S" if n in (0, 1, 4, 5) else "T") for n in range(8)]
        self.slots += [("px_m1ur", "PX-M1UR", M1, "000012050009603", "0", "TS"),
                       ("px_s1ur", "PX-S1UR", S1, "000012050009603", "0", "T")]
        self.write_plan()
        self.siano_list.write_text(
            "model=PX-S1UD usb=3275:0080 bus=1 address=7 port=1-2.1 receivers=1 status=ready\n"
            "receiver=0 device=0 local=0 system=ISDB-T\n"
            "model=PX-S1UD usb=3275:0080 bus=1 address=8 port=1-2.2 receivers=1 status=ready\n"
            "receiver=1 device=1 local=0 system=ISDB-T\n"
        )

    def write_plan(self):
        self.plan.write_text("".join("slot " + " ".join(slot) + "\n" for slot in self.slots))

    def generate(self, tuners=(), *, helper=None, env=None, success=True):
        config = yaml.safe_load((ADDON / "config.yml.template").read_text())
        config["tuners"] = list(tuners)
        self.source.write_text(yaml.safe_dump(config, allow_unicode=True))
        original = self.source.read_bytes()
        self.output.write_text("stale output\n")
        result = subprocess.run(
            [sys.executable, str(helper or ADDON / "generate-effective-config.py"),
             "--input", str(self.source), "--output", str(self.output),
             "--siano-list", str(self.siano_list), "--warmup-file", str(self.root / "warmup"),
             "--q3u4-enabled", "1" if self.slots else "0", "--px4-plan", str(self.plan),
             "--runtime-dir", self.runtime, "--siano-firmware", self.firmware],
            env=env or self.env, capture_output=True, text=True,
        )
        self.assertEqual(self.source.read_bytes(), original, "persistent user config changed")
        if not success:
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.output.exists(), "failed generation left stale output")
            return result.stderr
        self.assertEqual(result.returncode, 0, result.stderr)
        return yaml.safe_load(self.output.read_text())["tuners"]

    def native(self, instance=Q3, receiver="2", types=("GR",), extra=()):
        return {"name": "manual", "types": list(types), "priority": 5,
                "command": shlex.join(px4_command(CHANNEL, instance=instance, receiver=receiver,
                                                 runtime_dir=self.runtime) + list(extra))}

    def binding(self, tuner):
        argv = shlex.split(tuner["command"])
        if argv[0].endswith("px4-ts"):
            return (argv[argv.index("--instance") + 1], argv[argv.index("--receiver") + 1])
        if argv[0].endswith("siano-ts"):
            return ("siano", argv[argv.index("--device") + 1])
        return None

    def test_all_twelve_physical_tuners_once_and_hybrid_last(self):
        tuners = self.generate()
        bindings = [self.binding(tuner) for tuner in tuners]
        self.assertEqual(len(bindings), 12)
        self.assertEqual(len(set(bindings)), 12)
        self.assertEqual(set(bindings), {(slot[2], slot[4]) for slot in self.slots}
                         | {("siano", "0"), ("siano", "1")})
        self.assertEqual(bindings[-1], (M1, "0"))
        self.assertEqual(tuners[-1]["types"], ["GR", "BS", "CS"])
        for tuner in tuners:
            argv = shlex.split(tuner["command"])
            self.assertNotIn("--slot", argv)
            self.assertNotIn("--frequency-khz", argv)
            self.assertEqual(argv[argv.index("--channel") + 1], CHANNEL)
            if argv[0].endswith("px4-ts"):
                self.assertEqual(argv[argv.index("--runtime-dir") + 1], self.runtime)
            else:
                self.assertEqual(argv[argv.index("--firmware") + 1], self.firmware)

    def test_no_fixed_tuner_count(self):
        for enclosure in range(1, 8):
            serial = f"{enclosure:014d}"
            self.slots += [("px_q3u4", "PX-Q3U4", "px4-px_q3u4-" + serial,
                            serial, str(n), "S" if n in (0, 1, 4, 5) else "T")
                           for n in range(8)]
        self.write_plan()
        bindings = [self.binding(tuner) for tuner in self.generate()]
        self.assertEqual(len(bindings), 68)
        self.assertEqual(len(set(bindings)), 68)

    def test_manual_commands_preserve_options_and_reserve_receivers(self):
        px4 = self.native(extra=("--tune-timeout-ms", "7000"))
        siano = {"name": "USB port", "types": ["GR"], "priority": 8,
                 "command": "/usr/local/bin/siano-ts --device 1-2.1 --channel {{{channel}}} --verbose"}
        tuners = self.generate([px4, siano])
        self.assertEqual(len(tuners), 12)
        self.assertEqual(tuners[:2], [px4, siano])
        self.assertNotIn(("siano", "0"), [self.binding(t) for t in tuners[2:]])

    def test_numeric_serial_alias_connects_to_running_instance(self):
        manual = self.native()
        manual["command"] = manual["command"].replace("--instance " + Q3,
                                                       "--device 00001205000960")
        tuners = self.generate([manual])
        argv = shlex.split(tuners[0]["command"])
        self.assertNotIn("--device", argv)
        self.assertEqual(self.binding(tuners[0]), (Q3, "2"))
        self.assertEqual(len(tuners), 12)
        self.assertEqual(tuners[0]["priority"], 5)

    def test_ambiguous_serial_and_duplicate_physical_tuners_fail(self):
        manual = self.native(M1, "0")
        manual["command"] = manual["command"].replace("--instance " + M1,
                                                       "--device 000012050009603")
        self.assertIn("ambiguous", self.generate([manual], success=False))
        self.assertIn("same physical tuner", self.generate([self.native(), self.native()], success=False))
        alias = self.native()
        alias["command"] = alias["command"].replace("--instance " + Q3,
                                                     "--device 00001205000960")
        self.assertIn("same physical tuner", self.generate([self.native(), alias], success=False))

    def test_legacy_definitions_preserve_custom_siano_and_explicit_px4(self):
        siano = {"name": "legacy Siano", "types": ["GR"], "priority": 9,
                 "command": "env PX_S1UD_ADAPTER=1 PX_S1UD_SETTLE_SECONDS=0.1 "
                            "PX_S1UD_FIRMWARE=/custom/fw /usr/local/bin/px-s1ud-stream {{{channel}}}"}
        px4 = {"name": "legacy PX4", "types": ["GR"], "command":
               f"env PX4_INSTANCE={Q3} PX4_MODEL=px_q3u4 PX4_RECEIVER=2 "
               "/usr/local/bin/px4-ts-stream {{{channel}}}"}
        old_template = {"name": "old template", "types": ["GR"], "command":
                        "env PX4_PROFILE=px_s1ur PX4_RECEIVER=0 "
                        "/usr/local/bin/px4-ts-stream {{{channel}}}"}
        tuners = self.generate([siano, px4, old_template])
        self.assertEqual(tuners[:2], [siano, px4])
        self.assertEqual(len(tuners), 12)
        self.assertNotIn(old_template, tuners)
        self.assertIn("same physical tuner", self.generate([px4, self.native()], success=False))

    def test_custom_commands_and_pipeline_options_are_preserved(self):
        custom = [{"name": "echo", "types": ["GR"],
                   "command": "/bin/echo /usr/local/bin/px4-ts"},
                  {"name": "private driver", "types": ["GR"],
                   "command": "/media/private-ts --channel {{{channel}}}"}]
        manual = self.native()
        manual["command"] += " | /custom/decode --receiver 0"
        tuners = self.generate(custom + [manual])
        self.assertEqual(tuners[:3], custom + [manual])
        self.assertEqual(len(tuners), 14)
        self.assertEqual(sum(self.binding(t) == (Q3, "2") for t in tuners), 1)

    def test_absent_receivers_are_removed_and_capabilities_validated(self):
        self.assertIn("capabilities", self.generate([self.native(S1, "0", ("BS",))], success=False))
        self.slots = []
        self.write_plan()
        self.siano_list.write_text("0 devices\n")
        custom = {"name": "external", "types": ["GR"], "command": "/media/private-ts {{{channel}}}"}
        self.assertEqual(self.generate([self.native(), custom]), [custom])

    def test_native_siano_bus_address_alias_and_duplicate(self):
        manual = {"name": "bus address", "types": ["GR"],
                  "command": "siano-ts -d 01:007 --channel {{{channel}}}"}
        self.assertEqual(len(self.generate([manual])), 12)
        duplicate = {"name": "index", "types": ["GR"],
                     "command": "/usr/local/bin/siano-ts -d0 --channel {{{channel}}}"}
        self.assertIn("same physical tuner", self.generate([manual, duplicate], success=False))

    def test_compatibility_shims_forward_native_argv_and_custom_paths(self):
        env = dict(self.env, PX4_INSTANCE=Q3, PX4_DEVICE="000012050009603", PX4_RECEIVER="7",
                   PX4_TS_BIN=str(self.driver), PX4_RUNTIME_DIR=self.runtime)
        subprocess.run([str(ADDON / "px4-ts-stream"), "T27"], env=env, check=True, capture_output=True)
        self.assertEqual(json.loads(self.argv_log.read_text()),
                         px4_command("T27", instance=Q3, receiver=7, runtime_dir=self.runtime)[1:])
        env.pop("PX4_INSTANCE")
        env["PX4_RECEIVER"] = "0"
        subprocess.run([str(ADDON / "px4-ts-stream"), "BS01_0"], env=env, check=True, capture_output=True)
        self.assertEqual(json.loads(self.argv_log.read_text()),
                         px4_command("BS01_0", device=env["PX4_DEVICE"], receiver=0,
                                     runtime_dir=self.runtime)[1:])
        env = dict(self.env, SIANO_TS_BIN=str(self.driver), PX_S1UD_ADAPTER="1",
                   PX_S1UD_FIRMWARE=self.firmware, PX_S1UD_SETTLE_SECONDS="0.01")
        subprocess.run([str(ADDON / "px-s1ud-stream"), "27"], env=env, check=True, capture_output=True)
        self.assertEqual(json.loads(self.argv_log.read_text()),
                         siano_command("27", device=1, firmware=self.firmware)[1:])

    def test_scanner_uses_same_argv_and_explicit_selected_receiver(self):
        args = SimpleNamespace(px4_bin=str(self.driver), px4_instance=Q3, px4_device=None,
                               px4_receiver="7", runtime_dir=self.runtime, siano_bin=None)
        self.assertEqual(scanner.stream_command(args),
                         px4_command(CHANNEL, instance=Q3, receiver=7,
                                     binary=str(self.driver), runtime_dir=self.runtime))
        args.stream_cmd = scanner.stream_command(args)
        args.stream_env = self.env
        args.settle_seconds = 0
        args.capture_seconds = 0.2
        arib = self.root / "recording arib"
        arib.write_text('#!/usr/bin/env python3\nprint(\'{"name":"Fixture TV","type":1,"sid":1}\')\n')
        arib.chmod(0o755)
        args.arib_bin = str(arib)
        self.assertEqual(scanner.scan_channel(args, "T27")[0]["name"], "Fixture TV")
        self.assertEqual(json.loads(self.argv_log.read_text()),
                         px4_command("T27", instance=Q3, receiver=7, runtime_dir=self.runtime)[1:])
        args.px4_receiver = None
        with self.assertRaisesRegex(ValueError, "receiver"):
            scanner.stream_command(args)

    def test_siano_scanner_and_explicit_settle_override_keep_configuration(self):
        args = SimpleNamespace(px4_bin=None, siano_bin=str(self.driver),
                               siano_adapter="1", siano_firmware=self.firmware)
        self.assertEqual(scanner.stream_command(args),
                         siano_command(CHANNEL, device=1, binary=str(self.driver),
                                       firmware=self.firmware))
        env = dict(self.env, PX_S1UD_SETTLE_SECONDS="0.01", SIANO_TS_BIN=str(self.driver))
        tuners = self.generate(env=env)
        for adapter, tuner in enumerate(tuners[:2]):
            argv = shlex.split(tuner["command"])
            self.assertIn(f"PX_S1UD_ADAPTER={adapter}", argv)
            self.assertIn("SIANO_TS_BIN=" + str(self.driver), argv)
            self.assertIn("PX_S1UD_FIRMWARE=" + self.firmware, argv)
            self.assertIn("/usr/local/bin/px-s1ud-stream", argv)

    def test_packaged_module_imports_and_generated_commands_execute(self):
        installed = self.root / "installed"
        installed.mkdir()
        dockerfile = (ADDON / "Dockerfile").read_text()
        for name in ("generate-effective-config.py", "gr-scan.py", "tuner_commands.py"):
            self.assertIn(f"COPY {name} /usr/local/bin/{name}", dockerfile)
            shutil.copy2(ADDON / name, installed / name)
        env = dict(self.env, PX4_TS_BIN=str(self.driver), SIANO_TS_BIN=str(self.driver))
        tuners = self.generate(helper=installed / "generate-effective-config.py", env=env)
        for tuner in (tuners[0], tuners[-1]):
            argv = ["BS01_0" if token == CHANNEL else token
                    for token in shlex.split(tuner["command"])]
            subprocess.run(argv, env=env, check=True, capture_output=True)
            self.assertEqual(json.loads(self.argv_log.read_text()), argv[1:])
        result = subprocess.run([sys.executable, str(installed / "gr-scan.py"), "--help"],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
