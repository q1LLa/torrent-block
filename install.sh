#!/usr/bin/env bash
#
# Блокировка BitTorrent-трафика на Ubuntu (VPN-ноды, в т.ч. Remnawave Node).
#
# Два режима, выбираются автоматически:
#   1) штатное ядро Ubuntu  - модуль xt_ipp2p из xtables-addons + сигнатуры;
#   2) ядро, собранное clang (XanMod и т.п.) - только сигнатуры на встроенном
#      в ядро модуле xt_string. Сторонний модуль под такие ядра не собирается,
#      поэтому блокировка не ломается при обновлении ядра.
#
# Установка:
#   curl -fsSL https://raw.githubusercontent.com/q1LLa/torrent-block/main/install.sh | sudo bash
# Удаление:
#   curl -fsSL https://raw.githubusercontent.com/q1LLa/torrent-block/main/install.sh | sudo bash -s -- uninstall
#
# После установки:
#   torrent-block status   - режим, правила и счётчики
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
    log "Блокировка торрентов удалена (установленные пакеты оставлены)."
    exit 0
fi

# ---------- пакеты ----------
command -v apt-get >/dev/null || die "Скрипт рассчитан на Ubuntu/Debian (нужен apt)."
export DEBIAN_FRONTEND=noninteractive

# apt может вернуть ошибку, даже если нужное установилось, поэтому ошибки apt
# не прерывают скрипт - ниже проверяется фактический результат.
apt_install() {
    apt-get install -y -qq "$@" || warn "apt вернул ошибку при установке: $*"
}

pkg_present() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Eq 'installed|half|unpacked'
}

KERNEL="$(uname -r)"
KERNEL_FLAVOR="${KERNEL##*-}"

log "Ядро: ${KERNEL}"

if grep -qi 'clang' /proc/version; then
    # ---- режим 2: ядро собрано clang (XanMod) ----
    log "Ядро собрано clang (XanMod): модуль xt_ipp2p не собираю, использую сигнатуры."

    # Если пакет с DKMS-модулем остался от прошлых запусков, он не собирается
    # под это ядро и ломает каждую операцию apt - убираем его.
    if pkg_present xtables-addons-dkms; then
        log "Удаляю xtables-addons-dkms (не собирается под это ядро и ломает apt)..."
        apt-get purge -y -qq xtables-addons-dkms || warn "Не удалось удалить xtables-addons-dkms."
    fi

    apt-get update -qq || warn "apt-get update завершился с ошибкой."
    apt_install iptables kmod
