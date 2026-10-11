---
colors:
  canvas: "Color(red: 0.964, green: 0.952, blue: 0.940)"
  sidebar: "Color(red: 0.910, green: 0.891, blue: 0.868)"
  inspector: "Color(red: 0.953, green: 0.941, blue: 0.925)"
  card: "Color(red: 0.981, green: 0.975, blue: 0.966)"
  ink: "Color(red: 0.098, green: 0.118, blue: 0.145)"
  secondary: "Color(red: 0.390, green: 0.402, blue: 0.423)"
  selection: "Color(red: 0.865, green: 0.845, blue: 0.818)"
  line: "Color(red: 0.884, green: 0.867, blue: 0.850)"
typography:
  hero: ".system(size: 30, weight: .medium), tracking -1.1pt"
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
  primary_button: "Capsule()"
spacing:
  reference_window: "1352pt x 824pt"
  sidebar_width: "284pt at reference width; scales down with window width"
  inspector_width: "352pt at reference width; scales down with window width"
  window_minimum: "1120pt x 740pt"
  overview_horizontal_padding: "38pt"
  overview_top_padding: "76pt"
  summary_height: "104pt"
  category_row_height: "75pt"
  category_symbol: "50pt"
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

The native frontend uses a warm light three-column layout: sidebar, cleanup
workspace, and a brand/activity inspector. Numeric tokens above describe the
implemented translation, not exact values extracted from the reference image.
There is no YAML token runtime; component mappings remain empty.

## Colors

`TeboPalette` in `Sources/Tebo/Views/Shared/TeboTheme.swift` owns the literal palette,
including mint, blue, purple, orange, violet, and neutral category accents.
The shell uses a light appearance to match the user's reference. Category circles
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
category and tool content scroll where needed. The content extends through the
hidden title area, preserving native traffic lights and a draggable sidebar strip.

The sidebar includes the user's exact File cleanup / image cleanup labels above
navigation. Tool screens remain in the center. Longer existing tool controls use
multiple rows to fit this column. Search filters categories on the overview and
file metadata on shared scan screens.

## Elevation and Depth

Cards use thin neutral borders and pale fills. The active workspace segment has
an understated shadow. The inspector logo has a soft shadow and two circular
halos. The focus card uses two low-contrast vector waves. The surrounding desktop
wallpaper in the reference is not part of the app UI.

## Shapes

Overview cards use 16pt rounded corners; selection rows use 10pt. The primary
button is a capsule. Category symbols sit in circles. The logo retains the
supplied artwork's original silhouette; it is not redrawn.

## Components

Shared shell primitives live in `TeboTheme.swift`: `TeboPalette`, `TeboLogo`,
`CategorySymbol`, `SidebarSymbol`, `ScanRing`, `TeboPrimaryButtonStyle`, and
`FocusCard`. `WorkspaceSidebar` and `WorkspaceInspector` own the side panels;
`OverviewView` owns the category overview. `TeboPill` remains the Toolbox selector.
`ResultRow` and `ResultSection` remain shared file-row components.

Session counters use successful outcomes from the existing DeletePipeline.
Only actually moved rows leave the UI. Scanner-supplied recommendations remain
authoritative. No scan sizes or scan dates are fabricated for visual similarity.

## Do's and Don'ts

Match the supplied composition when extending this frontend. Reuse the shared
palette and primitives. Use real results or Not scanned states. Missing Downloads
and Auto Clean functionality stays explicitly unavailable. Preserve Preview as
the default and keep deletion behind existing confirmation and path validation.
Do not introduce new scanner, parser, engine, scheduling, or privilege behavior
as part of this frontend request.

## Evidence

| Token or rule | Source | Verification |
| --- | --- | --- |
| Composition and logo | User's 2026-10-11 request; retained image sources above | Supplied design reference |
| Colors and primitives | `Sources/Tebo/Views/Shared/TeboTheme.swift` | Literal declarations |
| Shell sizing and navigation | `ContentView.swift`, `TeboApp.swift`, `WorkspaceSidebar.swift` | Native window review |
| Overview and inspector dimensions | `Sources/Tebo/Views/OverviewView.swift` | Native screenshots and accessibility |
| Logo export | `scripts/make-icon.swift`, `scripts/make-icon.sh` | Supplied pixels retained; PNG and ICNS generated |
| Completion checks | [.hermes/plans/2026-10-11_tebo-reference-ui.md](.hermes/plans/2026-10-11_tebo-reference-ui.md) | Task record owns test and build evidence |

## Limits

This is a close native implementation of a raster reference, not a claim of
pixel-perfect reproduction across macOS versions or display scales. The reference's
example scan values are not application data. Full Disk Access was unavailable
during verification; the UI exposes its existing settings guidance.
