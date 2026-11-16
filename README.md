# torrent-block

Блокировка BitTorrent-трафика на Ubuntu для VPN-нод, в том числе Remnawave Node (`network_mode: host`).

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/q1LLa/torrent-block/main/install.sh | sudo bash
```

## Режимы

Режим выбирается автоматически по ядру:

| Ядро | Как блокируется |
|---|---|
| Штатное ядро Ubuntu | модуль `xt_ipp2p` из xtables-addons (DKMS) + сигнатуры |
| Ядро, собранное clang (XanMod) | только сигнатуры на встроенном модуле `xt_string` |

На XanMod сторонний модуль не собирается: xtables-addons отстаёт от свежих ядер и требует сборки через clang. Сигнатуры покрывают тот же нешифрованный BitTorrent и не ломаются при обновлении ядра.

## Что блокируется

- рукопожатие между пирами (`BitTorrent protocol`, TCP и uTP);
- DHT (запросы, ответы, `get_peers`, `announce_peer`, `find_node`);
- HTTP-трекеры (`info_hash=`);
- UDP-трекеры (запрос connect).

Правила лежат в цепочке `TORRENT_BLOCK`, подключённой к `INPUT`, `OUTPUT` и `FORWARD` (IPv4 и IPv6). Сервис `torrent-block.service` восстанавливает их после перезагрузки.

## Управление

```bash
torrent-block status   # режим, правила и счётчики пакетов
torrent-block remove   # временно снять правила (до перезагрузки)
torrent-block apply    # применить снова
```

## Удаление

```bash
curl -fsSL https://raw.githubusercontent.com/q1LLa/torrent-block/main/install.sh | sudo bash -s -- uninstall
```

## Ограничения

- Блокируется только нешифрованный BitTorrent. Клиенты с принудительным шифрованием протокола и HTTPS-трекеры могут проходить. Для них стоит дополнительно включить плагин Torrent Blocker в Remnawave или правило `protocol: bittorrent` в роутинге Xray.
- Ставить нужно на выходные ноды: на входной ноде каскада трафик уже зашифрован.
- На ядре, собранном clang, скрипт удаляет пакет `xtables-addons-dkms`, если он установлен: под такое ядро он не собирается и ломает `apt`.