else
    # ---- режим 1: штатное ядро, пробуем xt_ipp2p ----
    log "Устанавливаю пакеты..."
    apt-get update -qq || warn "apt-get update завершился с ошибкой."
    apt_install iptables kmod xtables-addons-common
    # Заголовки текущего ядра - чтобы DKMS собрал модуль под него.
    apt_install "linux-headers-${KERNEL}"
    # Метапакет заголовков - чтобы модуль пересобирался после обновления ядра.
    apt_install "linux-headers-${KERNEL_FLAVOR}"
    apt_install xtables-addons-dkms

    depmod -a
    if modprobe xt_ipp2p 2>/dev/null; then
        log "Модуль xt_ipp2p загружен."
    else
        warn "Модуль xt_ipp2p не загрузился (проверьте: dkms status)."
        warn "Будут работать только правила по сигнатурам."
    fi

    # Другие установленные ядра: предупредить, если под какое-то модуль не собран.
    for dir in /lib/modules/*/; do
        k="$(basename "$dir")"
        [[ "$k" == "$KERNEL" ]] && continue
        [[ -e "/boot/vmlinuz-$k" ]] || continue
        if ! compgen -G "${dir}updates/dkms/xt_ipp2p.ko*" >/dev/null; then
            warn "Под ядро $k модуль xt_ipp2p не собран: при загрузке в него"
            warn "останутся только правила по сигнатурам."
        fi
    done
fi

command -v iptables >/dev/null || die "iptables не установлен - продолжать нельзя."
modprobe xt_string 2>/dev/null || warn "Модуль xt_string не загрузился - правила по сигнатурам могут не примениться."

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

# Все сигнатуры BitTorrent находятся в начале пакета, поэтому проверяем только
# первые байты (считая от IP-заголовка) - это заметно снижает нагрузку на CPU.
SCAN_TO=512

# Текстовые сигнатуры (любой протокол).
SIGNATURES=(
    "BitTorrent protocol"   # рукопожатие между пирами (TCP и uTP)
    "d1:ad2:id20:"          # DHT: запрос
    "d1:rd2:id20:"          # DHT: ответ
    "info_hash="            # HTTP-трекер: announce/scrape
    "announce_peer"         # DHT
    "get_peers"             # DHT
    "find_node"             # DHT
    "d1:eli20"              # DHT: сообщение об ошибке
)

# Параметры HTTP-трекера: срабатывают только вместе с "GET /" в том же пакете
# (так же проверяет xt_ipp2p). passkey= используют приватные трекеры.
TCP_GET_SIGNATURES=(
    "peer_id="
    "passkey="
)

# Бинарные сигнатуры только для UDP.
UDP_HEX_SIGNATURES=(
    "|0000041727101980|"    # UDP-трекер: connect (protocol_id)
)

TOOLS=(iptables)
command -v ip6tables >/dev/null 2>&1 && TOOLS+=(ip6tables)

have_ipp2p() {
    modprobe xt_ipp2p 2>/dev/null
}

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
    local ipt hook sig ipp2p=0 failed=0
    have_ipp2p && ipp2p=1
    modprobe xt_string 2>/dev/null
    remove
    for ipt in "${TOOLS[@]}"; do
        "$ipt" -w -N "$CHAIN" || { echo "$ipt: не удалось создать цепочку" >&2; failed=1; continue; }

        if (( ipp2p )); then
            "$ipt" -w -A "$CHAIN" -m ipp2p --bit -j DROP 2>/dev/null \
                || echo "$ipt: правило ipp2p не добавилось, остаются сигнатуры" >&2
        fi

        for sig in "${SIGNATURES[@]}"; do
            "$ipt" -w -A "$CHAIN" -m string --algo bm --to "$SCAN_TO" --string "$sig" -j DROP \
                || { echo "$ipt: не добавилась сигнатура '$sig'" >&2; failed=1; }
        done
        for sig in "${TCP_GET_SIGNATURES[@]}"; do
            "$ipt" -w -A "$CHAIN" -p tcp \
                -m string --algo bm --to "$SCAN_TO" --string "GET /" \
                -m string --algo bm --to "$SCAN_TO" --string "$sig" -j DROP \
                || { echo "$ipt: не добавилась сигнатура 'GET / + $sig'" >&2; failed=1; }
        done
        for sig in "${UDP_HEX_SIGNATURES[@]}"; do
            "$ipt" -w -A "$CHAIN" -p udp -m string --algo bm --to "$SCAN_TO" --hex-string "$sig" -j DROP \
                || { echo "$ipt: не добавилась сигнатура '$sig'" >&2; failed=1; }
        done

        for hook in "${HOOKS[@]}"; do
            "$ipt" -w -I "$hook" 1 -j "$CHAIN" || failed=1
        done
    done
    return "$failed"
}

status() {
    local ipt
    echo "Ядро: $(uname -r)"
    if have_ipp2p; then
        echo "Режим: xt_ipp2p + сигнатуры"
    else
        echo "Режим: только сигнатуры (xt_string), модуль xt_ipp2p недоступен"
    fi
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
Description=Block BitTorrent traffic (ipp2p / string signatures)
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
if ! systemctl restart torrent-block.service; then
    warn "Сервис torrent-block завершился с ошибкой: journalctl -u torrent-block -n 30"
fi

log "Готово. Текущее состояние:"
"$BIN" status
