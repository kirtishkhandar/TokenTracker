# TokenTracker

A macOS menu bar app that tracks your Anthropic API token usage. A local Python proxy intercepts API calls, logs token counts to SQLite, and a SwiftUI app displays usage stats.

## What It Tracks

- Per-request input, output, cache creation, and cache read tokens
- Model used, endpoint, status code, stop reason
- Estimated cost based on published Anthropic pricing
- Both streaming (SSE) and non-streaming API responses

## What It Cannot Track

- **Claude.ai web chat** — those use your subscription, not your API key
- Any calls that bypass the proxy (i.e., go directly to api.anthropic.com)

## Architecture

```
Your Script / Claude Code
        |
        | HTTP request with your API key
        | (localhost:5005)
        v
  Python Proxy (proxy_server.py)
        |
        | Forwards request unchanged via HTTPS
        v
  api.anthropic.com
        |
        | Response (includes usage field)
        v
  Python Proxy
        |--- Parses token counts from response
        |--- Logs to SQLite database
        |--- Forwards response to caller unchanged
        v
  Your Script / Claude Code
```

The proxy is transparent — it does not modify requests or responses, and does not store your API key. Your key passes through from the calling application.

## Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 15+ (for building the Swift app)
- Python 3 (included with macOS)
- Homebrew (recommended, for installing xcodegen)

## Build — Option A: xcodegen (Recommended)

1. Install xcodegen:
   ```bash
   brew install xcodegen
   ```

2. Clone or download this repo, then cd into it:
   ```bash
   cd TokenTracker
   ```

3. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```
   **Look for:** `Created project at TokenTracker.xcodeproj` in terminal output.

4. Open and build:
   ```bash
   open TokenTracker.xcodeproj
   ```
   Press **⌘R** in Xcode to build and run.

   **Look for:** No build errors. A menu bar icon (gauge symbol) appears. The main window opens showing "Proxy stopped."

## Build — Option B: build.sh (No Xcode Project Needed)

1. Make the script executable:
   ```bash
   chmod +x build.sh
   ```

2. Run it:
   ```bash
   ./build.sh
   ```
   **Look for:** "Build complete" message with the path to the .app bundle.

3. Install or run:
   ```bash
   # Run directly
   open build/TokenTracker.app

   # Or copy to Applications
   cp -R build/TokenTracker.app /Applications/
   ```

## Build — Option C: Manual Xcode Project

If you prefer to create the project manually:

1. **Xcode → File → New → Project → macOS → App**
   - Product Name: `TokenTracker`
   - Interface: SwiftUI
   - Language: Swift
   - Uncheck "Include Tests"

2. **Delete** the default `ContentView.swift` and `TokenTrackerApp.swift` that Xcode creates.

3. **Drag all `.swift` files** from the `Sources/` folder into the Xcode project navigator.
   - Check "Copy items if needed"
   - Ensure target `TokenTracker` is checked

4. **Add proxy script to bundle:**
   - Drag `proxy/proxy_server.py` into the project navigator
   - Check "Copy items if needed" and ensure it's added to the target

5. **Copy `Info.plist`** from this repo over the one Xcode generated (or manually set `LSUIElement = YES` in the existing one).

6. **Disable App Sandbox:**
   - Target → Signing & Capabilities → remove App Sandbox if present

7. **Build Phases → Link Binary With Libraries:**
   - Add `libsqlite3.tbd`

8. **Set deployment target** to macOS 14.0 under General tab.

9. **⌘R** to build and run.

   **Look for:** Menu bar icon appears. Main window shows proxy status.

## Setup

After building and launching the app:

### 1. Start the Proxy

Click **Start** in the menu bar dropdown or the main window. The status indicator should turn green.

**Look for:** Green dot next to "Proxy running" in the menu bar popover.

### 2. Configure Your Shell

Add this line to `~/.zshrc` (or `~/.bashrc`):

```bash
export ANTHROPIC_BASE_URL=http://localhost:5005
```

Then restart your terminal or run:
```bash
source ~/.zshrc
```

The Settings tab in the app has a copy button for this command.

### 3. Verify

With the proxy running, make a test call:

```bash
curl http://localhost:5005/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 50,
    "messages": [{"role": "user", "content": "Say hello in 5 words."}]
  }'
