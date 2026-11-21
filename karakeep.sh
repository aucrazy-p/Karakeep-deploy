#!/usr/bin/env bash
# ============================================================
# Karakeep 管理菜单 (aucrazy-p/Karakeep-deploy)
# 上游项目: https://github.com/karakeep-app/karakeep
# Web 端口仅绑定 127.0.0.1, 公网访问由用户自行配置反代
# ============================================================

BASE_DIR="/opt/karakeep-deploy"
DATA_ROOT="/opt/karakeep"
DATA_DIR="$DATA_ROOT/data"          # web 容器 /data
MEILI_DIR="$DATA_ROOT/meili"        # meilisearch 容器 /meili_data
BACKUP_DIR="$BASE_DIR/backups"
ENV_FILE="$BASE_DIR/.env"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
IMAGE_WEB="ghcr.io/karakeep-app/karakeep:release"
IMAGE_CHROME="ghcr.io/karakeep-app/karakeep-chrome:release"
IMAGE_MEILI="getmeili/meilisearch:v1.55.0"
BIN="/usr/local/bin/kkp"

C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_C="\033[36m"; C_0="\033[0m"
info(){ echo -e "${C_G}[INFO]${C_0} $*"; }
warn(){ echo -e "${C_Y}[WARN]${C_0} $*"; }
err(){ echo -e "${C_R}[ERR ]${C_0} $*"; }

# ---- compose 命令封装 (运行时探测: 优先 v2 插件, 回退 v1) ----
dc(){
  if docker compose version >/dev/null 2>&1; then
    docker compose -p karakeep -f "$COMPOSE_FILE" "$@"
  else
    docker-compose -p karakeep -f "$COMPOSE_FILE" "$@"
  fi
}

