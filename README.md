# Pocket Rig

Pocket Rig streams games from your own PC to your iPhone, with on-screen controls you can customize.

- It works with stock [Sunshine](https://github.com/LizardByte/Sunshine) running on your PC.
- An optional Helper app adds library, downloads, and PC controls.
- It collects no data. See [PRIVACY.md](PRIVACY.md).

## Building

You need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/ryancalpin/pocket-rig-app.git
cd pocket-rig-app
git submodule update --init --recursive
xcodegen generate
xcodebuild build -project PocketRig.xcodeproj -scheme PocketRig \
  -destination 'generic/platform=iOS Simulator'
```

To run on a device, set your own team in `project.yml` (`DEVELOPMENT_TEAM`) and regenerate.

## License

GNU GPL version 3, with an App Store Distribution Exception. See [LICENSE](LICENSE).
Copyright (C) 2026 Ryan Calpin.
Pocket Rig includes moonlight-common-c (GPLv3), ENet (MIT), nanors (MIT) and OpenSSL (Apache 2.0).
