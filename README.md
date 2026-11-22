# CompShot

A Mac app for keying green screen and blue screen talking-head video, from the makers of 1Shot.
Drop in a clip, remove the screen, put yourself on any image or video background, and export.

Everything runs on your Mac's graphics chip, in real time: about 40 fps on 4K and well over 100 fps
on 1080p on an M1.

## What it does

- **Key:** finds the green or blue screen automatically and starts from settings tuned for each.
  Pick Screen Color if it guesses wrong. Strength, Softness and Spill controls clean up the result.
- **Edges:** Shrink and Smooth for compressed footage, Edge color repair for fringes, Screen
  correction for wrinkles and shadows, and a Mask to crop out lights and stands.
- **Compose:** an image or looping video background with blur, and drag handles (like 1Shot's
  graphics) to resize and move yourself in the frame.
- **Export:** a finished MP4 (HEVC) over your background, or a transparent ProRes 4444 MOV for
  DaVinci Resolve and Final Cut. Audio is copied as is.
- **AI control (MCP):** any AI app that speaks MCP (the Claude desktop app, Claude Code, Cursor,
  ChatGPT desktop, VS Code and others) can open a clip, look at the key, tune it, set the background
  and position, and export. The app's window follows along, so you see every change.

## Driving CompShot from an AI app

`./build.sh` installs the MCP server at
`~/Library/Application Support/CompShot/compshot-mcp` and adds it to the Claude desktop app
(quit and reopen Claude to connect). It opens CompShot when needed and talks to it over a private
local socket; nothing leaves your Mac.

For other AI apps, add a "stdio" MCP server whose command is that file. For example:

```bash
claude mcp add compshot "$HOME/Library/Application Support/CompShot/compshot-mcp"
```

or, in a JSON config such as Cursor's `mcp.json`:

```json
{ "mcpServers": { "compshot": { "command": "/Users/YOU/Library/Application Support/CompShot/compshot-mcp" } } }
```

Tools: `status`, `open_video`, `snapshot` (pictures of the key, matte or original, with measures
of how clean the key is), `set_key`, `set_background`, `set_placement`, `set_view`, `seek`,
`export` and `cancel_export`. Run `compshot-mcp --test` to check that the app answers.

## Building

You need an Apple Silicon Mac on macOS 26 and Apple's command-line developer tools
(`xcode-select --install`). Then:

```bash
./build.sh
```

That makes `CompShot.app` next to the script. The keyer's Metal code compiles when the app starts,
so no full Xcode install is needed.

## Layout

- `Keyer/GreenKeyer.swift` is the keyer on its own, with no app code, so it can move into 1Shot.
- `App/` is the window, the panels, backgrounds and export. `App/ControlServer.swift` is the
  app's side of AI control.
- `MCP/` is the `compshot-mcp` helper that AI apps start.
- `Tools/` has the icon drawing script and a tool that makes a blue screen test clip from a green one.
- `versions/0.3/` is a snapshot of version 0.3, kept as the reference point for bringing the keyer into 1Shot.

`./build.sh` also turns `AppIcon.png` into the app icon. Test clips and renders are kept out of the
repository.

## License

MIT, the same as 1Shot. See `LICENSE`.
