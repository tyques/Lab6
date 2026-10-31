#!/usr/bin/env bash
# Удалить ВМ и её собственные файлы: диск <имя>.qcow2 и seed-<имя>.iso.
# Базовый облачный образ и шаблон не трогает никогда.
#   scripts/destroy-vm.sh <имя-ВМ>
set -euo pipefail
cd "$(dirname "$0")/.."
source ./lab6.env

NAME=${1:?"имя ВМ"}
case $NAME in
  *tpl*|*base*) echo "отказ: '$NAME' похоже на шаблон или базовый образ"; exit 1 ;;
esac

virsh destroy "$NAME" 2>/dev/null || true
# внутренние снапшоты лежат в самом qcow2 и уйдут вместе с ним; libvirt хранит ещё их метаданные
virsh undefine "$NAME" --snapshots-metadata 2>/dev/null || true
sudo rm -fv "$IMG/$NAME.qcow2" "$IMG/seed-$NAME.iso"