get_val() {
  # get_val KEY [default] —— 从 .env 读取 key 的值
  local key="$1" def="${2:-}" v=""
  [ -f "$ENV_FILE" ] && v=$(grep "^${key}=" "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r')
  echo "${v:-$def}"
}

get_port()   { get_val HOST_PORT 3000; }
get_url()    { get_val NEXTAUTH_URL ""; }
gen_secret() { openssl rand -base64 36 | tr -dc 'A-Za-z0-9'; }

# ---- 确保 .env 存在且密钥齐全 ----
ensure_env() {
  mkdir -p "$BASE_DIR" "$DATA_DIR" "$MEILI_DIR" "$BACKUP_DIR"
  local first=0
  if [ ! -f "$ENV_FILE" ]; then
    first=1
    read -rp "请设置宿主机端口 [默认 3000]: " p
    p=${p:-3000}
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
      err "端口不合法: $p"; return 1
    fi
    if command -v ss >/dev/null 2>&1 && ss -tln | grep -q ":${p} "; then
      err "端口 $p 已被占用"; return 1
    fi
    read -rp "访问地址 NEXTAUTH_URL [默认 http://127.0.0.1:${p}]: " u
    u=${u:-"http://127.0.0.1:${p}"}
    {
      echo "HOST_PORT=$p"
      echo "NEXTAUTH_URL=$u"
      echo "MEILI_MASTER_KEY=$(gen_secret)"
      echo "NEXTAUTH_SECRET=$(gen_secret)"
    } > "$ENV_FILE"
    info "已生成配置 $ENV_FILE (端口 $p, 密钥已自动生成)"
  else
    info "已存在配置 $ENV_FILE, 执行更新..."
  fi
  # 补齐后续版本新增的密钥字段（不覆盖已有值）
  local changed=0 k v
  for k in MEILI_MASTER_KEY NEXTAUTH_SECRET; do
    v=$(get_val "$k" "")
    if [ -z "$v" ]; then
      echo "$k=$(gen_secret)" >> "$ENV_FILE"
      info "已补齐缺失密钥 $k"
      changed=1
    fi
  done
  [ "$changed" = 1 ] && info "配置已更新（已有密钥保持不变）"
  return 0
}

# ---- 动态生成 compose ----
gen_compose() {
  local port; port=$(get_port)
  local url;  url=$(get_url)
  {
    echo "services:"
    echo "  web:"
    echo "    image: $IMAGE_WEB"
    echo "    container_name: karakeep"
    echo "    restart: unless-stopped"
    echo "    volumes:"
    echo "      - ${DATA_DIR}:/data"
    echo "    ports:"
    echo "      - \"127.0.0.1:${port}:3000\""
    echo "    env_file:"
    echo "      - .env"
    echo "    environment:"
    echo "      MEILI_ADDR: http://meilisearch:7700"
    echo "      BROWSER_WEB_URL: http://chrome:9222"
    echo "      DATA_DIR: /data"
    echo "      NEXTAUTH_URL: ${url}"
    echo "    depends_on:"
    echo "      - chrome"
    echo "      - meilisearch"
    echo "    logging:"
    echo "      driver: json-file"
    echo "      options:"
    echo "        max-size: \"10m\""
    echo "        max-file: \"3\""
    echo "  chrome:"
    echo "    image: $IMAGE_CHROME"
    echo "    container_name: karakeep-chrome"
    echo "    restart: unless-stopped"
    echo "    init: true"
    echo "    command:"
    echo "      - --disable-gpu"
    echo "      - --disable-dev-shm-usage"
    echo "      - --hide-scrollbars"
    echo "      - --disable-blink-features=AutomationControlled"
    echo "      - --window-size=1440,900"
    echo "    logging:"
    echo "      driver: json-file"
    echo "      options:"
    echo "        max-size: \"10m\""
    echo "        max-file: \"3\""
    echo "  meilisearch:"
    echo "    image: $IMAGE_MEILI"
    echo "    container_name: karakeep-meilisearch"
    echo "    restart: unless-stopped"
    echo "    env_file:"
    echo "      - .env"
    echo "    environment:"
    echo "      MEILI_NO_ANALYTICS: \"true\""
    echo "    volumes:"
    echo "      - ${MEILI_DIR}:/meili_data"
    echo "    logging:"
    echo "      driver: json-file"
    echo "      options:"
    echo "        max-size: \"10m\""
    echo "        max-file: \"3\""
  } > "$COMPOSE_FILE"
  # 注意: 不生成 networks 段。web 端口只绑 127.0.0.1, 公网访问由用户自行配置。
}

probe() {
  local port; port=$(get_port)
  local code
  for _ in $(seq 1 10); do
    code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null)
    if [ -n "$code" ] && [ "$code" != "000" ]; then echo "$code"; return 0; fi
    sleep 1
  done
  echo "000"
}

container_status() {
  docker inspect -f '{{.State.Status}}' karakeep 2>/dev/null || echo "not-found"
}

# ---------- 安装完成后打印关键信息 ----------
print_key_info() {
  local port; port=$(get_port)
  local url;  url=$(get_url)
  echo ""
  echo -e "${C_C}================== 关键信息 ==================${C_0}"
  echo -e " 访问地址(本机) : ${C_G}http://127.0.0.1:${port}${C_0}"
  echo -e " NEXTAUTH_URL   : ${url}"
  echo -e " 首次部署       : 浏览器访问站点, 注册第一个账号即为管理员"
  echo -e " 公网访问       : 端口仅绑 127.0.0.1, 请自行配置反代后用菜单 8 修改访问地址"
  echo -e " Web 数据       : $DATA_DIR"
  echo -e " 搜索数据       : $MEILI_DIR"
  echo -e " 备份目录       : $BACKUP_DIR (菜单 9 备份, 保留最近 10 份)"
  echo -e " 管理命令       : ${C_G}kkp${C_0}  (等价: bash $BASE_DIR/karakeep.sh)"
  echo -e " 防火墙         : 无需放行 ${port}, 端口仅绑定 127.0.0.1"
  echo -e "${C_C}==============================================${C_0}"
}

