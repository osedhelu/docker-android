#!/usr/bin/env bash
# ÚNICO script para Mac → dispositivo físico en el servidor (sin Docker).
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "${DIR}/connect-device-mac.sh" "$@"
