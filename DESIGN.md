---
colors:
  canvas: "Color(red: 0.969, green: 0.973, blue: 0.980), central shell opacity 0.80"
  sidebar: "Color(red: 0.897, green: 0.902, blue: 0.909), shell opacity 0.72"
  inspector: "Color(red: 0.966, green: 0.971, blue: 0.980), shell opacity 0.84"
  card: "Color(red: 0.995, green: 0.996, blue: 1.000)"
  ink: "Color(red: 0.078, green: 0.102, blue: 0.153)"
  secondary: "Color(red: 0.350, green: 0.373, blue: 0.427)"
  selection: "Color(red: 0.818, green: 0.835, blue: 0.863)"
  line: "Color(red: 0.856, green: 0.872, blue: 0.900)"
typography:
  hero: ".system(size: 30, weight: .semibold), tracking -1.1pt"
  eyebrow: ".system(size: 11.5, weight: .medium), tracking 1.8pt"
  navigation: ".system(size: 14)"
  category_title: ".system(size: 14, weight: .medium)"
  category_detail: ".system(size: 11.5)"
  brand_title: ".system(size: 28, weight: .semibold), tracking -1pt"
  brand_tagline: ".system(size: 14)"
  path: ".caption + .monospaced()"
  stat_value: ".system(size: 22, weight: .semibold, design: .rounded) + .monospacedDigit()"
rounded:
  overview_card: "16pt"
  sidebar_selection: "10pt"
  workspace_switch: "10pt outer / 7pt selected item"
  search: "12pt"
  focus_card: "14pt"
  shared_tool_card: "12pt (Tebo.cardRadius)"
  primary_button: "22pt rounded graphite face with inset bevel and contact shadow"
spacing:
  reference_window: "1352pt x 824pt"
  sidebar_width: "284pt at reference width; scales down with window width"
  inspector_width: "352pt at reference width; scales down with window width"
  window_minimum: "1120pt x 740pt"
  overview_horizontal_padding: "38pt"
  overview_top_padding: "60pt, 40pt when available height is below 690pt"
  summary_height: "100pt minimum"
  stat_tile_height: "96pt: 72pt content plus 12pt padding on each edge"
  category_row_height: "54–75pt, equal rows calculated from available overview height"
  category_symbol: "44pt in both workspaces"
  primary_button_height: "42pt"
  secondary_button_height: "30pt, 26pt for small controls"
  sidebar_logo: "37pt"
  inspector_logo: "87pt"
  inspector_horizontal_padding: "25pt"
components: {}
---

# Design

## Overview

The user explicitly requested the app follow the supplied design image as closely
as possible on 2026-10-11. The retained reference is
[tebo-ui-goal.png](docs/design/tebo-ui-goal.png). The supplied logo is retained in
[Resources/TeboLogoSource.png](Resources/TeboLogoSource.png); the exported mark is
[Resources/TeboLogo.png](Resources/TeboLogo.png). These are user-provided assets.
Instructions depicted inside an image do not override the user's request.

On 2026-10-12, the user selected the frosted-silver three-column composition,
approved [the tactile-button preview](docs/design/concepts/2026-10-12/skeuomorphic/tebo-preview.png)
with "go ahead", and clarified that artwork fills the background and is blurred,
with a slider in Settings. The app's workspace and window keep their full size.
Earlier [Mole-inspired exploration](.hermes/plans/2026-10-12_mole-inspired-visuals.md)
remains a record of an alternative, not the implemented layout.

The native frontend uses a silver light three-column layout: sidebar, cleanup
workspace, and a brand/activity inspector. Numeric tokens above describe the
implemented translation, not exact values extracted from the reference image.
There is no YAML token runtime; component mappings remain empty.

## Colors

`TeboPalette` in `Sources/Tebo/Views/Shared/TeboTheme.swift` owns the literal palette,
including mint, blue, purple, orange, violet, and neutral category accents.
The shell uses a light appearance to match the approved reference. Category circles
use low-opacity color fills. Primary actions use charcoal and white. The title
and body text use ink and muted neutral colors. Tool cards share this palette.

## Typography

Use the source-backed values above. System fonts preserve native macOS rendering.
The overview headline has an explicit two-line composition. The eyebrow is small,
uppercase, and tracked. Paths remain monospaced and middle-truncated; numbers use
tabular figures. `TeboBytes.text` remains the size formatter.

## Layout

The reference window is 1352pt by 824pt. Sidebar and inspector widths scale down
on smaller windows, while the center flexes. The minimum is 1120pt by 740pt;
the overview fits its six equal-height rows without scrolling, while longer tool
results scroll where needed. The content extends through the
hidden title area, preserving native traffic lights and a draggable sidebar strip.

The sidebar uses File cleanup / Media cleanup labels above
navigation. Tool screens remain in the center. Longer existing tool controls use
multiple rows to fit this column. Search filters categories on the overview and
file metadata on shared scan screens.

