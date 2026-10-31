# ЛБ-6. План выполнения: ВМ, cloud-init, шаблоны, снапшоты (Ubuntu + KVM/libvirt)

**Черников Антон Васильевич, 8ПМ63.** N = 18, G = 63.
Платформа: физический хост Ubuntu, KVM + libvirt (`virsh`, `virt-install`), облачный образ Ubuntu 24.04,
cloud-init через NoCloud seed-ISO (`cloud-localds`).

Что лежит в папке (на Ubuntu скопировать её в `~/lab6`):

| Файл | Что это | Где нужен |
|---|---|---|
| `PLAN.md` | этот план | — |
| `lab6.env` | данные варианта, пути, `LIBVIRT_DEFAULT_URI` | `source lab6.env` в каждом терминале хоста |
| `libvirt/lab6-net.xml` | сеть libvirt 10.97.2.96/27 с NAT, без DHCP | 2.5 |
| `cloud-init/vm-18-63/` | `user-data`, `meta-data`, `network-config` основной ВМ | А |
| `cloud-init/vm-18-63-2/` | то же для клона | В |
| `scripts/deploy-vm.sh` | диск → seed-ISO → `virt-install` → ожидание SSH и cloud-init → замер времени | А, В, доп. |
| `scripts/destroy-vm.sh` | удалить ВМ и её файлы (шаблон и базовый образ не трогает) | пересоздание |
| `scripts/bench.sh` | замеры Г.1, запускается внутри ВМ | Г.1 |
| `scripts/pseudo_db.py` | «псевдо-БД» для Г.3, запускается внутри ВМ | Г.3 |
| `logs/measurements.md` | заготовки таблиц под замеры | все части |

Каждую строку конфигов и скриптов нужно понимать: на защите просят поменять опцию на месте. Комментарии
в файлах написаны как раз для этого — читать их до запуска.

---

## 0. Данные варианта

| Параметр | Формула | Значение |
|---|---|---|
| HOST | vm-N-G | **vm-18-63** |
| USER | stud-N | **stud-18** |
| P | из ЛБ-3: 16 + (18 + 63) mod 240 | 97, блок 10.97.0.0/16 |
| Y | 100 + N | 118 |
| IP | 10.P.X.Y из свободного диапазона ЛБ-3 | **10.97.2.118/27**, шлюз и DNS 10.97.2.97 |
| VCPU | 1 + (18 mod 4) = 1 + 2 | **3** |
| RAM | 1024 + 256 · (18 mod 5) = 1024 + 256 · 3 | **1792 МиБ** |
| DISK | 8 + (63 mod 8) = 8 + 7 | **15 ГиБ** |
| CORES | 8 + (18 mod 8) = 8 + 2 | **10** |
| DISKN | 8 + (18 mod 4) = 8 + 2 | **10** |
| NEED | 6 + (63 mod 6) = 6 + 3 | **9 ТБ** |
| RAM сервера (Е) | 64 + G | 127 ГБ |

**Почему 10.97.2.118/27 (это обоснование — в отчёт).**

- В плане ЛБ-3 подсети уложены от большей к меньшей вплотную, поэтому **дыр между подсетями нет**: занято
  10.97.0.0–10.97.2.83 (последняя — link-rt 10.97.2.80/30). Свободный «хвост» блока по списку из ЛБ-3:
  10.97.2.84/30, 10.97.2.88/29, **10.97.2.96/27**, 10.97.2.128/25, 10.97.3.0/24, 10.97.4.0/22 … 10.97.128.0/17.
- Y = 118 задан. Ищу свободный блок, в который попадает .118 при X = 2:

  ```text
  118        = 0111 0110
  маска /27  = 1110 0000
  AND        = 0110 0000 = 96   → 10.97.2.96/27 — есть в списке свободных
  ```

- /27 — это 30 usable-адресов: шлюз, 2 ВМ основной части, 2 ВМ доп. задания и запас. Блок беру целиком из
  списка, не дробя. Шлюз — первый usable (.97), как во всех подсетях ЛБ-3; этот адрес получит мост
  `virbr-lab6` на хосте.
- Сети стенда ЛБ-4 (10.97.38.0/24, 10.97.39.0/24, 10.97.40.0/30, 10.97.41.0/24) лежат в 10.97.32.0/19 и с
  выбранным блоком не пересекаются.
- Запасной вариант — 10.97.3.118/24 (первый свободный целый /24): маска проще, но 254 адреса уходят на 4 ВМ.

**Новая строка плана ЛБ-3:**

| Среда | CIDR | Маска | Network | Broadcast | First host | Last host | Шлюз |
|---|---|---|---|---|---|---|---|
| lab6-vm (ЛБ-6) | 10.97.2.96/27 | 255.255.255.224 | 10.97.2.96 | 10.97.2.127 | 10.97.2.97 | 10.97.2.126 | 10.97.2.97 (virbr-lab6) |

| Адрес | Узел |
|---|---|
| 10.97.2.97 | хост, мост `virbr-lab6`: шлюз, NAT, DNS (dnsmasq libvirt) |
| 10.97.2.118 | vm-18-63 — основная ВМ (А) |
| 10.97.2.119 | vm-18-63-2 — клон из шаблона (В), «измененный адрес» из условия |
| 10.97.2.120, .121 | svc-18-63-1, svc-18-63-2 — ВМ доп. задания |

После выделения свободными остаются 10.97.2.84/30, 10.97.2.88/29, 10.97.2.128/25, 10.97.3.0/24 и далее.
Проверка, как в ЛБ-3: `ipcalc -n 10.97.2.118/27` → Network 10.97.2.96/27, HostMin .97, HostMax .126, Broadcast .127.

---

## 1. Как работать: порядок, время, логи

**Порядок:** подготовка → А → Б → В → Г → Д → доп. → отчёт. Шаблон (В) делается **до** снапшотов (Г):
в шаблон не должны попасть тестовые файлы. Часть Е — расчёты на бумаге, готовый ход — в разделе 8;
её можно сделать в любой момент.

| Этап | Ориентир |
|---|---|
| Подготовка хоста | 30–60 мин (вместе со скачиванием образа) |
| А + демонстрация ошибки | 60–90 мин |
| Б | 30–40 мин |
| В | 40–60 мин |
| Г | 60–90 мин |
| Д | 30–40 мин |
| Е | 30 мин (проверить ход, перенести) |
| Доп. задание | 1–2 ч |
| Отчёт | 2–3 ч |

ВМ до защиты **не удалять**: на защите могут попросить изменить опцию и пересоздать ВМ (раздел 11).

**Логи** — как в ЛБ-3/ЛБ-4: всё, что было в терминале, сохраняется в `logs/`.

```bash
cd ~/lab6 && source lab6.env && mkdir -p logs
script -q -a logs/partA.typescript      # пишет весь терминал, включая ssh-сессии внутри ВМ; конец — exit
# … работа …
exit
# чистый текст для отчёта: убрать цвета, заголовки окна и \r
sed -E 's/\x1B\[[0-9;?]*[A-Za-z]//g; s/\x1B\][^\x07]*\x07//g; s/\r//g' logs/partA.typescript > logs/partA.log
```

Числа сразу заносить в `logs/measurements.md`. `deploy-vm.sh` сам дописывает времена развёртываний в
`logs/deploy-times.txt`.

---

## 2. Подготовка хоста Ubuntu

### 2.1. Перенести папку и проверить хост

```bash
# с Mac: scp -r ~/IdeaProjects/Lab6 <user>@<ubuntu>:~/lab6   (или git / флешка)
cd ~/lab6 && chmod +x scripts/*.sh scripts/*.py

lsb_release -ds; uname -r; nproc; free -h; df -h /var/lib/libvirt
grep -cE 'vmx|svm' /proc/cpuinfo        # > 0 — аппаратная виртуализация есть
```

Нужно: физический хост (или ВМ с вложенной виртуализацией), RAM ≥ 8 ГБ (две ВМ по 1,75 ГиБ одновременно),
свободно ≥ 30 ГБ в `/var/lib/libvirt` (+15 ГБ, если в Д делать полностью размеченный raw).

### 2.2. Пакеты и права

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst libosinfo-bin \
  cloud-image-utils qemu-utils libguestfs-tools cpu-checker python3-yaml ipcalc conntrack tcpdump
kvm-ok                                    # "KVM acceleration can be used"
sudo usermod -aG libvirt,kvm "$USER"      # перелогиниться (или: newgrp libvirt)
virt-host-validate qemu                   # FAIL быть не должно; WARN про IOMMU не мешает

source lab6.env
virsh version                             # версии libvirt и QEMU — в отчёт (раздел «платформа»)
osinfo-query os | grep -i ubuntu2         # есть ubuntu24.04? Если нет — поправить OS_VARIANT в lab6.env
```

| Пакет | Зачем |
|---|---|
| `qemu-kvm`, `libvirt-daemon-system`, `libvirt-clients`, `virtinst` | гипервизор, демон libvirt, `virsh`, `virt-install` |
| `cloud-image-utils` | `cloud-localds` — собирает NoCloud seed-ISO с меткой `cidata` |
| `qemu-utils` | `qemu-img` (часть Д и вообще все диски) |
| `libguestfs-tools` | `virt-sysprep` (шаблон), `virt-cat`/`virt-ls` (чтение диска ВМ без входа в неё) |
| `python3-yaml` | проверка синтаксиса YAML в `deploy-vm.sh` до запуска ВМ |
| `ipcalc`, `conntrack`, `tcpdump` | проверка адреса и NAT (часть Б), как в ЛБ-3/ЛБ-4 |

`lab6.env` выставляет `LIBVIRT_DEFAULT_URI=qemu:///system`. Без этого `virsh` от обычного пользователя
работает с `qemu:///session` и «не видит» ни ВМ, ни сеть.

