<h1 align="left">
  <b>DDify</b><br>
  <a href="https://github.com/xujiegb/DDify/">
    <img width="36" height="36" alt="SIG" src="https://github.com/user-attachments/assets/04300161-ae57-4cab-babf-6bd2cbe2f074" />
  </a>
</h1>

<h1 align="center">
  <font color="#30A2E7">It's Your Reinstall Script</font>
</h1>

<p align="center">
  <a href="https://www.redhat.com/"><img width="50" height="50" alt="redhat-icon" src="https://github.com/user-attachments/assets/0b920778-14d8-4a3c-a390-a54961bb156e" /></a>&nbsp;&nbsp;
  <a href="https://fedoraproject.org/"><img width="50" height="50" alt="fedora-icon" src="https://github.com/user-attachments/assets/10c51358-fd27-4a7b-b987-d482f4108af9" /></a>&nbsp;&nbsp;
  <a href="https://www.debian.org/"><img width="44.4" height="51.2" alt="debian-icon" src="https://github.com/user-attachments/assets/637d8994-cadc-44dd-b7dd-14a98c9987e2" /></a>&nbsp;&nbsp;
  <a href="https://www.freebsd.org/"><img width="50" height="50" alt="freebsd-icon" src="https://github.com/user-attachments/assets/94e0244c-ed9f-41ad-9d95-f0a80af7de6b" /></a>
</p>

## Requirement / 系统要求

| Component / 组件 | Requirement / 要求 |
| --- | :---: |
| RAM / 内存 | 1 GB or above |
| Disk / 磁盘 | 10 GB or above |

---

## Quick Start / 快速开始

### Step 1 · Prepare / 安装依赖

<table>
<tr><td><b>Red Hat Enterprise Linux · Fedora Linux · Rocky Linux · AlmaLinux</b></td></tr>
</table>

```sh
sudo dnf install -y curl
```

<table>
<tr><td><b>Debian GNU/Linux</b></td></tr>
</table>

```sh
sudo apt install -y curl
```

<table>
<tr><td><b>FreeBSD</b></td></tr>
</table>

```sh
pkg install -y curl
```

### Step 2 · Download Script / 下载脚本

```sh
curl -fLO https://raw.githubusercontent.com/xujiegb/DDify/main/ddify.sh || \
  wget -O ddify.sh https://raw.githubusercontent.com/xujiegb/DDify/main/ddify.sh
```

### Step 3 · Start Reinstall / 开始重装

The pre-reboot terminal wizard uses the system `/bin/sh` (including dash, BusyBox ash and FreeBSD sh), with no Bash or external TUI framework required. It guides you through environment checks, disk and image selection, authentication, confirmation, and rescue boot preparation. Non-interactive input and CI use plain text; `NO_COLOR=1` disables colors.

重启前提供五阶段终端向导：环境检测、磁盘和镜像、身份认证、确认安装、重启准备。只需系统 `/bin/sh`，无需 Bash 或额外的 TUI 框架。管道和 CI 使用纯文本输出，可通过 `NO_COLOR=1` 关闭色彩。

Run without arguments for interactive setup, or prefill any settings with the existing command-line options. Each supplied value is shown as `[CLI - preset]` and its prompt is skipped. Only missing settings are requested on an interactive terminal. Passwords and SSH key material are hidden; credentials and query strings in displayed URLs are redacted. The final destructive confirmation is always required.

无参数启动可进入完整交互配置，也可以使用原有命令行参数预填任意项目。已提供的参数显示为 `[CLI - preset]`，并跳过相应输入；只询问未提供的设置。密码、公钥内容以及 URL 中的敏感信息不回显。最终擦盘确认始终保留。

```sh
sh ddify.sh
sh ddify.sh rocky 10 --disk /dev/vda --ssh-key /root/.ssh/id_ed25519.pub --ssh-port 2222
```

**Warning / 警告:** DDify always uses disk staging. After you confirm the target disk, it erases the old system before the entire image is downloaded and verified. Back up your data first.

DDify 默认且仅使用磁盘暂存。确认目标磁盘后，脚本会在完整镜像下载和校验前擦除原系统，请先备份数据。

```sh
sh ddify.sh rocky 10
sh ddify.sh almalinux 10
sh ddify.sh fedora 44
sh ddify.sh freebsd 14
sh ddify.sh freebsd 15
sh ddify.sh debian 13
sh ddify.sh redhat --img="https://access.cdn.redhat.com/xxx.qcow2"
```

---
