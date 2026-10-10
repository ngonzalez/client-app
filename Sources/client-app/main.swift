import AppKit
import ClientAppKit
import Foundation

let usage = """
Usage:
  client-app login [--client-id ID] [--api-url URL] [--no-browser]
                                                      sign in through the browser
  client-app upload [--wait] PATH...                  upload files, or every file of a folder
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

func upload(_ arguments: [String]) async throws {
    var arguments = arguments
    let wait = flag("--wait", in: &arguments)
    guard !arguments.isEmpty else { fail("upload needs at least one file or folder") }

    let configuration = savedConfiguration()
    let client = OAuthClient(configuration: configuration, store: KeychainTokenStore(apiURL: configuration.apiURL))
    let uploader = DirectUploader(apiURL: configuration.apiURL, onEventError: { error in
        FileHandle.standardError.write(Data("client-app: the upload event wasn't recorded: \(error.localizedDescription)\n".utf8))
    }, accessToken: { try await client.accessToken() })

    let items = try arguments.flatMap { path -> [UploadItem] in
        let url = URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { fail("\(path): no such file or folder") }
        return isDirectory.boolValue ? try UploadItem.items(inFolder: url) : [UploadItem(url: url)]
    }

    var failures = 0
    for item in items {
        do {
            let uuid = try await uploader.upload(item)
            if wait { try await uploader.waitUntilDone(uuid) }
            print("\(wait ? "done" : "sent")  \(item.url.path)  \(uuid)")
        } catch ClientAppError.notSignedIn {
            fail(ClientAppError.notSignedIn.localizedDescription)
        } catch {
            failures += 1
            print("failed  \(item.url.path)  \(error.localizedDescription)")
        }
    }
    if failures > 0 { fail("\(failures) of \(items.count) files failed") }
}

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? "help" : arguments.removeFirst()
do {
    switch command {
    case "login": try await login(arguments)
    case "upload": try await upload(arguments)
    case "logout":
        let configuration = savedConfiguration()
        try OAuthClient(configuration: configuration, store: KeychainTokenStore(apiURL: configuration.apiURL)).logout()
        print("Signed out.")
    case "help", "--help", "-h": print(usage)
    default: fail("unknown command \(command)\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}
