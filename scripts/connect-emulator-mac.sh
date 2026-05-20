#!/usr/bin/env bash
#
# Mac: limpia puertos/túneles/ADB y conecta al emulador remoto vía SSH.
# Uso: ./scripts/connect-emulator-mac.sh
#
set -euo pipefail

SCRIPT_VERSION="2.2"
REMOTE_DOCKER_DIR="${REMOTE_DOCKER_DIR:-/home/osedhelu/android/docker-android}"
REMOTE_HOST="${REMOTE_HOST:-serverlocal-ubuntu}"
ADB_PORT="${ADB_PORT:-5555}"
CONSOLE_PORT="${CONSOLE_PORT:-5554}"
FORWARD_CONSOLE="${FORWARD_CONSOLE:-false}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
  cat <<EOF
connect-emulator-mac.sh v${SCRIPT_VERSION}

Uso: $(basename "$0") [--disconnect | --test-only | -h]

  (sin args)     Mata todo en 5554/5555, abre túnel ADB y prueba conexión
  --disconnect   Solo limpia (SSH + ADB)
  --test-only    Solo prueba ADB (túnel ya debe existir)

Variables: REMOTE_HOST, ADB_PORT, CONSOLE_PORT, FORWARD_CONSOLE=true
EOF
}

port_pids() {
  local port="$1"
  lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null | sort -u || true
}

force_kill_port() {
  local port="$1"
  local pids
  pids=$(port_pids "${port}")
  [[ -z "${pids}" ]] && return 0

  warn "Puerto ${port} → matando PID(s): $(echo "${pids}" | tr '\n' ' ')"
  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    kill "${pid}" 2>/dev/null || true
  done <<< "${pids}"
  sleep 1

  pids=$(port_pids "${port}")
  if [[ -n "${pids}" ]]; then
    warn "Puerto ${port} → kill -9 forzado"
    while IFS= read -r pid; do
      [[ -z "${pid}" ]] && continue
      kill -9 "${pid}" 2>/dev/null || true
    done <<< "${pids}"
    sleep 0.5
  fi

  if port_pids "${port}" | grep -q .; then
    error "No se pudo liberar el puerto ${port}"
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN || true
    return 1
  fi
  return 0
}

kill_all_ssh_to_host() {
  local pid args
  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    args=$(ps -ww -p "${pid}" -o args= 2>/dev/null || true)
    # Solo túneles (-N) hacia nuestro servidor, no sesiones SSH interactivas
    if [[ "${args}" == *ssh* ]] && [[ "${args}" == *"${REMOTE_HOST}"* ]] && [[ "${args}" == *"-N"* ]]; then
      warn "Cerrando SSH túnel PID ${pid}"
      kill "${pid}" 2>/dev/null || kill -9 "${pid}" 2>/dev/null || true
    fi
  done < <(pgrep -x ssh 2>/dev/null || true)
}

adb_kill_all_local() {
  command -v adb >/dev/null 2>&1 || return 0
  adb start-server >/dev/null 2>&1 || true

  # Quitar entradas offline (emulator-5554, localhost:5555, etc.)
  local serial state
  while read -r serial state _; do
    [[ -z "${serial}" || "${serial}" == "List" ]] && continue
    if [[ "${state}" == "offline" ]] || [[ "${serial}" == emulator-* ]] || [[ "${serial}" == localhost:* ]]; then
      warn "ADB disconnect ${serial} (${state})"
      adb disconnect "${serial}" >/dev/null 2>&1 || true
    fi
  done < <(adb devices 2>/dev/null | tail -n +2)

  adb disconnect "localhost:${ADB_PORT}" >/dev/null 2>&1 || true
  adb disconnect "localhost:${CONSOLE_PORT}" >/dev/null 2>&1 || true
}

