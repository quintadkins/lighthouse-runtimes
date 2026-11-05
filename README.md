# Lighthouse Runtimes

Downloadable runtime bundles for the **Lighthouse** desktop app
(Lighthouse Music LLC). This repo holds no application code — only
prebuilt engine bundles, published as release assets, so the app can
install optional components on first use without a terminal.

## Stem engine (`demucs-engine-v1`)

Per-architecture zips the app downloads when the user clicks
**Install stem engine**:

- `demucs-engine-arm64.zip` — Apple Silicon
- `demucs-engine-x86_64.zip` — Intel

Each zip is a fully self-contained, relocatable folder:

- CPython 3.11 (python-build-standalone, PSF license)
- Demucs 4.0.1 (MIT) with PyTorch / torchaudio (BSD) and their
  dependencies, installed for the target platform only
- The `htdemucs` model weights, pre-seeded in the torch hub cache
  so separation works offline after install

Audio never leaves the user's machine; the download is the engine
only. `build-engine.sh` in this repo documents exactly how the
bundles are assembled (including the dependency-closure check run
against a macOS marker environment).

## License

The Lighthouse app itself is not in this repo. The bundled
components are redistributed under their own licenses (PSF, MIT,
BSD, Apache-2.0 and others as recorded in each package's metadata
inside the zips).
