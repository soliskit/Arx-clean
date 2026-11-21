# Arx

A Mac app that shares selected Apple Reminders lists and actions with a paired browser. The bridge runs on your Mac and serves the browser page itself: the HTML, CSS and JavaScript are bundled with the app, and there is no separate hosted frontend.

## What Arx does

- Lists your Reminders lists in the native app, with source labels and writability, so you can choose deliberately.
- Gives each paired client only the lists and actions you grant: read; create, edit, move, complete and reopen; delete with exact-title confirmation. Each client starts with no grants; revoke and pair again to change a client's access.
- Serves the browser interface from a listener bound to `127.0.0.1`. Pairing uses a single-use secret that expires after two minutes. Clients can be revoked at any time.

## Status and boundaries

Automated qualification and acceptance on the owner's Mac and remote connection are still pending. Install by building in Xcode; no signed installer or App Store release is provided.

Apple grants full Reminders access. Arx's server enforces the selected-list and action grants. Each client starts with no grants; revoke and pair again to change an existing client's access. Moves need both lists granted and writable. Deletion needs its own grant and exact-title confirmation.

Reads show up to 100 reminders per page, with Previous/Next controls and no total list-size cap. EventKit fetches the selected list natively because it has no paged API; Arx retains identifiers and converts only one page to response snapshots. At most four reads run concurrently, one per client. Every page rechecks the session, grant and current list membership. External changes can shift pages; Refresh restarts from the beginning.

The listener binds to `127.0.0.1`. The HTTPS connector makes it remotely reachable; pairing authenticates clients. Cloudflare can process the proxied reminder traffic. An optional Cloudflare Access login is not configured by Arx. Verify the connector and authentication before enabling remote access.

Pairing secrets are single-use and expire after two minutes. Enter them privately in the browser, never a URL, chat, log or screenshot. Cookies are Secure, HttpOnly and SameSite=Strict. Sessions expire after 24 hours or 30 idle minutes; background checks count as activity. Stop or restart clears all grants and sessions. Revocation blocks new requests, not copies already seen or changes already saved.

The app requests Reminders only. It does not manage lists, install a service or prevent sleep. Tags, subtasks, attachments, assignments and Smart Lists are outside the supported interface. Email and file/URL-opening alarm actions are excluded.

## Prerequisites