### 2.3. SSH-ключ

```bash
ssh-keygen -t ed25519 -f ~/.ssh/lab6_stud18 -C "stud-18@lab6"
cat ~/.ssh/lab6_stud18.pub
# подставить публичный ключ во все user-data вместо заглушки
sed -i "s|ssh-ed25519 AAAA.*REPLACE.*|$(cat ~/.ssh/lab6_stud18.pub)|" cloud-init/*/user-data
grep -n 'ssh-ed25519' cloud-init/*/user-data
```

Приватный ключ `~/.ssh/lab6_stud18` в отчёт не попадает никогда; публичный можно сократить:
`ssh-ed25519 AAAAC3Nz…Xy9 stud-18@lab6`.

Добавить в `~/.ssh/config` (короткие имена для ВМ и отдельный known_hosts: ВМ будут пересоздаваться с
новыми ключами хоста, а старые записи удаляет `deploy-vm.sh`):

```bash
cat >> ~/.ssh/config <<'EOF'

# ЛБ-6: ВМ в сети libvirt lab6 (10.97.2.96/27)
Host vm-18-63 vm-18-63-2 svc-18-63-1 svc-18-63-2
    User stud-18
    IdentityFile ~/.ssh/lab6_stud18
    IdentitiesOnly yes
    UserKnownHostsFile ~/.ssh/known_hosts_lab6
    StrictHostKeyChecking accept-new
Host vm-18-63
    HostName 10.97.2.118
Host vm-18-63-2
    HostName 10.97.2.119
Host svc-18-63-1
    HostName 10.97.2.120
Host svc-18-63-2
    HostName 10.97.2.121
EOF
```

### 2.4. Сеть libvirt по плану ЛБ-3

```bash
cat libvirt/lab6-net.xml                  # прочитать комментарии
virsh net-define libvirt/lab6-net.xml
virsh net-start lab6
virsh net-autostart lab6
virsh net-list --all
virsh net-dumpxml lab6                    # libvirt дописал uuid и MAC моста
ip -br addr show virbr-lab6               # 10.97.2.97/27 — это и есть шлюз ВМ
ip route | grep virbr-lab6                # 10.97.2.96/27 dev virbr-lab6 proto kernel scope link src 10.97.2.97 linkdown
```

`linkdown` до появления первой ВМ — норма: в мосту ещё нет ни одного порта.
Ошибка `Network is already in use by interface …` значит, что подсеть пересекается с чем-то на хосте (`ip route`).

### 2.5. Облачный образ Ubuntu 24.04

```bash
sudo mkdir -p $IMG/base && cd $IMG/base
sudo wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
sudo wget https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS            # noble-server-cloudimg-amd64.img: OK
qemu-img info noble-server-cloudimg-amd64.img        # qcow2, virtual size 3.5 GiB, disk size ≈ 600 MiB
cd ~/lab6
```

Уже здесь виден thin provisioning: виртуально 3,5 ГиБ, файл ≈ 0,6 ГиБ. Пригодится в части Д.
Если хост на ARM, нужен `…-arm64.img`, а UEFI ломает внутренние снапшоты. План написан под amd64.

---

## 3. Часть А. ВМ с cloud-init

### 3.1. Что и когда применяет cloud-init

NoCloud: при загрузке `ds-identify` находит диск с меткой `cidata` (наш seed-ISO) и читает с него
`meta-data`, `user-data`, `network-config`. Модули выполняются по стадиям (порядок из `/etc/cloud/cloud.cfg`):

| Стадия | Что выполняется из нашего конфига |
|---|---|
| init-local (до сети) | `network-config` → `/etc/netplan/50-cloud-init.yaml` |
| init | `write_files` (маркер), `growpart`/`resizefs` (корень до 15 ГиБ), `set_hostname`, `update_etc_hosts`, `users_groups` (stud-18, sudo), `ssh` (ключи хоста, `authorized_keys`) |
| config | `runcmd` — только записывает скрипт `/var/lib/cloud/instance/scripts/runcmd` |
| final | `package_update_upgrade_install` (apt), `scripts_user` (выполняет runcmd), `final_message` |

Поэтому `write_files` пишет маркер раньше, чем создан пользователь (владелец — root), а `runcmd` запускает
qemu-guest-agent уже после установки пакетов.

Ресурсы ВМ (3 vCPU, 1792 МиБ, 15 ГиБ) — параметры гипервизора: `virt-install --vcpus/--memory` и
`qemu-img resize`. cloud-init только растягивает раздел и ФС до размера диска.

### 3.2. Развёртывание

```bash
cd ~/lab6 && source lab6.env
script -q -a logs/partA.typescript
scripts/deploy-vm.sh vm-18-63 base
```

Во втором терминале — загрузка вживую (выход — `Ctrl+]`):

```bash
source ~/lab6/lab6.env; virsh console vm-18-63
```

В консоли видны таблицы `ci-info` с сетью, отпечатки ключей хоста
(`-----BEGIN SSH HOST KEY FINGERPRINTS-----`) и `final_message`. Отпечаток можно сверить с тем, что
спросит ssh при первом входе: так проверяют, что подключаешься к своей ВМ.

Что делает `deploy-vm.sh vm-18-63 base`:

1. Проверяет, что ключ подставлен, ВМ ещё нет и YAML всех трёх файлов разбирается.
2. Копирует облачный образ в `$IMG/vm-18-63.qcow2` и растягивает до 15 ГиБ (`qemu-img resize`).
3. Собирает `$IMG/seed-vm-18-63.iso` (`cloud-localds -N network-config seed.iso user-data meta-data`).
4. Запускает `virt-install --import`: 3 vCPU, 1792 МиБ, диск virtio с `cache=none` (замеры в Г — по диску,
   а не по RAM хоста), seed как CD-ROM, сеть `lab6`, канал qemu-guest-agent, серийная консоль.
5. Ждёт SSH, затем `cloud-init status --wait --long`.
6. Извлекает seed-ISO из привода: ISO имеет формат raw, и с ним libvirt откажет во внутренних снапшотах
   (`internal snapshot for disk sda unsupported for storage type raw`).
7. Пишет времена этапов в `logs/deploy-times.txt`.

### 3.3. Проверки для отчёта

Первый вход — полной командой, это и есть «вход по SSH под USER»:

```bash
ssh -i ~/.ssh/lab6_stud18 stud-18@10.97.2.118
hostname; hostnamectl | head -3
id                                  # groups=…(sudo),…(adm)
sudo -l | tail -2                   # (ALL) NOPASSWD: ALL
cat /etc/lab6-owner                 # ФИО, группа, вариант + «Дата первого старта: …»
cloud-init status --long            # status: done, detail: DataSourceNoCloud [seed=/dev/sr0]
nproc; free -m; lsblk; df -h /      # 3 CPU, ~1.7 ГиБ, vda 15G, корень растянут (growpart)
dpkg -l qemu-guest-agent tcpdump traceroute | tail -3
systemctl is-active qemu-guest-agent
exit
```

С хоста:

```bash
virsh dominfo vm-18-63                     # CPU(s): 3, Max memory: 1835008 KiB = 1792 МиБ
virsh domblkinfo vm-18-63 vda --human      # Capacity 15 GiB, Allocation ≈ 2–3 GiB — тонкий диск
virsh domifaddr vm-18-63 --source agent    # адрес глазами гостевого агента
```

`cloud-init status` снимать **до первой перезагрузки**: seed уже извлечён, и после перезагрузки
cloud-init не найдёт источник и будет `disabled`. Логи при этом остаются.

### 3.4. Где искать, если что-то не применилось

```bash
cloud-init status --long                          # extended_status: done / degraded done / error, recoverable_errors
sudo cloud-init schema --system --annotate        # проверка user-data и network-config по схеме, с номерами строк
sudo grep -nE 'WARNING|ERROR|Traceback' /var/log/cloud-init.log | head
sudo tail -n 30 /var/log/cloud-init-output.log    # вывод apt, runcmd и final_message
cloud-init analyze blame | head                   # сколько секунд занял каждый модуль
ls /var/lib/cloud/instance/                       # user-data.txt, scripts/runcmd, boot-finished
cat /etc/netplan/50-cloud-init.yaml               # что cloud-init сделал из network-config
```

| Файл | Что в нём |
|---|---|
| `/var/log/cloud-init.log` | подробный журнал: какой модуль, с каким конфигом, ошибки и трассировки |
| `/var/log/cloud-init-output.log` | stdout/stderr модулей: apt, runcmd |
| `/run/cloud-init/result.json`, `status.json` | итог текущей загрузки |
| `/var/lib/cloud/instance/` | что получено от источника и что сгенерировано (скрипт runcmd) |

### 3.5. Демонстрация диагностики (рекомендую, даже если всё заработало сразу)

Условие требует показать путь «нашёл → исправил → перезапустил», если что-то не применилось. Если ошибок
не было, честно делаю **намеренную** и так и пишу в отчёте.

```bash
cp -r cloud-init/vm-18-63 /tmp/vm-18-63.good                      # исправная копия
sed -i 's/^write_files:/write_file:/' cloud-init/vm-18-63/user-data
scripts/destroy-vm.sh vm-18-63
scripts/deploy-vm.sh vm-18-63 base 2>&1 | tee logs/A-broken.log    # YAML валиден, ошибка — в схеме
```

Ожидаемая картина:

- `cat /etc/lab6-owner` — в маркере **только** строка «Дата первого старта»: ФИО нет. Файл создал `runcmd`
  своим `>>`, `write_files` не сработал.
- `cloud-init status --long` → `extended_status: degraded done`, в `recoverable_errors` — предупреждение о
  невалидном cloud-config.
