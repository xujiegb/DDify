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
| RAM / 内存 | 768 MB or above |
| Disk / 磁盘 | 10 GB or above |

---

## Quick Start / 快速开始

### Step 1 · Prepare / 安装依赖

<table>
<tr><td><b>Red Hat Enterprise Linux · Fedora Linux · Rocky Linux · AlmaLinux</b></td></tr>
</table>

```bash
sudo dnf install curl bash
```

<table>
<tr><td><b>Debian GNU/Linux</b></td></tr>
</table>

```bash
sudo apt install curl bash
```

<table>
<tr><td><b>FreeBSD</b></td></tr>
</table>

```bash
pkg install curl bash
```

### Step 2 · Download Script / 下载脚本

```bash
curl -O https://raw.githubusercontent.com/xujiegb/DDify/main/ddify.sh || wget -O ${_##*/} $_
```

### Step 3 · Start Reinstall / 开始重装

```bash
bash ddify.sh rocky     10
              almalinux 10
              fedora    43
              freebsd   14 | 15
              debian    13
              redhat    --img="http://access.cdn.redhat.com/xxx.qcow2"
```

---
