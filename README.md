# DebianInit

Debian 13 (Trixie) 系统初始化脚本，带交互菜单，需以 root 运行。

## 运行

```bash
wget -qO debian13_setup.sh --timeout=10 -t 1 https://gh-proxy.com/https://raw.githubusercontent.com/Fr33raNg3r/DebianInit/main/debian13_setup.sh || wget -qO debian13_setup.sh --timeout=10 -t 1 https://raw.githubusercontent.com/Fr33raNg3r/DebianInit/main/debian13_setup.sh; bash debian13_setup.sh
```

- 需以 root 运行，不使用 sudo。第一条 wget 走 gh-proxy 加速，失败自动回退 GitHub 直连。
- 脚本内置自更新：之后直接运行 `bash debian13_setup.sh`，启动时会比对远程 `SCRIPT_VERSION`，版本不同才下载并覆盖自身，一致则不下载；网络不通时继续使用本地版本。
- 脚本使用交互菜单，请先下载再执行，不要使用 `wget -qO- ... | bash`（管道会占用标准输入，菜单读不到输入）。

> **维护约定**：每次修改脚本都必须同步递增 `SCRIPT_VERSION`，否则用户不会拿到新版。

## 基本功能

- 软件源配置与系统更新
- 内核安装与旧内核清理（Zabbly / XanMod）
- 网络配置（静态 IP）与主机名设置
- SSH 配置（密钥登录、密码登录等）
- 系统优化与调优
- 重装系统

具体选项以脚本内菜单为准。

## 文件说明

| 文件 | 说明 |
| --- | --- |
| `debian13_setup.sh` | 初始化脚本本体，直接运行 |