- `sudo cloud-init schema --system --annotate` → у строки `write_file:` пометка
  `Additional properties are not allowed ('write_file' was unexpected)`: в корне схемы cloud-config
  лишние ключи запрещены.
- `sudo grep -n "write_files" /var/log/cloud-init.log` →
  `Skipping modules 'write_files' because no applicable config is provided.`

Исправление и перезапуск:

```bash
cp /tmp/vm-18-63.good/user-data cloud-init/vm-18-63/user-data
scripts/destroy-vm.sh vm-18-63 && scripts/deploy-vm.sh vm-18-63 base 2>&1 | tee logs/A-fixed.log
```

Почему ВМ пересоздаётся, а не «перечитывает конфиг»: per-instance модули выполняются один раз на
instance-id. Новая ВМ — новый экземпляр (эфемерность). Альтернатива для любопытных: новый seed с другим
`instance-id` через `virsh change-media` и перезагрузка — cloud-init решит, что это новый экземпляр.

Ещё одна классическая ошибка, которую можно показать вместо первой: в `runcmd` строка
`- echo "Дата: $(date)" >> /etc/lab6-owner` без внешних кавычек. `: ` внутри делает её YAML-словарём,
`runcmd` падает с `Unable to shellify type 'dict'`, `status: error`.

### 3.6. Если SSH не поднялся — диагностика без входа в ВМ

- `virsh console vm-18-63` — сообщения загрузки и cloud-init, таблицы `ci-info` (какой адрес получил интерфейс).
- `sudo virt-cat -d vm-18-63 /var/log/cloud-init.log | grep -nE 'WARNING|ERROR|Traceback'` — чтение лога
  прямо с диска ВМ с хоста (libguestfs). Работает, даже когда пользователь не создан и войти нельзя.
- `sudo virt-cat -d vm-18-63 /etc/netplan/50-cloud-init.yaml` — что вышло из network-config.

### 3.7. В отчёт (А)

`user-data` (ключ сокращён), `meta-data`, `network-config`; строка из `logs/deploy-times.txt`; первый вход
по SSH, `hostname`, `cat /etc/lab6-owner`, `cloud-init status --long`; ресурсы (`virsh dominfo`, `lsblk`,
`free`); при ошибке — симптом → команда, которой нашёл → исправление → чистый прогон.

---

## 4. Часть Б. Сеть и связность

### 4.1. Внутри ВМ: адреса и маршруты

```bash
ssh vm-18-63
ip addr
ip route
ip neigh                              # шлюз .97 с MAC моста virbr-lab6 (после первого обращения)
resolvectl status | grep -E 'DNS Servers|DNS Domain'
networkctl status enp1s0 | head -15   # backend systemd-networkd, конфиг от netplan
ipcalc -n 10.97.2.118/27              # если нет: sudo apt install ipcalc (или на хосте)
```

Ожидаемые маршруты и что о них написать:

```text
default via 10.97.2.97 dev enp1s0 proto static
10.97.2.96/27 dev enp1s0 proto kernel scope link src 10.97.2.118
```

- `default via 10.97.2.97 … proto static` — маршрут по умолчанию (0.0.0.0/0) из `routes: to: default` в
  network-config. Его поставил systemd-networkd по конфигурации netplan (`proto static`). В ЛБ-4 такой же
  маршрут командой `ip route add` давал `proto boot`. Всё, для чего нет более длинного префикса (интернет,
  LAN хоста), уходит на 10.97.2.97, то есть на мост хоста.
- `10.97.2.96/27 … proto kernel scope link src 10.97.2.118` — connected-маршрут. Ядро создало его само,
  когда назначило адрес с маской /27. Соседи .97–.126 доступны напрямую через ARP, без шлюза; `src` — адрес
  источника. Шлюз .97 лежит в этой сети, иначе default был бы невалиден (как в ЛБ-4).

Строки `ip addr`, которые стоит разобрать:

- `link/ether 52:54:00:…` — префикс QEMU/KVM. 0x52 = 0101 0010: бит U/L = 1, адрес локально
  администрируемый, вендора нет (как у veth в ЛБ-3 Г.3).
- `inet 10.97.2.118/27 brd 10.97.2.127 scope global enp1s0` — адрес и маска из плана, broadcast .127.
- `inet6 fe80::5054:ff:fe…/64 scope link` — EUI-64 из MAC: 52 → 50 после инверсии бита U/L (как в ЛБ-3 Е.1).

**Совпадение с планом — часть оценки:** рядом в отчёте строка плана из раздела 0 и `ip addr`/`ipcalc`.

### 4.2. Связность и кто делает NAT

С хоста:

```bash
virsh domiflist vm-18-63                  # vnet0, источник — сеть lab6, модель virtio, MAC
ip -br link show master virbr-lab6        # vnet0 (tap ВМ) включён в мост — как veth в мосту Docker из ЛБ-3
ping -c 3 10.97.2.118                     # хост → ВМ
ssh vm-18-63 hostname                     # хост → ВМ по SSH
```

Из ВМ:

```bash
ping -c 3 10.97.2.97                      # ВМ → хост (адрес моста)
ping -c 3 <LAN-адрес хоста>               # тоже хост, его внешний интерфейс (ip -br a на хосте)
ping -c 3 1.1.1.1                         # ВМ → интернет (если ICMP режут — 8.8.8.8 или curl)
curl -sI https://ubuntu.com | head -1
traceroute -n -q 1 1.1.1.1 | head -5      # 1-й хоп 10.97.2.97, 2-й — домашний роутер
resolvectl query ubuntu.com               # DNS через dnsmasq libvirt
ping -c 2 vm-18-63-2                      # (после части В) имя → адрес через dnsmasq и search-домен
```

Кто делает NAT — ядро хоста (netfilter). Правило MASQUERADE поставил сетевой драйвер libvirt при
`virsh net-start lab6`, он же включил пересылку:

```bash
sysctl net.ipv4.ip_forward                                # = 1
sudo iptables -t nat -S | grep -iE 'masq|LIBVIRT'         # бэкенд iptables (libvirt ≤ 10.x)
sudo nft list ruleset | grep -n -i -B3 -A3 masquerade     # бэкенд nftables (новые libvirt)
sudo iptables -t nat -L LIBVIRT_PRT -n -v                 # счётчики растут после ping из ВМ
```

Доказательство подмены адреса — tcpdump с двух сторон, как в ЛБ-4:

```bash
UPLINK=$(ip route get 1.1.1.1 | grep -oP 'dev \K\S+')
sudo tcpdump -lnni virbr-lab6 -c 4 icmp and host 1.1.1.1 &
sudo tcpdump -lnni "$UPLINK"  -c 4 icmp and host 1.1.1.1 &
ssh vm-18-63 ping -c 2 1.1.1.1; wait
sudo conntrack -L -p icmp 2>/dev/null | grep 10.97.2.118
```

На `virbr-lab6` будет `10.97.2.118 > 1.1.1.1`, на аплинке — `<LAN-адрес хоста> > 1.1.1.1`. В conntrack —
`src=10.97.2.118 dst=1.1.1.1 … src=1.1.1.1 dst=<LAN-адрес хоста>`: ответ возвращается на адрес хоста, ядро
переписывает его обратно. Дальше домашний роутер делает второй NAT в публичный адрес провайдера (двойной NAT).

### 4.3. Письменно: ВМ и netns (5–7 предложений, своими словами)

Тезисы, из которых собрать текст:

- **Общее.** Изолированный сетевой стек: свои интерфейсы, адреса, таблица маршрутов (те же две строки:
  connected + default), ARP-таблица, свой `lo`. Подключение к хосту виртуальным «кабелем» (veth-пара ↔ tap
  `vnet0` + virtio-net) и мостом (`virbr-lab6` устроен как `br-…` Docker из вывода ЛБ-3), наружу — NAT хоста
  (MASQUERADE, как в ЛБ-4).
- **Отличия.**
  - netns — то же ядро хоста, изолирована только сеть, а процессы, ФС и пользователи общие. ВМ — своё ядро
    и полная ОС (systemd, sshd, свои пользователи и sudo).
  - У ВМ своё виртуальное железо: 3 vCPU, 1792 МиБ, диск 15 ГиБ, сетевая карта с MAC 52:54:00:…; у netns нет
    ни лимитов CPU/RAM, ни диска.
  - Состояние: ВМ хранит его в qcow2 — пакеты, файлы и настройки переживают перезагрузку хоста. netns живёт
    в памяти ядра и исчезает после `ip netns del` или перезагрузки: в ЛБ-3 стенд каждый раз пересоздавался
    скриптом.
  - Жизненный цикл: netns создаётся за миллисекунды; ВМ — define/start/shutdown/snapshot/clone, загрузка
    занимает десятки секунд (свой замер из В).
  - Изоляция и цена: граница аппаратной виртуализации (VT-x/AMD-V) прочнее, но ВМ резервирует 1,75 ГиБ RAM
    против почти нуля у netns.
  - Эфемерность: netns эфемерен по природе. ВМ становится «скотом, а не питомцем» только с шаблоном и
    cloud-init (часть В).
- **Где что в моём стеке ЛБ-2–ЛБ-5 (2–3 примера):**
  - Контейнеры: стенд ЛБ-2 (nginx + 2 экземпляра Kotlin-приложения + RabbitMQ + воркер) — stateless-сервисы
    на одном ядре, `docker compose up --scale` за секунды. Сетевые стенды ЛБ-3/ЛБ-4 на netns: миллисекунды
    на создание и удаление.
  - ВМ: сам Docker в ЛБ-2–ЛБ-4 жил внутри ВМ colima на macOS — ядро Linux пришлось взять у ВМ. Узлы
    PostgreSQL/Patroni из архитектуры ЛБ-2: свой диск, ядро и `sysctl`, изоляция от соседей. Учебные стенды,
    где нужна полная ОС (cloud-init, systemd, снапшоты — эта ЛБ).
  - На практике это комбинация: контейнеры внутри ВМ (узлы Kubernetes в облаке — ВМ).

