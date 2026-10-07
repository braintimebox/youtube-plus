# YouTube Native Share Hybrid (Theos / Logos Tweak)

Кастомный твик для iOS YouTube, реализующий гибридное меню «Поделиться»:
1. **Нативный iOS Share Sheet** (интерфейс с системными иконками вместо громоздкого стандартного меню YouTube).
2. **Интеграция тайм-кодов**: автоматическое добавление параметров текущего времени воспроизведения (`&t=XXs`) при вызове шаринга из плеера, а также кастомная кнопка/действие «Копировать с тайм-кодом».

## Архитектура
Твик написан на Logos/Objective-C для внедрения в процесс приложения YouTube (`com.google.ios.youtube`).
- Перехватывает вызов `YTSharePanelViewController`.
- Извлекает текущее время из `YTPlayerViewController` / `ASCLController` (медиа-таймкоды).
- Формирует `UIActivityViewController` с кастомными активностями (`UIActivity`).
