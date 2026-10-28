"""Exercise installers without touching system services or /root."""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ("realm.sh", "CN/realm.sh", "test/realm.sh")


class InstallerTests(unittest.TestCase):
    def run_installer(self, script, *, arch="x86_64", failure="", latest="2.9.6", action="deploy_realm", service_missing=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bindir = root / "bin"
            bindir.mkdir()
            realm = root / "realm"
            realm.mkdir()
            (realm / "realm").write_text("old binary")
            (realm / "realm").chmod(0o755)
            config = b'[network]\nuse_udp = true\n# existing forwarding rules\n'
            (realm / "config.toml").write_bytes(config)
            if action.startswith("service_control") and not service_missing:
                (root / "realm.service").write_text("[Service]\nExecStart=/configured/binary --custom\n")
            commands = {
                "uname": '#!/bin/sh\nprintf "%s\\n" "$TEST_ARCH"\n',
                "systemctl": '''#!/bin/sh
echo "$*" >> "$TEST_ROOT/systemctl.log"
if [ "$TEST_FAILURE" = reset_not_loaded ] && [ "$1" = reset-failed ]; then
    echo "Failed to reset failed state of unit realm.service: Unit realm.service not loaded." >&2
    exit 1
fi
[ "$TEST_FAILURE" != service ]
''',
                "curl": '''#!/bin/bash
echo "$*" >> "$TEST_ROOT/curl.log"
if [[ "$*" == *releases/latest* ]]; then
    printf '{"tag_name": "v%s"}\\n' "$TEST_LATEST"
    exit 0
fi
[[ "$TEST_FAILURE" == download ]] && exit 22
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then
        cp "$TEST_ROOT/archive.tar.gz" "$2"
        exit $?
    fi
    shift
done
exit 1
''',
            }
            for name, content in commands.items():
                path = bindir / name
                path.write_text(content)
                path.chmod(0o755)
            candidate = b'#!/bin/sh\necho "realm 2.9.6"\nexit 0\n'
            if failure == "binary":
                candidate = b'#!/bin/sh\necho "GLIBC_2.38 not found" >&2\nexit 1\n'
            with tarfile.open(root / "archive.tar.gz", "w:gz") as archive:
                if failure != "missing":
                    info = tarfile.TarInfo("realm")
                    info.size = len(candidate)
                    info.mode = 0o755
                    archive.addfile(info, io.BytesIO(candidate))
            if failure == "archive":
                (root / "archive.tar.gz").write_text("not an archive")
            env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"],
                       TEST_ROOT=str(root), TEST_ARCH=arch, TEST_FAILURE=failure, TEST_LATEST=latest)
            result = subprocess.run([
                "bash", "-c",
                'source "$1"; REALM_DIR="$2/realm"; CONFIG_FILE="$REALM_DIR/config.toml"; '
                'SERVICE_FILE="$2/realm.service"; LOG_FILE="$2/manager.log"; '
                + action,
                "test", str(ROOT / script), str(root),
            ], env=env, capture_output=True, text=True)
            self.assertEqual((realm / "config.toml").read_bytes(), config)
            self.assertFalse(list(realm.glob(".install.*")))
            return {
                "result": result,
                "binary": (realm / "realm").read_bytes(),
                "backup": (realm / "realm.bak").read_bytes() if (realm / "realm.bak").exists() else None,
                "service": (root / "realm.service").exists(),
                "service_contents": (root / "realm.service").read_text() if (root / "realm.service").exists() else "",
                "urls": (root / "curl.log").read_text() if (root / "curl.log").exists() else "",
                "commands": (root / "systemctl.log").read_text() if (root / "systemctl.log").exists() else "",
            }

    def test_install_supported_architectures(self):
        for script in SCRIPTS:
            for arch, target in (("x86_64", "x86_64"), ("aarch64", "aarch64")):
                with self.subTest(script=script, arch=arch):
                    data = self.run_installer(script, arch=arch)
                    self.assertEqual(data["result"].returncode, 0, data["result"].stderr)
                    self.assertIn(f"realm-{target}-unknown-linux-musl.tar.gz", data["urls"])
                    self.assertEqual(data["backup"], b"old binary")
                    self.assertTrue(data["service"])

    def test_failure_preserves_installation(self):
        for script in SCRIPTS:
            for failure in ("download", "archive", "missing", "binary"):
                with self.subTest(script=script, failure=failure):
                    data = self.run_installer(script, failure=failure)
                    self.assertNotEqual(data["result"].returncode, 0)
                    self.assertEqual(data["binary"], b"old binary")
                    self.assertFalse(data["service"])
                    self.assertEqual(data["commands"], "")

    def test_unsupported_architecture(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                data = self.run_installer(script, arch="riscv64")
                self.assertNotEqual(data["result"].returncode, 0)
                self.assertEqual(data["binary"], b"old binary")
                self.assertEqual(data["urls"], "")

    def test_version_lookup_failure_uses_known_musl_release(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                data = self.run_installer(script, latest="invalid")
                self.assertEqual(data["result"].returncode, 0)
                self.assertIn("/v2.9.6/realm-x86_64-unknown-linux-musl.tar.gz", data["urls"])

    def test_service_failure_is_reported(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                data = self.run_installer(script, failure="service", action="service_control start")
                self.assertNotEqual(data["result"].returncode, 0)
                self.assertNotIn("✔ 服务已启动", data["result"].stdout)

    def test_service_restart_resets_failure_limit(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                data = self.run_installer(script, action="service_control restart")
                self.assertEqual(data["result"].returncode, 0)
                self.assertLess(data["commands"].index("reset-failed"), data["commands"].index("restart"))

    def test_unloaded_unit_does_not_block_first_start(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                data = self.run_installer(script, failure="reset_not_loaded", action="service_control start")
                self.assertEqual(data["result"].returncode, 0, data["result"].stdout)
                self.assertIn("restart realm.service", data["commands"])
                self.assertIn("is-active --quiet realm.service", data["commands"])
                self.assertEqual(data["service_contents"], "[Service]\nExecStart=/configured/binary --custom\n")

    def test_missing_service_file_is_recreated_for_existing_installation(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                data = self.run_installer(script, action="service_control restart", service_missing=True)
                self.assertEqual(data["result"].returncode, 0, data["result"].stdout)
                self.assertTrue(data["service"])
                self.assertIn("ExecStart=", data["service_contents"])
                self.assertIn("/realm/realm -c ", data["service_contents"])
                self.assertIn("restart realm.service", data["commands"])


if __name__ == "__main__":
    unittest.main()