---

## 5. Часть В. Шаблон и клон

### 5.1. Шаблон («золотой образ») из настроенной ВМ

Сама vm-18-63 остаётся нетронутой. Шаблон — очищенная копия её диска.

```bash
virsh shutdown vm-18-63
until [ "$(virsh domstate vm-18-63)" = "shut off" ]; do sleep 1; done

# 1. Копия только текущего состояния диска (без внутренних снапшотов, без пустых кластеров)
time sudo qemu-img convert -p -O qcow2 $IMG/vm-18-63.qcow2 $TPL_IMG

# 2. Очистка копии от «личности» экземпляра (sysprep)
sudo virt-sysprep -a $TPL_IMG \
  --operations machine-id,ssh-hostkeys,logfiles,bash-history,tmp-files,package-manager-cache,customize \
  --run-command 'cloud-init clean --logs --seed --configs network'

# 3. Шаблон только для чтения: от него будут зависеть linked-клоны
sudo chmod 0444 $TPL_IMG
qemu-img info $TPL_IMG

# проверка, что заморожено, а что вычищено
sudo virt-cat -a $TPL_IMG /etc/lab6-owner                     # маркер на месте
sudo virt-ls  -a $TPL_IMG /etc/ssh | grep -c ssh_host || true # 0 — ключей хоста нет
sudo virt-cat -a $TPL_IMG /etc/machine-id                     # пусто или "uninitialized"
sudo virt-ls  -a $TPL_IMG /etc/netplan                        # 50-cloud-init.yaml удалён

virsh start vm-18-63                                          # исходная ВМ работает как раньше
```

Если `cloud-init clean` в этой версии не знает `--configs`, заменить `--run-command` на
`--run-command 'cloud-init clean --logs --seed' --delete /etc/netplan/50-cloud-init.yaml`.
Список всех операций: `virt-sysprep --list-operations`.

| Заморожено в шаблоне (у всех клонов одинаково) | Сброшено, у каждого клона своё |
|---|---|
| Ubuntu 24.04, ядро, разметка (корень уже 15 ГиБ) | hostname и `/etc/hosts` — из user-data клона |
| пакеты qemu-guest-agent, tcpdump, traceroute, списки apt | сеть: netplan удалён, новый — из network-config клона |
| пользователь stud-18, правило sudo, `authorized_keys` | `machine-id` — systemd создаст при первой загрузке |
| маркер `/etc/lab6-owner` — с ФИО и датой первого старта **vm-18-63** | SSH host keys — сгенерирует cloud-init |
| | состояние cloud-init, логи, история bash, кэш apt, `/tmp` |
| | MAC и UUID ВМ — генерирует libvirt при `virt-install` |

Зачем чистить: два клона с одним `machine-id` получают одинаковый DHCP DUID (одна аренда на двоих) и
путаются в журналах. Одинаковые ключи хоста означают, что один утёкший ключ открывает все клоны для MITM.
Оставленный netplan с .118 даёт конфликт IP с оригиналом, если cloud-init на клоне не отработает. Удалить
netplan безопаснее: без seed клон останется без сети, но не займёт чужой адрес.

### 5.2. Вторая ВМ из шаблона и замер

```bash
cat cloud-init/vm-18-63-2/*                                         # hostname, .119, новый instance-id
scripts/deploy-vm.sh vm-18-63-2 linked 2>&1 | tee logs/V-clone.log
cat logs/deploy-times.txt                                           # сравнить с vm-18-63 (base)

ssh vm-18-63-2 'hostname; ip -br a; cat /etc/lab6-owner; cat /etc/machine-id; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'
ssh vm-18-63   'cat /etc/machine-id; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'
ssh vm-18-63-2 'ping -c 2 vm-18-63'                                 # клоны видят друг друга по имени

sudo qemu-img info -U --backing-chain $IMG/vm-18-63-2.qcow2         # overlay → backing file: шаблон
sudo du -h $IMG/vm-18-63-2.qcow2 $TPL_IMG $IMG/vm-18-63.qcow2
```

Ожидаемо: у клона другой hostname, адрес .119, другой `machine-id` и отпечаток ключа хоста. В маркере две
строки дат: «Дата первого старта» vm-18-63 (заморожена) и «Клон … первый старт».
Overlay клона в начале — единицы МБ, при работе растёт. Клон стартует быстрее: apt не работает, пакеты уже
в шаблоне.

Таблица времени (`logs/deploy-times.txt`, все отсчёты от начала):

| Развёртывание | диск | virt-install | SSH | cloud-init done |
|---|---|---|---|---|
| vm-18-63 из облачного образа + пакеты (А) | | | | |
| vm-18-63-2 из шаблона, linked clone (В) | | | | |

### 5.3. Linked vs full: цифры и риск

```bash
time sudo qemu-img create -f qcow2 -F qcow2 -b $TPL_IMG $IMG/linked-test.qcow2   # миллисекунды
time sudo qemu-img convert -p -O qcow2 $TPL_IMG $IMG/full-test.qcow2             # секунды: копируются все данные
sudo du -h $IMG/linked-test.qcow2 $IMG/full-test.qcow2
sudo rm $IMG/linked-test.qcow2 $IMG/full-test.qcow2
```

Риск linked-клона — опыт с «пропавшей» базой (базу только переименовываю, не удаляю!):

```bash
virsh shutdown vm-18-63-2; until [ "$(virsh domstate vm-18-63-2)" = "shut off" ]; do sleep 1; done
sudo mv $TPL_IMG $TPL_IMG.away
virsh start vm-18-63-2              # ошибка: Cannot access backing file '…/tpl-vm-18-63.qcow2' …
sudo mv $TPL_IMG.away $TPL_IMG
virsh start vm-18-63-2              # снова работает
```

Если переименовать базу при **работающем** клоне, он продолжит работать: QEMU держит открытый дескриптор.
Сломается он только при следующем старте — отказ отложенный и поэтому коварный.

### 5.4. Письменно

**(а) Ручная установка против шаблона** — оценка с обоснованием (свои числа подставить):

| Шаг вручную | Минут |
|---|---|
| Скачать ISO live-server (~3 ГБ при 100 Мбит/с) | 4–5 |
| Создать ВМ (virt-install `--cdrom` / virt-manager) | 2–3 |
| Установщик Subiquity: язык, сеть (статический IP руками), диск, пользователь, SSH | 5–10 (ручной ввод) |
| Копирование системы и обновления в установщике | 5–15 |
| Перезагрузка, вход, ключ, sudo NOPASSWD | 3–5 |
| apt install 3 пакетов, маркер, проверка | 2–4 |
| **Итого** | **≈ 20–40 мин**, из них 15+ мин — внимание человека |

Шаблон: T_clone секунд (замер) и ноль ручных шагов → выигрыш ≈ 1200 / T_clone … 2400 / T_clone раз.
Даже без шаблона облачный образ + cloud-init (T_A из А) быстрее ручной установки в десятки раз. Шаблон
убирает ещё и apt — отсюда разница T_A и T_clone. Плюс воспроизводимость: опечатку в IP руками сделать
можно, в файле — один раз и сразу видно.
Если есть 30 минут, ручную установку можно сделать по-настоящему (`virt-install --cdrom ubuntu-24.04.x-live-server-amd64.iso`)
и вписать реальные числа — это сильнее оценки.

**(б) Linked vs full clone в libvirt/QEMU** (по документации `qemu-img(1)`, раздел про backing files, и libvirt):

- Full clone (`virt-clone`, `qemu-img convert`, `cp`) — полная копия: независим от исходника, базу можно
  удалить. Стоит места (весь занятый объём) и времени (копирование всех данных).
- Linked clone = qcow2-overlay с backing file (`qemu-img create -b … -F qcow2`; в libvirt отдельной кнопки
  нет, в `virt-install` — `--disk …,backing_store=`). Создаётся мгновенно, занимает только дельту, общие
  блоки базы делят и место на диске, и page cache хоста. Экономит время развёртывания и место.
- Риски linked: удалили или переместили базу — все клоны не стартуют (опыт 5.3). Изменили базу (загрузили
  саму шаблонную ВМ, сделали `commit` в неё) — дельты клонов ссылаются на старые блоки, данные клонов
  молча портятся. Поэтому база только для чтения (`chmod 0444`, в Proxmox — флаг template). Чтение
  неизменённых данных идёт через цепочку, повреждение базы бьёт по всем клонам. Перенести клон отдельно
  нельзя, сначала нужно «сплющить»: `qemu-img convert` или `virsh blockpull`.

---

## 6. Часть Г. Снапшоты: польза и вред

### 6.0. Какие снапшоты делаем

В libvirt снапшот бывает:

- **внутренний** — внутри того же qcow2. Для работающей ВМ это диск + RAM («точка восстановления системы»);
- **внешний** (`--disk-only`) — новый файл-overlay поверх замороженного диска.

Во всей части Г — **внутренние**: откат работает в любой версии libvirt. Перед началом:

```bash
virsh domblklist vm-18-63         # у sda (CD-ROM) источник "-": seed извлечён, иначе снапшот не создастся
virsh snapshot-list vm-18-63      # пусто
```

После первого снапшота проверить тип:

```bash
virsh snapshot-dumpxml vm-18-63 g1-clean | grep -E "<state>|snapshot="
# ждём: <state>running</state>, <memory snapshot='internal'/>, <disk name='vda' snapshot='internal'/>
```

