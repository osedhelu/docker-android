#!/usr/bin/env bash
#
# Mac → dispositivo Android FÍSICO (USB) en el servidor vía SSH.
# No usa Docker. Reenvía el servidor ADB (puerto 5037) a tu Mac.
#
set -euo pipefail

SCRIPT_VERSION="1.6"
REMOTE_HOST="${REMOTE_HOST:-serverlocal-ubuntu}"
REMOTE_DEVICE_DIR="${REMOTE_DEVICE_DIR:-/home/osedhelu/android/docker-android}"
REMOTE_DEVICE_FILE="${REMOTE_DEVICE_FILE:-${REMOTE_DEVICE_DIR}/.selected-device}"
LOCAL_DEVICE_FILE="${LOCAL_DEVICE_FILE:-${HOME}/.selected-device}"
DEVICE_SERIAL="${DEVICE_SERIAL:-}"
ADB_PORT="${ADB_SERVER_PORT:-5037}"
export ADB_SERVER_PORT="${ADB_PORT}"
# Puertos de vídeo/control de scrcpy (deben coincidir con --port= en scrcpy)
SCRCPY_PORT="${SCRCPY_PORT:-27183}"
SCRCPY_PORTS=("${SCRCPY_PORT}" "$((SCRCPY_PORT + 1))")
TUNNEL_PORTS=("${ADB_PORT}" "${SCRCPY_PORTS[@]}" 5554 5555 5556)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "${CYAN}>>${NC} $*"; }

usage() {
  cat <<EOF
connect-device-mac.sh v${SCRIPT_VERSION}

  ./connect-mac.sh              Mata todo lo anterior y crea conexión nueva
  ./connect-mac.sh --disconnect Solo limpia
  ./connect-mac.sh --test-only  Prueba (túnel ya abierto)
  ./connect-mac.sh --scrcpy           Abre scrcpy
  ./connect-mac.sh --list-devices     Lista dispositivos en el servidor
  ./connect-mac.sh --device SERIAL    Usa ese dispositivo (ej: N82)

Variables:
  DEVICE_SERIAL          Serial ADB (si no, lee ~/.selected-device o servidor)
EOF
}

resolve_device_serial() {
  local serial="${DEVICE_SERIAL}"

  if [[ -z "${serial}" && -f "${LOCAL_DEVICE_FILE}" ]]; then
    serial=$(tr -d '[:space:]' < "${LOCAL_DEVICE_FILE}")
  fi

  if [[ -z "${serial}" ]]; then
    serial=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "${REMOTE_HOST}" \
      "cat '${REMOTE_DEVICE_FILE}' 2>/dev/null" | tr -d '[:space:]' || true)
  fi

  if [[ -n "${serial}" ]]; then
    echo "${serial}"
    return 0
  fi

  # Fallback: primer dispositivo físico
  adb_via_server devices 2>/dev/null | grep -E '[[:space:]]device$' | grep -v offline | awk '{print $1; exit}'
}

list_remote_devices() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_HOST}" \
    "cd '${REMOTE_DEVICE_DIR}' && ./scripts/setup-device-server.sh list" 2>/dev/null || {
    error "No se pudo listar. En el servidor: ./scripts/setup-device-server.sh list"
    return 1
  }
}

port_pids() {
  lsof -nP -iTCP:"${1}" -sTCP:LISTEN -t 2>/dev/null | sort -u || true
}

force_kill_port() {
  local port="$1" pids
  pids=$(port_pids "${port}")
  [[ -z "${pids}" ]] && return 0
  step "Puerto ${port}: cerrando proceso anterior (PID $(echo "${pids}" | tr '\n' ' '))"
  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    kill "${pid}" 2>/dev/null || kill -9 "${pid}" 2>/dev/null || true
  done <<< "${pids}"
  sleep 0.5
  pids=$(port_pids "${port}")
  [[ -n "${pids}" ]] && kill -9 ${pids} 2>/dev/null || true
  sleep 0.5
}

kill_ssh_to_host() {
  local port="$1" pid args
  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    args=$(ps -ww -p "${pid}" -o args= 2>/dev/null || true)
    if [[ "${args}" == *ssh* ]] && [[ "${args}" == *"${REMOTE_HOST}"* ]] && [[ "${args}" == *"-N"* ]]; then
      if [[ "${args}" == *":${port}:"* ]] || [[ "${args}" == *"${port}:127.0.0.1:${port}"* ]]; then
        step "SSH túnel viejo en ${port} (PID ${pid}) → cerrado"
        kill -9 "${pid}" 2>/dev/null || true
      fi
    fi
  done < <(pgrep -x ssh 2>/dev/null || true)
}

remote_cleanup() {
  step "Servidor (${REMOTE_HOST}): limpiando ADB viejo..."
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_HOST}" bash -s <<'EOF' || true
adb disconnect 127.0.0.1:5555 2>/dev/null || true
adb disconnect 127.0.0.1:5556 2>/dev/null || true
adb forward --remove-all 2>/dev/null || true
# Reinicio suave del servidor ADB remoto
adb kill-server 2>/dev/null || true
sleep 1
adb start-server 2>/dev/null || true
EOF
}

local_cleanup() {
  step "Mac: cerrando ADB local, túneles y puertos viejos..."
  unset ADB_SERVER_SOCKET ANDROID_ADB_SERVER_ADDRESS 2>/dev/null || true

  if command -v adb >/dev/null 2>&1; then
    while read -r serial _; do
      [[ -z "${serial}" || "${serial}" == "List" ]] && continue
      adb disconnect "${serial}" >/dev/null 2>&1 || true
    done < <(adb devices 2>/dev/null | tail -n +2 || true)
    adb kill-server >/dev/null 2>&1 || true
  fi

  for p in "${TUNNEL_PORTS[@]}"; do
    kill_ssh_to_host "${p}"
    force_kill_port "${p}"
  done

  pkill -x scrcpy 2>/dev/null || true
  sleep 1
  export ADB_SERVER_PORT="${ADB_PORT}"
  info "Limpieza terminada — conexión nueva"
}

