# EZrealm（Debian 12 兼容修复版）

本仓库 fork 自 [qqrrooty/EZrealm](https://github.com/qqrrooty/EZrealm)，更早来源为 [Jaydooooooo/Port-forwarding](https://github.com/Jaydooooooo/Port-forwarding)。

## GLIBC 兼容修复（v1.1.2）

原安装器下载 `realm-x86_64-unknown-linux-gnu.tar.gz`。部分上游 GNU 构建要求 GLIBC 2.38，在 Debian 12 等系统会报 `GLIBC_2.38 not found`。

本版本的 `realm.sh`、`CN/realm.sh` 和 `test/realm.sh` 改为下载官方 **musl 静态构建**，不依赖宿主 GLIBC，无需升级系统 libc。自动识别 x86_64 和 aarch64/ARM64；其他架构会明确报错。

- 下载到临时目录，解压后运行 `realm --version` 验证，再替换程序。
- 下载、解压或程序验证失败时保留现有安装；已有 `config.toml` 不会被覆盖。
- 替换前将旧程序备份为 `/root/realm/realm.bak`（下一次成功安装会更新此备份）。
- 获取最新版本失败时使用已确认提供 musl 包的 v2.9.6。
- 启动/重启前清除 systemd 失败次数限制；命令失败时不再显示启动成功。
- 移除当前安装器对 `sudo` 的依赖，仍须使用 root 运行。
- 自动更新指向本 fork；国内脚本保持使用国内下载入口。

## 安装或修复现有安装

以 **root** 执行。先确保安装了 `curl`、`tar` 和 CA 证书：

```bash
apt-get update && apt-get install -y curl tar ca-certificates
```

可直连 GitHub 的机器：

```bash
curl -fL https://raw.githubusercontent.com/misakaok/EZrealm/main/realm.sh -o realm.sh && bash realm.sh
```

需要下载代理的机器：

```bash
curl -fL https://ghfast.top/https://raw.githubusercontent.com/misakaok/EZrealm/main/CN/realm.sh -o realm.sh && bash realm.sh
```

进入菜单后：

1. 选择 **1：安装/更新 Realm**，将不兼容程序替换成 musl 构建。
2. 新安装先选择 **2：添加转发规则**；已有规则无需重复添加。
3. 选择 **7：重启服务**（或 **5：启动服务**）。

检查实际状态和错误日志：

```bash
systemctl status realm.service --no-pager -l
journalctl -u realm.service -b -n 60 --no-pager
```

之后运行 `bash realm.sh` 即可再次进入管理菜单。下载源始终使用 musl 构建，但实际启动仍取决于转发配置、监听端口和系统网络设置。`realm-2024.sh`、`realm-2025.sh`、`CN/old-realm.sh` 和 `test/prevision.sh` 是保留的历史脚本，本次修复不适用于这些旧入口，请使用上面的安装命令。

## 开发验证

```bash
bash -n realm.sh
bash -n CN/realm.sh
bash -n test/realm.sh
python3 -m unittest discover -s tests -v
```

回归测试在临时目录中模拟下载和 systemd，覆盖两种架构、下载/解压/执行失败、版本检测回退、配置保留以及服务启动失败。不会改动开发机器的 `/root` 或真实服务；它们不能替代 Linux 主机上的实际运行验证。