File cleanup contains Clean, Uninstall, Optimize, Analyze, Status and Project
Cleanup (Mole's Purge workflow). Downloaded installers are grouped under Clean.
History replaces the unsupported Auto Clean entry
in this workspace. Each workflow has a semantic icon, tint and description.
Its six overview rows adapt together between 54pt and 75pt, with 18pt bottom padding.
Media cleanup uses the same shell. Its six rows are Similar Images, Duplicates,
Similar Videos, Similar Music, File Checks and Media Tools. File Checks contains
eight engine tools; Media Tools contains metadata cleanup and video copy exports.
History is shared across workspaces.
Diagnostic folder sizes do not contribute
to cleanup totals; incomplete measurements are marked with ≥.

Shared stat cards have a fixed 96pt outer height. Optional detail text occupies
reserved space, so Found, Reclaimable and Selected share top and bottom edges,
label positions and value baselines. The user withdrew the scrolling complaint;
the earlier cleanup UI polish did not change scrolling behavior.

## Elevation and Depth

Cards use thin neutral borders, bright pearl fills and subtle shadows. Primary
buttons have a graphite gradient, dark rim, inner top highlight and contact shadow.
Secondary buttons and the selected workspace segment use raised pearl faces;
selected navigation uses a neutral inset surface. Pressed states lower the face
and soften its shadow; disabled faces dim. Press animation honors Reduce Motion.

The approved hand/robot/book artwork is reconstructed as
[Resources/TeboBackdrop.png](Resources/TeboBackdrop.png). It fills the native
window behind the entire workspace; there is no artwork strip or smaller inner
window. Only the artwork is blurred. Settings → Appearance offers a live 0–50
blur slider, initially 18, saved under `appearance.backgroundBlur`. A small
Settings preview makes the effect visible. Both scenes observe the same
`TeboAppearanceSettings` instance created in `TeboApp`; UserDefaults persists
the value instead of carrying live updates between the scenes. This corrected a
reproduced case where the preview changed but the main artwork stayed sharp.
The supplied logo and app icon remain
unchanged after the user withdrew the icon replacement request.

The inspector logo has a soft shadow and two pearl/blue circular halos. The focus
card retains two low-contrast vector waves. Existing UI controls and text stay sharp.

## Shapes

Overview cards use 16pt rounded corners; selection rows use 10pt. The primary
button is a capsule. Category symbols sit in circles. The logo retains the
supplied artwork's original silhouette; it is not redrawn.

## Components

Shared shell primitives live in `TeboTheme.swift`: `TeboPalette`, `TeboLogo`,
`CategorySymbol`, `SidebarSymbol`, `ScanRing`, `TeboPrimaryButtonStyle`, and
`FocusCard`, `MolePageHeading`, `TeboButtonStyle`, `TeboControlSurface`,
`TeboInsetSurface` and `TeboArtworkBackground`. Bundled images are cached once.
`WorkspaceSidebar` and `WorkspaceInspector` own the side panels;
`OverviewView` owns the category overview. `TeboPill` remains the Toolbox selector.
`ResultRow` and `ResultSection` remain shared file-row components.

Session counters use successful outcomes from the existing DeletePipeline.
Only actually moved rows leave the UI. Scanner-supplied recommendations remain
authoritative. No scan sizes or scan dates are fabricated for visual similarity.

## Do's and Don'ts

Match the supplied composition when extending this frontend. Reuse the shared
palette and primitives. Use real results or Not scanned states. File cleanup follows
the [Mole feature map](docs/MOLE-FEATURES.md). Preserve Preview as the default and
keep removal behind confirmation and path validation. Missing backend functionality
was authorized in the subsequent Mole-workspace request. Administrator actions
remain manual; image-workspace navigation and engine behavior are preserved.

## Evidence

| Token or rule | Source | Verification |
| --- | --- | --- |
| Composition and logo | User's 2026-10-11 request; retained image sources above | Supplied design reference |
| Colors and primitives | `Sources/Tebo/Views/Shared/TeboTheme.swift` | Literal declarations |
| Shell sizing and navigation | `ContentView.swift`, `TeboApp.swift`, `WorkspaceSidebar.swift` | Native window review |
| Overview and inspector dimensions | `Sources/Tebo/Views/OverviewView.swift` | Native screenshots and accessibility |
| Logo export | `scripts/make-icon.swift`, `scripts/make-icon.sh` | Supplied pixels retained; PNG and ICNS generated |
| Completion checks | [.hermes/plans/2026-10-11_tebo-reference-ui.md](.hermes/plans/2026-10-11_tebo-reference-ui.md) | Task record owns test and build evidence |
| Stat card alignment and cleanup grouping | [.hermes/plans/2026-10-11_cleanup-ui-polish.md](.hermes/plans/2026-10-11_cleanup-ui-polish.md) | Final native screenshot, build and 191 tests |
| Tactile UI and live background blur | [.hermes/plans/2026-10-12_skeuomorphic-preview.md](.hermes/plans/2026-10-12_skeuomorphic-preview.md) | Native Settings interaction and persistence checks |

## Limits

This is a close native implementation of a raster reference, not a claim of
pixel-perfect reproduction across macOS versions or display scales. The reference's
example scan values are not application data. Full Disk Access was unavailable
during verification; the UI exposes its existing settings guidance.
