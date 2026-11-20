# IR4Anki Desktop (Flutter · Material Design 3 Expressive)

Standalone native desktop client for **IR4Anki** built in Flutter with **Material Design 3 Expressive (M3E)** design language, running directly as a native Linux desktop application (GTK3) outside the browser.

> **Fallback preserved**: The existing SolidJS web frontend in `../frontend/` remains untouched and continues to serve at `http://127.0.0.1:8901/`.

## Quick Start

Make sure the IR4Anki backend is running (default `http://127.0.0.1:8901`, configurable inside **Sync & Settings**):

```bash
# Launch standalone native desktop app (auto-builds if needed)
./flutter_app/run-desktop.sh

# Force rebuild release bundle and launch
./flutter_app/run-desktop.sh --build

# Install a native Linux desktop menu entry (~/.local/share/applications/ir4anki-desktop.desktop)
./flutter_app/run-desktop.sh --install-desktop
```

## Architecture & UX Alignment

- **Material Design 3 Expressive System** (`lib/theme/`, `lib/widgets/m3e/`):
  - Official M3E Expressive & Standard spring physics (`fastSpatial`, `defaultSpatial`, `slowSpatial`, `effects`), switchable in Settings.
  - 4 Vibrant M3E palettes (`DynamicSchemeVariant.vibrant`) + Light / Dark / System mode.
  - Shape-morphing buttons (pill ↔ squircle), Connected Button Groups, Split Buttons, Floating Toolbars, Wavy Progress Indicator, 7-shape morphing Loading Indicator, Collapsible/Expandable Navigation Rail.
- **Learning Flow Fidelity** (`lib/state/app_controller.dart`, `lib/widgets/study/`):
  - Single unified daily interleaved flow (`even-floor-v1` alternating reading slots and FSRS review card blocks).
  - `cardId`-keyed reveal state + strict **Answer-Leak Guard** masking the right supporting pane while reviewing face-down.
  - Non-modal floating right **Card Authoring Drawer** (`Ctrl+Shift+C` Cloze / QA Add / Edit) so reading context stays readable and copyable.
  - Whole-file seeding & recursive bookmark line splitting (`lib/services/line_split_engine.dart`) without mutating source Markdown.
  - Stand-off **AI Highlight & Comment Layer** (`lib/services/ai_layer_engine.dart`) with 2-tier exact + skeleton matching.
  - Native Markdown + KaTeX (`flutter_math_fork`) + Storage v2 `:/<resource_id>` image resolution (`lib/widgets/markdown/ir_markdown_view.dart`).
- **Desktop Upgrades**:
  - FSRS `next_intervals` printed directly on the 4 rating buttons (`1`–`4`) plus FSRS memory state badge (`S`/`D`/`R`).
  - Draggable split-pane divider + keyboard-first shortcuts (`Space`, `1`–`4`, `Z`, `A`, `C`, `E`, `T`, `H`, `Ctrl+Shift+C`, `Ctrl+Enter`).
  - Three-pane **Files Workbench** (`lib/screens/files_workbench_screen.dart`) with FTS5 search, Reading Queue, **Revision History** rollback, **Trash** restore/empty, and Interop file/folder import with 409 conflict handling.

## Development & Tests

```bash
cd flutter_app
flutter analyze --no-fatal-infos
flutter test
flutter build linux --release
```
