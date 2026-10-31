#!/usr/bin/env python3
"""Псевдо-БД для ЛБ-6 (часть Г.3): непрерывно дописывает пронумерованные записи.

Каждая запись пишется в два файла:
  fsync.log    — как СУБД с журналом: write -> flush -> fsync, и только потом «ответ клиенту»;
  buffered.log — как наивное приложение: write() в буфер Python (8 КиБ). В ядро данные уходят,
                 только когда буфер заполнится, а на диск — когда ядро сбросит page cache
                 (через ~5–30 с, vm.dirty_writeback_centisecs / vm.dirty_expire_centisecs).
«Ответ клиенту» — строка ACK в stdout. Процесс запускается по SSH с хоста, stdout сохраняется
на хосте: откат ВМ этот журнал не затронет, по нему видно, что клиенту успели подтвердить.

Запуск (на хосте):
  ssh vm-18-63 'python3 -u ~/pseudo_db.py --dir /var/lib/pseudodb' | tee logs/G3-acks.txt
"""
import argparse
import datetime
import os
import signal
import time

ap = argparse.ArgumentParser()
ap.add_argument("--dir", default="/var/lib/pseudodb")
ap.add_argument("--rate", type=float, default=20.0, help="записей в секунду")
args = ap.parse_args()

# после отката «с памятью» процесс оживёт, а его SSH-сессии уже не будет: не умирать от обрыва
signal.signal(signal.SIGHUP, signal.SIG_IGN)

os.makedirs(args.dir, exist_ok=True)
buffered = open(os.path.join(args.dir, "buffered.log"), "a")   # буфер по умолчанию, 8 КиБ
durable = open(os.path.join(args.dir, "fsync.log"), "a")

seq = 0
while True:
    seq += 1
    ts = datetime.datetime.now().isoformat(timespec="milliseconds")
    line = f"{seq:07d} {ts} pid={os.getpid()} {'x' * 48}\n"      # ~100 байт на запись

    buffered.write(line)          # лежит в памяти процесса, пока буфер не заполнится
    durable.write(line)
    durable.flush()               # буфер Python -> page cache ядра
    os.fsync(durable.fileno())    # page cache -> диск ВМ: запись «закоммичена»

    try:
        print(f"ACK {seq:07d} {ts}", flush=True)   # клиенту подтвердили
    except BrokenPipeError:
        pass                      # клиента (SSH) больше нет — сервер продолжает работать
    time.sleep(1 / args.rate)
