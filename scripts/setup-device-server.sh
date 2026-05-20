#!/usr/bin/env bash
#
# En el SERVIDOR: comprueba el dispositivo USB y (opcional) lo expone en un puerto TCP.
# Uso: ./scripts/setup-device-server.sh
#
set -euo pipefail

DEVICE_PORT="${DEVICE_PORT:-5556}"

echo "=== ADB en servidor ==="
adb start-server
adb devices -l

SERIAL=$(adb devices | awk 'NR>1 && $2=="device" && $1 !~ /^emulator-/{print $1; exit}')

if [[ -z "${SERIAL}" ]]; then
  echo ""
  echo "ERROR: No hay dispositivo físico USB conectado."
  echo "  1. Conecta el N82 por USB"
  echo "  2. Activa Opciones desarrollador → Depuración USB"
  echo "  3. Acepta 'Permitir depuración USB' en la pantalla"
  exit 1
fi

echo ""
echo "Dispositivo: ${SERIAL}"

# Quitar forwards viejos de este serial
adb -s "${SERIAL}" forward --list 2>/dev/null || true

echo ""
echo "Para usar desde la Mac SIN Docker, lo más simple es:"
echo "  En la Mac: ./scripts/connect-device-mac.sh"
echo "  (túnel al puerto ADB 5037 del servidor)"
echo ""
echo "NO hace falta forward tcp:5556 para USB."
echo "Desde la Mac usa: ./scripts/connect-device-mac.sh"

echo ""
echo "Listo."
