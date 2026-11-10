# Ledger — Everyday Wallet app icon

The user selected concept **D — Everyday Wallet** on November 1, 2026. The production artwork retains the evergreen wallet, sage clasp, ivory button, terracotta card and warm ivory tile.

- Master: [ledger-wallet.png](ledger-wallet.png), 1024 × 1024 PNG with transparent outer margins.
- Generation: built-in image generation, editing the selected concept D board. The generated output was copied into the repository and mechanically resized to the 1024px master with macOS sips; the original generated output is retained outside Git.
- Build: `sh Scripts/build-icon.sh` produces all ten standard/Retina representations and `.build/AppIcon.icns` using macOS sips/iconutil. Xcode actool compiles the same representations into an asset catalog for current macOS icon lookup.
- Packaging: `run-app.sh` builds the icon, copies it to each app's `Contents/Resources/AppIcon.icns`, copies the compiled `Assets.car`, sets `CFBundleIconFile` and `CFBundleIconName`, then signs the completed bundle. Packaging creates a fresh bundle and replaces the old generated bundle after signing, avoiding macOS retaining its placeholder icon for the old file identity. Both Ledger and Ledger Demo use the chosen icon.
- Build intermediates and generated app bundles stay excluded from Git. Reopen an already-running app to load its new icon.

## Production generation prompt

```text
Use case: logo-brand. Edit target: the attached Ledger concept D board. Produce the FINAL APP ICON ASSET, using ONLY the large main wallet icon from the board as the design reference. Preserve the selected design closely: warm ivory rounded-square tile; softly tactile dark evergreen wallet viewed straight-on; simple sage clasp on the right with one ivory button; a single terracotta banknote/card peeking from the top at a gentle angle. Preserve its proportions, colors, rounded forms and restrained tactile shading. Do not redesign the wallet, add details or change to an outline graphic.

Output one single centered icon on a square 1024x1024 transparent canvas. The ivory rounded-square tile should occupy approximately 88% of canvas width/height, centered with consistent clear transparent margins. Keep the entire tile and a very restrained soft drop shadow within the canvas. Everything outside the rounded tile and its shadow must have genuine alpha transparency. The tile itself remains opaque warm ivory. Sharp polished high-resolution edges. No board background, labels, captions, miniature repeats, light/dark comparison, text, letters, currency signs or watermark. This is the reusable production icon only.
```


## Platform references

- [Apple: CFBundleIconFile](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile)
- [Apple: macOS bundle resources](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)

The current local development bundle includes an ICNS fallback and a compiled app-icon asset catalog, retaining its macOS 14 deployment target. The in-app warm light/dark theme remains system-following; this icon is one shared artwork.
