#!/usr/bin/env bash
# Repara ADB: "protocol fault" / "Connection reset by peer"
set -euo pipefail

echo "=== Reparar ADB ==="

# Si la Mac usa túnel al servidor, esto rompe adb local hasta desactivarlo
if [[ -n "${ADB_SERVER_PORT:-}" ]] || [[ -n "${ADB_SERVER_SOCKET:-}" ]]; then
  echo "[!] ADB_SERVER_PORT/SOCKET definido → puede ser túnel SSH roto."
  echo "    Desactivando variables de entorno..."
  unset ADB_SERVER_PORT ADB_SERVER_SOCKET ANDROID_ADB_SERVER_ADDRESS
fi

echo "[1] Matando procesos adb y ssh en puerto 5037..."
pkill -9 adb 2>/dev/null || true
killall -9 adb 2>/dev/null || true

if [[ "$(uname -s)" == "Darwin" ]]; then
  # macOS
  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    kill -9 "${pid}" 2>/dev/null || true
  done < <(lsof -nP -iTCP:5037 -sTCP:LISTEN -t 2>/dev/null || true)
  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    args=$(ps -ww -p "${pid}" -o args= 2>/dev/null || true)
    [[ "${args}" == *ssh* ]] && [[ "${args}" == *5037* ]] && kill -9 "${pid}" 2>/dev/null || true
  done < <(pgrep -x ssh 2>/dev/null || true)
else
  # Linux
  fuser -k 5037/tcp 2>/dev/null || true
  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    kill -9 "${pid}" 2>/dev/null || true
  done < <(lsof -nP -iTCP:5037 -sTCP:LISTEN -t 2>/dev/null || true)
fi

sleep 2

echo "[2] Comprobando puerto 5037..."
if lsof -nP -iTCP:5037 -sTCP:LISTEN 2>/dev/null | grep -q .; then
  echo "    AÚN OCUPADO:"
  lsof -nP -iTCP:5037 -sTCP:LISTEN 2>/dev/null || true
  echo "    Mata manualmente: kill -9 \$(lsof -ti :5037)"
  exit 1
fi
echo "    Puerto 5037 libre."

echo "[3] Iniciando adb start-server..."
if ! adb start-server 2>&1; then
  echo ""
  echo "ERROR: adb no arranca. Prueba:"
  echo "  which adb"
  echo "  adb version"
  echo "  brew reinstall android-platform-tools   # Mac"
  echo "  sudo apt install --reinstall adb          # Linux"
  exit 1
fi

echo "[4] Limpiando conexiones TCP viejas..."
adb disconnect 127.0.0.1:5555 2>/dev/null || true
adb disconnect 127.0.0.1:5556 2>/dev/null || true
adb disconnect 127.0.0.1:5557 2>/dev/null || true
adb forward --remove-all 2>/dev/null || true

echo ""
echo "=== adb devices ==="
adb devices -l

echo ""
if adb devices 2>/dev/null | grep -E '[[:space:]]device($|[[:space:]])' | grep -qv 'offline'; then
  echo "OK: hay al menos un dispositivo listo."
else
  echo "AVISO: sin dispositivo 'device'. Revisa USB y depuración USB en el equipo."
fi

echo ""
echo "En la Mac, para conectar al N82 del servidor después:"
echo "  unset ADB_SERVER_PORT"
echo "  ~/connect-device-mac.sh"
