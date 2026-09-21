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
DEFAULT_REF=v0.37.0

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

env_get() { sed -n "s/^$1=//p" "$STACK/.env" 2>/dev/null | head -1; }
env_set() { sed -i "s/^$1=.*/$1=$2/" "$STACK/.env"; }

current_ref() {
    REF=$(env_get COMFY_REF)
    [ -n "$REF" ] || REF=$DEFAULT_REF
    echo "$REF"
}

image_name() { echo "comfyui-nas:${1:-$(current_ref)}"; }

preflight() {
    [ -f "$COMPOSE_FILE" ] || { log "compose file not found: $COMPOSE_FILE"; return 1; }
    [ -f "$STACK/.env" ] || { log ".env missing, install may be incomplete: $STACK/.env"; return 1; }

    # The NVIDIA kernel modules can take minutes to load after a reboot (345
    # seconds on the reference machine) and dockerd comes up later still.
    # Container Station itself can also start after this package, in which case
    # its docker binary does not exist yet. Checking for it before the loop made
    # the service give up at boot and never retry. Wait up to 600 seconds for
    # all three; that is far more useful than failing immediately.
    RT=$(env_get COMFY_GPU_RUNTIME)
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

do_start() {
    ENABLED=$(/sbin/getcfg $QPKG_NAME Enable -u -d FALSE -f $CONF)
    if [ "$ENABLED" != "TRUE" ]; then
        echo "$QPKG_NAME is disabled."
        return 1
    fi
    mkdir -p "$STACK/logs"
    preflight || { echo "preflight failed, see $LOG"; return 1; }

    # The image is not shipped inside the QPKG. A docker save tarball of roughly
    # 9 GB would make the package unwieldy and would have to be unpacked and
    # loaded during install, which strains both the Container Station docker
    # volume and the install timeout. Build in place instead, which needs
    # internet access on first start.
    IMG=$(image_name)
    if ! $DOCKER image inspect "$IMG" >/dev/null 2>&1; then
        log "image $IMG not present, building (expect 15 to 30 minutes)"
        $DOCKER compose -f "$COMPOSE_FILE" build >> "$LOG" 2>&1 \
            || { log "build failed, see $LOG"; return 1; }
        log "build complete"
    fi

    log "compose up"
    $DOCKER compose -f "$COMPOSE_FILE" up -d >> "$LOG" 2>&1
}

do_stop() {
    log "compose down"
    $DOCKER compose -f "$COMPOSE_FILE" down --remove-orphans >> "$LOG" 2>&1
}

# Ask ComfyUI itself, from inside the container. Curling the published port
# from the host is not reliable here: Container Station runs dockerd with
# --userland-proxy=false, and hairpin traffic to 127.0.0.1 depends on sysctls
# the NAS may not set.
wait_ready() {
    i=0
    while [ $i -lt 60 ]; do
        if $DOCKER exec comfyui python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8188/system_stats', timeout=5)" >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 5
    done
    return 1
}

# The bundled example nodes are shadowed by the custom_nodes bind mount, so
# copy them out of a fresh source tree.
copy_example_nodes() {
    for n in websocket_image_save.py example_node.py.example; do
        [ -f "$STACK/ComfyUI/custom_nodes/$n" ] && \
            cp "$STACK/ComfyUI/custom_nodes/$n" "$STACK/custom_nodes/$n"
    done
}

# Swap the source tree in $STACK/ComfyUI.prev-<to> back in, keep the current one
# as $STACK/ComfyUI.prev-<from>, point .env at <to> and start.
switch_to() {
    TO="$1"
    FROM=$(current_ref)
    [ -f "$STACK/ComfyUI.prev-$TO/main.py" ] || { log "no source tree at $STACK/ComfyUI.prev-$TO"; return 1; }
    [ -e "$STACK/ComfyUI.prev-$FROM" ] && { log "$STACK/ComfyUI.prev-$FROM already exists, move it away first"; return 1; }
    do_stop
    mv "$STACK/ComfyUI" "$STACK/ComfyUI.prev-$FROM" || return 1
    mv "$STACK/ComfyUI.prev-$TO" "$STACK/ComfyUI" || return 1
    env_set COMFY_REF "$TO"
    copy_example_nodes
    log "source switched from $FROM to $TO"
    do_start && wait_ready
}

do_upgrade() {
    NEW="$1"
    echo "$NEW" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || { echo "Usage: $0 upgrade vX.Y.Z"; return 1; }
    OLD=$(current_ref)
    [ "$NEW" = "$OLD" ] && { echo "Already on $NEW"; return 0; }
    mkdir -p "$STACK/logs"
    preflight || { echo "preflight failed, see $LOG"; return 1; }
    [ -e "$STACK/ComfyUI.prev-$OLD" ] && { log "upgrade: $STACK/ComfyUI.prev-$OLD already exists, move it away first"; return 1; }
    log "upgrade: $OLD -> $NEW"

    # Nothing below touches the running service until the new image exists.
    # A tree left behind by an earlier rollback is reused instead of downloaded.
    if [ ! -f "$STACK/ComfyUI.prev-$NEW/main.py" ]; then
        TARBALL="$STACK/ComfyUI-$NEW.tar.gz"
        log "upgrade: downloading source $NEW"
        rm -rf "$STACK/ComfyUI.prev-$NEW" "$TARBALL"
        if ! /sbin/curl -fsSL -o "$TARBALL" \
                "https://codeload.github.com/comfyanonymous/ComfyUI/tar.gz/refs/tags/$NEW" >> "$LOG" 2>&1; then
            rm -f "$TARBALL"
            log "upgrade: download of $NEW failed, nothing changed"
            return 1
        fi
        mkdir -p "$STACK/ComfyUI.prev-$NEW"
        tar -xzf "$TARBALL" --strip-components=1 -C "$STACK/ComfyUI.prev-$NEW" >> "$LOG" 2>&1
        rm -f "$TARBALL"
        if [ ! -f "$STACK/ComfyUI.prev-$NEW/main.py" ]; then
            rm -rf "$STACK/ComfyUI.prev-$NEW"
            log "upgrade: $NEW tarball has no main.py, nothing changed"
            return 1
        fi
    fi

    # Build while the old container keeps serving. The shell variable wins over
    # .env, so this builds and tags the new image without editing anything.
    if ! $DOCKER image inspect "$(image_name "$NEW")" >/dev/null 2>&1; then
        log "upgrade: building $(image_name "$NEW") while $OLD keeps serving (expect 15 to 30 minutes)"
        if ! COMFY_REF="$NEW" $DOCKER compose -f "$COMPOSE_FILE" build >> "$LOG" 2>&1; then
            log "upgrade: build of $NEW failed, still running $OLD. Source kept in $STACK/ComfyUI.prev-$NEW"
            return 1
        fi
    fi

    if switch_to "$NEW"; then
        log "upgrade: now running $NEW. $OLD is kept for rollback: $STACK/ComfyUI.prev-$OLD and image $(image_name "$OLD"). Remove both once you are happy."
        return 0
    fi

    log "upgrade: $NEW did not come up, rolling back to $OLD"
    if [ -f "$STACK/ComfyUI.prev-$OLD/main.py" ] && [ "$(current_ref)" = "$NEW" ]; then
        switch_to "$OLD" && log "upgrade: rolled back to $OLD" || log "upgrade: rollback to $OLD failed too, see above"
    fi
    return 1
}

do_rollback() {
    TO="$1"
    if [ -z "$TO" ]; then
        set -- "$STACK"/ComfyUI.prev-v*
        if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
            echo "Found $# candidate trees. Name one: $0 rollback vX.Y.Z"
            ls -d "$STACK"/ComfyUI.prev-v* 2>/dev/null
            return 1
        fi
        TO=${1##*/ComfyUI.prev-}
    fi
    if ! $DOCKER image inspect "$(image_name "$TO")" >/dev/null 2>&1; then
        log "rollback: image $(image_name "$TO") is gone, start will rebuild it"
    fi
    log "rollback: $(current_ref) -> $TO"
    switch_to "$TO"
}

case "$1" in
  start)
    do_start || exit 1
    ;;

  stop)
    do_stop
    ;;

  restart)
    do_stop
    do_start || exit 1
    ;;

  upgrade)
    do_upgrade "$2" || { echo "upgrade failed, see $LOG"; exit 1; }
    ;;

  rollback)
    do_rollback "$2" || { echo "rollback failed, see $LOG"; exit 1; }
    ;;

  remove)
    # Remove the container and the locally built image only. Never touch
    # output, user, models-local or custom_nodes under $STACK.
    log "remove: dropping container and image, keeping data"
    $DOCKER compose -f "$COMPOSE_FILE" down --rmi local >> "$LOG" 2>&1
    ;;

  *)
    echo "Usage: $0 {start|stop|restart|upgrade vX.Y.Z|rollback [vX.Y.Z]|remove}"
    exit 1
esac

exit 0
