import AppKit
import ClientAppKit
import Foundation

let usage = """
Usage:
  client-app login [--client-id ID] [--api-url URL] [--no-browser]
                                                      sign in through the browser
  client-app upload [--wait] PATH...                  upload files, or every file of a folder
  client-app folders [QUERY] [--state STATE] [--page N] [--per-page N] [--all]
                                                      list the folders, by name; QUERY searches
                                                      the names and tags, STATE is created,
                                                      published or archived
  client-app publish|unpublish|archive|unarchive ID...
                                                      change the folders' state
  client-app delete [--yes] ID...                     delete the folders, with their files
  client-app logout                                   forget the tokens

The client id comes from `bin/rails oauth:register` on the backend; login
saves it with the API URL in ~/.config/client-app/config.json.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("client-app: \(message)\n".utf8))
    exit(1)
}

/// The value after an option (`--client-id ID`), removed from the arguments
func option(_ name: String, in arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { fail("\(name) needs a value") }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

func flag(_ name: String, in arguments: inout [String]) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

func savedConfiguration() -> Configuration {
    guard let configuration = (try? Configuration.load()) ?? nil else { fail("not configured: run `client-app login --client-id ID`") }
    return configuration
}

func login(_ arguments: [String]) async throws {
    var arguments = arguments
    var configuration = (try? Configuration.load()) ?? nil
    if let clientID = option("--client-id", in: &arguments) {
        configuration = Configuration(apiURL: configuration?.apiURL ?? Configuration.defaultAPIURL, clientID: clientID)
    }
    if let apiURL = option("--api-url", in: &arguments) {
        guard let url = URL(string: apiURL), configuration != nil else { fail("--api-url needs a URL and a client id") }
        configuration?.apiURL = url
    }
    let openBrowser = !flag("--no-browser", in: &arguments)
    guard let configuration else { fail("no client id: run `client-app login --client-id ID`") }
    try configuration.save()

    let client = OAuthClient(configuration: configuration, store: KeychainTokenStore(apiURL: configuration.apiURL))
    print("Opening the browser to sign in to \(configuration.apiURL.host() ?? "")…")
    try await client.login { url in
        print("If it doesn't open, go to:\n  \(url.absoluteString)")
        fflush(stdout)
        if openBrowser { NSWorkspace.shared.open(url) }
    }
    print("Signed in.")
}

func signedInClient() -> (Configuration, OAuthClient) {
    let configuration = savedConfiguration()
    return (configuration, OAuthClient(configuration: configuration, store: KeychainTokenStore(apiURL: configuration.apiURL)))
}

func folderClient() -> FolderClient {
    let (configuration, client) = signedInClient()
    return FolderClient(apiURL: configuration.apiURL, accessToken: { try await client.accessToken() })
}

/// A whole number option (`--page 2`), checked
func number(_ name: String, in arguments: inout [String], allowed: [Int]? = nil) -> Int? {
    guard let value = option(name, in: &arguments) else { return nil }
    guard let number = Int(value), number > 0, allowed?.contains(number) ?? true else {
        fail("\(name) needs \(allowed.map { "one of " + $0.map(String.init).joined(separator: ", ") } ?? "a number from 1")")
    }
    return number
}

func printFolders(_ folders: [FolderClient.Folder]) {
    let width = folders.map { String($0.id).count }.max() ?? 2
    for folder in folders {
        let id = String(folder.id).padding(toLength: width, withPad: " ", startingAt: 0)
        let state = folder.state.padding(toLength: 9, withPad: " ", startingAt: 0)
        let tags = (folder.tags ?? []).isEmpty ? "" : "  [\((folder.tags ?? []).joined(separator: ", "))]"
        print("\(id)  \(state)  \(folder.name ?? "")\(tags)")
    }
}

func folders(_ arguments: [String]) async throws {
    var arguments = arguments
    let state = option("--state", in: &arguments)
    if let state, !FolderClient.states.contains(state) { fail("--state needs one of \(FolderClient.states.joined(separator: ", "))") }
    let page = number("--page", in: &arguments) ?? 1
    let perPage = number("--per-page", in: &arguments, allowed: FolderClient.pageSizes) ?? 25
    let all = flag("--all", in: &arguments)
    if let unknown = arguments.first(where: { $0.hasPrefix("--") }) { fail("unknown option \(unknown)") }
    let query = arguments.isEmpty ? nil : arguments.joined(separator: " ")

    let client = folderClient()
    if all {
        let folders = try await client.listAll(query: query, state: state)
        printFolders(folders)
        print("\(folders.count) folders")
    } else {
        let result = try await client.list(query: query, state: state, page: page, perPage: perPage)
        printFolders(result.folders)
        print("page \(result.page) of \(max(result.totalPages, 1)), \(result.totalCount) folders")
    }
}

func change(_ action: FolderClient.Action, _ arguments: [String]) async throws {
    var arguments = arguments
    let confirmed = flag("--yes", in: &arguments)
    guard !arguments.isEmpty else { fail("\(action.rawValue) needs at least one folder id (see `client-app folders`)") }
    let ids = arguments.map { argument -> Int in
        guard let id = Int(argument), id > 0 else { fail("\(argument): not a folder id") }
        return id
    }
    if action == .delete && !confirmed {
        guard isatty(STDIN_FILENO) != 0 else { fail("delete asks for a confirmation: add --yes") }
        print("Delete \(ids.count == 1 ? "this folder" : "these \(ids.count) folders") and their files? [y/N] ", terminator: "")
        fflush(stdout)
        guard ["y", "yes"].contains(readLine()?.lowercased() ?? "") else { fail("nothing deleted") }
    }
    try await folderClient().perform(action, ids: ids)
    print("\(action.rawValue): \(ids.map(String.init).joined(separator: " "))")
}

func upload(_ arguments: [String]) async throws {
    var arguments = arguments
    let wait = flag("--wait", in: &arguments)
    guard !arguments.isEmpty else { fail("upload needs at least one file or folder") }

    let (configuration, client) = signedInClient()
    let uploader = DirectUploader(apiURL: configuration.apiURL, onEventError: { error in
        FileHandle.standardError.write(Data("client-app: the upload event wasn't recorded: \(error.localizedDescription)\n".utf8))
    }, accessToken: { try await client.accessToken() })

    let items = try arguments.flatMap { path -> [UploadItem] in
        let url = URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { fail("\(path): no such file or folder") }
        return isDirectory.boolValue ? try UploadItem.items(inFolder: url) : [UploadItem(url: url)]
    }

    // four files at a time; with --wait, the waiting starts once all are sent
    let outcomes = await uploader.uploadAll(items, concurrency: 4, wait: wait) { outcome in
        switch outcome.step {
        case .sent: print("sent    \(outcome.item.url.path)  \(outcome.uuid ?? "")")
        case .done: print("done    \(outcome.item.url.path)  \(outcome.uuid ?? "")")
        case .failed: print("failed  \(outcome.item.url.path)  \(outcome.error?.localizedDescription ?? "")")
        }
    }
    if outcomes.contains(where: { ($0.error as? ClientAppError) == .notSignedIn }) {
        fail(ClientAppError.notSignedIn.localizedDescription)
    }
    let failures = outcomes.filter { $0.step == .failed }.count
    if failures > 0 { fail("\(failures) of \(items.count) files failed") }
}

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? "help" : arguments.removeFirst()
do {
    switch command {
    case "login": try await login(arguments)
    case "upload": try await upload(arguments)
    case "folders": try await folders(arguments)
    case let action where FolderClient.Action(rawValue: action) != nil:
        try await change(FolderClient.Action(rawValue: action)!, arguments)
    case "logout":
        let configuration = savedConfiguration()
        try await OAuthClient(configuration: configuration, store: KeychainTokenStore(apiURL: configuration.apiURL)).logout()
        print("Signed out.")
    case "help", "--help", "-h": print(usage)
    default: fail("unknown command \(command)\n\n\(usage)")
    }
} catch ClientAppError.http(status: 403, _) {
    fail("this sign-in doesn't allow it: run `client-app login` again to allow the folders")
} catch {
    fail(error.localizedDescription)
}