# ---------- 1) 安装 / 更新 ----------
do_install() {
  ensure_env || return 1
  gen_compose
  info "拉取镜像 ..."
  local img
  for img in "$IMAGE_WEB" "$IMAGE_CHROME" "$IMAGE_MEILI"; do
    info "  $img"
    docker pull "$img" || { err "镜像拉取失败: $img, 请检查网络或配置镜像加速后重试"; return 1; }
  done
  dc up -d || { err "容器启动失败, 可用菜单 6 查看日志"; return 1; }
  local port code; port=$(get_port); code=$(probe)
  if [ "$code" != "000" ]; then
    info "服务已就绪 (HTTP $code)"
  else
    warn "容器已启动但本机探活未通过, 稍后可用菜单 2 查看"
  fi
  print_key_info
}

# ---------- 2) 状态 ----------
do_status() {
  local st; st=$(container_status)
  local port; port=$(get_port)
  echo -e "${C_C}---------------- 状态 ----------------${C_0}"
  if [ "$st" = "running" ]; then
    echo -e " Web 容器: ${C_G}运行中${C_0}"
  elif [ "$st" = "not-found" ]; then
    echo -e " Web 容器: ${C_R}未安装${C_0}"
  else
    echo -e " Web 容器: ${C_Y}$st${C_0}"
  fi
  echo " 端口: 127.0.0.1:${port} (仅本机)"
  echo " 访问地址: $(get_url)"
  [ -d "$DATA_DIR" ]  && echo " Web 数据: $(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)  $DATA_DIR"
  [ -d "$MEILI_DIR" ] && echo " 搜索数据: $(du -sh "$MEILI_DIR" 2>/dev/null | cut -f1)  $MEILI_DIR"
  if [ "$st" = "running" ]; then
    local code; code=$(probe)
    if [ "$code" != "000" ]; then
      echo -e " 探活: ${C_G}HTTP $code OK${C_0}"
    else
      echo -e " 探活: ${C_R}失败${C_0} (可用菜单 6 查日志)"
    fi
  fi
  echo -e "${C_C}--------------------------------------${C_0}"
}

# ---------- 7) 更改端口 ----------
do_change_port() {
  local old; old=$(get_port)
  read -rp "当前端口 $old, 输入新端口: " np
  if ! [[ "$np" =~ ^[0-9]+$ ]] || [ "$np" -lt 1 ] || [ "$np" -gt 65535 ]; then
    err "端口不合法"; return 1
  fi
  [ "$np" = "$old" ] && { warn "端口未变化"; return 0; }
  if command -v ss >/dev/null 2>&1 && ss -tln | grep -q ":${np} "; then
    err "端口 $np 已被占用"; return 1
  fi
  sed -i "s/^HOST_PORT=.*/HOST_PORT=$np/" "$ENV_FILE"
  # 若访问地址仍是旧的回环默认地址, 一并同步
  local url; url=$(get_url)
  if [ "$url" = "http://127.0.0.1:${old}" ]; then
    sed -i "s|^NEXTAUTH_URL=.*|NEXTAUTH_URL=http://127.0.0.1:${np}|" "$ENV_FILE"
    info "访问地址已同步为 http://127.0.0.1:${np}"
  fi
  gen_compose
  dc up -d && info "端口已切换为 $np (127.0.0.1)"
}

# ---------- 8) 修改访问地址 ----------
do_change_url() {
  local old; old=$(get_url)
  echo "当前访问地址: ${old:-未设置}"
  echo "提示: 配好公网访问后, 这里应填对外地址(如 https://your.domain), 影响登录会话与回调"
  read -rp "输入新访问地址 (直接回车取消): " u
  [ -z "$u" ] && { info "已取消"; return 0; }
  case "$u" in
    http://*|https://*) ;;
    *) err "地址必须以 http:// 或 https:// 开头"; return 1 ;;
  esac
  if grep -q '^NEXTAUTH_URL=' "$ENV_FILE"; then
    sed -i "s|^NEXTAUTH_URL=.*|NEXTAUTH_URL=$u|" "$ENV_FILE"
  else
    echo "NEXTAUTH_URL=$u" >> "$ENV_FILE"
  fi
  gen_compose
  dc up -d && info "访问地址已更新为 $u (容器已重建)"
}

