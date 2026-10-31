# DebianInit

Debian 13 (Trixie) 系统初始化脚本，带交互菜单，需以 root 运行。

## 运行

```bash
wget https://raw.githubusercontent.com/Fr33raNg3r/DebianInit/main/debian13_setup.sh && sudo bash debian13_setup.sh
```

> 脚本使用交互菜单，请先下载再执行，不要使用 `wget -qO- ... | bash`（管道会占用标准输入，菜单读不到输入）。

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
| `debian13_setup.txt` | 生成器：在 Debian 上执行 `bash debian13_setup.txt` 会在当前目录生成 `debian13_setup.sh` |
