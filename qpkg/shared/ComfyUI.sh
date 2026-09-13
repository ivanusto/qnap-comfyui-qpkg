#!/bin/sh
# ComfyUI QPKG service script.
#
# This deliberately avoids the system-docker-compose wrapper used by QNAP's own
# containerized-qpkg sample, which is broken here in two ways:
#   1. system-docker execs "docker-compose", the Compose v1 standalone binary
#      name. Container Station 3.x ships Compose as a CLI plugin, so that file
#      does not exist and only "docker compose" works.
#   2. It points DOCKER_HOST at /var/run/system-docker.sock, a second daemon.
#      User containers live on /var/run/docker.sock, so the two cannot see each
#      other.
# So call Container Station's own docker binary directly.

CONF=/etc/config/qpkg.conf
QPKG_NAME="ComfyUI"
QPKG_ROOT=$(/sbin/getcfg $QPKG_NAME Install_Path -f ${CONF})

# Container Station's install path varies by machine. Ask qpkg.conf first, then
# fall back to scanning /share. This runs again inside preflight, because at
# boot Container Station may not be mounted yet when this package starts.
resolve_docker() {
    QCS_DIR=$(/sbin/getcfg container-station Install_Path -f ${CONF})
    if [ -z "$QCS_DIR" ] || [ ! -x "$QCS_DIR/bin/docker" ]; then
        for d in /share/*/.qpkg/container-station; do
            [ -x "$d/bin/docker" ] && QCS_DIR="$d" && break
        done
    fi
    DOCKER="$QCS_DIR/bin/docker"
}
resolve_docker

# Rewritten to the real path by pkg_post_install.
STACK=__STACK_PATH__

COMPOSE_FILE="$STACK/docker-compose.yml"
LOG="$STACK/logs/qpkg.log"

export QNAP_QPKG=$QPKG_NAME
# The docker CLI wants to create a config directory under $HOME. The default
# HOME usually lands under container-station/homes/ and is not writable, which
# fails outright with permission denied.
export HOME="$STACK"
export DOCKER_CONFIG="$STACK/.docker"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

image_name() {
    REF=$(sed -n 's/^COMFY_REF=//p' "$STACK/.env" 2>/dev/null | head -1)
    [ -n "$REF" ] || REF=v0.34.3
    echo "comfyui-nas:$REF"
}

preflight() {
    [ -f "$COMPOSE_FILE" ] || { log "compose file not found: $COMPOSE_FILE"; return 1; }
    [ -f "$STACK/.env" ] || { log ".env missing, install may be incomplete: $STACK/.env"; return 1; }

    # The NVIDIA kernel modules can take minutes to load after a reboot (345
    # seconds on the reference machine) and dockerd comes up later still.
    # Container Station itself can also start after this package, in which case
    # its docker binary does not exist yet. Checking for it before the loop made
    # the service give up at boot and never retry. Wait up to 600 seconds for
    # all three; that is far more useful than failing immediately.
    RT=$(sed -n 's/^COMFY_GPU_RUNTIME=//p' "$STACK/.env" 2>/dev/null | head -1)
    [ -n "$RT" ] || RT=nvidia-runtime
    i=0
    while [ $i -lt 60 ]; do
        [ -x "$DOCKER" ] || resolve_docker
        if [ -x "$DOCKER" ] && [ -c /dev/nvidia0 ] && $DOCKER info 2>/dev/null | grep -q "$RT"; then
            [ $i -gt 0 ] && log "waited $((i * 10))s for Container Station, the GPU and docker to come up"
            return 0
        fi
        i=$((i + 1))
        sleep 10
    done
    if [ ! -x "$DOCKER" ]; then
        log "timeout: docker not found at $DOCKER, is Container Station running?"
        return 1
    fi
    [ -c /dev/nvidia0 ] || log "timeout: /dev/nvidia0 missing, is the NVIDIA GPU Driver package enabled?"
    $DOCKER info 2>/dev/null | grep -q "$RT" || log "timeout: docker has no runtime named '$RT'"
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
    preflight || { echo "preflight failed, see $LOG"; exit 1; }

    # The image is not shipped inside the QPKG. A docker save tarball of roughly
    # 9 GB would make the package unwieldy and would have to be unpacked and
    # loaded during install, which strains both the Container Station docker
    # volume and the install timeout. Build in place instead, which needs
    # internet access on first start.
    IMG=$(image_name)
    if ! $DOCKER image inspect "$IMG" >/dev/null 2>&1; then
        log "image $IMG not present, building (expect 15 to 30 minutes)"
        $DOCKER compose -f "$COMPOSE_FILE" build >> "$LOG" 2>&1 \
            || { log "build failed, see $LOG"; exit 1; }
        log "build complete"
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
    # Remove the container and the locally built image only. Never touch
    # output, user, models-local or custom_nodes under $STACK.
    log "remove: dropping container and image, keeping data"
    $DOCKER compose -f "$COMPOSE_FILE" down --rmi local >> "$LOG" 2>&1
    ;;

  *)
    echo "Usage: $0 {start|stop|restart|remove}"
    exit 1
esac

exit 0
