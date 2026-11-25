# SnowfallMac 0.8.4 — надёжнее обнаружение Dock

- `dockSurfaceFrame`/`currentDockAXFrame` больше не отбраковывают Dock по жёстким
  пиксельным порогам (`maxY <= 220`, `height <= 180` и т.п.) — эти пороги оказались
  хрупкими на части Retina/4K экранов и при увеличенном размере значков Dock.
  Теперь панель распознаётся по форме и положению: заметно шире, чем выше, и
  центр по вертикали — в нижних 45% экрана.
- Пункт меню «Снег на Dock» теперь реально проверяет, что панель найдена
  (`dockSurfaceFrame`), а не только что разрешение включено — раньше он мог
  показывать «доступ разрешён», хотя снег на Dock всё равно не появлялся.
  При неудаче показывает короткую причину.
- Добавлен `scripts/create_dev_cert.sh`: один раз создаёт локальный стабильный
  сертификат для подписи кода. `build_app.sh` использует его автоматически, если
  он есть. Раньше ad-hoc подпись менялась при каждой пересборке, из-за чего
  macOS негласно сбрасывал разрешение на Dock в Универсальном доступе, хотя в
  Настройках оно продолжало выглядеть включённым.
- Диалог в меню после «Снег на Dock: разрешить доступ…» теперь подсказывает
  оба шага исправления (пересоздать разрешение в Настройках или один раз
  запустить `create_dev_cert.sh`), если разрешение уже есть, а Dock всё ещё не найден.
- Версия приложения: 0.8.4 (build 25).

# SnowfallMac 0.8.3.2 — dog route and snow tint

- Dog approaches from a randomly selected side on each visit and returns the way it came.
- Tall mounds are approached at an accessible shoulder rather than at the peak, preventing the dog from climbing to an extreme height.
- Removed the visible liquid-like stream and droplets. The event now leaves only a compact yellow pigment patch embedded in the snow surface.
- Narrowed and softened the tint footprint; the snow crust itself changes colour without adding liquid or snow mass.
- Bumped app version to 0.8.3.2 (build 24).

# SnowfallMac 0.8.3.1 — build fix

- Removed a duplicate `snowDog` stored-property declaration in `SnowOverlayView` that caused Swift's `invalid redeclaration` compile error.
- No dog behavior, snow physics, or settings were changed.
- Bumped app version to 0.8.3.1 (build 23).

# SnowfallMac 0.8.3 — Dog visit event

- Added a small animated dog that visits the largest eligible snowdrift approximately every 10 minutes.
- The dog runs along the selected surface, pauses briefly, leaves a localized yellow-tinted patch on the snow crest, then runs away.
- A single shared coordinator compares mound mass across displays, so only one dog visits at a time.
- Added a status-menu command, “Позвать собаку сейчас (проверка)”, to test the event without waiting 10 minutes.
- Yellow snow is a separate surface tint, not extra snow mass. Fresh snowfall gradually buries it; clearing and melting fade it.
- The yellow tint is saved with Dock / ground snow snapshots, and the snowblower can collect and relocate some of the stain with the snow.
- Previous snapshots remain readable because the new Codable field is optional.
- Bumped app version to 0.8.3 (build 22).

# SnowfallMac 0.8.0 — этапы 3 и 4

## Настройки окружения
- Ветер: сила от 0 до 2.0 и направление (переменный / слева направо / справа налево).
- Режим «Только за окнами».
- Режим «Не накапливать на окнах».
- Выбор подключённых дисплеев; выбор сохраняется, список обновляется при подключении/отключении монитора.
- Экспериментальный поиск оконных поверхностей Notification Center / WidgetKit. Это не гарантированная поддержка каждого виджета: macOS не предоставляет публичную стабильную геометрию отдельных WidgetKit-элементов.

## Полировка
- В покое опрос геометрии окон снижен до 10 Гц.
- На батарее и в Low Power Mode целевая частота рендера снижена до 30 FPS; во время перетаскивания окна ограничение снимается.
- Сохранение сугробов Dock и нижнего края каждого дисплея. Сугробы обычных окон не восстанавливаются, поскольку ID окон меняются между запусками.
- Автозапуск через SMAppService сохранён.
- Добавлена задача VS Code для проверки синтаксиса и конфигурации.


## 0.8.1 — Snowblower targeting and persistence

- Manual snowblower calls now select the snowiest visible surface, including eligible application-window ledges.
- Automatic patrols remain restricted to Dock / display ground to avoid distracting movement across active windows.
- Stable Dock and ground snow snapshots are saved every 15 seconds as well as when the overlay stops.
- Bumped app version to 0.8.1 (build 20).


## 0.8.2 — Surface-aware snow physics

- Added surface-specific angle of repose, lateral flow, edge slope, compaction and melt rates for window ledges, Dock and display ground.
- Detached grains now optionally carry an explicit snow-mass value. Window/Dock edge runoff transfers that mass onto the first lower unoccluded surface it lands on instead of recreating a radius-derived amount.
- Normalized snow-deposition footprints so a landing transfers the requested mass instead of multiplying it by the sum of the Gaussian weights. Ambient decorative flakes were recalibrated to preserve their previous visual accumulation rate.
- Improved snowblower blade engagement: collection responds to snow depth and load, loose snow is taken more readily than packed snow, a small portion is pushed into side windrows, and track contact compacts rather than removes snow.
- Bumped app version to 0.8.2 (build 21).