### 6.1. Г.1. Производительность до и после

Работаем на vm-18-63 (запущена после 5.1).

```bash
scp scripts/bench.sh vm-18-63:
ssh vm-18-63 ./bench.sh prepare                 # файл 1 ГиБ (кластеры qcow2 выделены), .deb nmap в кэше,
                                                # apt-daily/unattended-upgrades выключены — не мешают замерам
sudo du -h $IMG/vm-18-63.qcow2                  # размер до снапшота

# 1. базовый замер (снапшотов нет)
ssh vm-18-63 ./bench.sh run before | tee logs/G1-before.txt

# 2. снапшот
time virsh snapshot-create-as vm-18-63 g1-clean --description "Г.1: чистая ВМ" --atomic
virsh snapshot-list vm-18-63
sudo qemu-img snapshot -U -l $IMG/vm-18-63.qcow2   # VM SIZE — сколько заняло состояние RAM
sudo du -h $IMG/vm-18-63.qcow2

# 3. изменения: несколько файлов и новый пакет
ssh vm-18-63 'mkdir -p ~/after-snap && for i in 1 2 3 4 5; do head -c 20M /dev/urandom > ~/after-snap/f$i.bin; done;
              ls -la ~/after-snap; sudo apt-get install -y -qq mc && mc --version | head -1'

# 4. повторный замер при существующем снапшоте
ssh vm-18-63 ./bench.sh run after | tee logs/G1-after.txt
sudo du -h $IMG/vm-18-63.qcow2                    # файл вырос
```

Что меряет `bench.sh` и почему так (детали — в комментариях скрипта):

- **(а)** `dd` 1 ГиБ блоками 1 МиБ, `oflag=direct` (мимо кэша ОС ВМ) и `conv=notrunc,fsync` — запись в тот
  же файл и, значит, в те же кластеры qcow2. До снапшота это перезапись на месте. Три прогона.
- **(б)** установка `nmap` из локального кэша `.deb` (сеть не влияет), холодный кэш ОС перед каждой
  установкой. Три цикла install/purge, в конце пакет удалён.

Таблица в отчёт (`logs/measurements.md`): dd#1–3 (МБ/с), apt#1–3 (с) — «без снапшота / со снапшотом / Δ %»,
и размер `vm-18-63.qcow2` до снапшота, после снапшота и после замеров.

**Объяснение через COW (внутренний снапшот qcow2):**

- При снапшоте QEMU сохраняет копию таблицы L1 и увеличивает счётчик ссылок (refcount) всех занятых
  кластеров до 2. В тот же файл пишется состояние RAM — отсюда первый прирост размера.
- Запись в кластер с refcount > 1 — это copy-on-write. QEMU выделяет новый кластер в конце файла, пишет туда
  данные и обновляет L2-таблицу и refcount'ы. Это дополнительные записи метаданных со сбросами для
  порядка записи. Если кластер (64 КиБ) переписывается не целиком, сначала читаются старые данные
  (read-modify-write). Старый кластер остаётся за снапшотом.
- Ожидаемо: dd#1 после снапшота медленнее — 16 384 кластера файла выделяются заново. dd#2 и dd#3 снова как
  до снапшота: кластеры уже «свои» (refcount 1). apt — много мелких записей с fsync, частичная перезапись
  кластеров, поэтому относительное замедление сильнее. Файл qcow2 вырос примерно на 1 ГиБ: старые блоки
  держит снапшот.
- Если разницы почти нет — так и написать и объяснить: снапшот первый, цепочка короткая, диск быстрый
  (NVMe), запись целыми кластерами идёт без чтения. Замедление — тенденция длинных цепочек (внешние
  снапшоты: чтение проходит все overlay) и мелкой случайной записи, а не гарантия.

### 6.2. Г.2. Откат

```bash
date '+%T.%3N'; time virsh snapshot-revert vm-18-63 g1-clean; date '+%T.%3N'
virsh domstate vm-18-63                                   # running: память восстановлена вместе с диском
ssh vm-18-63 'ls -la ~/after-snap; dpkg -s mc 2>&1 | head -1; command -v mc || echo "mc нет"; cat /etc/lab6-owner'
virsh domtime vm-18-63 --pretty; date '+%F %T'           # часы ВМ «застряли» в моменте снапшота
virsh domtime vm-18-63 --now                             # синхронизировать (через qemu-guest-agent)
```

Ожидаемо: `ls: cannot access '/home/stud-18/after-snap'`, `package 'mc' is not installed`, маркер на месте.
Время отката — несколько секунд: читается сохранённая RAM. Старые ssh-сессии после отката мертвы: TCP-
состояние в ВМ «из прошлого».

### 6.3. Г.3. «Опасный» сценарий: псевдо-БД

`pseudo_db.py` пишет каждую запись в два файла:

- `fsync.log` — как СУБД с журналом: write → flush → fsync, и только потом ответ клиенту;
- `buffered.log` — как наивное приложение: буфер Python 8 КиБ, без fsync.

«Ответ клиенту» (ACK) уходит в stdout. Процесс запускаю по SSH с хоста, stdout сохраняется в файл **на
хосте**, и откат ВМ его не трогает. Три терминала на хосте, в каждом `cd ~/lab6 && source lab6.env`.

**Терминал 1 — запуск:**

```bash
scp scripts/pseudo_db.py vm-18-63:
ssh vm-18-63 'sudo install -d -o stud-18 -g stud-18 /var/lib/pseudodb'
ssh vm-18-63 'python3 -u ~/pseudo_db.py --dir /var/lib/pseudodb --rate 20' | tee logs/G3-acks.txt
```

**Терминал 2 — хронология и снапшот:**

```bash
mark() { echo "$(date '+%T.%3N')  $*  | последний ACK на хосте: $(tail -n1 logs/G3-acks.txt)" | tee -a logs/G3-timeline.txt; }
sleep 60                                            # пусть поработает
ssh vm-18-63 'sysctl vm.dirty_writeback_centisecs vm.dirty_expire_centisecs; grep -E "^(Dirty|Writeback):" /proc/meminfo'
ssh vm-18-63 'echo "в page cache: $(wc -l < /var/lib/pseudodb/buffered.log) строк buffered"; tail -n1 /var/lib/pseudodb/fsync.log'
mark "t1: снапшот — начало"
time virsh snapshot-create-as vm-18-63 g3-live --description "Г.3: псевдо-БД работает"
mark "t1: снапшот — готово"
sleep 60                                            # данные «после снапшота»
mark "t2: останавливаю процесс"                     # и сразу Ctrl+C в терминале 1
ssh vm-18-63 'wc -l /var/lib/pseudodb/*.log; tail -n1 /var/lib/pseudodb/fsync.log'   # до отката всё на месте
```

Обратить внимание: во время `snapshot-create-as` ВМ стоит на паузе (сохраняется RAM). В `G3-acks.txt`
будет разрыв меток времени — клиент видел задержку ответа.

**Откат A — «только диск» (как дисковые снапшоты облака и бэкапы ВМ без агента):**

```bash
mark "откат A: начало"
time virsh snapshot-revert vm-18-63 g3-live --paused   # диск и RAM вернулись в t1, процессор стоит
virsh destroy vm-18-63                                  # «выдернули питание»: память t1 выброшена
virsh start vm-18-63
until ssh -o ConnectTimeout=2 vm-18-63 true 2>/dev/null; do sleep 1; done
mark "откат A: ВМ загрузилась с диска в состоянии t1"
ssh vm-18-63 'sudo dmesg | grep -iE "EXT4-fs.*(recover|orphan)";
              wc -l /var/lib/pseudodb/*.log; tail -n2 /var/lib/pseudodb/fsync.log;
              tail -c 300 /var/lib/pseudodb/buffered.log | cat -A | tail -n3'
```

Внутренний снапшот работающей ВМ хранит и диск, и RAM. Откат с `--paused` и сразу `destroy` оставляет от
снапшота **только диск** — ровно то, что было записано на виртуальный диск к моменту t1. Это эквивалент
отключения питания в t1: ext4 при загрузке воспроизводит журнал (`recovery complete` в dmesg).

**Откат B — полный, с памятью (дополнительно, 5 минут, сильный аргумент для таблицы «вредит»):**

```bash
mark "откат B: начало"
time virsh snapshot-revert vm-18-63 g3-live             # ВМ снова в t1 и сразу работает
virsh domtime vm-18-63 --pretty; date '+%F %T'          # часы ВМ отстают на (сейчас − t1)
ssh vm-18-63 'pgrep -af pseudo_db; tail -n3 /var/lib/pseudodb/fsync.log'   # процесс «воскрес»!
virsh domtime vm-18-63 --now; sleep 3
ssh vm-18-63 'tail -n3 /var/lib/pseudodb/fsync.log'     # номера N1+1… теперь с другим временем
grep -m1 "ACK $(printf '%07d' <N1+1>)" logs/G3-acks.txt  # та же запись в «старом будущем» у клиента
ssh vm-18-63 'pkill -f pseudo_db.py'
virsh snapshot-delete vm-18-63 g3-live; virsh snapshot-delete vm-18-63 g1-clean
```

Если `snapshot-revert` попросит `--force` — добавить: так libvirt подтверждает откат работающей ВМ.

Таблица в отчёт:

| Точка | Номер последней записи |
|---|---|
| ACK клиенту перед снапшотом (t1) | N1 |
| в page cache ВМ перед снапшотом (`wc -l buffered.log`) | N1 − a (a ≈ записи в буфере Python) |
| ACK клиенту при остановке (t2) | N2 |
| `fsync.log` после отката A | ≈ N1 |
| `buffered.log` после отката A | N1 − k (+ возможно оборванная строка — нет `$` в `cat -A`) |
| `fsync.log` после отката B | N1, затем процесс продолжил с N1+1, но с другими метками времени |