full_cleanup() {
  echo ""
  step "=== Paso 1/3: Matar conexiones anteriores (esto es normal) ==="
  remote_cleanup
  local_cleanup
  echo ""
}

remote_check_devices() {
  step "=== Paso 2/3: Comprobar N82 en el servidor ==="
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_HOST}" bash -s <<'EOF'
adb devices -l
echo ""
if ! adb devices | grep -E '[[:space:]]device($|[[:space:]])' | grep -qv offline; then
  echo "ERROR: ningún dispositivo USB en estado 'device'"
  exit 1
fi
echo "OK: dispositivo listo"
EOF
}

open_tunnel() {
  local port="$1"
  info "Túnel ${port}: Mac → ${REMOTE_HOST}:127.0.0.1:${port}"
  ssh -fNL "${port}:127.0.0.1:${port}" "${REMOTE_HOST}"
  sleep 0.5
  if [[ -z "$(port_pids "${port}")" ]]; then
    error "No se abrió el túnel en puerto ${port}"
    return 1
  fi
}

start_all_tunnels() {
  step "=== Paso 3/3: Crear túneles SSH (ADB + scrcpy) ==="
  open_tunnel "${ADB_PORT}" || return 1
  export ADB_SERVER_PORT="${ADB_PORT}"
  info "Túnel ADB (${ADB_PORT}) OK"
  for p in "${SCRCPY_PORTS[@]}"; do
    open_tunnel "${p}" || return 1
  done
  info "Túneles scrcpy (${SCRCPY_PORTS[*]}) OK — necesarios para ver la pantalla"
}

adb_via_server() {
  export ADB_SERVER_PORT="${ADB_PORT}"
  adb "$@"
}

test_connection() {
  command -v adb >/dev/null 2>&1 || {
    error "Instala adb: brew install android-platform-tools"
    return 1
  }

  adb_via_server start-server >/dev/null 2>&1
  sleep 1

  echo ""
  echo "=== adb devices (Mac → servidor) ==="
  adb_via_server devices -l
  echo ""

  local serial state
  serial=$(resolve_device_serial)
  if [[ -z "${serial}" ]]; then
    error "No hay dispositivo 'device'."
    error "En el servidor: ./scripts/setup-device-server.sh"
    return 1
  fi
  info "Usando dispositivo: ${serial}"

  state=$(adb_via_server -s "${serial}" get-state 2>/dev/null || echo "missing")
  [[ "${state}" == "device" ]] || {
    error "Estado de ${serial}: ${state}"
    return 1
  }

  local ver model
  ver=$(adb_via_server -s "${serial}" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
  model=$(adb_via_server -s "${serial}" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
  info "Listo — ${serial} — Android ${ver} (${model})"
  echo ""
  echo "  export ADB_SERVER_PORT=${ADB_PORT}"
  echo "  scrcpy -s ${serial} --no-audio --force-adb-forward --port=${SCRCPY_PORT}"
  echo "  adb -s ${serial} install app.apk"
  return 0
}

run_scrcpy() {
  local serial
  serial=$(resolve_device_serial)
  [[ -n "${serial}" ]] || { error "Sin dispositivo. Ejecuta ~/connect-mac.sh primero."; return 1; }
  command -v scrcpy >/dev/null 2>&1 || { error "Instala scrcpy: brew install scrcpy"; return 1; }
  info "Abriendo scrcpy (${serial})..."
  exec scrcpy -s "${serial}" --no-audio --force-adb-forward --port="${SCRCPY_PORT}" "$@"
}

main() {
  local mode="connect"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disconnect) mode="disconnect"; shift ;;
      --test-only)  mode="test"; shift ;;
      --scrcpy)         mode="scrcpy"; shift ;;
      --list-devices)   mode="list"; shift ;;
      --device)
        DEVICE_SERIAL="${2:-}"
        [[ -n "${DEVICE_SERIAL}" ]] || { error "Falta serial: --device N82"; exit 1; }
        shift 2
        ;;
      -h|--help)    usage; exit 0 ;;
      *) error "Opción: $1"; usage; exit 1 ;;
    esac
  done

  echo "=== Dispositivo físico → Mac v${SCRIPT_VERSION} ==="
  echo "Servidor: ${REMOTE_HOST}  |  ADB: ${ADB_PORT}  |  scrcpy: ${SCRCPY_PORTS[*]}"
  echo ""

  case "${mode}" in
    disconnect)
      full_cleanup
      unset ADB_SERVER_PORT 2>/dev/null || true
      info "Desconectado."
      exit 0
      ;;
    test)
      test_connection
      exit $?
      ;;
    scrcpy)
      export ADB_SERVER_PORT="${ADB_PORT}"
      run_scrcpy "$@"
      exit $?
      ;;
    list)
      list_remote_devices
      exit $?
      ;;
  esac

  unset ADB_SERVER_SOCKET ANDROID_ADB_SERVER_ADDRESS 2>/dev/null || true
  export ADB_SERVER_PORT="${ADB_PORT}"

  ssh -o BatchMode=yes -o ConnectTimeout=8 "${REMOTE_HOST}" "echo ok" >/dev/null 2>&1 || {
    error "Sin SSH a ${REMOTE_HOST}"
    exit 1
  }
  info "SSH OK"

  full_cleanup
  remote_check_devices || exit 1
  start_all_tunnels || exit 1
  test_connection
}

main "$@"
