import Darwin
import Foundation

/// Тип відновлюваної теки в проєкті. Кожну можна безпечно видалити, бо її перегенерує інструмент збірки.
public struct ArtifactKind: Sendable {
    public let id: String
    /// Назви тек, що належать до цього типу.
    public let names: [String]
    /// Поруч з текою (в її батьківській) має лежати один із цих файлів (glob). Без цього тека не вважається артефактом.
    public let markers: [String]
    /// Усередині теки має бути один із цих файлів.
    public let innerMarkers: [String]
    public let risk: Risk
    public let autoSelectOlderThanDays: Int?

    public static let defaultIdleDays = 30

    public static let all: [ArtifactKind] = [
        ArtifactKind(
            id: "project.node_modules", names: ["node_modules"],
            markers: ["package.json"], innerMarkers: [], risk: .safe, autoSelectOlderThanDays: defaultIdleDays),
        ArtifactKind(
            id: "project.pods", names: ["Pods"],
            markers: ["Podfile"], innerMarkers: [], risk: .safe, autoSelectOlderThanDays: defaultIdleDays),
        ArtifactKind(
            id: "project.dart", names: [".dart_tool"],
            markers: ["pubspec.yaml"], innerMarkers: [], risk: .safe, autoSelectOlderThanDays: defaultIdleDays),
        ArtifactKind(
            id: "project.gradle", names: [".gradle"],
            markers: ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"],
            innerMarkers: [], risk: .safe, autoSelectOlderThanDays: defaultIdleDays),
        ArtifactKind(
            id: "project.build", names: ["build"],
            markers: [
                "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
                "pubspec.yaml", "*.xcodeproj", "*.xcworkspace", "CMakeLists.txt",
            ],
            innerMarkers: [], risk: .safe, autoSelectOlderThanDays: defaultIdleDays),
        ArtifactKind(
            id: "project.frameworks", names: [".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular"],
            markers: ["package.json"], innerMarkers: [], risk: .safe, autoSelectOlderThanDays: defaultIdleDays),
        ArtifactKind(
            id: "project.target", names: ["target"],
            markers: ["Cargo.toml", "pom.xml", "build.sbt"], innerMarkers: [], risk: .safe,
            autoSelectOlderThanDays: defaultIdleDays),
        ArtifactKind(
            id: "project.swiftpm", names: [".build"],
            markers: ["Package.swift"], innerMarkers: [], risk: .safe, autoSelectOlderThanDays: defaultIdleDays),
        ArtifactKind(
            id: "project.venv", names: [".venv", "venv"],
            markers: [], innerMarkers: ["pyvenv.cfg"], risk: .careful, autoSelectOlderThanDays: nil),
    ]

    private static let byName: [String: ArtifactKind] = {
        var map: [String: ArtifactKind] = [:]
        for kind in all { for name in kind.names { map[name] = kind } }
        return map
    }()

    public static func kind(forDirectoryNamed name: String) -> ArtifactKind? { byName[name] }
    public static func isArtifactName(_ name: String) -> Bool { byName[name] != nil }

    /// Назва й опис залежать від мови, тому обчислюються при кожному зверненні (а не зберігаються в реєстрі).
    public var title: String {
        switch id {
        case "project.gradle": L("Project Gradle cache (.gradle)")
        case "project.build": L("Build output (build)")
        case "project.frameworks": L("Framework caches (.next, .nuxt, .turbo…)")
        case "project.swiftpm": L("Swift packages (.build)")
        case "project.node_modules": "node_modules"
        case "project.pods": "CocoaPods (Pods)"
        case "project.dart": "Dart / Flutter (.dart_tool)"
        case "project.target": "Rust / Maven (target)"
        case "project.venv": "Python venv"
        default: id
        }
    }

    public var detail: String {
        switch id {
        case "project.node_modules": L("JavaScript project dependencies. Restored with `npm install` (or `yarn`, `pnpm`).")
        case "project.pods": L("iOS/macOS project dependencies. Restored with `pod install`.")
        case "project.dart": L("Dart and Flutter cache. Restored with `flutter pub get`.")
        case "project.gradle": L("Gradle cache inside the project. Rebuilt on the next build.")
        case "project.build": L("Android, Flutter, Xcode: whatever the build produced. Rebuilt on the next build. Shown only where project files are next to it.")
        case "project.frameworks": L("Next.js, Nuxt, Turbo, Parcel, SvelteKit and Angular caches. Restored when you start the dev server or build.")
        case "project.target": L("Cargo or Maven build output. Rebuilt with `cargo build` / `mvn package`.")
        case "project.swiftpm": L("Swift package build output. Rebuilt with `swift build`.")
        case "project.venv": L("Python virtual environments. Careful: packages you installed by hand will need to be installed again.")
        default: ""
        }
    }

    /// Синтетичне правило для інтерфейсу й рушія.
    public var rule: CleanupRule {
        CleanupRule(
            id: id, group: "projects", title: title, detail: detail, risk: risk,
            granularity: .selfItem, autoSelectOlderThanDays: autoSelectOlderThanDays
        )
    }

    /// Чи є поруч/всередині потрібні файли проєкту.
    public func isSatisfied(artifact: URL) -> Bool {
        let parent = artifact.deletingLastPathComponent().path
        if !markers.isEmpty, !Self.anyEntry(in: parent, matching: markers) { return false }
        if !innerMarkers.isEmpty, !Self.anyEntry(in: artifact.path, matching: innerMarkers) { return false }
        return true
    }