**Что объяснить:**

- Записи после t1 (N1+1…N2) потеряны при **любом** откате, хотя клиент получил на них ACK. Для БД это
  потерянные подтверждённые транзакции. Реплики их уже применили — рассинхрон.
- Записи из **кэша приложения** (буфер Python ~80 записей) не дошли до ядра — откат A их потерял.
- Записи из **кэша ОС** (dirty pages, сброс через 5–30 с по `dirty_writeback`/`dirty_expire`) ядро не
  успело записать на диск — откат A потерял и их, поэтому k ≫ a. Оборванная последняя строка — «рваная
  запись», которую приложение должно уметь отбросить (у СУБД это контрольные суммы страниц WAL).
- `fsync.log` в A цел до t1: fsync — граница, после которой данные на диске. Ровно поэтому СУБД
  подтверждает коммит только после fsync журнала.
- Откат B восстановил и кэши, процесс «ожил» и пишет **вторую версию истории** с теми же номерами.
  Клиенты и реплики помнят первую — split-brain в миниатюре (ЛБ-2, Г.2). Часы ВМ отстают.
- Почему снапшот диска — не консистентный бэкап живой БД: это в лучшем случае crash-consistent копия
  (как после отключения питания). Нет буферов СУБД и незакоммиченного, БД придётся делать crash recovery;
  если данные и WAL на разных дисках, снапшоты дисков не атомарны между собой. Правильно — средствами СУБД:
  `pg_dump`, `pg_basebackup` + архив WAL (PITR), `mysqldump --single-transaction`. Или снапшот с quiesce
  (`--quiesce` через qemu-guest-agent делает fsfreeze, это даёт консистентность ФС) плюс хуки СУБД
  `pg_backup_start/stop` для консистентности приложения.

### 6.4. Таблица «снапшот спасает / вредит» (своими словами, привязать к своим цифрам)

| Спасает | Вредит |
|---|---|
| Откат перед рискованным изменением (ядро, `/etc/fstab`, sudoers, netplan) — X с против переустановки (Г.2) | Откат живой БД: подтверждённые транзакции после снапшота потеряны, реплики рассинхронизированы (Г.3, N2 − N1 записей) |
| Чистая точка для тестов: прогнал, откатил — стенд идентичен (Г.1→Г.2: файлы и пакет исчезли, маркер на месте) | Снапшот без quiesce — «выдернули питание»: нет данных из кэшей ОС и приложения, рваная запись (Г.3, k записей) |
| Учебный или демо-стенд: вернуть эталон перед следующим занятием или защитой | COW: первая запись после снапшота медленнее (Г.1, −Y %), файл растёт (+Z ГиБ), длинные цепочки ещё медленнее, забытые снапшоты съедают хранилище |
| (ещё) Быстрый откат неудачного обновления stateless-узла (nginx, бэкенд без данных) | Откат с памятью — «машина времени»: часы ВМ отстают, TCP-сессии рвутся, процессы «воскресают» с устаревшим состоянием |
| | Ложное чувство бэкапа: снапшот лежит на том же хранилище; отказ диска или `virsh undefine --remove-all-storage` уничтожают и ВМ, и снапшоты |

---

## 7. Часть Д. Дисковая бухгалтерия: qemu-img

Всё на хосте Ubuntu. Данные пишем изнутри ВМ vm-18-63-2 (подключаем образ вторым диском).

```bash
# Д.1. тонкий образ виртуальным размером DISK = 15 ГиБ
sudo qemu-img create -f qcow2 $IMG/d-test.qcow2 15G
sudo qemu-img info $IMG/d-test.qcow2                 # virtual size: 15 GiB, disk size ≈ 200 KiB
sudo ls -lsh $IMG/d-test.qcow2

# Д.2. подключить к ВМ и записать данные изнутри
virsh attach-disk vm-18-63-2 $IMG/d-test.qcow2 vdb --driver qemu --subdriver qcow2 --targetbus virtio --live
ssh vm-18-63-2 'lsblk /dev/vdb;                                       # гость видит 15G
  sudo mkfs.ext4 -q -L dtest /dev/vdb && sudo mkdir -p /mnt/d && sudo mount /dev/vdb /mnt/d;
  sudo dd if=/dev/urandom of=/mnt/d/random-1G.bin bs=1M count=1024 status=progress;  # несжимаемое
  sudo cp -a /usr/share /mnt/d/usr-share;                                            # мелкие, сжимаемые
  sudo dd if=/dev/zero of=/mnt/d/zeros-512M.bin bs=1M count=512;                     # нули — тоже «данные»
  sync; df -h /mnt/d; sudo du -sh /mnt/d/*; sudo umount /mnt/d'
virsh detach-disk vm-18-63-2 vdb --live

# Д.3. виртуальный vs фактический размер
sudo qemu-img info $IMG/d-test.qcow2                 # virtual 15 GiB, disk size ≈ 2 GiB
sudo ls -lh $IMG/d-test.qcow2; sudo du -h $IMG/d-test.qcow2
sudo qemu-img check $IMG/d-test.qcow2                # "N/245760 = X% allocated" — 245 760 кластеров по 64 КиБ
sudo qemu-img map --output=human $IMG/d-test.qcow2 | head   # какие диапазоны гостя реально лежат в файле
```

**Откуда разница (Д.3).** Виртуальный размер — то, что видит гость (`lsblk`: 15G). Фактический — только
кластеры по 64 КиБ, в которые гость хоть раз писал: данные, метаданные ext4, нули из `zeros-512M.bin`
(QEMU по умолчанию не распознаёт нули, `detect-zeroes=off`). Плюс заголовок, таблицы L1/L2 и refcount.
Непрописанных областей в файле нет вообще: таблица L2 говорит «не выделено», и гость при чтении получает
нули. Файл растёт по мере записи. Удаление файлов в госте его не уменьшает, пока не включены
discard/`fstrim` или пока образ не пересобран через `qemu-img convert`.

```bash
# Д.4. qcow2 → raw → qcow2: размеры и время
cd $IMG
time sudo qemu-img convert -p -f qcow2 -O raw   d-test.qcow2 d-test.raw
time sudo qemu-img convert -p -f raw   -O qcow2 d-test.raw   d-test-back.qcow2
sudo qemu-img compare d-test.qcow2 d-test-back.qcow2          # Images are identical.
sudo ls -lh d-test*; sudo du -h d-test*
# опционально: raw без «дыр» — так raw выглядит без sparse-файлов (нужно 15 ГБ свободного места!)
time sudo qemu-img convert -p -S 0 -f qcow2 -O raw d-test.qcow2 d-test-full.raw
# опционально: сжатый qcow2
time sudo qemu-img convert -p -c -f qcow2 -O qcow2 d-test.qcow2 d-test-c.qcow2
sudo du -h d-test-full.raw d-test-c.qcow2
cd ~/lab6
```

| Файл | Формат | `ls -lh` (видимый) | `du -h` (реально) | Время конвертации |
|---|---|---|---|---|
| d-test.qcow2 | qcow2 | | | — |
| d-test.raw | raw (sparse) | 15G | | |
| d-test-back.qcow2 | qcow2 | | | |
| d-test-full.raw (опц.) | raw, `-S 0` | 15G | 15G | |
| d-test-c.qcow2 (опц.) | qcow2, сжатый | | | |

Ожидаемые наблюдения:

- raw по `ls` — 15G, по `du` — около 1,5 ГиБ. Это sparse-файл ФС хоста: тонкость обеспечивает уже ФС, а не
  формат. При копировании через `scp`, на FAT/NTFS или в объектное хранилище он раздуется до 15 ГБ
  (`cp --sparse=always` и `rsync -S` дыры сохраняют).
- `d-test-back.qcow2` меньше исходного примерно на 512 МиБ: `convert` не пишет нулевые блоки.
- `-S 0` — полностью размеченный raw: занимает всё сразу, зато запись никогда не выделяет место.
- Сжатие почти не трогает `random-1G.bin` и заметно ужимает `/usr/share`.

**Письменно: когда какой формат.**

- **qcow2** — шаблоны и золотые образы, linked-клоны, внутренние снапшоты, стенды разработки,
  переполненное хранилище (overcommit), перенос по сети (компактен сам по себе), сжатие и шифрование.
- **raw** — продакшен с интенсивным I/O (БД), когда снапшоты и тонкость даёт слой хранения (LVM thin,
  Ceph RBD, ZFS, СХД). Максимальная и предсказуемая производительность, простота (`dd`, монтирование
  через loop), совместимость с любым гипервизором.
- **Чем qcow2 платит за компактность:**
  - косвенная адресация: гостевой адрес → L1 → L2 → кластер в файле; промах кэша L2 — лишнее чтение;
  - выделение при первой записи: обновление L2 и refcount со сбросами для порядка записи;
  - фрагментация: последовательный I/O гостя становится случайным на хосте;
  - COW при снапшотах (Г.1) и цепочки backing-файлов;
  - риск переполнения хранилища: тонкие образы «обещают» больше, чем есть на диске; при ENOSPC libvirt
    ставит ВМ на паузу с I/O error;
  - более сложное восстановление после сбоя (`qemu-img check -r`).
- Компромисс — qcow2 с `preallocation=metadata|falloc|full`: метаданные или место выделены заранее.

---

## 8. Часть Е. Серверный фундамент: расчёт (ход готов, сверить и перенести)

Сервер: 2 CPU × 10 ядер = **20 физических ядер** (40 потоков с HT), RAM **127 ГБ**,
полка **10 × 2 ТБ**. ВМ: **3 vCPU, 1792 МиБ = 1,75 ГиБ**.

