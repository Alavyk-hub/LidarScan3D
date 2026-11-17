# LiDAR Scan 3D (iPhone 16 Pro)

Jednoduchá SwiftUI aplikace pro 3D skenování objektů a export pro úpravy a 3D tisk.

## Režimy
1. **Objekt – vysoká kvalita** (Apple Object Capture, iOS 17+): LiDAR + snímky z 48MP kamery → fotogrammetrie přímo v telefonu. Výstup: `model.usdz` (s texturou) + `model_mm.stl/.obj/.ply`. Složka `Images` s fotkami jde přenést na Mac a zpracovat ve vyšší kvalitě (Full/Raw).
2. **Rychlý LiDAR mesh** (ARKit scene reconstruction): síť přímo z hloubkového senzoru. Klepnutím na stůl vedle objektu nastavíš střed výřezu, posuvníkem poloměr; podložka se odřízne. Výstup: `lidar_mm.stl/.obj/.ply`.

Všechny STL/OBJ/PLY jsou v **milimetrech** (slicery je tak čtou). Soubory najdeš v aplikaci Soubory → Na mém iPhonu → LiDAR Scan, nebo přes tlačítko Sdílet.

## Sestavení
```bash
brew install xcodegen
cd LidarScan3D
xcodegen generate
open LidarScan3D.xcodeproj
```
V Xcode nastav Signing (Team), připoj iPhone a spusť. Simulátor nepodporuje LiDAR ani Object Capture.

Alternativa bez XcodeGen: Xcode → New Project → iOS App (SwiftUI, iOS 17), smaž vygenerované .swift soubory, přidej soubory ze `Sources/` a do Info nastav `NSCameraUsageDescription`, `UIFileSharingEnabled = YES`, `LSSupportsOpeningDocumentsInPlace = YES`.

## Workflow pro 3D tisk
1. Sken → export STL.
2. Oprava/uzavření sítě: Blender (3D Print Toolbox), Meshmixer, nebo PrusaSlicer/Bambu Studio (Opravit model).
3. Případné zesílení stěn, rovná základna (Plane Cut), zmenšení počtu trojúhelníků.
4. Slicer → tisk.
