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


DEFAULT_CONFIG = b'[network]\nuse_udp = true\n# existing forwarding rules\n'
TWO_RULES = (b'[network]\nuse_udp = true\n\n'
             b'[[endpoints]]\n# \xe5\xa4\x87\xe6\xb3\xa8: first \nlisten = "[::]:8080"\nremote = "1.1.1.1:80"\n\n'
             b'[[endpoints]]\n# \xe5\xa4\x87\xe6\xb3\xa8: second \nlisten = "0.0.0.0:9090"\nremote = "2.2.2.2:90"\n')


class InstallerTests(unittest.TestCase):
    def run_installer(self, script, *, arch="x86_64", failure="", latest="2.9.6", action="deploy_realm",
                      service_missing=False, config=DEFAULT_CONFIG, config_changes=False, stdin="",
                      crontab=None, argv0="test"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bindir = root / "bin"
            bindir.mkdir()
            realm = root / "realm"
            realm.mkdir()
            (realm / "realm").write_text("old binary")
            (realm / "realm").chmod(0o755)
            (realm / "config.toml").write_bytes(config)
            if not action.startswith("deploy_realm") and not service_missing:
                (root / "realm.service").write_text("[Service]\nExecStart=/configured/binary --custom\n")
            if crontab is not None:
                (root / "crontab").write_text(crontab)
            (root / "update.sh").write_text('#!/bin/bash\n# CURRENT_VERSION="9.9.9"\necho "restarted $*"\n')
            commands = {
                "uname": '#!/bin/sh\nprintf "%s\\n" "$TEST_ARCH"\n',
                "systemctl": '''#!/bin/sh
echo "$*" >> "$TEST_ROOT/systemctl.log"
if [ "$TEST_FAILURE" = reset_not_loaded ] && [ "$1" = reset-failed ]; then
    echo "Failed to reset failed state of unit realm.service: Unit realm.service not loaded." >&2
    exit 1
fi
if [ "$TEST_FAILURE" = bad_port ]; then
    # 模拟 Realm 无法使用 9999 端口：带该端口的配置启动失败
    case "$1" in
        restart)
            if grep -q ':9999"' "$TEST_ROOT/realm/config.toml"; then
                touch "$TEST_ROOT/failed"
                exit 1
            fi
            rm -f "$TEST_ROOT/failed"
            ;;
        is-active) [ ! -e "$TEST_ROOT/failed" ] ;;
    esac
    exit $?
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
source="$TEST_ROOT/archive.tar.gz"
[[ "$*" == *realm.sh* ]] && source="$TEST_ROOT/update.sh"
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then
        cp "$source" "$2"
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
                'SERVICE_FILE="$2/realm.service"; LOG_FILE="$2/manager.log"; CRON_FILE="$2/crontab"; '
                + action,
                argv0, str(ROOT / script), str(root),
            ], env=env, capture_output=True, text=True, input=stdin, cwd=root, timeout=30)
            if not config_changes:
                self.assertEqual((realm / "config.toml").read_bytes(), config)
            self.assertFalse(list(realm.glob(".install.*")))
            leftovers = [p.name for p in realm.glob("config.toml.*") if p.name != "config.toml.bak"]
            self.assertEqual(leftovers, [], "temporary config files left behind")
            return {
                "config": (realm / "config.toml").read_text(),
                "crontab": (root / "crontab").read_text() if (root / "crontab").exists() else None,
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

    def test_add_rule_writes_rule_and_restarts(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                data = self.run_installer(script, action="add_rule", config_changes=True,
                                          stdin="8080\n1.2.3.4\n80\nweb\n1\nn\n")
                self.assertIn('listen = "[::]:8080"\nremote = "1.2.3.4:80"', data["config"])
                self.assertIn("✔ 添加成功", data["result"].stdout)
                self.assertIn("restart realm.service", data["commands"])

    def test_add_rule_brackets_ipv6_target(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                data = self.run_installer(script, action="add_rule", config_changes=True,
                                          stdin="9000\n2001:db8::1\n443\n\n2\nn\n")
                self.assertIn('listen = "0.0.0.0:9000"\nremote = "[2001:db8::1]:443"', data["config"])

    def test_add_rule_rejects_invalid_and_duplicate_ports(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                # 已占用端口（不同监听地址）、超范围端口、空目标地址、带端口的目标地址都应被拒绝
                data = self.run_installer(script, action="add_rule", config=TWO_RULES, stdin=(
                    "9090\n3.3.3.3\n80\ndup\n1\n"
                    "70000\n3.3.3.3\n80\nrange\n"
                    "7000\n\n80\nempty\n"
                    "7000\n3.3.3.3:80\n80\nwith-port\n"))
                self.assertIn("已被现有规则使用", data["result"].stdout)
                self.assertIn("1-65535", data["result"].stdout)
                self.assertEqual(data["result"].stdout.count("目标地址无效"), 2)
                self.assertEqual(data["commands"], "")

    def test_add_rule_rolls_back_config_that_breaks_running_service(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                data = self.run_installer(script, action="add_rule", config=TWO_RULES, failure="bad_port",
                                          stdin="9999\n3.3.3.3\n80\nbad\n2\nn\n")
                self.assertEqual(data["config"].encode(), TWO_RULES)
                self.assertIn("已恢复修改前的配置", data["result"].stdout)
                self.assertNotIn("✔ 添加成功", data["result"].stdout)
                self.assertTrue(data["commands"].endswith("restart realm.service\n"))

    def test_delete_rule_removes_selected_rule(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                data = self.run_installer(script, action="delete_rule", config=TWO_RULES, config_changes=True,
                                          stdin="1\n")
                self.assertNotIn("8080", data["config"])
                self.assertIn('listen = "0.0.0.0:9090"\nremote = "2.2.2.2:90"', data["config"])
                self.assertIn("restart realm.service", data["commands"])

    def test_cron_only_touches_own_jobs(self):
        other = "0 4 * * * root /usr/local/bin/backup-realm-data\n"
        legacy = "0 5 * * * root /usr/bin/systemctl restart realm\n"
        for script in SCRIPTS:
            with self.subTest(script=script):
                data = self.run_installer(script, action="manage_cron; manage_cron", stdin="1\n3\n1\n03\n",
                                          crontab=other + legacy)
                self.assertEqual(data["crontab"].count("restart realm # ezrealm"), 1)
                self.assertIn("已存在", data["result"].stdout)
                data = self.run_installer(script, action="manage_cron", stdin="2\n",
                                          crontab=other + legacy + "0 3 * * * root /usr/bin/systemctl restart realm # ezrealm\n")
                self.assertEqual(data["crontab"], other)

    def test_self_update_restarts_when_started_as_bash_script(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                # README 推荐的 "bash realm.sh" 启动方式下 $0 不含路径
                data = self.run_installer(script, action="perform_update", argv0="realm.sh")
                self.assertEqual(data["result"].returncode, 0, data["result"].stderr)
                self.assertIn("restarted --no-update", data["result"].stdout)


if __name__ == "__main__":
    unittest.main()