### 8.1. Консолидация

Резерв под гипервизор (ОС хоста, потоки I/O QEMU, page cache): 2 ядра и 8 ГиБ RAM. Доступно 18 ядер и
119 ГиБ = 121 856 МиБ. RAM не переподписываем (overcommit памяти рискованнее: swap и OOM на хосте).

| | Пул vCPU | ВМ по CPU | ВМ по RAM | Итого | Узкое место |
|---|---|---|---|---|---|
| (а) 1:1 | 18 · 1 = 18 | 18 / 3 = **6** | 121 856 / 1792 = **68** | **6** | CPU |
| (б) 1:4 | 18 · 4 = 72 | 72 / 3 = **24** | 68 | **24** | CPU |
| для сравнения 1:2 | 36 | 12 | 68 | 12 | CPU |
| без резерва 1:1 / 1:4 | 20 / 80 | 6 / 26 | 130 048 / 1792 = 72 | 6 / 26 | CPU |

С учётом накладных расходов QEMU (~100 МиБ на ВМ) по RAM выходит 121 856 / 1892 ≈ 64 ВМ — всё равно
намного больше, чем по CPU.

**Почему 1:4 для веб-нагрузки учебного стенда.** Веб-узлы большую часть времени ждут сеть и БД, средняя
загрузка vCPU 10–25 %. При 1:4 и 15 % средней загрузки занято 24 · 3 · 0,15 ≈ 10,8 ядра из 18 (60 %) — есть
запас на пики. HT добавляет ещё 15–30 % пропускной способности (не ×2). Следить за steal time (`%st` в `top`
внутри ВМ, `virsh domstats --vcpu`): устойчиво выше 5–10 % — уменьшать коэффициент. Для продакшен-веба с
пиками — 1:2 (12 ВМ), для CPU-тяжёлых задач (сборки CI, БД) — 1:1.

**Узкое место — CPU, и это особенность варианта.** Обычно первой кончается RAM, но у этой ВМ на 1 vCPU
всего 1,75 / 3 = 0,58 ГиБ. Сервер даёт 119 / 18 = 6,6 ГиБ на ядро, при 1:4 — 1,65 ГиБ на vCPU. RAM стала бы
пределом только при коэффициенте 68 · 3 / 18 ≈ 11,3 : 1. Для сравнения, «типичная» ВМ 2 vCPU / 8 ГиБ упрётся
в RAM: 119 / 8 = 14 ВМ против 72 / 2 = 36 по CPU при 1:4. Вывод для закупки: под такой профиль ВМ этому
серверу не хватает ядер, а память при CPU-пределе загружена лишь на 6 · 1,75 / 119 ≈ 9 % (1:1) и
24 · 1,75 / 119 ≈ 35 % (1:4).

### 8.2. RAID

n = DISKN = 10, S = 2 ТБ, NEED = 9 ТБ. Обязательно — пережить отказ 1 диска. Желательно — пережить 2 **или**
иметь ≥ 9 ТБ.

| RAID | Ёмкость | Переживает | ≥ 9 ТБ | Вывод |
|---|---|---|---|---|
| 0 | 10 · 2 = 20 ТБ | 0 дисков | да | ✗ не выполняет обязательное |
| 1 | 2 ТБ (зеркало) | 1 | нет | ✗ ёмкость |
| 10 | 10 · 2 / 2 = 10 ТБ | 1 гарантированно; 2 — с вероятностью 8/9 ≈ 89 % | да (запас 1 ТБ) | возможен |
| 5 | (10 − 1) · 2 = 18 ТБ | 1 | да | возможен |
| **6** | (10 − 2) · 2 = **16 ТБ** | **любые 2** | **да (запас 7 ТБ)** | **выбор** |

- **Выбор — RAID 6:** выполняет обязательное условие и **оба** желательных сразу. 16 ТБ ≥ 9 ТБ, запас
  7 ТБ (×1,78). В двоичных единицах 16 · 10¹² / 2⁴⁰ ≈ 14,55 ТиБ против 9 ТБ ≈ 8,19 ТиБ — тоже с запасом.
- **Почему не RAID 5, хотя 18 ТБ.** Ребилд диска 2 ТБ занимает минимум 2 · 10¹² / 150 · 10⁶ ≈ 13 300 с ≈
  3,7 ч, под нагрузкой — 10–20 ч. Всё это время нужно прочитать 9 · 2 = 18 ТБ = 1,44 · 10¹⁴ бит без единой
  ошибки. При URE 10⁻¹⁴ (настольные диски) ожидается 1,44 ошибки, P(успех) = e^−1,44 ≈ 24 %. При 10⁻¹⁵
  (серверные) — 87 %. Второй отказ или URE во время ребилда убивают RAID 5.
- **Почему не RAID 10.** 10 ТБ проходит впритык, а два отказа переживает лишь в 8 из 9 случаев (второй
  диск может оказаться парой первого). Зато штраф записи у него 2 против 6 у RAID 6 — для тяжёлой БД я бы
  выбрал RAID 10.
- Вариант на практике: RAID 6 из 9 дисков + 1 hot spare: (9 − 2) · 2 = 14 ТБ ≥ 9 ТБ, и ребилд начинается
  сразу, без ожидания замены.

**Почему RAID не отменяет бэкапы (один аргумент с примером).** RAID защищает от отказа диска, но не от
логической ошибки: любое изменение он мгновенно и добросовестно размножает на все диски. Шифровальщик,
зашифровавший `/var/lib/libvirt/images`, или оператор, выполнивший `virsh undefine --remove-all-storage`
не на той ВМ, получат на RAID 6 идеально согласованную чётность — для уже зашифрованных или удалённых
данных. Вернуть вчерашнее состояние может только независимая копия: бэкап на другом хранилище, офлайн или
неизменяемый, с версиями (правило 3-2-1).

### 8.3. Tier ЦОД

| Элемент | Переживает? | Почему |
|---|---|---|
| Диск | да, 1–2 | RAID 6 |
| Блок питания | да, если в сервере 2 БП (N+1) | резерв внутри корпуса |
| Линия питания | только если БП разведены на независимые линии A/B | иначе одна линия — единая точка отказа |
| Короткое отключение электричества | при наличии ИБП — минуты | генератора нет |
| Материнская плата, CPU, контроллер RAID, модуль RAM | нет | ECC исправляет одиночные ошибки битов, но не отказ модуля |
| Ядро гипервизора (panic), обновление прошивки или ОС | нет | все ВМ простаивают: мигрировать некуда |
| Сеть: одна сетевая карта, один коммутатор, один аплинк | нет | нужен bonding в 2 ToR |
| Охлаждение, пожар, помещение | нет | одно помещение |

Итог — **Tier I**. Избыточность есть только у компонентов внутри коробки (диски, возможно БП), а сам
сервер, тракт питания, сеть и охлаждение — единственные. Обслуживание без остановки (критерий Tier III)
невозможно: любое обновление или замена платы — простой всех ВМ на часы или дни (ожидание запчасти).
Tier II требует резервирования компонентов питания и охлаждения площадки (N+1), а не только дисков.
Привязка к ЛБ-2: SLA 99,5 % (3,6 ч простоя в месяц) один сервер не гарантирует — замена материнской
платы съест бюджет за раз. Путь вверх: ≥ 2 хоста в кластере + общее или реплицируемое хранилище +
live migration + питание A/B + 2 ToR с LACP + ИБП и генератор.

---

## 9. Дополнительное задание (выбрать одно)

Рекомендую **вариант 1**, если ЛБ-5 готова: он продолжает то, что уже сделано (шаблон + cloud-init +
`deploy-vm.sh` с `READY_URL`). Папка `Lab5` на Mac пустая, поэтому ниже каркас — после ответа про ЛБ-5
допишу конкретные файлы.

### Вариант 1. «Пайплайн стенда»: шаблон → готовый узел nginx + бэкенд

1. `cloud-init/svc-18-63-1/` и `cloud-init/svc-18-63-2/`: `meta-data` (свой instance-id, hostname),
   `network-config` (.120 / .121), `user-data`:

   ```yaml
   #cloud-config
   hostname: svc-18-63-1
   users: [ … как у клона … ]
   packages: [nginx]                       # + рантайм бэкенда из ЛБ-5 (python3 уже есть в образе)
   write_files:
     - path: /opt/lb5/app.py                # код бэкенда из ЛБ-5 (или jar — см. ниже)
       content: |
         …
     - path: /etc/systemd/system/lb5-backend.service
       content: |
         [Unit]
         Description=LB-5 backend
         After=network-online.target
         [Service]
         ExecStart=/usr/bin/python3 /opt/lb5/app.py --port <порт бэкенда из ЛБ-5>
         Restart=always
         [Install]
         WantedBy=multi-user.target
     - path: /etc/nginx/sites-available/lb5
       content: |
         server {
           listen <порт nginx из ЛБ-5>;
           location / { proxy_pass http://127.0.0.1:<порт бэкенда>; }
         }
   runcmd:
     - [ln, -sf, /etc/nginx/sites-available/lb5, /etc/nginx/sites-enabled/lb5]
     - [rm, -f, /etc/nginx/sites-enabled/default]
     - [systemctl, daemon-reload]
     - [systemctl, enable, --now, lb5-backend]
     - [systemctl, reload, nginx]
   ```

   Если бэкенд на Kotlin/JVM (как в ЛБ-2), собирать в ВМ долго. Проще положить jar на хост и раздать:
   `python3 -m http.server 8000 --bind 10.97.2.97 -d ~/lab6/artifacts`, а в `runcmd` выполнить
   `curl -fsSLo /opt/lb5/app.jar http://10.97.2.97:8000/app.jar`. При включённом ufw:
   `sudo ufw allow in on virbr-lab6 to any port 8000 proto tcp`.
