#!/usr/bin/env bash
#
# Блокировка BitTorrent-трафика на Ubuntu через xtables-addons (модуль xt_ipp2p).
#
# Установка:
#   curl -fsSL https://raw.githubusercontent.com/q1LLa/torrent-block/main/install.sh | sudo bash
# Удаление:
#   curl -fsSL https://raw.githubusercontent.com/q1LLa/torrent-block/main/install.sh | sudo bash -s -- uninstall
#
# После установки:
#   torrent-block status   - показать правила и счётчики
#   torrent-block remove   - временно снять правила (до перезагрузки)
#   torrent-block apply    - применить снова

set -euo pipefail

BIN=/usr/local/sbin/torrent-block
UNIT=/etc/systemd/system/torrent-block.service

log()  { echo -e "\e[32m[+]\e[0m $*"; }
warn() { echo -e "\e[33m[!]\e[0m $*" >&2; }
die()  { echo -e "\e[31m[x]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите от root (sudo)."

# ---------- удаление ----------
if [[ "${1:-}" == "uninstall" ]]; then
    [[ -x $BIN ]] && "$BIN" remove || true
    systemctl disable --now torrent-block.service 2>/dev/null || true
    rm -f "$UNIT" "$BIN"
    systemctl daemon-reload
    log "Блокировка торрентов удалена (пакеты xtables-addons оставлены)."
    exit 0
fi

# ---------- пакеты ----------
command -v apt-get >/dev/null || die "Скрипт рассчитан на Ubuntu/Debian (нужен apt)."
export DEBIAN_FRONTEND=noninteractive

log "Устанавливаю пакеты..."
apt-get update -qq
apt-get install -y -qq iptables kmod xtables-addons-common

# Заголовки ядра нужны, чтобы DKMS собрал модуль под текущее ядро.
if ! apt-get install -y -qq "linux-headers-$(uname -r)"; then
    warn "Не нашлись заголовки для ядра $(uname -r)."
    warn "Обычно помогает: apt full-upgrade && reboot, затем запустить скрипт ещё раз."
fi

# Метапакет заголовков: с ним заголовки приходят вместе с каждым новым ядром,
# и DKMS сам пересобирает модуль после обновления ядра.
KERNEL_FLAVOR="$(uname -r | sed 's/.*-//')"
if ! apt-get install -y -qq "linux-headers-${KERNEL_FLAVOR}"; then
    warn "Не удалось поставить метапакет linux-headers-${KERNEL_FLAVOR}."
    warn "После обновления ядра модуль может не собраться - тогда запустите скрипт ещё раз."
fi

apt-get install -y -qq xtables-addons-dkms || warn "xtables-addons-dkms установился с ошибкой."

depmod -a
if modprobe xt_ipp2p 2>/dev/null; then
    log "Модуль xt_ipp2p загружен."
else
    warn "Модуль xt_ipp2p не загрузился (проверьте: dkms status)."
    warn "Будут работать только резервные правила по сигнатурам (-m string)."
fi

# ---------- управляющий скрипт ----------
log "Создаю $BIN"
cat > "$BIN" <<'EOF'
#!/usr/bin/env bash
# Управление правилами блокировки BitTorrent. Создан install.sh.
set -u

CHAIN=TORRENT_BLOCK
# INPUT/OUTPUT - трафик самого сервера (в т.ч. Xray и другие прокси в userspace),
# FORWARD - маршрутизируемый трафик (WireGuard, OpenVPN, NAT).
HOOKS=(INPUT OUTPUT FORWARD)

# Резервные сигнатуры на случай, если ipp2p что-то пропустит.
SIGNATURES=(
    "BitTorrent protocol"
    "d1:ad2:id20:"
    "info_hash="
    "announce_peer"
    "get_peers"
)

TOOLS=(iptables)
command -v ip6tables >/dev/null 2>&1 && TOOLS+=(ip6tables)

remove() {
    local ipt hook
    for ipt in "${TOOLS[@]}"; do
        for hook in "${HOOKS[@]}"; do
            while "$ipt" -w -D "$hook" -j "$CHAIN" 2>/dev/null; do :; done
        done
        "$ipt" -w -F "$CHAIN" 2>/dev/null
        "$ipt" -w -X "$CHAIN" 2>/dev/null
    done
    return 0
}

apply() {
    local ipt hook sig
    modprobe xt_ipp2p 2>/dev/null
    remove
    for ipt in "${TOOLS[@]}"; do
        "$ipt" -w -N "$CHAIN" || { echo "$ipt: не удалось создать цепочку" >&2; continue; }

        "$ipt" -w -A "$CHAIN" -m ipp2p --bit -j DROP 2>/dev/null \
            || echo "$ipt: ipp2p недоступен, остаются только сигнатуры" >&2

        for sig in "${SIGNATURES[@]}"; do
            "$ipt" -w -A "$CHAIN" -m string --algo bm --string "$sig" -j DROP
        done

        for hook in "${HOOKS[@]}"; do
            "$ipt" -w -I "$hook" 1 -j "$CHAIN"
        done
    done
}

status() {
    local ipt
    for ipt in "${TOOLS[@]}"; do
        echo "== $ipt =="
        "$ipt" -w -nvL "$CHAIN" 2>/dev/null || echo "правила не применены"
    done
}

case "${1:-}" in
    apply)  apply ;;
    remove) remove ;;
    status) status ;;
    *) echo "Использование: $0 {apply|remove|status}" >&2; exit 1 ;;
esac
EOF
chmod 755 "$BIN"

# ---------- автозапуск ----------
log "Создаю systemd-сервис"
cat > "$UNIT" <<EOF
[Unit]
Description=Block BitTorrent traffic (xtables-addons ipp2p)
After=network-pre.target docker.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN apply
ExecStop=$BIN remove

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable torrent-block.service >/dev/null 2>&1
systemctl restart torrent-block.service

log "Готово. Текущие правила:"
"$BIN" status
