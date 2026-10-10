# client-app

A Swift client for the appshare backend: it signs the user in through the
browser, like `az login`, and uploads files straight to Azure Blob Storage,
in one request per file and without chunks.

## Layout

| Path | What |
|---|---|
| `Sources/ClientAppKit` | the library: sign-in (OAuth 2 authorization code + PKCE, local server on `127.0.0.1`), tokens in the Keychain, direct uploads |
| `Sources/client-app` | the command line |
| `Tests/ClientAppKitTests` | unit tests (Swift Testing) |

## Requirements

- macOS 14 or later, Swift 6 (Xcode 16 or later)
- a client id: an app registered on the backend with
  `NAME="Client App" bin/rails oauth:register`

## Build and test

```bash
swift build -c release     # .build/release/client-app
swift test
```

## Use

```bash
client-app login --client-id <ID>       # opens the browser: sign in, then Allow
client-app upload photo.jpg notes.pdf   # files
client-app upload --wait ~/Pictures/Holidays   # every file of a folder, down to two levels
client-app logout
```

| Option | Command | What |
|---|---|---|
| `--client-id ID` | login | the registered app; saved in `~/.config/client-app/config.json` |
| `--api-url URL` | login | another backend (default `https://api.appshare.site`); saved too |
| `--no-browser` | login | only print the sign-in address (to open it elsewhere) |
| `--wait` | upload | wait until the backend has processed each file |

A folder's files are named like DemoApp's import: files in the folder go
to a folder named after it, files one level down to "<folder> <subfolder>",
two levels down to "<subfolder> <subsubfolder>"; deeper files and hidden
files are skipped.

## How it works

**Sign-in.** `login` starts a server on `127.0.0.1` on a free port and opens
`/oauth/authorize` with a PKCE challenge. After the sign-in and approval
pages, the browser comes back to `http://127.0.0.1:<port>/callback` with a
code, which the app exchanges with its PKCE verifier for an access token
(1 hour) and a refresh token. Both are kept in the login keychain
(service `site.appshare.client-app`), read once per command and kept in
memory: a folder upload reads the Keychain once, not once per request. The
access token is renewed when it expires (and saved again), and an expired
refresh token asks for a new `login`.

**Upload.** Four files at a time; with `--wait`, the waiting starts once
all are sent, for all of them together (checks after 0.25 s, then less
often, up to every 2 s). For each file: `POST /api/v1/direct_uploads` with its details
and MD5 → a signed Azure URL; `PUT` the file to it (streamed from the disk,
up to 5000 MiB); `POST /api/v1/direct_uploads/:uuid/complete`; with
`--wait`, `GET /api/v1/direct_uploads/:uuid` until `done`. Every response is
checked: a failed file is reported and the others go on (exit code 1).