- A Mac running macOS 27.2 or later.
- Xcode with Swift 6.2 or later.
- Node 26.13.0 for development checks and browser tests. The Mac app does not need Node to run.
- Homebrew (installation instructions at https://brew.sh), to install the `cloudflared` connector (remote access only).
- A Cloudflare account and a domain on Cloudflare (remote access only).

## Build and run

Clone the repository and open the project on the Mac:

```sh
git clone https://github.com/soliskit/Arx.git
cd Arx
open Arx.xcodeproj
```

Select the Mac scheme, and build/run on a supported Mac. Choose your own development signing identity if Xcode requires it. Do not disable App Sandbox or add capabilities to work around a permission error.

On first run, read the permission explanation, then use **Connect Reminders**. The list inventory stays in the native app.

To try the app without real Reminders, run the explicit fixture mode; it never constructs the EventKit adapter:

```sh
/path/to/Arx.app/Contents/MacOS/Arx --bridge-fixtures
```

## Set up remote access with Cloudflare Tunnel

The bridge listens on `127.0.0.1` only, on port 8765 by default. To reach it from other devices, publish it through a Cloudflare Tunnel connector (`cloudflared`) that you control.

1. Install the connector with Homebrew:

   ```sh
   brew install cloudflared
   ```

   Cloudflare's download page also offers a standalone macOS binary. No background-service installation is required for a foreground connector.
2. In the Cloudflare dashboard, go to **Networking > Tunnels** and select **Create Tunnel**. Choose **cloudflared**, name the tunnel and create it. Verify the account and domain you intend and a free configuration. Do not overwrite DNS, repoint an existing site or change nameservers as part of this setup. A temporary Quick Tunnel is not the delivery route.
3. Copy the tunnel token (the `eyJ...` string in the dashboard's install command). Protect it: anyone holding it can run a connector for that tunnel. Keep it out of shell history, command arguments, logs, chat and screenshots.
4. Start the connector in the foreground. In zsh (the default Mac shell), read the token at a hidden prompt and pass it through the environment, never as a command argument:

   ```zsh
   read -sr TUNNEL_TOKEN
   export TUNNEL_TOKEN
   cloudflared tunnel run
   ```

   cloudflared reads the `TUNNEL_TOKEN` environment variable. Control-C stops the connector; run `unset TUNNEL_TOKEN` or close the shell to clear the token afterward. Consult current Cloudflare instructions for token handling.
5. Under the tunnel's **Routes**, add a published application. Choose an unused single-level subdomain on your domain (for example `reminders.example.com`); deeper levels can require paid certificate features. Leave the route path empty. Set the service URL to `http://127.0.0.1:8765`, matching the app's local port. Verify the hostname is unused before creating DNS. Do not create SSH, SMB, RDP, bastion or private-network routes for this app. Consider a separate Cloudflare Access identity gate before publishing, and verify any chosen gate with the intended client rather than assuming compatibility.
6. In Arx, enter the exact HTTPS origin (for example `https://reminders.example.com`) and the local port, then start the bridge and wait for **Listener running**. That confirms the local listener only, not remote connectivity.

The Mac must stay awake and online with Arx and the foreground connector running. Sleep, quitting or losing connectivity interrupts access.

## Pair a client

1. In Arx, choose the client's lists and actions, then create a pairing secret.
2. On the client, open the HTTPS page and enter the secret privately. Secrets are single-use and expire after two minutes; never publish one in evidence.
3. Read-only provider lists remain read-only even with a change grant. Revoke and pair again to change a client's access.

## Development checks

Use the project's Xcode toolchain with Swift 6.2 or later. The app's deployment minimum remains macOS 27.2. The package's lower macOS library floor does not lower the app requirement. CI's explicit macOS 27.0 test override is for runner evidence only, not supported-OS certification.

Hummingbird is pinned to 2.28.1 in `Package.swift`; commit the resolved graph. macOS uses system CryptoKit. Linux fixture qualification references the same resolved swift-crypto 5.1.1 package.

Install the pinned checks and hooks in each checkout:

```sh
npm ci --ignore-scripts
bash scripts/install-linters.sh
swift package --disable-sandbox lefthook install
swift package --disable-sandbox lefthook validate
npm run lint
swift format lint --strict --recursive BridgeCore BridgeCoreTests BridgeFixtureServer Arx ArxTests ArxUITests Package.swift
swift test
```

The shell installer verifies pinned release hashes and keeps ShellCheck/actionlint in the ignored `.tools/bin` directory. No system install is needed. Hooks and the existing CI build job check authored browser files, scripts and workflow with the same rules. Dependencies, generated proof output and Xcode-managed files are excluded.

`BridgeFixtureServer` and `scripts/browser-proof.mjs` exercise a loopback fixture through a temporary self-signed HTTPS proxy and a disposable browser profile. The certificate exceptions are confined to that proof process, not deployment instructions. No real Reminders or tunnel account is used. Native fixture screenshots cover wide, narrow, minimum-window and sidebar states. Inspect the actual images as well as check results.

## Conflicts and uncertain results

Before saving, Arx compares the client's displayed original values with a fresh store snapshot. A detected mismatch requires refresh and review. EventKit has no atomic compare-and-swap for these saves: iCloud or another app can still change an item after comparison. Review changes in Reminders when a concurrent edit is possible.

Missing/stale identifiers fail closed. The app never reconnects an old grant or pending edit by a matching name. Unchanged unsupported recurrence/alarm state is preserved rather than silently simplified. Unsupported edits fail with an error.

Mutation operation IDs limit duplicate application within a session. Do not blindly repeat an uncertain create/delete with a new ID. Refresh and inspect the actual result in Reminders first.

## Stop and revoke

- **Revoke** removes one client's grant/session.
- **Stop all sharing** immediately clears all grants/sessions and begins listener shutdown. Start stays disabled as **Stopping listener** until teardown finishes. The next start uses the same loopback port without restoring old clients. A second active listener must still be refused.
- Control-C stops the foreground connector. That does not revoke the app's macOS permission.
- Remove a route separately if you no longer want that hostname mapped. Stopping the connector does not delete DNS.
- Revoke Reminders access separately in macOS privacy settings if desired.
- For a compromised tunnel token, Cloudflare requires token rotation and disconnection of existing connectors; rotation alone leaves already connected replicas active. Do not rotate or disconnect unrelated connectors without checking their use.

## Sources

- [Apple EventKit access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store.md)
- [Cloudflare Tunnel setup](https://developers.cloudflare.com/tunnel/get-started/)
- [cloudflared downloads](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)
- [Cloudflare token handling](https://developers.cloudflare.com/tunnel/reference/tunnel-tokens/)
- [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)
- [Cloudflare HTTP privacy](https://developers.cloudflare.com/data-localization/regional-services/http-requests/)