2. Развернуть обе из шаблона и замерить «от шаблона до работающего сервиса»:

   ```bash
   READY_URL=http://10.97.2.120:<порт>/ scripts/deploy-vm.sh svc-18-63-1 linked
   READY_URL=http://10.97.2.121:<порт>/ scripts/deploy-vm.sh svc-18-63-2 linked
   ```

3. Проверка с другой ВМ: `ssh svc-18-63-2 curl -s http://svc-18-63-1:<порт>/` и наоборот.
4. RAM хоста: если 4 ВМ одновременно не помещаются — выключить vm-18-63 и vm-18-63-2 (`virsh shutdown`).

### Вариант 2. Переносимость: libvirt/qcow2 → VirtualBox (если ЛБ-5 не готова)

1. Выключить vm-18-63-2 и «сплющить» в независимый образ: `qemu-img convert -O vdi $IMG/vm-18-63-2.qcow2 vm.vdi`
   (или `-O vmdk`). Записать форматы, размеры и время.
2. KVM и VirtualBox на одном хосте не уживаются: остановить все ВМ libvirt и выгрузить модуль —
   `sudo modprobe -r kvm_intel` (или `kvm_amd`), иначе VirtualBox выдаст `VERR_VMX_IN_VMX_ROOT_MODE`.
3. ВМ в VirtualBox: Linux / Ubuntu 64, диск `vm.vdi` на SATA, NAT. Новый seed-ISO с DHCP-конфигом и новым
   instance-id подключить как CD.
4. Что проверить и задокументировать:
   - имя интерфейса: enp1s0 на q35 → enp0s3 в VirtualBox. `match: name: "en*"` переживает смену, привязка по
     MAC или имени — нет;
   - статический .118 в чужой сети NAT 10.0.2.0/24 бесполезен — чинит новый seed;
   - диск virtio → SATA (`/dev/vda` → `/dev/sda`): fstab и GRUB по LABEL/UUID переживают;
   - qemu-guest-agent без канала virtio-serial не стартует;
   - `machine-id` и ключи хоста — копии исходной ВМ: дубликат, если обе работают.
5. Вывод о vendor lock: формат диска конвертируется (`qemu-img`), cloud-init абстрагирует настройку. Но
   метаданные ВМ (domain XML ↔ .vbox), виртуальное железо, драйверы, внутренние снапшоты qcow2 и имена
   сетевых интерфейсов не переносятся как есть.

---

## 10. Отчёт `Черников_ЛБ6.md`: что откуда

Стиль — как в ЛБ-3/ЛБ-4: фрагменты логов без правок, пропуски «…», полные логи в `logs/`.

1. **Шапка:** ФИО, группа, N, G, таблица раздела 0, IP и обоснование выбора (двоичная проверка, ссылка на
   список свободных диапазонов ЛБ-3), новая строка плана.
2. **Платформа и почему:** Ubuntu + KVM/libvirt — на рабочем Mac ЛБ-3/ЛБ-4 шли внутри ВМ colima, полноценную
   ВМ с KVM там не поднять. KVM — гипервизор в ядре Linux (стек Proxmox и OpenStack). Сеть libvirt позволяет
   взять подсеть из своего плана (в Multipass статический адрес из своего плана задаётся с трудом).
   `qemu-img` и снапшоты qcow2 — родные. NoCloud seed-ISO показывает механику cloud-init руками.
   Версии из `virsh version`.
3. **А:** конфиги (ключ сокращён) → `deploy-times.txt` → вход, hostname, маркер, `cloud-init status` →
   демонстрация ошибки и исправленный прогон.
4. **Б:** `ip addr`, `ip route` с разбором строк; ping и SSH; NAT — правило, tcpdump с двух сторон,
   conntrack; текст ВМ vs netns + примеры.
5. **В:** команды шаблона, таблица «заморожено / сброшено», клон, таблица времени, linked vs full (цифры и
   опыт с базой), письменные (а) и (б).
6. **Г:** таблица замеров Г.1 + объяснение COW; Г.2 — вывод и время отката; Г.3 — хронология
   (`G3-timeline.txt`), таблица N1/N2/k, объяснение кэшей; таблица «спасает / вредит».
7. **Д:** `qemu-img info` до и после, таблица размеров и времени, письменное «когда какой формат».
8. **Е:** раздел 8 с ходом.
9. **Доп. задание.**
10. **Вывод (5–7 предложений) + рефлексия** — своими словами. Что изменилось в понимании «сервера»;
    что сказать работодателю про стенд ЛБ-2 (физический сервер / ВМ / контейнеры); что понравилось,
    что удивило, что было трудно, чем пригодится в работе.

---

## 11. Подготовка к защите: изменить опцию на месте

Цикл «правка → новая ВМ» занимает 1,5–3 минуты:
`scripts/destroy-vm.sh vm-18-63 && scripts/deploy-vm.sh vm-18-63 base`.

| Просьба | Что править |
|---|---|
| Другой IP (например, .122) | `network-config: addresses`; при желании — `<host>` в `lab6-net.xml` и `HostName` в `~/.ssh/config` |
| Ещё один пакет | `user-data: packages` |
| Другое имя хоста | `user-data: hostname` и `meta-data: local-hostname` (+ имя в `deploy-vm.sh` = имя каталога) |
| Второй ключ или пользователь | `users[].ssh_authorized_keys` / ещё один элемент `users` |
| Другие права или владелец маркера | `write_files: permissions/owner` (для владельца stud-18 — `defer: true`: файл пишется после создания пользователя) |
| Команда при старте | `runcmd` (список-форма — без проблем с кавычками и `: `) |
| Больше vCPU или RAM | `VCPU`/`RAM_MB` в `lab6.env` (это гипервизор, не cloud-init) |

Вопросы, к которым стоит быть готовым: почему cloud-init не применяет изменения на существующей ВМ
(instance-id); где лежат логи; почему `write_files` раньше `users_groups`; почему шлюз .97 и кто делает
NAT; что «заморожено» в шаблоне; чем internal-снапшот отличается от external; почему откат A потерял больше
записей, чем было в буфере Python.

---

## 12. Если что-то пошло не так

| Симптом | Причина → что делать |
|---|---|
| `virsh list --all` пуст, сети `lab6` «нет» | не выполнен `source lab6.env` → `qemu:///session` вместо `qemu:///system` |
| `net-start`: `Network is already in use by interface …` | подсеть пересекается с чем-то на хосте (`ip route`) |
| `virt-install`: `Unknown OS name` | `osinfo-query os`, поставить `OS_VARIANT=ubuntu22.04` или `linux2022` |
| `virt-install`: ошибка в `--channel` | старый virtinst: `--channel unix,target_type=virtio,name=org.qemu.guest_agent.0` |
| SSH не поднимается | `virsh console`; `sudo virt-cat -d <ВМ> /var/log/cloud-init.log`; проверить network-config (адрес, шлюз, `match`) |
| `Permission denied (publickey)` | ключ не подставлен или user-data не разобрался → пользователь не создан; `virt-cat … /home/stud-18/.ssh/authorized_keys` |
| ВМ пингует хост, но не интернет | на хосте Docker (FORWARD policy DROP) или ufw; при nftables-бэкенде libvirt: `sudo iptables -I DOCKER-USER -i virbr-lab6 -j ACCEPT; sudo iptables -I DOCKER-USER -o virbr-lab6 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT` или `firewall_backend = "iptables"` в `/etc/libvirt/network.conf` + перезапуск libvirtd |
| Адрес есть, имена не резолвятся | `resolvectl status`; ufw режет 53/udp на `virbr-lab6` |
| apt «Waiting for cache lock» | работает apt-daily или unattended-upgrades: подождать (`bench.sh prepare` их выключает) |
| `internal snapshot for disk sda unsupported for storage type raw` | seed-ISO в приводе: `virsh change-media vm-18-63 sda --eject --live --config` |
| `internal snapshots … pflash … not supported` | ВМ создана с UEFI — пересоздать без `--boot uefi` |
| Откат на внутренний снапшот падает на libvirt 11.2–11.3 | известная регрессия, исправлена в 11.4 (`virsh version`) |
| `virt-sysprep`/`virt-cat`: supermin не может прочитать ядро | запускать через `sudo` |
| `qemu-img: Failed to get shared "write" lock` | образ открыт работающей ВМ: `-U` (только для info/snapshot -l/map) или выключить ВМ |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` | ВМ пересоздана: `ssh-keygen -R 10.97.2.118 -f ~/.ssh/known_hosts_lab6` |

---

## 13. Уборка (после защиты)

```bash
cd ~/lab6 && source lab6.env
for vm in svc-18-63-1 svc-18-63-2 vm-18-63-2 vm-18-63; do scripts/destroy-vm.sh $vm; done
virsh net-destroy lab6; virsh net-undefine lab6
sudo rm -rf $IMG                              # базовый образ, шаблон, d-test*
rm -f ~/.ssh/known_hosts_lab6                 # блок «ЛБ-6» из ~/.ssh/config удалить вручную
```

Порядок важен: сначала linked-клоны, потом шаблон.

---

## 14. Открытые вопросы (от ответов зависит часть плана)

1. **ЛБ-5:** сделана ли и где код (nginx + бэкенд, порты)? От этого зависит выбор доп. задания.
2. **Хост Ubuntu:** версия (`lsb_release -ds`), RAM, свободное место, стоят ли Docker и ufw (раздел 12).
3. **IP:** оставляем 10.97.2.118/27 или берём 10.97.3.118/24?
