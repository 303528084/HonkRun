# HonkRun

仿 `303528084/OpenWrtRun` 的思路，为 [daeuniverse/honk](https://github.com/daeuniverse/honk) 做的一套 GitHub Actions 自动化仓库：每天从 daeuniverse 官方 OpenWrt apk feed 同步最新 honk 组件，用 `makeself`（或内置自解压头）打成单个 `.run` 自解压安装包，发布到本仓库的 Release。

**这个仓库不含任何 honk 源码，也不重新编译 honk** —— 它只是搬运并重新封装官方已经编译签名的 `.apk`，附带一个在路由器上执行的安装脚本。

```
官方 apk feed  →  Actions 定时抓取  →  版本指纹比对  →  makeself 打包  →  Release
```

## 为什么需要它

OpenWrtRun 打的是 24.10 及更早的 `ipk` 包；honk 只支持 **OpenWrt / ImmortalWrt 25.12**（`apk` 体系，内核 6.12+ / BTF），包格式和依赖处理都不同，所以不能直接套用。本项目按 25.12 的 apk 规则重新实现。

## 目录结构

```
HonkRun/
├── .github/workflows/build-honk.yml   主工作流：定时 / 手动 / 推送触发
├── scripts/
│   ├── build-run.sh                   核心：解析 feed 索引 → 下载 apk → 打 .run → 生成指纹与清单
│   ├── install.sh                     打进 .run 内、在路由器上执行的安装脚本
│   ├── run-header.sh                  内置自解压头（makeself 缺失时回退）
│   └── verify-run.sh                  冒烟测试：解压 .run 并校验内容
└── README.md
```

## 部署到自己的 GitHub

1. 新建一个空仓库（例如 `你的用户名/HonkRun`），把本目录全部文件推到 `main` 分支。
2. 在仓库 **Settings → Actions → General → Workflow permissions** 选择 **Read and write permissions**（工作流里的 `permissions: contents: write` 通常已足够，但关掉组织级只读限制更稳妥）。
3. 打开 **Actions → Build honk .run packages → Run workflow**，手动跑一次，确认 Release 生成。
4. 之后每天 UTC 03:23（北京时间 11:23）自动检查一次；上游 apk 没有变化就跳过发布，不产生垃圾 Release。

`workflow_dispatch` 可填：

| 输入 | 说明 |
| --- | --- |
| `force` | 上游没变也强制重建发布 |
| `arches` | 只构建指定架构，空格分隔，如 `x86_64 aarch64_generic`；`all` 为全部 5 个 |

发布策略：

- 滚动 **`latest`** tag —— 下载链接固定，始终指向最新构建（`overwrite_files` 覆盖）。
- 版本快照 tag —— 如 `honk-0.1.0_beta6-r1-20261109`，不会被覆盖；工作流会**只保留最近 5 个**快照，更旧的快照 Release 连同 tag 自动删除（`latest` 永不清理）。要调整数量，改工作流里的 `KEEP_SNAPSHOTS`。这样避免 Release 资产无限累积。

## 产物

命名沿用 OpenWrtRun 的 `25-` 约定（`25_` 开头表示 25.12 系统）：

```
25_honk_<honk版本>_<架构>.run
```

支持 5 个架构：`x86_64`、`aarch64_generic`、`aarch64_cortex-a53`、`aarch64_cortex-a72`、`aarch64_cortex-a76`。

每个 `.run` 内含：`honk-*.apk`、`luci-app-honk-*.apk`、`luci-lib-daeuniverse-*.apk`、中文与繁中语言包，以及 `install.sh` / `build-info.sh`。**故意不打包** `dae-*.apk`、`luci-app-dae-*.apk`（与 honk 冲突）和 `vmlinux-btf-builtin-*.apk`（空包，BTF 与内核/目标绑定）。

Release 同时附带 `SHA256SUMS`、`manifest.txt`（包清单）、`fingerprint.txt`（去重指纹）、自动生成的说明。

## 在路由器上使用

先确认架构：

```sh
. /etc/openwrt_release && echo "$DISTRIB_RELEASE $DISTRIB_ARCH $DISTRIB_TARGET"
```

下载并安装（默认在线模式）：

```sh
wget -O honk.run https://github.com/<你的用户名>/HonkRun/releases/download/latest/25_honk_<版本>_<架构>.run
sha256sum -c SHA256SUMS
sh honk.run
```

安装脚本参数：

| 参数 | 作用 |
| --- | --- |
| 无参数 | 在线模式：导入签名公钥、写入 daeuniverse feed、`apk update`、`apk add honk@daeuniverse ...`（推荐） |
| `--offline` | 离线模式：只装包内 apk，不联网 |
| `--no-luci` | 不装 LuCI 界面与语言包 |
| `--enable` | 装完立即 enable + start（**默认不启动**） |
| `--help` | 查看帮助 |
| `--target DIR --noexec` | 只解压到 DIR，不执行安装 |

给安装脚本传参时用 `--` 分隔：`sh honk.run -- --offline --no-luci`。也支持环境变量 `HONK_OFFLINE=1 sh honk.run`。

只查看内容：

```sh
sh honk.run --target /tmp/honk --noexec
```

## 几个刻意的设计

- **默认走在线模式，而不是直接 `apk add ./*.apk`**：从本地文件安装的 apk 会把 world 约束固定到该文件，之后任何 `apk add` 都可能报 `breaks: world[honk>...]`。在线模式用 `@daeuniverse` 仓库标签安装，后续可直接 `apk upgrade`。离线模式装完会提示如何解除 pin。
- **默认不自动启动服务**：honk 首次部署会改动网络 hook、命名空间和 sysctl，官方明确要求保留带外管理通道。装完只提示检查 `/etc/honk/config.dae`（默认 LAN 接口 `br-lan`），用户确认后再手动启用。
- **检测到 dae 正在运行就直接中止**：dae 与 honk 不能同时接管 eBPF 数据面。
- **官方 OpenWrt 无内建 BTF**：脚本检查 `/sys/kernel/btf/vmlinux`，缺失时自动追加 kmods 仓库行并尝试装 `vmlinux-btf`。
- **指纹去重**：`fingerprint.txt` 是所有架构 apk 的「相对路径 + 字节数」排序后的 sha256，工作流与上次 `latest` Release 比对，相同则跳过发布。
- **双重打包兜底**：优先用 `makeself`；未安装、或 makeself 执行失败时，`build-run.sh` 自动回退到内置自解压头，生成同样兼容 `--target` / `--noexec` 的 `.run`。两种产物用法完全一致，CI 不存在单点故障。

## 前置条件与限制

- 只支持 **OpenWrt / ImmortalWrt 25.12**，内核 6.12+，且具备 BTF；24.10 / 23.05 / opkg 系统不支持。
- 只提供 64 位 ARM 与 x86_64，不支持 32 位 ARM / MIPS。
- 架构必须和 `DISTRIB_ARCH` 严格一致，装错会失败。
- 离线模式可能缺少 `v2ray-geoip` / `v2ray-geosite` / `vmlinux-btf` 等依赖，建议只在应急时用。
- honk 自身处于 **Early alpha**（官方明确写着不建议用于生产），本仓库不会改变这一点。
- 官方 feed 是首选安装方式（能自动升级）；`.run` 更适合单文件分发、离线应急或批量部署。

详细系统要求见 <https://daeuniverse.org/openwrt/>。

## 本地验证

无需 GitHub 也能完整跑一遍（需要 bash、curl、tar、sha256sum；没有 makeself 会自动走内置自解压）：

```sh
bash scripts/build-run.sh --arch x86_64
bash scripts/verify-run.sh
ls -lh dist/honk-run/run/
```

只想验证抓取与版本解析、不下载打包：

```sh
bash scripts/build-run.sh --all --no-package
```

覆盖 feed 地址或产物目录：

```sh
FEED_BASE=https://example.org/25.12/packages OUT_DIR=/tmp/out bash scripts/build-run.sh --all
```

## 说明

本项目只做官方公开发布包的自动化抓取与封装，**不包含任何代理节点、订阅地址或网络访问配置**，也未修改 honk 二进制。honk 是 Linux 透明代理引擎，实际部署与使用请遵守所在地区的法律法规及网络管理规定，并自行评估在生产环境使用 alpha 阶段软件的风险。

honk 遵循 `GPL-3.0-only`；本仓库的构建脚本可自由使用与修改。第三方组件的来源、许可证、未修改声明与商标归属详见 [NOTICE.md](NOTICE.md)。
