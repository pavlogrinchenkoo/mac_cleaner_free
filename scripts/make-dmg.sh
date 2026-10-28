#!/bin/bash
# Збирає build/Cleaner.dmg, який можна передати другу.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release

STAGE="build/dmg"
rm -rf "$STAGE" build/Cleaner.dmg
mkdir -p "$STAGE"
cp -R build/Cleaner.app "$STAGE/Cleaner.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Як відкрити.txt" <<'TXT'
CLEANER: як встановити й відкрити

1. Перетягни Cleaner у папку «Програми» (Applications).
2. Двічі клікни Cleaner у «Програмах». macOS скаже, що не може перевірити розробника:
   застосунок не підписаний платним сертифікатом Apple. Це нормально для власних програм.
   Натисни «Готово» (НЕ «У смітник»).
3. Одразу після цього відкрий Системні налаштування → Конфіденційність і безпека і
   прокрути в САМИЙ НИЗ до розділу «Безпека»: там буде рядок про Cleaner з кнопкою
   «Все одно відкрити». Натисни її й введи пароль.
   Рядок з'являється тільки ПІСЛЯ спроби відкрити застосунок і лише на кілька хвилин:
   якщо його немає, ще раз двічі клікни Cleaner у «Програмах» і зайди в налаштування.
   (Або в Терміналі: xattr -dr com.apple.quarantine /Applications/Cleaner.app)
4. Для Кошика, Завантажень і захищених папок дай Cleaner повний доступ до диска:
   застосунок сам покаже, як це зробити.

ЯК ПЕРЕСЛАТИ ДІАГНОСТИКУ (щоб налаштувати програму під твій Mac)
1. Відкрий Cleaner і дочекайся, поки внизу зліва зникне «Сканую…».
2. Увімкни перемикач «Пробний запуск» і натисни «Перевірити». Нічого не видаляється.
3. Зачекай хвилину-дві: збирається звіт.
4. У вікні натисни «Поділитися…» і надішли файл.
   У файлі є назви файлів і програм з цього Mac: за потреби перегляньте його.

ВАЖЛИВО: Cleaner видаляє файли. Особисті файли, дублікати, резервні копії iPhone
і програми він не вибирає сам і переміщує в Кошик (їх можна повернути).
Кеші видаляються назовсім. Спершу завжди роби «Пробний запуск».
TXT

hdiutil create -volname "Cleaner" -srcfolder "$STAGE" -ov -format UDZO build/Cleaner.dmg >/dev/null
rm -rf "$STAGE"

# Копія з номером версії в releases/ (її build/ не чіпає), щоб кожен випуск лишався окремо.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Cleaner.app/Contents/Info.plist)"
mkdir -p releases
cp build/Cleaner.dmg "releases/Cleaner-$VERSION.dmg"
echo "Готово: build/Cleaner.dmg ($(du -h build/Cleaner.dmg | cut -f1)), копія: releases/Cleaner-$VERSION.dmg"