# Comprueba en el servidor que el emulador Docker escucha en REMOTE_ADB_PORT
remote_preflight() {
  local remote_port="${REMOTE_ADB_PORT:-5555}"
  info "Comprobando emulador en ${REMOTE_HOST}..."

  local out
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_HOST}" bash -s <<EOF
set -e
remote_port="${remote_port}"
docker_dir="${REMOTE_DOCKER_DIR}"

echo "=== docker ==="
if [[ -d "\${docker_dir}" ]]; then
  cd "\${docker_dir}" && docker compose ps 2>/dev/null || docker-compose ps 2>/dev/null || echo "no compose"
else
  echo "DIR_MISSING \${docker_dir}"
fi

echo "=== puerto \${remote_port} ==="
if command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>/dev/null | grep ":\${remote_port}" || echo "PUERTO_CERRADO"
else
  nc -z 127.0.0.1 "\${remote_port}" && echo "PUERTO_ABIERTO" || echo "PUERTO_CERRADO"
fi

echo "=== adb servidor ==="
if command -v adb >/dev/null 2>&1; then
  adb devices 2>/dev/null | tail -n +2 || true
fi
EOF
) || {
    error "No se pudo ejecutar comprobación remota en ${REMOTE_HOST}"
    return 1
  }

  echo "${out}" | sed 's/^/  /'

  if echo "${out}" | grep -q "DIR_MISSING"; then
    error "No existe ${REMOTE_DOCKER_DIR} en el servidor."
    error "Si usas el N82 por USB, NO uses este script."
    error "En la Mac ejecuta: ./connect-device-mac.sh"
    return 1
  fi

  if echo "${out}" | grep -q "PUERTO_CERRADO"; then
    if echo "${out}" | grep -qE 'N82|[[:space:]]device'; then
      error "El emulador Docker NO está corriendo (puerto 5555 cerrado)."
      error "En el servidor hay un N82 físico. En la Mac usa:"
      error "  ./connect-device-mac.sh"
      return 1
    fi
  fi

  if echo "${out}" | grep -qE "Exited|unhealthy|no compose"; then
    if ! echo "${out}" | grep -qi "Up"; then
      error "El contenedor android-emulator NO está corriendo en el servidor."
      echo ""
      echo "  En el servidor ejecuta:"
      echo "    cd ${REMOTE_DOCKER_DIR}"
      echo "    docker compose up android-emulator -d"
      echo "    docker compose logs -f android-emulator   # espera ANDROID_READY"
      return 1
    fi
  fi

  if echo "${out}" | grep -q "PUERTO_CERRADO"; then
    error "En el servidor nada escucha en 127.0.0.1:${remote_port} (emulador parado)."
    error "  docker compose up android-emulator -d   (en el servidor, si quieres emulador)"
    return 1
  fi

  # Si 5555 lo usa 'adb' del host (N82) y no docker-proxy, avisar
  if echo "${out}" | grep ":${remote_port}" | grep -q 'users:(("adb"'; then
    if ! echo "${out}" | grep -qi "Up"; then
      warn "El puerto ${remote_port} en el servidor lo usa ADB del host (¿N82?), no el emulador Docker."
      warn "Para el emulador: para el N82/forward en 5555 o mapea Docker a otro puerto (ej. 5557)."
    fi
  fi

  return 0
}

cleanup_everything() {
  warn "=== Limpieza total (v${SCRIPT_VERSION}) ==="

  adb_kill_all_local
  kill_all_ssh_to_host

  force_kill_port "${CONSOLE_PORT}" || true
  force_kill_port "${ADB_PORT}" || true

  sleep 1
  info "Puertos ${CONSOLE_PORT} y ${ADB_PORT} libres"
}

start_tunnel() {
  local port="$1"
  force_kill_port "${port}" || return 1

  info "Túnel SSH: localhost:${port} → ${REMOTE_HOST}:localhost:${port}"
  ssh -fNL "${port}:localhost:${port}" "${REMOTE_HOST}"
  sleep 1

  if [[ -n "$(port_pids "${port}")" ]]; then
    info "Túnel activo en ${port}"
    return 0
  fi
  error "Falló el túnel en puerto ${port}"
  return 1
}