# ---------- 12) 重新生成密钥 ----------
do_rekey() {
  warn "重新生成 NEXTAUTH_SECRET 会让所有用户会话失效, 需要重新登录。"
  warn "MEILI_MASTER_KEY 不会改动 (改动会导致搜索索引不可用)。"
  read -rp "输入 YES 确认: " c
  [ "$c" = "YES" ] || { info "已取消"; return 0; }
  local ts; ts=$(date +%Y%m%d%H%M%S)
  cp "$ENV_FILE" "${ENV_FILE}.bak-${ts}"
  sed -i "s|^NEXTAUTH_SECRET=.*|NEXTAUTH_SECRET=$(gen_secret)|" "$ENV_FILE"
  dc up -d && info "密钥已更新, 请重新登录 (旧配置备份: ${ENV_FILE}.bak-${ts})"
}

# ---------- 13) 关闭/开启注册 ----------
do_toggle_signups() {
  local arg="${1:-}"
  local cur; cur=$(get_val DISABLE_SIGNUPS "false")
  local state
  if [ "$cur" = "true" ]; then
    state="${C_R}已关闭${C_0}（禁止新注册，仅现有账号可登录）"
  else
    state="${C_G}开放中${C_0}（任何人可注册）"
  fi
  echo -e "${C_C}---------------- 注册开关 ----------------${C_0}"
  echo -e " 当前: ${state}"
  echo "   1) 关闭注册 (off) —— 仅自己使用时推荐"
  echo "   2) 开放注册 (on)"
  echo -e "${C_C}------------------------------------------${C_0}"

  local c="$arg"
  if [ -z "$c" ]; then
    read -rp "选择 [1/2，回车取消]: " c
    [ -z "$c" ] && { info "已取消"; return 0; }
  fi

  local val desc
  case "$c" in
    1|off|disable) val="true";  desc="注册已关闭" ;;
    2|on|enable)   val="false"; desc="注册已开放" ;;
    *) err "无效选择: $c (可用 1/off 关闭，2/on 开放)"; return 1 ;;
  esac

  [ "$cur" = "$val" ] && { warn "当前已是该状态，无需改动"; return 0; }

  # 关闭注册有把自己锁在外面的风险，交互模式下需二次确认
  if [ "$val" = "true" ] && [ -z "$arg" ]; then
    warn "关闭后新用户无法注册。请确认已注册好自己的管理员账号，否则将无法登录！"
    read -rp "输入 YES 确认关闭: " cf
    [ "$cf" = "YES" ] || { info "已取消"; return 0; }
  fi

  if grep -q '^DISABLE_SIGNUPS=' "$ENV_FILE"; then
    sed -i "s|^DISABLE_SIGNUPS=.*|DISABLE_SIGNUPS=$val|" "$ENV_FILE"
  else
    echo "DISABLE_SIGNUPS=$val" >> "$ENV_FILE"
  fi
  gen_compose
  if dc up -d --force-recreate web; then
    info "$desc (web 容器已重建；配置见 $ENV_FILE)"
  else
    err "web 容器重建失败，配置已写入但可能未生效，请查日志（菜单 6）"
    return 1
  fi
}