    private static func anyEntry(in directory: String, matching patterns: [String]) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return false }
        return names.contains { name in patterns.contains { fnmatch($0, name, 0) == 0 } }
    }
}

public enum ProjectScanner {
    /// Глибше цього проєкти не шукаємо.
    public static let maxDepth = 8
    /// Ці теки не містять проєктів, тож у них не заходимо.
    private static let skipNames: Set<String> = [".git", "DerivedData", ".idea", ".vscode"]

    /// Шукає артефакти в усіх (валідних) папках проєктів. Повертає по правилу на кожен знайдений тип.
    public static func discover(guard artifactGuard: ArtifactGuard) -> [RuleResult] {
        var byKind: [String: [Entry]] = [:]
        var seen = Set<String>()

        for root in artifactGuard.roots {
            walk(root: root) { url in
                guard let kind = ArtifactKind.kind(forDirectoryNamed: url.lastPathComponent),
                      seen.insert(url.path).inserted,
                      (try? artifactGuard.validate(url)) != nil
                else { return }
                let entry = Entry(
                    ruleID: kind.id, url: url,
                    name: projectName(parent: url.deletingLastPathComponent(), root: root),
                    subtitle: url.lastPathComponent, ageLabel: L("activity"), scope: .project
                )
                byKind[kind.id, default: []].append(entry)
            }
        }

        return ArtifactKind.all.compactMap { kind in
            guard var entries = byKind[kind.id], !entries.isEmpty else { return nil }
            entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return RuleResult(rule: kind.rule, entries: entries)
        }
    }

    /// Шлях проєкту відносно папки проєктів: `my-api/web-client`.
    static func projectName(parent: URL, root: URL) -> String {
        let relative = parent.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? root.lastPathComponent : relative
    }

    private static func walk(root: URL, onArtifact: (URL) -> Void) {
        guard let cRoot = strdup(root.path) else { return }
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(stream) }

        while let ent = fts_read(stream) {
            if Task.isCancelled { break }
            guard Int32(ent.pointee.fts_info) == FTS_D else { continue }
            let level = Int(ent.pointee.fts_level)
            if level == 0 { continue }

            let path = String(cString: ent.pointee.fts_path)
            let name = (path as NSString).lastPathComponent
            let dataless = (ent.pointee.fts_statp?.pointee.st_flags ?? 0) & 0x4000_0000 != 0
            if level > maxDepth || skipNames.contains(name) || dataless || DiskSize.isCloudProviderDirectory(path) {
                fts_set(stream, ent, FTS_SKIP)
            } else if ArtifactKind.isArtifactName(name) {
                onArtifact(URL(fileURLWithPath: path))
                // Усередині артефакту проєктів немає, тож не заходимо (node_modules величезні).
                fts_set(stream, ent, FTS_SKIP)
            }
        }
    }
}

/// Оцінює, коли проєктом востаннє користувались: за змінами коду, маніфестів і git.
/// Повертає лише дату, ніколи не змінює нічого.
public enum ProjectActivity {
    private static let manifestNames = [
        "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
        "Podfile", "Podfile.lock", "pubspec.yaml", "pubspec.lock",
        "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
        "Cargo.toml", "Cargo.lock", "pom.xml", "Package.swift",
    ]
    /// Скільки записів переглядаємо в проєкті максимум (великі монорепо не мають гальмувати скан).
    private static let sourceWalkLimit = 8000

    public static func newest(in project: URL, home: URL) -> Date? {
        var newest: Int = 0
        func consider(_ path: String) {
            var st = stat()
            if lstat(path, &st) == 0 { newest = max(newest, Int(st.st_mtimespec.tv_sec)) }
        }

        consider(project.path)
        for name in manifestNames { consider(project.appendingPathComponent(name).path) }

        // Найближчий git-репозиторій вгору по дереву: коміти, checkout, pull змінюють ці файли.
        var directory = project.standardizedFileURL
        for _ in 0..<8 {
            let git = directory.appendingPathComponent(".git")
            var st = stat()
            if lstat(git.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                for name in ["HEAD", "index", "logs/HEAD"] { consider(git.appendingPathComponent(name).path) }
                break
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory || directory.path == home.standardizedFileURL.path { break }
            directory = parent
        }

        newest = max(newest, newestSourceMTime(in: project))
        return newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil
    }

    private static func newestSourceMTime(in project: URL) -> Int {
        guard let cPath = strdup(project.path) else { return 0 }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(stream) }

        var newest = 0
        var visited = 0
        while let ent = fts_read(stream) {
            visited += 1
            if visited > sourceWalkLimit || Task.isCancelled { break }
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_D || info == FTS_F {
                if info == FTS_D, ent.pointee.fts_level > 0 {
                    let name = (String(cString: ent.pointee.fts_path) as NSString).lastPathComponent
                    // Артефакти й .git не є «роботою над проєктом».
                    if ArtifactKind.isArtifactName(name) || name == ".git" {
                        fts_set(stream, ent, FTS_SKIP)
                        continue
                    }
                }
                if let st = ent.pointee.fts_statp?.pointee { newest = max(newest, Int(st.st_mtimespec.tv_sec)) }
            }
        }
        return newest
    }
}

/// Папки з проєктами за замовчуванням: ті з поширених місць, що існують. Користувач може змінити список.
public enum ProjectRoots {
    public static let candidates = [
        "Developer", "Projects", "dev", "Code", "src", "Sites",
        "Documents/prodjects", "Documents/projects", "Documents/GitHub", "Documents/Developer",
    ]

    public static func detectDefaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        candidates
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                    && ArtifactGuard.isValidRoot(url, home: home)
            }
    }
}
