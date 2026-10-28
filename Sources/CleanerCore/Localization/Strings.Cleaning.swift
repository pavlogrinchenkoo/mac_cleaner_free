// Ukrainian translations. Key = the exact English string passed to `L(...)`. See Localization.swift for the rules.
// Area: clean engine (Cleaner.swift), path guards (PathGuard.swift) and the `cleanerctl` command-line tool.
enum CleaningStrings {
    static let uk: [String: String] = [
        // MARK: PathGuard.swift (GuardError descriptions)
        "Outside the home folder: %@": "Поза домашньою папкою: %@",
        "Path is too shallow: %@": "Занадто високий рівень: %@",
        "Protected path: %@": "Захищений шлях: %@",
        "Personal data, leaving it alone: %@": "Особисті дані, не чіпаю: %@",
        "Path leaves the home folder through a symlink: %@": "Шлях веде за межі домашньої папки через symlink: %@",
        "Invalid path: %@": "Некоректний шлях: %@",
        "Not a project artifact: %@": "Це не артефакт проєкту: %@",
        "Outside the project folders: %@": "Поза папками проєктів: %@",
        "Nested artifact, leaving it alone: %@": "Вкладений артефакт, не чіпаю: %@",
        "No project file next to it (package.json, Podfile…): %@": "Поруч немає файлу проєкту (package.json, Podfile…): %@",
        "System path is not on the allowed list: %@": "Системний шлях не з дозволеного списку: %@",
        "Invalid identifier: %@": "Некоректний ідентифікатор: %@",
        "Outside the user folders (Downloads, Desktop…): %@": "Поза папками користувача (Downloads, Desktop…): %@",
        "Hidden item, package or system folder: %@": "Прихований, пакет чи службова тека: %@",
        "Not a regular file: %@": "Це не звичайний файл: %@",
        "Not an iPhone backup: %@": "Це не резервна копія iPhone: %@",
        "Not a third-party app from /Applications: %@": "Це не сторонній застосунок з /Applications: %@",
        "The leftover does not belong to this app: %@": "Залишок не належить цьому застосунку: %@",

        // MARK: Cleaner.swift (CleanEngine outcomes, notes, log, password prompt)
        "Refusing to delete with administrator rights: %@": "Відмовляюсь видаляти з правами адміна: %@",
        "It is the original of a duplicate that is being removed": "Це оригінал дубліката, який видаляється разом: лишаю його",
        "Unknown rule": "Невідоме правило",
        "Item type does not match the rule": "Тип елемента не збігається з правилом",
        "Already gone": "Вже не існує",
        "Waiting for the administrator password…": "Чекаю на пароль адміна…",
        "Cleaner deletes system files and apps. Enter your administrator password.":
            "Cleaner видаляє системні файли й програми. Введи пароль адміна.",
        "Could not move the leftovers to the Trash: %@": "Не вдалося перемістити залишки: %@",
        "# Freed: %lld bytes; in Trash: %lld bytes": "# Звільнено: %lld байт; у Кошику: %lld байт",
        "Password not entered": "Пароль не введено",
        "Could not delete": "Не вдалося видалити",
        "The system did not allow deletion": "Система не дозволила видалити",
        "No original is set for the duplicate": "Для дубліката не вказано оригінал",
        "The original changed or is gone: leaving the copy alone": "Оригінал змінився або зник: копію не чіпаю",
        "simctl exited with code %ld": "simctl завершився з кодом %ld",

        // MARK: cleanerctl/main.swift
        "Usage: cleanerctl scan | clean [--yes] [--risk safe|all] [--rule <id>]... | diagnose [--out file]\n  extra: --root <folder>  --min-size <MB>  --top N  --no-files":
            "Використання: cleanerctl scan | clean [--yes] [--risk safe|all] [--rule <id>]... | diagnose [--out файл]\n  додатково: --root <папка>  --min-size <МБ>  --top N  --no-files",
        "Could not read the rules: %@": "Не вдалося прочитати правила: %@",
        "  (%@ %ld days ago)": "  (%@ %ld дн. тому)",
        "modified": "змінено",
        " 🗑→Trash": " 🗑→Кошик",
        "  [blocked: %@]": "  [заблоковано: %@]",
        "... %ld more smaller ones": "... ще %ld дрібніших",
        "\nSelected by default (✓): %@   The rest is up to you: %@":
            "\nВибрано за замовчуванням (✓): %@   Решта на твій вибір: %@",
        "Project folders: %@": "Папки проєктів: %@",
        "not found (add --root <folder>)": "не знайдено (додай --root <папка>)",
        "Disk: %@ free of %@": "Диск: вільно %@ з %@",
        "… Collecting the disk usage map (up to a few minutes)": "… Збираю карту зайнятого місця (до кількох хвилин)",
        "Could not write %@: %@": "Не вдалося записати %@: %@",
        "Diagnostics written: %@ (%ld KB)": "Діагностику записано: %@ (%ld КБ)",
        "Could not write the diagnostics": "Не вдалося записати діагностику",
        "Running for %@ (%@)%@...": "Виконую для %@ (%@)%@...",
        ", an administrator password will be requested": ", буде запит пароля адміна",
        "DRY RUN: %@ (%@). Nothing is changed; add --yes to run it for real.":
            "ПРОБНИЙ ЗАПУСК: %@ (%@). Нічого не змінюю; додай --yes, щоб виконати.",
        "Freed": "Звільнено",
        "Would free": "Було б звільнено",
        "In Trash": "У Кошику",
        "Would be in Trash": "Було б у Кошику",
        "skipped (%@): %@": "пропущено (%@): %@",
        "ERROR (%@): %@": "ПОМИЛКА (%@): %@",
        "Log: %@": "Лог: %@",
        "Free on disk: %@ → %@": "Вільно на диску: %@ → %@",
    ]
}
