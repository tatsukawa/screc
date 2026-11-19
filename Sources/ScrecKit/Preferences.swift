import Foundation

/// Settings that are kept between runs: everything chosen in the picker's Options menu.
///
/// They apply to the GUI, that is the app and `screc` without arguments. On the command line every setting can be
/// given as an option, and an option that was given always wins over the stored value (see `apply(to:)`).
struct Preferences: Equatable {
    /// Where recordings made with the GUI are saved.
    enum SaveFolder: Equatable {
        case movies, desktop, documents
        case custom(URL)

        var url: URL {
            switch self {
            case .movies: FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            case .desktop: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            case .documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            case .custom(let url): url
            }
        }

        /// How it is stored: a name for the standard folders, otherwise the path.
        var stored: String {
            switch self {
            case .movies: "movies"
            case .desktop: "desktop"
            case .documents: "documents"
            case .custom(let url): url.path
            }
        }

        init(stored: String) {
            switch stored {
            case "movies": self = .movies
            case "desktop": self = .desktop
            case "documents": self = .documents
            default: self = stored.hasPrefix("/") ? .custom(URL(fileURLWithPath: stored, isDirectory: true)) : .movies
            }
        }
    }

    /// What to do once a recording made with the GUI has been saved.
    enum AfterSaving: String, CaseIterable {
        case showInFinder, open, nothing
    }

    /// Movies rather than the Desktop by default: like QuickTime Player, and because saving to the Desktop or Documents
    /// makes macOS ask the app for permission to those folders first.
    var saveFolder = SaveFolder.movies
    var quality = Quality.medium
    var hevc = false
    var fps = 60
    var showsCursor = true
    /// The microphone last chosen in the picker; `nil` for none.
    var microphoneID: String?
    var afterSaving = AfterSaving.showInFinder

    /// The defaults domain, shared by the app and the binary run from a terminal. It is deliberately not the app's
    /// bundle identifier: a process may not use its own bundle identifier as a suite name, and the bare binary has none.
    static let domain = "screc"

    static var store: UserDefaults { UserDefaults(suiteName: domain)! }

    private enum Key {
        static let saveFolder = "saveFolder", quality = "quality", hevc = "hevc", fps = "fps"
        static let showsCursor = "showsCursor", microphoneID = "microphoneID", afterSaving = "afterSaving"
    }

    /// Reads the stored settings. Anything missing or invalid keeps its default value.
    static func load(from defaults: UserDefaults = store) -> Preferences {
        var preferences = Preferences()
        if let value = defaults.string(forKey: Key.saveFolder) { preferences.saveFolder = SaveFolder(stored: value) }
        if let value = defaults.string(forKey: Key.quality).flatMap(Quality.init(rawValue:)) { preferences.quality = value }
        if defaults.object(forKey: Key.hevc) != nil { preferences.hevc = defaults.bool(forKey: Key.hevc) }
        if [30, 60].contains(defaults.integer(forKey: Key.fps)) { preferences.fps = defaults.integer(forKey: Key.fps) }
        if defaults.object(forKey: Key.showsCursor) != nil { preferences.showsCursor = defaults.bool(forKey: Key.showsCursor) }
        preferences.microphoneID = defaults.string(forKey: Key.microphoneID)
        if let value = defaults.string(forKey: Key.afterSaving).flatMap(AfterSaving.init(rawValue:)) { preferences.afterSaving = value }
        return preferences
    }

    /// The individual values a picker choice can persist.
    enum Setting: CaseIterable {
        case saveFolder, quality, hevc, fps, showsCursor, microphone, afterSaving
    }

    func save(_ setting: Setting, to defaults: UserDefaults) {
        switch setting {
        case .saveFolder: defaults.set(saveFolder.stored, forKey: Key.saveFolder)
        case .quality: defaults.set(quality.rawValue, forKey: Key.quality)
        case .hevc: defaults.set(hevc, forKey: Key.hevc)
        case .fps: defaults.set(fps, forKey: Key.fps)
        case .showsCursor: defaults.set(showsCursor, forKey: Key.showsCursor)
        case .microphone: defaults.set(microphoneID, forKey: Key.microphoneID)
        case .afterSaving: defaults.set(afterSaving.rawValue, forKey: Key.afterSaving)
        }
    }

    /// The settings to start the picker with: these, except where the command line said otherwise.
    func overridden(by options: Options) -> Preferences {
        var result = self
        let given = options.given
        if given.contains("--output-dir"), let directory = options.outputDirectory { result.saveFolder = .custom(directory) }
        if given.contains("--quality") { result.quality = options.quality }
        if given.contains("--hevc") { result.hevc = options.hevc }
        if given.contains("--fps") { result.fps = options.fps }
        if given.contains("--no-cursor") { result.showsCursor = options.showsCursor }
        if !given.isDisjoint(with: ["--mic", "--mic-device"]) { result.microphoneID = options.mic ? options.micDevice : nil }
        return result
    }

    /// Writes every setting into `options`. The save folder only matters when no output file was given.
    func configure(_ options: inout Options) {
        if options.output == nil { options.outputDirectory = saveFolder.url }
        options.quality = quality
        options.hevc = hevc
        options.fps = fps
        options.showsCursor = showsCursor
        options.mic = microphoneID != nil
        options.micDevice = microphoneID
    }

    /// Fills in everything the command line did not say.
    func apply(to options: inout Options) {
        overridden(by: options).configure(&options)
    }
}