# ---------- 9) 备份数据 ----------
do_backup() {
  mkdir -p "$BACKUP_DIR"
  local stop=0 a
  read -rp "备份时暂停容器以保证数据一致? [Y/n]: " a
  case ${a:-Y} in [Yy]*) dc stop; stop=1 ;; esac
  local ts f
  ts=$(date +%Y%m%d-%H%M%S)
  f="$BACKUP_DIR/kkp-backup-$ts.tar.gz"
  # 两个数据目录打包为一份, 使用相对路径避免恢复时绝对路径问题
  if tar -czf "$f" -C "$DATA_ROOT" data meili 2>/dev/null; then
    info "备份完成: $f ($(du -sh "$f" | cut -f1))"
  else
    # data/meili 若某目录缺失, 逐目录兜底打包
    rm -f "$f"
    if tar -czf "$f" -C "$DATA_ROOT" $(ls -1 "$DATA_ROOT" 2>/dev/null); then
      warn "部分数据目录缺失, 已按现存目录打包: $f"
    else
      err "备份失败"
    fi
  fi
  [ "$stop" = 1 ] && dc up -d
  # 保留最近 10 份
  ls -1t "$BACKUP_DIR"/kkp-backup-*.tar.gz 2>/dev/null | tail -n +11 | while read -r old; do
    rm -f "$old"
  done
}

# ---------- 10) 恢复数据 ----------
do_restore() {
  local list
  list=$(ls -1t "$BACKUP_DIR"/kkp-backup-*.tar.gz 2>/dev/null) || { err "无可用备份"; return 1; }
  echo "可用备份(按时间倒序):"
  echo "$list" | nl -w2 -s') '
  read -rp "选择编号: " n
  local sel; sel=$(echo "$list" | sed -n "${n}p")
  [ -f "$sel" ] || { err "无效选择"; return 1; }
  warn "将用 $sel 覆盖当前两个数据目录 (data + meili)"
  read -rp "输入 YES 确认: " c
  [ "$c" = "YES" ] || { info "已取消"; return 0; }
  local ts; ts=$(date +%Y%m%d%H%M%S)
  dc stop
  # 现有目录各转 .bak-<ts>
  [ -d "$DATA_DIR" ]  && mv "$DATA_DIR"  "${DATA_DIR}.bak-${ts}"
  [ -d "$MEILI_DIR" ] && mv "$MEILI_DIR" "${MEILI_DIR}.bak-${ts}"
  mkdir -p "$DATA_ROOT"
  if tar -xzf "$sel" -C "$DATA_ROOT"; then
    dc up -d
    info "恢复完成, 原数据已另存为 *.bak-${ts}"
  else
    # 恢复失败必须回滚, 不能让容器以空数据目录启动
    [ -d "${DATA_DIR}.bak-${ts}" ]  && mv "${DATA_DIR}.bak-${ts}"  "$DATA_DIR"
    [ -d "${MEILI_DIR}.bak-${ts}" ] && mv "${MEILI_DIR}.bak-${ts}" "$MEILI_DIR"
    dc up -d
    err "恢复失败(备份包损坏或路径不符), 已回滚原数据"
    return 1
  fi
}

# ---------- 11) 卸载 ----------
do_uninstall() {
  warn "将停止并移除 karakeep 容器与 compose 项目"
  read -rp "输入 YES 确认: " c
  [ "$c" = "YES" ] || { info "已取消"; return 0; }
  dc down 2>/dev/null || true
  read -rp "删除镜像 (web/chrome/meilisearch 三个)? [y/N]: " a
  case ${a:-N} in
    [Yy]*)
      docker rmi "$IMAGE_WEB" "$IMAGE_CHROME" "$IMAGE_MEILI" 2>/dev/null || true
      info "镜像删除尝试完成"
      ;;
  esac
  read -rp "删除数据目录 $DATA_ROOT (含 data + meili)? [y/N]: " a
  case ${a:-N} in
    [Yy]*)
      read -rp "数据将不可恢复, 再输入 DELETE 二次确认: " c2
      [ "$c2" = "DELETE" ] && rm -rf "$DATA_ROOT" && info "数据已删除" || info "数据保留"
      ;;
    *) info "数据保留在 $DATA_ROOT" ;;
  esac
  read -rp "删除管理脚本 $BASE_DIR 与 $BIN? [y/N]: " a
  case ${a:-N} in
    [Yy]*) rm -rf "$BASE_DIR"; rm -f "$BIN"; info "已卸载管理脚本, 菜单退出"; exit 0 ;;
  esac
  info "卸载完成"
}

