#!/bin/sh
# ComfyUI QPKG service script.
#
# 這裡刻意不用官方 containerized-qpkg 範例的 system-docker-compose，實測它壞在兩處：
#   1. system-docker 是個 wrapper，basename 為 system-docker-compose 時會 exec
#      "docker-compose"（Compose v1 的獨立二進位名），而 Container Station 3.x 的
#      compose 是 CLI plugin，只能用 "docker compose" 子命令，沒有那個檔。
#   2. 它會把 DOCKER_HOST 指到 /var/run/system-docker.sock，那是另一個 daemon。
#      使用者的容器全在 /var/run/docker.sock 上，走錯 daemon 會看不到彼此。
# 所以直接用 Container Station 自己的 docker 二進位，不經 wrapper。

CONF=/etc/config/qpkg.conf
QPKG_NAME="ComfyUI"
QPKG_ROOT=$(/sbin/getcfg $QPKG_NAME Install_Path -f ${CONF})

# Container Station 的安裝路徑因機器而異，先問 qpkg.conf，問不到再掃 /share。
QCS_DIR=$(/sbin/getcfg container-station Install_Path -f ${CONF})
if [ -z "$QCS_DIR" ] || [ ! -d "$QCS_DIR" ]; then
    for d in /share/*/.qpkg/container-station; do
        [ -x "$d/bin/docker" ] && QCS_DIR="$d" && break
    done
fi
DOCKER="$QCS_DIR/bin/docker"

# 由 package_routines 的 pkg_post_install 改寫成實際路徑。
STACK=__STACK_PATH__

COMPOSE_FILE="$STACK/docker-compose.yml"
LOG="$STACK/logs/qpkg.log"

export QNAP_QPKG=$QPKG_NAME
# docker CLI 會想在 $HOME 底下建設定目錄。預設的 HOME 通常落在
# container-station/homes/ 之下且不可寫，會直接以 permission denied 收場。
export HOME="$STACK"
export DOCKER_CONFIG="$STACK/.docker"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

image_name() {
    REF=$(sed -n 's/^COMFY_REF=//p' "$STACK/.env" 2>/dev/null | head -1)
    [ -n "$REF" ] || REF=v0.34.3
    echo "comfyui-nas:$REF"
}

preflight() {
    [ -x "$DOCKER" ] || { log "找不到 docker：$DOCKER"; return 1; }
    [ -f "$COMPOSE_FILE" ] || { log "找不到 compose 檔：$COMPOSE_FILE"; return 1; }
    [ -f "$STACK/.env" ] || { log "找不到 .env，安裝可能未完成：$STACK/.env"; return 1; }

    # 開機後 NVIDIA 核心模組要好幾分鐘才載入（實測某機種是第 345 秒），
    # dockerd 也要時間。這裡最多等 600 秒，比直接失敗有用得多。
    RT=$(sed -n 's/^COMFY_GPU_RUNTIME=//p' "$STACK/.env" 2>/dev/null | head -1)
    [ -n "$RT" ] || RT=nvidia-runtime
    i=0
    while [ $i -lt 60 ]; do
        if [ -c /dev/nvidia0 ] && $DOCKER info 2>/dev/null | grep -q "$RT"; then
            [ $i -gt 0 ] && log "等待 GPU 與 docker 就緒花了 $((i * 10)) 秒"
            return 0
        fi
        i=$((i + 1))
        sleep 10
    done
    [ -c /dev/nvidia0 ] || log "逾時：/dev/nvidia0 不存在，NVIDIA GPU Driver 可能未啟用"
    $DOCKER info 2>/dev/null | grep -q "$RT" || log "逾時：docker 未註冊 runtime「$RT」"
    return 1
}

case "$1" in
  start)
    ENABLED=$(/sbin/getcfg $QPKG_NAME Enable -u -d FALSE -f $CONF)
    if [ "$ENABLED" != "TRUE" ]; then
        echo "$QPKG_NAME is disabled."
        exit 1
    fi
    mkdir -p "$STACK/logs"
    preflight || { echo "preflight 失敗，詳見 $LOG"; exit 1; }

    # 映像不隨 QPKG 打包：約 9 GB 的 docker save tar 會讓套件過大，安裝時還要
    # 解壓再 load，對 Container Station 的 docker volume 空間與安裝逾時都是壓力。
    # 改為首次啟動時就地建置，需要能連外網下載 pip 套件。
    IMG=$(image_name)
    if ! $DOCKER image inspect "$IMG" >/dev/null 2>&1; then
        log "映像 $IMG 不存在，開始建置（預估 15 至 30 分鐘）"
        $DOCKER compose -f "$COMPOSE_FILE" build >> "$LOG" 2>&1 \
            || { log "建置失敗，詳見 $LOG"; exit 1; }
        log "建置完成"
    fi

    log "compose up"
    $DOCKER compose -f "$COMPOSE_FILE" up -d >> "$LOG" 2>&1 || exit 1
    ;;

  stop)
    log "compose down"
    $DOCKER compose -f "$COMPOSE_FILE" down --remove-orphans >> "$LOG" 2>&1
    ;;

  restart)
    $0 stop
    $0 start
    ;;

  remove)
    # 只移除容器與本地建置的映像，絕不碰 $STACK 底下的
    # output、user、models-local、custom_nodes。
    log "remove：清掉容器與映像，保留資料"
    $DOCKER compose -f "$COMPOSE_FILE" down --rmi local >> "$LOG" 2>&1
    ;;

  *)
    echo "Usage: $0 {start|stop|restart|remove}"
    exit 1
esac

exit 0
