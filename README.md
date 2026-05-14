# Realm-Web

基于 `realm` 的一键安装与管理脚本，支持：

- Realm 一键安装 / 更新
- 转发规则添加、查看、删除
- 服务启动、停止、重启
- 定时任务管理
- Web 面板管理
- 面板安装、卸载、修改端口

适合想用命令行快速部署，同时又希望后续可以通过网页管理转发规则的场景。

---

## 命令界面预览

![命令界面](https://pic.sl.al/gdrive/pic/2026-05-14/fileid_1hQBf9oHDsc6EGCoyz3sBRWR7udQe0wjk_image.png)

## 面板界面预览

![面板界面](https://pic.sl.al/gdrive/pic/2026-05-14/fileid_1mVHAXv2-UfqcSDv9yvMShFfXHo0Kp2NE_image.png)

---

## 功能介绍

### 1. 命令行管理

脚本保留了原本的命令行管理方式，可直接进行：

- 安装 / 更新 Realm
- 添加转发规则
- 查看转发规则
- 删除转发规则
- 启动 / 停止 / 重启服务
- 查看日志
- 完全卸载

### 2. Web 面板管理

脚本新增了网页面板，可在菜单中进入 `11. 面板管理` 进行安装。

面板支持：

- 单条添加规则
- 批量导入规则
- 编辑规则
- 启用 / 暂停规则
- 删除规则
- 全部删除
- 备份导出 / 导入恢复
- 管理员账号修改
- 自定义背景图

默认面板端口：

```text
3060
```

---

## 安装方式

### 国外服务器

```bash
wget -N https://raw.githubusercontent.com/Assute/Realm-Web/main/realm.sh && chmod +x realm.sh && ./realm.sh
```

### 国内服务器

```bash
wget -N https://ghfast.top/https://raw.githubusercontent.com/Assute/Realm-Web/main/CN/realm.sh && chmod +x realm.sh && ./realm.sh
```

---

## 使用说明

首次运行：

```bash
./realm.sh
```

如果已经下载过脚本，后续再次运行：

```bash
/root/realm.sh
```

或在当前目录直接执行：

```bash
./realm.sh
```

---

## 面板安装说明

进入脚本菜单后：

```text
11. 面板管理
1. 安装 / 更新面板
```

安装完成后，浏览器访问：

```text
http://你的服务器IP:3060
```

如需修改端口，可在：

```text
11. 面板管理
3. 修改面板端口
```

---

## 仓库地址

```text
https://github.com/Assute/Realm-Web
```
