// Ukrainian translations. Key = the exact English string passed to `L(...)`. See Localization.swift for the rules.
// Area: scanning (DiskScanner, FileScanner, ProjectScanner, Applications, Backups, Simulators, RunningProbe).
enum ScanningStrings {
    static let uk: [String: String] = [
        "No access to %@. Full Disk Access is required.": "Немає доступу до %@. Потрібен Full Disk Access.",
        "folders: %ld (%@)": "теки: %ld (%@)",
        "Latest version, currently in use": "Остання версія, зараз у використанні",
        "Looking for projects, simulators and apps…": "Шукаю проєкти, симулятори й програми…",
        "Measuring sizes…": "Рахую розміри…",
        "Used today": "Використовувався сьогодні",
        "Used %@ ago": "Використовувався %@ тому",
        "App is running": "Застосунок запущений",
        "administrator password needed: manual only": "потрібен пароль адміна: лише вручну",
        "personal files: manual only": "особисті файли: лише вручну",
        "backup: manual only": "резервна копія: лише вручну",
        "app: manual only": "програма: лише вручну",
        "unknown when it last changed": "невідомо, коли змінювалось",
        "not modified for %@ (at least %ld required)": "не змінювалось %@ (потрібно від %ld)",
        "activity %@ ago (at least %ld required)": "активність %@ тому (потрібно від %ld)",
        "custom rule: manual only": "власне правило: лише вручну",
        "safe cache": "безпечний кеш",
        "careful rule: manual only": "обережне правило: лише вручну",
        "Quit %@": "Закрий %@",
        "Quit the app %@": "Закрий застосунок %@",
        "Process “%@” is running. For Gradle: ./gradlew --stop": "Запущений процес «%@». Для Gradle: ./gradlew --stop",
        "iPhone and iPad backups": "Резервні копії iPhone та iPad",
        "Copies Finder made from a phone or tablet, often 20–50 GB each. They are moved to the Trash. If this is the only copy of the device, better not to delete it. Full Disk Access is required.":
            "Копії, які Finder зробив з телефону чи планшета, часто по 20–50 ГБ. Перемістяться в Кошик. Якщо це єдина копія пристрою, краще не видаляти. Потрібен Full Disk Access.",
        "No access to iPhone backups. Full Disk Access is required.":
            "Немає доступу до резервних копій iPhone. Потрібен Full Disk Access.",
        "Unknown device": "Невідомий пристрій",
        "version %@": "версія %@",
        "encrypted": "зашифрована",
        "backup from": "копія від",
        "unavailable (runtime removed)": "недоступний (runtime видалено)",
        "booted": "запускався",
        "Simulator is running, shut it down first": "Симулятор запущений, спершу вимкни його",
        "A newer build of this runtime exists: %@": "Є новіша збірка цього ж runtime: %@",
        "last used": "використовувався",
        "Part of Xcode, cannot be deleted": "Частина Xcode, видалити не можна",
        "Project Gradle cache (.gradle)": "Gradle-кеш проєкту (.gradle)",
        "Build output (build)": "Результати збірки (build)",
        "Framework caches (.next, .nuxt, .turbo…)": "Кеші фреймворків (.next, .nuxt, .turbo…)",
        "Swift packages (.build)": "Swift-пакети (.build)",
        "JavaScript project dependencies. Restored with `npm install` (or `yarn`, `pnpm`).":
            "Залежності JavaScript-проєктів. Повертаються командою `npm install` (чи `yarn`, `pnpm`).",
        "iOS/macOS project dependencies. Restored with `pod install`.":
            "Залежності iOS/macOS-проєктів. Повертаються командою `pod install`.",
        "Dart and Flutter cache. Restored with `flutter pub get`.":
            "Кеш Dart і Flutter. Повертається командою `flutter pub get`.",
        "Gradle cache inside the project. Rebuilt on the next build.":
            "Кеш Gradle всередині проєкту. Відновиться при наступній збірці.",
        "Android, Flutter, Xcode: whatever the build produced. Rebuilt on the next build. Shown only where project files are next to it.":
            "Android, Flutter, Xcode: те, що створила збірка. Перезбирається при наступному білді. Показую лише там, де поруч є файли проєкту.",
        "Next.js, Nuxt, Turbo, Parcel, SvelteKit and Angular caches. Restored when you start the dev server or build.":
            "Кеші Next.js, Nuxt, Turbo, Parcel, SvelteKit, Angular. Відновляться при запуску dev-сервера чи збірки.",
        "Cargo or Maven build output. Rebuilt with `cargo build` / `mvn package`.":
            "Результати збірки Cargo чи Maven. Перезбираються командою `cargo build` / `mvn package`.",
        "Swift package build output. Rebuilt with `swift build`.":
            "Результати збірки Swift-пакета. Перезбираються командою `swift build`.",
        "Python virtual environments. Careful: packages you installed by hand will need to be installed again.":
            "Віртуальні середовища Python. Обережно: пакети, які ти ставив вручну, доведеться поставити знову.",
        "activity": "активність",
        "Installed apps": "Встановлені програми",
        "The app and all its leftovers (settings, caches, data) are moved to the Trash. Apple's system apps are not shown (only iMovie, GarageBand, Keynote, Pages, Numbers). Apps installed through the Mac App Store or by Microsoft need the administrator password and are deleted permanently.":
            "Програма й усі її залишки (налаштування, кеші, дані) переміщуються в Кошик. Системні програми Apple не показую (лише iMovie, GarageBand, Keynote, Pages, Numbers). Те, що встановлено через Mac App Store чи Microsoft, потребує пароля адміна й видаляється назовсім.",
        "no leftovers": "без залишків",
        "leftovers: %ld": "залишків: %ld",
        "password required": "потрібен пароль",
        "opened": "відкривали",
        "Old Adobe versions (remove through Creative Cloud)": "Старі версії Adobe (видаляй через Creative Cloud)",
        "Several versions of the same app are installed. The extra ones take 3–7 GB each. Remove them in Creative Cloud (Apps → ⋯ → Uninstall); it also cleans up the helper files. I only show them here.":
            "Встановлено кілька версій однієї програми. Зайві займають по 3–7 ГБ кожна. Видали їх у Creative Cloud (Програми → ⋯ → Видалити), він прибере й службові файли. Тут я їх лише показую.",
        "Remove through Creative Cloud: Apps → ⋯ → Uninstall": "Видаляй через Creative Cloud: Програми → ⋯ → Видалити",
        "a newer version exists: %ld": "є новіша версія: %ld",
        "beta version": "бета-версія",
        "modified": "змінено",
        "Settings of old Illustrator versions": "Налаштування старих версій Illustrator",
        "Settings of Illustrator versions that are not on this Mac, 4–8 GB each. Settings of installed versions stay (they are shown locked). If that Illustrator version is installed outside /Applications, do not delete them. They are moved to the Trash.":
            "Налаштування версій Illustrator, яких немає на цьому Mac, по 4–8 ГБ кожна. Налаштування встановлених версій лишаються (їх показано заблокованими). Якщо Illustrator такої версії стоїть не в /Applications, не видаляй. Перемістяться в Кошик.",
        "this version is installed": "ця версія встановлена",
        "version %ld is not installed on this Mac": "версії %ld немає на цьому Mac",
        "This Illustrator version is installed": "Ця версія Illustrator встановлена",
        "Large video and audio": "Великі відео й аудіо",
        "Video, audio and editing projects. They are moved to the Trash, so you can restore them.":
            "Відео, звук і проєкти монтажу. Перемістяться в Кошик, тож їх можна повернути.",
        "Large archives and disk images": "Великі архіви й образи дисків",
        "Archives (.zip, .rar…), disk images (.dmg, .iso). Often left over after an installation or a download.":
            "Архіви (.zip, .rar…), образи дисків (.dmg, .iso). Часто залишаються після встановлення чи завантаження.",
        "Large design and photo files": "Великі дизайн- і фото-файли",
        "Photoshop, Sketch, Figma files, RAW, 3D. This is your work, so look carefully. They are moved to the Trash.":
            "Фотошоп, Sketch, Figma-файли, RAW, 3D. Це твоя робота, тож дивись уважно. Перемістяться в Кошик.",
        "Other large files": "Інші великі файли",
        "Everything else above the set size. They are moved to the Trash.":
            "Усе інше більше за заданий розмір. Перемістяться в Кошик.",
        "Installers in Downloads and on the Desktop": "Інсталятори в Downloads і на столі",
        "Files such as .dmg, .pkg, .iso that are usually already installed and no longer needed. They are moved to the Trash.":
            "Файли .dmg, .pkg, .iso, які зазвичай уже встановлено й більше не потрібно. Перемістяться в Кошик.",
        "Duplicate files": "Дублікати файлів",
        "Exact copies (the whole content matches). In each group one original always stays and is never offered for deletion. On APFS, file clones may not free any space.":
            "Точні копії (збігається весь вміст). У кожній групі один оригінал завжди лишається: його я не пропоную видаляти. На APFS клони файлів можуть не звільнити місця.",
        "Scanning files…": "Переглядаю файли…",
        "Looking for duplicates…": "Шукаю дублікати…",
        "Copy of %@": "Копія: %@",
    ]
}