```

**Look for:** A JSON response from Claude. The main window's request table shows one new row with the model name, token counts, and estimated cost.

### 4. Use with Claude Code

No additional configuration needed. Claude Code reads `ANTHROPIC_BASE_URL` automatically. Start Claude Code as usual — all API calls will route through the proxy.

### 5. Use with OpenClaw

OpenClaw does not read the `ANTHROPIC_BASE_URL` environment variable for its API calls. You need to configure the proxy URL directly in OpenClaw's config (`~/.openclaw/openclaw.json`):

```json
{
  "models": {
    "providers": {
      "anthropic": {
        "baseUrl": "http://localhost:5005",
        "api": "anthropic-messages",
        "models": [
          { "id": "claude-opus-4-6", "name": "Claude Opus 4" },
          { "id": "claude-sonnet-4-5-20250929", "name": "Claude Sonnet 4.5" },
          { "id": "claude-haiku-4-5-20251001", "name": "Claude Haiku 4.5" }
        ]
      }
    }
  }
}
```

Add or update the model IDs as needed. The `env.vars` setting can be kept alongside this for other apps that do respect the environment variable:

```json
{
  "env": {
    "vars": {
      "ANTHROPIC_BASE_URL": "http://localhost:5005"
    }
  }
}
```

### 6. Custom Caller Identification (Optional)

If you want to distinguish between different scripts in the usage log, add a custom header:

```python
# Python example
import anthropic
client = anthropic.Anthropic(
    default_headers={"X-TokenTracker-Caller": "my-script-name"}
)
```

The caller name will appear in the request log.

## Data Storage

| What | Where |
|------|-------|
| Usage database | `~/.tokentracker/usage.db` (SQLite) |
| Proxy config | In-app (port number, stored in app state) |
| API key | **Not stored** — passes through from your environment |

## Project Structure

```
TokenTracker/
├── Sources/                    # Swift source files
│   ├── TokenTrackerApp.swift   # App entry point
│   ├── AppState.swift          # Observable state, proxy lifecycle
│   ├── Models.swift            # Data structures, pricing
│   ├── Database.swift          # SQLite reader (Swift side)
│   ├── MainWindowView.swift    # Dashboard view
│   ├── MenuBarView.swift       # Menu bar popover
│   └── SettingsView.swift      # Configuration view
├── proxy/
│   └── proxy_server.py         # Python HTTP proxy server
├── Resources/
│   └── Assets.xcassets/        # App icon (placeholder)
├── Info.plist                  # App metadata (LSUIElement=true)
├── TokenTracker.entitlements   # Network permissions
├── project.yml                 # xcodegen spec
├── build.sh                    # Standalone build script
└── README.md
```

## Troubleshooting

**Proxy won't start:**
- Check if port 5005 is already in use: `lsof -i :5005`
- Try a different port in Settings → General

**No requests showing up:**
- Verify `ANTHROPIC_BASE_URL` is set: `echo $ANTHROPIC_BASE_URL`
- Make sure you restarted your terminal after editing `.zshrc`
- Check the proxy health: `curl http://localhost:5005/_health`

**Build errors about SQLite:**
- Ensure `libsqlite3.tbd` is linked (Build Phases → Link Binary With Libraries)
- Or if using build.sh, ensure Xcode command line tools are installed: `xcode-select --install`

## Future Enhancements

- Auto-start proxy on app launch
- Launch at login
- Configurable cost rates per model
- Export usage data to CSV
- Usage alerts / budget warnings
- Menu bar chart sparkline
