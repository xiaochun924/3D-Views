# 3D Views

A native iOS 3D CAD viewer written in **Swift 6** + SwiftUI + SceneKit.
Open STEP and STL files, orbit/pan/zoom, and measure point-to-point distances.

## Features

- **STEP (.step / .stp) viewer** — built-in B-rep parser:
  - CARTESIAN_POINT, DIRECTION, AXIS2_PLACEMENT_3D
  - LINE, CIRCLE, ELLIPSE, B_SPLINE_CURVE
  - PLANE, CYLINDRICAL_SURFACE faces (ear-clipped triangulation)
  - Wireframe edge overlay + shaded faces
- **STL (.stl) viewer** — ASCII and binary.
- **Measurement** — tap two points, read the distance in mm / cm / in / m.
- **Gestures** — orbit, pan, pinch-zoom (SceneKit default camera controller).
- **Liquid-glass UI** — transparent navigation, floating glass capsule title, circular glass buttons.

## About SolidWorks (.SLDPRT / .SLDASM)

SolidWorks native files are a proprietary binary format. **No cross-platform
application (iOS, Android, web) can open them directly** — doing so requires
the SolidWorks API on Windows. To view a SolidWorks part in 3D Views:

1. Open the part in SolidWorks.
2. `File ▸ Save As ▸ STEP AP214 (.step, .stp)`.
3. AirDrop / share the exported `.step` file into 3D Views.

STEP is the standard neutral CAD exchange format, and 3D Views is built
around it.

## Requirements

- Xcode 16+ (Swift 6 language mode)
- iOS 17+ (device or simulator)
- No third-party dependencies — pure SwiftUI + SceneKit.

## Building

1. Open `3D-Views/` in Xcode (or run `xcodegen generate` in `3D-Views/`).
2. Select the `3D-Views` scheme and any iOS 17 simulator.
3. ⌘R to run.

## Project layout

```
3D-Views/
├── .github/workflows/ios-build.yml   CI build
└── 3D-Views/                         XcodeGen project
    ├── project.yml                    XcodeGen spec
    └── 3D-Views/                      sources
        ├── 3D_ViewsApp.swift          @main entry
        ├── Models/
        │   ├── STEP/                  STEP tokenizer / parser / resolver
        │   ├── STL/STLParser.swift    ASCII + binary STL
        │   └── Mesh/Tessellator.swift B-rep → SCNGeometry
        ├── ViewModels/ViewerViewModel.swift
        ├── Views/
        │   ├── MainView.swift         liquid-glass UI + help
        │   └── SceneView.swift        SCNView wrapper + tap-to-pick
        └── Utilities/Units.swift
```

## Roadmap

- [ ] More surface types (conical, spherical, toroidal, B-spline surface tessellation)
- [ ] Edge length / radius / angle measurement
- [ ] Section planes
- [ ] STEP units read from `LENGTH_MEASURE` entity
- [ ] macOS Catalyst target
