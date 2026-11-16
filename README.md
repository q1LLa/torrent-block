# torrent-block

Блокировка BitTorrent-трафика на Ubuntu через xtables-addons (модуль `xt_ipp2p`) с резервными правилами по сигнатурам (`-m string`). Подходит для VPN-нод, в том числе Remnawave Node (`network_mode: host`).

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/q1LLa/torrent-block/main/install.sh | sudo bash
```

## Что делает скрипт

- ставит `xtables-addons-common`, `xtables-addons-dkms`, заголовки текущего ядра и метапакет заголовков (чтобы модуль пересобирался после обновления ядра);
- создаёт цепочку `TORRENT_BLOCK` и подключает её к `INPUT`, `OUTPUT` и `FORWARD` (IPv4 и IPv6);
- добавляет сервис `torrent-block.service`, который восстанавливает правила после перезагрузки.

## Управление

```bash
torrent-block status   # правила и счётчики пакетов
torrent-block remove   # временно снять правила (до перезагрузки)
torrent-block apply    # применить снова
```

## Удаление

```bash
curl -fsSL https://raw.githubusercontent.com/q1LLa/torrent-block/main/install.sh | sudo bash -s -- uninstall
```

## Ограничения

- Блокируется только нешифрованный BitTorrent. Клиенты с принудительным шифрованием и HTTPS-трекеры могут проходить.
- Ставить нужно на выходные ноды: на входной ноде каскада трафик уже зашифрован.
- Если метапакет заголовков поставить не удалось, после обновления ядра модуль не соберётся; останутся только правила по сигнатурам, пока скрипт не запустят повторно.