adb_connect_and_test() {
  command -v adb >/dev/null 2>&1 || {
    error "Instala adb: brew install android-platform-tools"
    return 1
  }

  adb start-server >/dev/null 2>&1
  adb_kill_all_local

  info "ADB connect localhost:${ADB_PORT} ..."
  local i state
  for i in 1 2 3 4 5; do
    adb connect "localhost:${ADB_PORT}" 2>&1 | grep -v "^$" || true
    sleep 2
    state=$(adb -s "localhost:${ADB_PORT}" get-state 2>/dev/null || echo "missing")
    [[ "${state}" == "device" ]] && break
    warn "Intento ${i}/5 — estado: ${state}"
  done

  echo ""
  echo "=== adb devices ==="
  adb devices -l
  echo ""

  local state
  state=$(adb -s "localhost:${ADB_PORT}" get-state 2>/dev/null || echo "missing")

  case "${state}" in
    device)
      local ver model
      ver=$(adb -s "localhost:${ADB_PORT}" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
      model=$(adb -s "localhost:${ADB_PORT}" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
      info "✓ Conexión lista — Android ${ver} (${model})"
      echo ""
      echo "  scrcpy -s localhost:${ADB_PORT}"
      echo "  scrcpy -s localhost:${ADB_PORT} --require-audio"
      return 0
      ;;
    offline)
      error "Dispositivo offline. ¿Emulador corriendo en el servidor?"
      error "  ssh ${REMOTE_HOST} 'docker compose -f ~/android/docker-android/docker-compose.yml ps'"
      return 1
      ;;
    *)
      error "Sin dispositivo en localhost:${ADB_PORT} (estado: ${state})"
      return 1
      ;;
  esac
}

main() {
  # Este script es SOLO para emulador Docker. Para N82 físico → connect-mac.sh
  if [[ "${USE_EMULATOR:-}" != "1" ]]; then
    echo ""
    error "Este script NO es para el N82 físico."
    error "En tu Mac ejecuta:"
    error "  ~/connect-mac.sh"
    error "  (copia con: scp serverlocal-ubuntu:/home/osedhelu/android/docker-android/scripts/connect-mac.sh ~/)"
    error ""
    error "Si de verdad quieres el emulador Docker:"
    error "  USE_EMULATOR=1 ./connect-emulator-mac.sh"
    exit 2
  fi

  local mode="connect"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disconnect) mode="disconnect"; shift ;;
      --test-only)  mode="test"; shift ;;
      -h|--help)    usage; exit 0 ;;
      *) error "Opción desconocida: $1"; usage; exit 1 ;;
    esac
  done

  echo "=== Emulador Android (Mac) v${SCRIPT_VERSION} ==="
  echo "Servidor: ${REMOTE_HOST}  |  ADB: ${ADB_PORT}"
  echo ""
  warn "Este script es solo para EMULADOR DOCKER (puerto 5555)."
  warn "Si usas el N82 físico por USB → usa: ./scripts/connect-device-mac.sh"
  echo ""

  case "${mode}" in
    disconnect)
      cleanup_everything
      info "Desconectado."
      exit 0
      ;;
    test)
      adb_connect_and_test
      exit $?
      ;;
  esac

  if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "${REMOTE_HOST}" "echo ok" >/dev/null 2>&1; then
    error "No hay SSH a ${REMOTE_HOST}. Prueba: ssh ${REMOTE_HOST}"
    exit 1
  fi
  info "SSH → ${REMOTE_HOST} OK"

  remote_preflight || exit 1

  cleanup_everything

  if [[ "${FORWARD_CONSOLE}" == "true" ]]; then
    start_tunnel "${CONSOLE_PORT}" || exit 1
  fi

  start_tunnel "${ADB_PORT}" || exit 1
  adb_connect_and_test
}

main "$@"
