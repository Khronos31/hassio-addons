#!/usr/bin/env python3
"""Do not reserialize custom shell syntax when mapping a serial endpoint."""

import importlib.util
from pathlib import Path
import sys
import unittest

ADDON = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ADDON))
spec = importlib.util.spec_from_file_location("effective_config", ADDON / "generate-effective-config.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

INSTANCE = "px4-px_q3u4-00001205000960"
SLOTS = [("px_q3u4", "PX-Q3U4", INSTANCE, "00001205000960", "2", "T")]


def filter_command(command):
    return helper.filter_tuners(
        [{"name": "manual", "types": ["GR"], "command": command}],
        [], True, "px_q3u4", helper.SIANO_WRAPPER, helper.Q3U4_WRAPPER,
        drop_px4=True, px4_slots=SLOTS,
    )[0]


class NativeCommandSyntaxTests(unittest.TestCase):
    def test_grouped_siano_options_reserve_selected_adapter_without_duplication(self):
        for options in ("-vd1", "-vd 1", "-vld1", "--dev 1"):
            with self.subTest(options=options):
                tuner = {"name": "manual", "types": ["GR"], "priority": 9,
                         "command": f"siano-ts {options} --channel " + "{{{channel}}}"}
                result = helper.filter_tuners(
                    [tuner], [0, 1], False, "px_q3u4", helper.SIANO_WRAPPER, helper.Q3U4_WRAPPER,
                    drop_px4=True, siano_aliases={"0": 0, "1": 1},
                )
                self.assertEqual(result[0], [tuner])
                self.assertEqual(result[1], [1])
                generated = helper.siano_tuners_from_adapters([0, 1], result[1])
                self.assertEqual(len(generated), 1)
                self.assertEqual(generated[0]["name"], "PX-S1UD #0")

    def test_zero_padded_siano_port_reserves_same_physical_adapter(self):
        tuner = {"name": "port", "types": ["GR"], "priority": 9,
                 "command": "siano-ts --device 01-02.01 --channel {{{channel}}} --verbose"}
        result = helper.filter_tuners(
            [tuner], [0], False, "px_q3u4", helper.SIANO_WRAPPER, helper.Q3U4_WRAPPER,
            drop_px4=True, siano_aliases={"0": 0, "1-2.1": 0},
        )
        self.assertEqual(result[0], [tuner])
        self.assertEqual(result[1], [0])
        self.assertEqual(result[3], 0)

    def test_serial_alias_with_shell_syntax_fails_instead_of_corrupting_command(self):
        prefix = "/usr/local/bin/px4-ts --device 00001205000960 --receiver 2 --channel {{{channel}}}"
        for suffix in (" 2>/tmp/px4.log", " 2>&1", " >/tmp/out", " </tmp/input",
                       " | /usr/bin/cat", " && /usr/bin/true", " ; /usr/bin/true"):
            with self.subTest(suffix=suffix):
                with self.assertRaisesRegex(helper.ConfigError, "use --instance"):
                    filter_command(prefix + suffix)

    def test_explicit_instance_preserves_custom_shell_command(self):
        command = f"/usr/local/bin/px4-ts --instance {INSTANCE} --receiver 2 --channel {{{{{{channel}}}}}} 2>/tmp/px4.log"
        self.assertEqual(filter_command(command)[0]["command"], command)


if __name__ == "__main__":
    unittest.main()