# ---------- 菜单 ----------
# 终端显示宽度：ASCII 算 1 列，中文/全角算 2 列
_str_width() {
  local s="$1" n=0 i ch o
  for (( i=0; i<${#s}; i++ )); do
    ch="${s:i:1}"
    printf -v o '%d' "'$ch" 2>/dev/null || o=0
    if [ "$o" -ge 32 ] && [ "$o" -le 126 ]; then
      n=$((n + 1))
    else
      n=$((n + 2))
    fi
  done
  echo "$n"
}

# 一行两项：编号(含右括号)左对齐固定 3 列，左描述固定 30 列，右列起点恒定
menu_line() {
  local lnum="$1" ldesc="$2" rnum="$3" rdesc="$4"
  local w pad
  w=$(_str_width "$ldesc")
  pad=$((30 - w))
  [ "$pad" -lt 1 ] && pad=1
  printf "  %-3s %s%*s  %-3s %s\n" "$lnum" "$ldesc" "$pad" "" "$rnum" "$rdesc"
}

show_menu() {
  clear
  local st port
  st=$(container_status); port=$(get_port)
  echo -e "${C_C}========== Karakeep 管理菜单 ==========${C_0}"
  if [ "$st" = "running" ]; then
    echo -e " 状态: ${C_G}运行中${C_0}   端口: 127.0.0.1:${port}"
  else
    echo -e " 状态: ${C_R}${st}${C_0}"
  fi
  echo -e "${C_C}=======================================${C_0}"
  menu_line "1)" "安装 / 更新"  "8)"  "修改访问地址(NEXTAUTH_URL)"
  menu_line "2)" "状态"         "9)"  "备份数据"
  menu_line "3)" "启动"         "10)" "恢复数据"
  menu_line "4)" "停止"         "11)" "卸载"
  menu_line "5)" "重启"         "12)" "重新生成密钥"
  menu_line "6)" "查看日志"     "13)" "注册开关(禁止新注册)"
  menu_line "7)" "更改端口"     "0)"  "退出"
  echo -e "${C_C}=======================================${C_0}"
}

case_main() {
  case "${1:-}" in
    1|install)  do_install ;;
    2|status)   do_status ;;
    3|start)    dc up -d && info "已启动" ;;
    4|stop)     dc stop && info "已停止" ;;
    5|restart)  dc restart && info "已重启" ;;
    6|logs)     dc logs -f --tail 200 ;;
    7)          do_change_port ;;
    8)          do_change_url ;;
    9|backup)   do_backup ;;
    10|restore) do_restore ;;
    11)         do_uninstall ;;
    12)         do_rekey ;;
    13|signups) do_toggle_signups "${2:-}" ;;
    0)          exit 0 ;;
    *) err "未知命令: ${1:-} (可用: install|status|start|stop|restart|logs|backup|restore|signups 或菜单编号 1-13)"; return 1 ;;
  esac
}

# ---- 以下顶层逻辑仅在直接执行时生效 (source 时跳过, 便于函数测试) ----
if [[ "${BASH_SOURCE[0]}" == "${0:-}" ]]; then

  # root 校验先于任何分发, 非交互子命令同样受保护
  if [ "$(id -u)" -ne 0 ]; then
    err "请用 root 运行 (sudo kkp)"
    exit 1
  fi

  # 支持非交互调用: karakeep.sh start / karakeep.sh status / karakeep.sh signups off ...
  # 透传全部参数, 使 signups 的第二个参数(off/on)可被 do_toggle_signups 读取
  if [ -n "${1:-}" ] && [ "${1:-}" != "menu" ]; then
    case_main "$@"
    exit $?
  fi

  while true; do
    show_menu
    read -rp "请选择: " c || exit 0
    case_main "$c"
    [ "$c" = "0" ] && break
    read -rp "回车返回菜单..." _ || exit 0
  done

fi
