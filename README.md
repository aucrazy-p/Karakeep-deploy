# Karakeep-deploy — Karakeep 一键部署与管理

为 [karakeep-app/karakeep](https://github.com/karakeep-app/karakeep)（稍后读 / 书签 / AI 自动打标）提供的 VPS 一键部署脚本与管理菜单。参考 `aucrazy-p/fcb-deploy` 的交互风格改造。

设计目标：

- **一键安装**：裸 Linux VPS 一条命令拉起，无需面板依赖
- **端口安全**：Web 服务只绑 `127.0.0.1`，浏览器与搜索引擎容器不对外暴露
- **菜单管理**：安装/更新/状态/启停/日志/改端口/改访问地址/注册开关/备份/恢复/重新生成密钥/卸载，全在一个菜单里
- **版本跟随 latest**：官方镜像 `ghcr.io/karakeep-app/karakeep:release`、`:karakeep-chrome:release`、`getmeili/meilisearch:v1.55.0`

## 一键安装

国际网络 / 有代理：

```bash
curl -fsSL https://raw.githubusercontent.com/aucrazy-p/Karakeep-deploy/main/install.sh | bash
```

国内 VPS（raw 直连不通时，走 jsDelivr CDN）：

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/aucrazy-p/Karakeep-deploy@main/install.sh | bash
```

- `install.sh` 内部下载 `karakeep.sh` 时自动多源回退（raw 超时 5 秒即切 jsDelivr），国内 VPS 用任一入口都能装完
- 未安装 docker 时会提示先手动安装：`curl -fsSL https://get.docker.com | sh`
- jsDelivr 有 CDN 缓存（最长约 12 小时），更新后如未生效可等缓存刷新或用 raw 入口

安装完成后运行 `kkp` 进入管理菜单（等价 `bash /opt/karakeep-deploy/karakeep.sh`），选 `1) 安装 / 更新`。首次安装会交互询问宿主机端口与访问地址，并自动生成 `MEILI_MASTER_KEY`、`NEXTAUTH_SECRET`。

## 管理菜单

```
========== Karakeep 管理菜单 ==========
 状态: 运行中   端口: 127.0.0.1:3456
=======================================
  1)  安装 / 更新                     8)  修改访问地址(NEXTAUTH_URL)
  2)  状态                            9)  备份数据
  3)  启动                            10) 恢复数据
  4)  停止                            11) 卸载
  5)  重启                            12) 重新生成密钥
  6)  查看日志                        13) 注册开关(禁止新注册)
  7)  更改端口                        0)  退出
=======================================
```

也支持非交互子命令：`kkp status` / `kkp start` / `kkp stop` / `kkp restart` / `kkp logs` / `kkp backup` / `kkp restore` / `kkp install` / `kkp signups`（后者是注册开关交互菜单，也支持 `kkp signups off` 直接关闭、`kkp signups on` 直接开启）。

### 菜单要点

- **8) 修改访问地址**：Karakeep 的 `NEXTAUTH_URL` 影响登录会话与回调。若对外访问地址与默认的 `http://127.0.0.1:<端口>` 不同，务必改这里。
- **12) 重新生成密钥**：重新生成 `NEXTAUTH_SECRET`，会让所有用户会话失效（需重新登录）；`MEILI_MASTER_KEY` 不动，否则搜索索引不可用。执行前需输入 `YES` 确认，旧 `.env` 自动备份。
- **13) 关闭/开启注册**：仅自己使用时，先注册好管理员账号，再选 1 关闭注册（写入 `DISABLE_SIGNUPS=true` 并重建 web 容器）。关闭后注册按钮消失，已有账号照常登录；选 2 可随时重新开放。仅允许现有用户登录，不影响登录与 API。

## 目录结构（VPS 上）

| 路径 | 用途 |
|---|---|
| `/opt/karakeep-deploy/karakeep.sh` | 管理菜单脚本（`/usr/local/bin/kkp` 软链） |
| `/opt/karakeep-deploy/.env` | 配置：`HOST_PORT`、`NEXTAUTH_URL`、`MEILI_MASTER_KEY`、`NEXTAUTH_SECRET`、`DISABLE_SIGNUPS`（注册开关，由菜单 13 写入） |
| `/opt/karakeep-deploy/docker-compose.yml` | 实际 compose（由 karakeep.sh 生成） |
| `/opt/karakeep-deploy/backups/` | 备份（保留最近 10 份） |
| `/opt/karakeep/data/` | Web 数据（挂载到容器 `/data`） |
| `/opt/karakeep/meili/` | 搜索引擎数据（挂载到容器 `/meili_data`） |

数据目录采用 bind mount（而非官方默认 named volume），便于打包备份、迁移和查看。

## 三个容器

| 服务 | 镜像 | 端口 | 说明 |
|---|---|---|---|
| web | `ghcr.io/karakeep-app/karakeep:release` | `127.0.0.1:<HOST_PORT>:3000` | 主程序，数据 `/data` |
| chrome | `ghcr.io/karakeep-app/karakeep-chrome:release` | 不暴露 | 网页抓取用的无头浏览器，仅内网 `chrome:9222` |
| meilisearch | `getmeili/meilisearch:v1.55.0` | 不暴露 | 全文搜索，数据 `/meili_data` |

## 备份与恢复（菜单 9 / 10）

- 备份把 `data` 与 `meili` 两个目录打包为**一份** tar.gz，默认暂停容器保证一致性，保留最近 10 份
- 恢复前现有两目录各自转为 `.bak-<时间戳>`，可回退；恢复失败会自动回滚，避免容器以空数据启动

## 卸载（菜单 11）

容器移除 → 可选删除镜像 / 数据目录（需二次输入 `DELETE` 确认）/ 管理脚本，均有确认保护。

## 公网访问

Web 端口只绑定 `127.0.0.1:<HOST_PORT>`，防火墙无需放行。对外访问方式由使用者自行配置；配置好后记得用菜单 8 把 `NEXTAUTH_URL` 改成实际对外地址。

## 数据迁移

新旧机器之间迁移：旧机用菜单 9 备份，把 `backups/kkp-backup-*.tar.gz` 传到新机 `backups/` 目录，新机装好脚本后用菜单 10 恢复。密钥（`.env`）建议一并迁移，避免搜索索引与登录态失效。

## 免责声明

本项目仅为部署辅助脚本，上游软件 Karakeep 按其自身许可证发布。请勿用于违法内容，部署者自行承担内容合规责任。
