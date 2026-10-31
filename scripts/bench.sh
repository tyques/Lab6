#!/usr/bin/env bash
# Г.1. Замеры ВНУТРИ ВМ. Копирование: scp scripts/bench.sh vm-18-63:
#   ./bench.sh prepare       один раз, до базового замера
#   ./bench.sh run before    базовый замер: снапшота ещё нет
#   ./bench.sh run after     тот же замер при существующем снапшоте
#
# (а) Потоковая запись: dd пишет 1 ГиБ блоками по 1 МиБ в ОДИН И ТОТ ЖЕ файл (conv=notrunc).
#     ext4 пишет в те же блоки, значит, и в те же кластеры qcow2. До снапшота это перезапись на месте,
#     после снапшота первый проход вызывает copy-on-write каждого кластера.
#     oflag=direct — мимо кэша ОС ВМ; fsync — сброс кэша диска входит в замер.
# (б) Установка пакета PKG из локального кэша .deb (сеть не влияет): 3 цикла install/purge.
set -euo pipefail
PKG=${PKG:-nmap}
F=/var/tmp/ddtest.bin
TIMEFORMAT=%R                     # bash time: только реальное время, в секундах

case ${1:?"prepare | run <метка>"} in
prepare)
  # фоновые apt-daily и unattended-upgrades держат блокировку dpkg и грузят диск — выключаем на время ЛБ
  sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service \
    >/dev/null 2>&1 || true
  # первая запись выделяет кластеры qcow2 (рост тонкого диска) — это ещё не замер
  dd if=/dev/zero of="$F" bs=1M count=1024 oflag=direct conv=fsync status=none
  sudo apt-get install -y -qq --download-only "$PKG" >/dev/null
  echo "prepare: $(du -h "$F" | cut -f1) в $F; .deb для $PKG и зависимостей — в /var/cache/apt/archives"
  ;;
run)
  L=${2:?"метка: before | after"}
  echo "== $L $(date '+%F %T')  dd: 1 GiB, bs=1M, oflag=direct, conv=notrunc,fsync"
  for i in 1 2 3; do
    printf 'dd#%s  ' "$i"
    dd if=/dev/zero of="$F" bs=1M count=1024 oflag=direct conv=notrunc,fsync 2>&1 | tail -n1
  done
  echo "== $L  apt-get install $PKG (пакет и зависимости из локального кэша)"
  for i in 1 2 3; do
    sudo apt-get purge -y -qq --autoremove "$PKG" >/dev/null 2>&1 || true
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null      # холодный кэш ОС перед каждой установкой
    t=$( { time sudo apt-get install -y -qq "$PKG" >/dev/null 2>&1; } 2>&1 )
    echo "apt#$i  $t s"
  done
  sudo apt-get purge -y -qq --autoremove "$PKG" >/dev/null 2>&1
  echo "== $PKG снова удалён: пакетный состав ВМ — как до замера"
  ;;
*)
  echo "prepare | run <метка>"; exit 1 ;;
esac
