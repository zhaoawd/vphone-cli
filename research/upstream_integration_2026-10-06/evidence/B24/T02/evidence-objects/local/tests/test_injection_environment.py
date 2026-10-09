"""Run the real C environment helper; no guest processes or dylib deployment."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class InjectionEnvironmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="vphone injection ")
        cls.addClassCleanup(cls.temp.cleanup)
        source = Path(cls.temp.name) / "test.c"
        cls.binary = source.with_suffix("")
        header = ROOT / "sources/VPhoneGuestComponents/Shared/InjectionEnvironment.h"
        source.write_text('#include ' + json.dumps(str(header)) + '\n' + r'''
int main(int argc, char **argv) {
    if (argc != 2) return 99;
    if (strcmp(argv[1], "duplicates") == 0) {
        char *keys[] = {"DISABLE_TWEAKS", "_SafeMode", "_MSSafeMode"};
        for (int i = 0; i < 3; i++) {
            char off[80], on[80];
            snprintf(off, sizeof(off), "%s=0", keys[i]);
            snprintf(on, sizeof(on), "%s=1", keys[i]);
            char *env[] = {off, on, NULL};
            if (!vpInjectionDisabled(env)) return 1;
        }
    } else if (strcmp(argv[1], "bounded") == 0) {
        char *env[4098];
        for (int i = 0; i < 4097; i++) env[i] = "A=0";
        env[4097] = NULL;
        if (!vpInjectionDisabled(env)) return 2;
    } else if (strcmp(argv[1], "legacy") == 0) {
        char *env[] = {"DISABLE_TWEAKS=01", "_SafeMode=0", "A=1", NULL};
        if (vpInjectionDisabled(env) || vpInjectionDisabled(NULL)) return 3;
        VPInjectionEnvironment first = vpInsertHook(env, "/private/bootstrap");
        if (!first.values || !vpHasHook(vpEnvValue(first.values, "DYLD_INSERT_LIBRARIES"))) return 4;
        if (strcmp(vpEnvValue(first.values, "VPHONE_JB_ROOT"), "/private/bootstrap") != 0) return 5;
        VPInjectionEnvironment second = vpInsertHook(first.values, "/private/bootstrap");
        if (second.values) return 6;
        vpFreeEnvironment(&second);
        vpFreeEnvironment(&first);
    } else return 98;
    return 0;
}
''')
        subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", str(source), "-o", str(cls.binary)], check=True, capture_output=True)

    def run_case(self, name):
        result = subprocess.run([str(self.binary), name], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, name + ": " + result.stderr.decode())

    def test_any_explicit_safe_flag_disables_injection_despite_duplicate_env_keys(self):
        self.run_case("duplicates")

    def test_oversized_environment_refuses_injection(self):
        self.run_case("bounded")

    def test_legacy_exact_flags_hook_deduplication_and_bootstrap_root_are_preserved(self):
        self.run_case("legacy")
