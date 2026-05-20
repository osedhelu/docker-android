#!/usr/bin/env bash
#
# En el SERVIDOR: lista dispositivos USB y elige cuál usar con la Mac.
#
# Uso:
#   ./scripts/setup-device-server.sh          # lista y elige interactivo
#   ./scripts/setup-device-server.sh list     # solo listar
#   ./scripts/setup-device-server.sh N82      # elegir por serial
#   DEVICE_SERIAL=ABC123 ./scripts/setup-device-server.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEVICE_FILE="${DEVICE_FILE:-${PROJECT_DIR}/.selected-device}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
  cat <<EOF
setup-device-server.sh — elegir dispositivo Android en el servidor

  ./scripts/setup-device-server.sh           Lista y menú interactivo
  ./scripts/setup-device-server.sh list      Solo muestra dispositivos
  ./scripts/setup-device-server.sh <serial>  Guarda ese dispositivo (ej: N82)
  DEVICE_SERIAL=<serial> ./scripts/setup-device-server.sh

Archivo guardado: ${DEVICE_FILE}
En la Mac: DEVICE_SERIAL=<serial> ~/connect-mac.sh
           o lee automático desde el servidor si ya ejecutaste este script.
EOF
}

# Devuelve líneas: serial|modelo|marca|android|transporte
collect_devices() {
  adb start-server >/dev/null 2>&1
  local line serial state model brand android transport
  while read -r line; do
    [[ -z "${line}" || "${line}" == List* ]] && continue
    serial="${line%%[[:space:]]*}"
    state=$(echo "${line}" | awk '{print $2}')
    [[ "${state}" != "device" ]] && continue
    [[ "${serial}" == emulator-* ]] && continue
    model=$(adb -s "${serial}" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "?")
    brand=$(adb -s "${serial}" shell getprop ro.product.brand 2>/dev/null | tr -d '\r' || echo "?")
    android=$(adb -s "${serial}" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' || echo "?")
    transport=$(echo "${line}" | grep -oE 'usb:[^ ]+' | head -1 || echo "usb")
    echo "${serial}|${model}|${brand}|${android}|${transport}"
  done < <(adb devices -l 2>/dev/null)
}

print_device_table() {
  local -a rows=("$@")
  local i row serial model brand android transport
  echo ""
  echo "┌────┬──────────────────┬─────────────────────────────┬──────────┐"
  echo "│ #  │ Serial           │ Dispositivo                 │ Android  │"
  echo "├────┼──────────────────┼─────────────────────────────┼──────────┤"
  for i in "${!rows[@]}"; do
    IFS='|' read -r serial model brand android transport <<< "${rows[$i]}"
    printf "│ %-2s │ %-16s │ %-27s │ %-8s │\n" "$((i + 1))" "${serial}" "${brand} ${model}" "${android}"
  done
  echo "└────┴──────────────────┴─────────────────────────────┴──────────┘"
  echo ""
}

save_device() {
  local serial="$1"
  echo "${serial}" > "${DEVICE_FILE}"
  info "Dispositivo seleccionado: ${serial}"
  info "Guardado en: ${DEVICE_FILE}"
}

verify_serial_exists() {
  local want="$1" row serial
  local -a rows
  mapfile -t rows < <(collect_devices)
  for row in "${rows[@]}"; do
    serial="${row%%|*}"
    [[ "${serial}" == "${want}" ]] && return 0
  done
  return 1
}

pick_interactive() {
  local -a rows
  mapfile -t rows < <(collect_devices)
  if [[ ${#rows[@]} -eq 0 ]]; then
    error "No hay dispositivos físicos en estado 'device'."
    echo ""
    echo "  1. Conecta el USB al servidor"
    echo "  2. Activa Depuración USB"
    echo "  3. Acepta el diálogo en la pantalla del equipo"
    exit 1
  fi

  if [[ ${#rows[@]} -eq 1 ]]; then
    IFS='|' read -r serial _ _ _ _ <<< "${rows[0]}"
    warn "Solo hay un dispositivo → se usa: ${serial}"
    save_device "${serial}"
    show_next_steps "${serial}"
    return
  fi

  echo "=== Dispositivos conectados al servidor ==="
  print_device_table "${rows[@]}"

  local choice serial
  while true; do
    read -r -p "Elige número [1-${#rows[@]}] (q=salir): " choice
    [[ "${choice}" == "q" || "${choice}" == "Q" ]] && exit 0
    if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#rows[@]} )); then
      IFS='|' read -r serial _ _ _ _ <<< "${rows[$((choice - 1))]}"
      save_device "${serial}"
      show_next_steps "${serial}"
      return
    fi
    warn "Opción inválida."
  done
}

show_next_steps() {
  local serial="$1"
  echo ""
  info "En la Mac:"
  echo "  scp ${REMOTE_HOST:-serverlocal-ubuntu}:${DEVICE_FILE} ~/.selected-device   # opcional"
  echo "  ~/connect-mac.sh"
  echo "  # o forzar serial:"
  echo "  DEVICE_SERIAL=${serial} ~/connect-mac.sh"
  echo ""
  echo "  scrcpy -s ${serial} --no-audio --force-adb-forward --port=27183"
  echo ""
}

list_only() {
  local -a rows
  mapfile -t rows < <(collect_devices)
  if [[ ${#rows[@]} -eq 0 ]]; then
    warn "Ningún dispositivo físico conectado."
    adb devices -l
    exit 1
  fi
  adb devices -l
  print_device_table "${rows[@]}"
  if [[ -f "${DEVICE_FILE}" ]]; then
    info "Selección actual: $(cat "${DEVICE_FILE}")"
  else
    warn "Sin selección guardada. Ejecuta: ./scripts/setup-device-server.sh"
  fi
}

main() {
  local arg="${1:-}"

  case "${arg}" in
    -h|--help|help)
      usage
      exit 0
      ;;
    list|-l)
      list_only
      exit 0
      ;;
    "")
      pick_interactive
      exit 0
      ;;
  esac

  # Serial por argumento o variable de entorno
  local serial="${DEVICE_SERIAL:-${arg}}"
  if ! verify_serial_exists "${serial}"; then
    error "Serial no encontrado o no está 'device': ${serial}"
    echo ""
    list_only
    exit 1
  fi
  save_device "${serial}"
  adb -s "${serial}" forward --remove-all 2>/dev/null || true
  show_next_steps "${serial}"
}

main "$@"
