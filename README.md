# YouTube Plus

Твик для iOS YouTube: **родное меню «Поделиться» (как в iOS) + копирование тайм-кодов.**

## Что делает

1. **Нативный iOS Share Sheet.** Заменяет кастомное меню «Поделиться» YouTube на системный
   `UIActivityViewController` — AirDrop, Сообщения, Копировать и т.д. с родными иконками.
   Заодно убирает трекинг-параметр `si` из ссылок.
2. **Копирование с тайм-кодом.** Добавляет в это же меню действие
   «Копировать ссылку с тайм-кодом», которое формирует
   `https://www.youtube.com/watch?v=<id>&t=<секунды>` по текущей позиции плеера.

## Как это работает

Твик по умолчанию внедряется в процесс `com.google.ios.youtube` (Logos/Theos). Он:
- перехватывает `YTShareEntityEndpointCommandHandler` — точку вызова штатного share-меню;
- берёт активную позицию воспроизведения из
  `YTMainAppVideoPlayerOverlayViewController` (`mediaTime` / `videoID`);
- показывает нативный `UIActivityViewController` с кастомной `UIActivity`
  (`YTCopyTimestampActivity`).

Реальные имена классов взяты из первоисточников:
- [`jkhsjdhjs/youtube-native-share`](https://github.com/jkhsjdhjs/youtube-native-share) — нативный share sheet (GPL-3.0)
- [`dayanch96/YTLite`](https://github.com/dayanch96/YTLite) — способ получения тайм-кода

## Сборка

Твик собирается на macOS через Theos (см. `.github/workflows/build.yml`):

```bash
git clone --recursive https://github.com/theos/theos ~/theos
export THEOS=~/theos
make package FINALPACKAGE=1        # → packages/*.deb + YouTubePlus.dylib
```

CI (GitHub Actions, `macos-latest`) на каждый push в `main` публикует артефакт
`YouTubePlus-tweak` (`.deb` + `.dylib`).

## Установка / сборка IPA

Репозиторий **не поставляет базовый YouTube.ipa** — его нужно снять (decrypted) со своего
устройства. Инъекция твика в ваш `.ipa`:

```bash
./scripts/inject-ipa.sh YouTube.ipa YouTubePlus.dylib YouTubePlus.ipa
```

Нужны `optool` или `insert_dylib` (`brew install optool`), опционально `ldid` для подписи.

## Статус

- [x] Замена share sheet на нативный (проверенный подход первоисточника)
- [x] Кастомное действие «Копировать с тайм-кодом»
- [x] CI-сборка `.deb`/`.dylib`
- [ ] Проверка на устройстве под конкретную версию YouTube (имена классов плеера
      версионно-зависимы — требуется валидация на живом приложении)

Лицензия производных частей: GPL-3.0-or-later (наследуется от youtube-native-share).
