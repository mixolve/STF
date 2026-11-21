# mixolve_custom-view v10 (macOS ARM64)

Independent REAPER extension without `base.dylib` or `native_core.dylib`.

## Window actions (Main Action List)

- **mixolve: Windows - Toggle native titlebars (REAPER + FX)** — switches native titlebars on/off for the REAPER main window and recognized floating Track/Take FX windows. Starts in hidden state. The action has a REAPER toggle indicator (on = hidden).
- **mixolve: Windows - Move focused window until click** — begins placing the currently focused REAPER/FX window. The window follows the cursor **without holding any mouse button**; the next mouse click fixes the position. Running the action again cancels movement at its current position.

Move preserves the initial cursor-to-window offset, so activation doesn't immediately jump the window under the cursor. Movement is only started on command, never automatically.

**Magnetic snapping:** while Move is active, the window snaps within 14 screen points to the usable edges of any connected monitor (excluding Dock/menu bar) and to the edges of other verified REAPER / floating FX windows. Adjacent and aligned edges are supported; the perpendicular window extents must overlap. Snapping ends when the next click fixes the window. Screen and window sizes are unchanged. Adjust `kWindowSnapDistance` in `fx-windows.mm` if needed.

**Cyrillic shortcuts:** `keyboard.mm` no longer transliterates Russian/Cyrillic key events to Latin. REAPER receives the original macOS key events while recording action shortcuts and while executing them. The track-name editor mouse filter still works. Actual assignment and matching of non-Latin shortcuts is controlled by REAPER/macOS; this patch cannot guarantee REAPER itself will accept every Unicode key combination.

Window movement uses a 60 Hz timer, mouse location, local and global click monitoring, with mouse-button state polling as fallback. A click outside REAPER may require macOS Input Monitoring permission for reliable detection depending on system configuration.

## Build / install

Place the full project folder on your Apple Silicon Mac, then run:

```bash
bash install_macos.command
```

The installer creates `reaper_mixolve_custom-view.dylib` in the project directory and installs it to the configured Google Drive `UserPlugins` folder, replacing the current file. Restart REAPER.

## Scope / limitations

- Only confirmed REAPER main and floating Track/Take FX windows are modified. System dialogs, plugin-process windows and arbitrary apps are excluded.
- Restoring titlebars **preserves the window's current position** (including positions set by Move).
- Some host-managed FX windows may restore their native chrome after an REAPER layout event.
- The source-only project remains a partial reconstruction of the former CustomView: the old FX Strip / fitHiddenEditor are not implemented.
- macOS / REAPER runtime testing is not available in this environment.
