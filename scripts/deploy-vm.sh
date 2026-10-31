#!/usr/bin/env bash
# Развернуть ВМ libvirt с cloud-init (NoCloud seed-ISO) и замерить время этапов.
#
#   scripts/deploy-vm.sh <имя-ВМ> <base|linked|full>
#
#   base   — диск = копия облачного образа Ubuntu, растянутая до DISK_GB (часть А)
#   linked — диск = overlay поверх шаблона TPL_IMG, linked clone (часть В)
#   full   — диск = полная копия шаблона, full clone (часть В, для сравнения)
#
# Конфигурация cloud-init берётся из cloud-init/<имя-ВМ>/{user-data,meta-data,network-config}.
# Переменные окружения (необязательно):
#   READY_URL=http://10.97.2.120/   дождаться ответа сервиса (доп. задание)
#   SKIP_LINT=1                     не проверять YAML перед запуском (для намеренно сломанного user-data)
set -euo pipefail
cd "$(dirname "$0")/.."
source ./lab6.env

NAME=${1:?"имя ВМ, например vm-18-63"}
MODE=${2:?"base | linked | full"}
CI=cloud-init/$NAME
DISK=$IMG/$NAME.qcow2
SEED=$IMG/seed-$NAME.iso

for f in user-data meta-data network-config; do
  [[ -f $CI/$f ]] || { echo "нет файла $CI/$f"; exit 1; }
done
if grep -q REPLACE "$CI/user-data"; then
  echo "в $CI/user-data не подставлен публичный ключ (PLAN.md, шаг 2.4)"; exit 1
fi
if virsh dominfo "$NAME" >/dev/null 2>&1; then
  echo "ВМ $NAME уже есть. Пересоздать: scripts/destroy-vm.sh $NAME && scripts/deploy-vm.sh $NAME $MODE"
  exit 1
fi
# адрес ВМ — первый a.b.c.d/nn в network-config (комментарии отрезаем)
IP=$(sed 's/#.*//' "$CI/network-config" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | head -1 | cut -d/ -f1)

if [[ -z ${SKIP_LINT:-} ]]; then
  # синтаксис YAML — до запуска; схему модулей cloud-init проверим уже в ВМ (cloud-init schema)
  python3 - "$CI" <<'PY' || { echo "ошибка YAML (см. выше); намеренно сломанный файл — SKIP_LINT=1"; exit 1; }
import sys, yaml
for name in ("user-data", "meta-data", "network-config"):
    yaml.safe_load(open(f"{sys.argv[1]}/{name}", encoding="utf-8"))
print("YAML ok")
PY
fi

sudo -v                                   # спросить пароль sudo сейчас, а не внутри замера
now() { date +%s.%N; }
dt()  { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }

echo "== $NAME: диск ($MODE)"
t0=$(now)
case $MODE in
  base)   sudo cp "$BASE_IMG" "$DISK"
          sudo qemu-img resize -q "$DISK" "${DISK_GB}G" ;;
  linked) sudo qemu-img create -q -f qcow2 -F qcow2 -b "$TPL_IMG" "$DISK" ;;
  full)   sudo qemu-img convert -O qcow2 "$TPL_IMG" "$DISK" ;;
  *)      echo "режим: base | linked | full"; exit 1 ;;
esac
t_disk=$(now)

echo "== $NAME: seed-ISO (метка cidata) и virt-install"
sudo cloud-localds -N "$CI/network-config" "$SEED" "$CI/user-data" "$CI/meta-data"
virt-install \
  --name "$NAME" \
  --vcpus "$VCPU" \
  --memory "$RAM_MB" \
  --os-variant "$OS_VARIANT" \
  --import \
  --disk "path=$DISK,format=qcow2,bus=virtio,cache=none" \
  --disk "path=$SEED,device=cdrom" \
  --network "network=$NET,model=virtio" \
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole
t_start=$(now)

# ВМ с тем же IP могла существовать раньше с другими ключами хоста
ssh-keygen -R "$IP" -f ~/.ssh/known_hosts_lab6 >/dev/null 2>&1 || true
SSH=(ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=2
     -o UserKnownHostsFile="$HOME/.ssh/known_hosts_lab6" -o StrictHostKeyChecking=accept-new
     "$VM_USER@$IP")
echo "== $NAME: жду SSH на $IP (загрузку видно в virsh console $NAME)"
ok=
for _ in $(seq 300); do
  if "${SSH[@]}" true 2>/dev/null; then ok=1; break; fi
  sleep 1
done
if [[ -z $ok ]]; then
  echo "SSH не поднялся за 5 мин. Смотреть: virsh console $NAME;"
  echo "  sudo virt-cat -d $NAME /var/log/cloud-init.log | grep -nE 'WARNING|ERROR|Traceback'"
  exit 1
fi
t_ssh=$(now)

echo "== $NAME: жду окончания cloud-init"
"${SSH[@]}" 'cloud-init status --wait --long' ||
  echo "!!! cloud-init закончил с ошибками или предупреждениями: разбор — PLAN.md, А.5"
t_ci=$(now)

t_svc=
if [[ -n ${READY_URL:-} ]]; then
  echo "== $NAME: жду сервис $READY_URL"
  until curl -fsS -o /dev/null --max-time 2 "$READY_URL"; do sleep 1; done
  t_svc=$(now)
fi

# seed больше не нужен; с ISO (формат raw) в приводе libvirt откажется делать внутренние снапшоты
CD=$(virsh domblklist "$NAME" --details | awk '$2 == "cdrom" {print $3}')
virsh change-media "$NAME" "$CD" --eject --live --config >/dev/null && echo "seed-ISO извлечён ($CD)"

mkdir -p logs
{
  printf '%s  %-12s %-6s  от старта: диск %s с | virt-install %s с | SSH %s с | cloud-init %s с' \
    "$(date '+%F %T')" "$NAME" "$MODE" \
    "$(dt "$t0" "$t_disk")" "$(dt "$t0" "$t_start")" "$(dt "$t0" "$t_ssh")" "$(dt "$t0" "$t_ci")"
  [[ -n $t_svc ]] && printf ' | сервис %s с' "$(dt "$t0" "$t_svc")"
  printf '\n'
} | tee -a logs/deploy-times.txt
