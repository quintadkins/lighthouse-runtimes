#!/bin/bash
# Assemble one Demucs engine bundle (macOS) on any host.
# Usage: build-engine.sh <arm64|x86_64>
# Layout produced (all relocatable, no venv, no absolute paths):
#   demucs-engine-<arch>/
#     python/          python-build-standalone CPython 3.11
#     site-packages/   pip --target install of demucs + torch
#     torch-home/hub/checkpoints/955717e8-8726e21a.th (htdemucs)
#     demucs           launcher: bundled python -m demucs
set -euo pipefail
ARCH="${1:?arm64 or x86_64}"
cd "$(dirname "$0")"
PBS_TAG="20261026"
PBS_VER="3.11.18"
if [ "$ARCH" = "arm64" ]; then
  PBS_ARCH="aarch64-apple-darwin"
  PLATFORM="macosx_11_0_arm64"
  TORCH="torch==2.5.1"
  TORCHAUDIO="torchaudio==2.5.1"
else
  PBS_ARCH="x86_64-apple-darwin"
  PLATFORM="macosx_10_13_x86_64"
  TORCH="torch==2.2.2"
  TORCHAUDIO="torchaudio==2.2.2"
fi
# pip unpacks wheels into TMPDIR; on the build VM /tmp is a
# 512 MB tmpfs that torch alone overflows, so keep temp here.
export TMPDIR="$(pwd)/.tmp"
mkdir -p "$TMPDIR"
OUT="demucs-engine-$ARCH"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "== Python (standalone, $PBS_ARCH) =="
curl -fL -o pbs.tar.gz "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/cpython-$PBS_VER+$PBS_TAG-$PBS_ARCH-install_only.tar.gz"
tar -xzf pbs.tar.gz -C "$OUT"   # extracts a top-level python/ tree
rm pbs.tar.gz

echo "== demucs 4.0.1 wheel (its release is sdist-only) =="
# demucs 4.0.1 (the version spike 5 was verified with) ships no
# wheel, and 4.1.0's dependency metadata resolves badly for
# cross-platform installs, so build the pure-python wheel once
# and let the binary-only install below pick it up locally.
mkdir -p wheelhouse
python3 -m pip wheel --quiet --no-deps --wheel-dir wheelhouse "demucs==4.0.1"

echo "== Packages ($PLATFORM) =="
# --no-deps with an explicit list: torch's mac wheels carry
# Linux-marked nvidia deps in their metadata (skipped on a
# real Mac, but pip evaluates platform_system markers on THIS
# host when cross-installing, so a full resolve chases CUDA
# packages that can never match). The true mac dependency set
# is small and listed here; the verifier below proves the
# closure is complete for a macOS environment.
# Two runtime needs are NOT in any package metadata, found the
# hard way on a real Mac (2026-11-05): demucs shells out to
# ffmpeg/ffprobe (the app puts its bundled copies on PATH),
# and torchaudio saves WAVs through the soundfile package
# (declared by nothing), so soundfile + its cffi chain are
# listed explicitly even though the verifier cannot see them.
python3 -m pip install --quiet --target "$OUT/site-packages" \
  --platform "$PLATFORM" --python-version 3.11 --implementation cp --abi cp311 \
  --only-binary=:all: --find-links wheelhouse --no-deps \
  "$TORCH" "$TORCHAUDIO" "demucs==4.0.1" "numpy==1.26.4" \
  filelock "typing-extensions>=4.8.0" networkx jinja2 MarkupSafe fsspec \
  "sympy==1.13.1" mpmath "pyyaml>=5.5" tqdm "julius>=0.2.3" "lameenc>=1.2" dora-search einops openunmix omegaconf retrying submitit treetable antlr4-python3-runtime cloudpickle \
  "soundfile==0.13.1" cffi pycparser

echo "== Verify dependency closure for macOS =="
python3 - "$OUT/site-packages" "$ARCH" <<'VERIFY'
import glob, sys
from pip._vendor.packaging.markers import Marker
from pip._vendor.packaging.requirements import Requirement
from pip._vendor.packaging.utils import canonicalize_name

site_packages, arch = sys.argv[1], sys.argv[2]
env = {
    "implementation_name": "cpython",
    "implementation_version": "3.11.18",
    "os_name": "posix",
    "platform_machine": arch,
    "platform_python_implementation": "CPython",
    "platform_release": "",
    "platform_system": "Darwin",
    "platform_version": "",
    "python_full_version": "3.11.18",
    "python_version": "3.11",
    "sys_platform": "darwin",
    "extra": "",
}
installed = {}
for meta in glob.glob(site_packages + "/*.dist-info/METADATA"):
    name = None
    reqs = []
    for line in open(meta, encoding="utf-8", errors="replace"):
        if line.startswith("Name:"):
            name = canonicalize_name(line.split(":", 1)[1].strip())
        elif line.startswith("Requires-Dist:"):
            reqs.append(line.split(":", 1)[1].strip())
    if name:
        installed[name] = reqs
missing = []
for pkg, reqs in installed.items():
    for raw in reqs:
        req = Requirement(raw)
        if req.marker is not None and not req.marker.evaluate(env):
            continue
        if canonicalize_name(req.name) not in installed:
            missing.append(f"{pkg} requires {req.name}")
if missing:
    print("MISSING:", *missing, sep="\n  ")
    sys.exit(1)
print(f"closure ok: {len(installed)} distributions")
VERIFY

echo "== htdemucs weights =="
mkdir -p "$OUT/torch-home/hub/checkpoints"
curl -fL -o "$OUT/torch-home/hub/checkpoints/955717e8-8726e21a.th" \
  "https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/955717e8-8726e21a.th"

cat > "$OUT/demucs" <<'LAUNCHER'
#!/bin/sh
# Lighthouse stem engine launcher: runs the bundled Demucs with
# the bundled Python. Everything resolves relative to this
# script, so the folder can live anywhere.
HERE="$(cd "$(dirname "$0")" && pwd)"
export PYTHONPATH="$HERE/site-packages"
export PYTHONNOUSERSITE=1
export TORCH_HOME="$HERE/torch-home"
exec "$HERE/python/bin/python3" -m demucs "$@"
LAUNCHER
chmod +x "$OUT/demucs"

echo "== Zip =="
rm -f "$OUT.zip"
python3 - "$OUT" <<'PYEOF'
import os, sys, zipfile
root = sys.argv[1]
with zipfile.ZipFile(root + ".zip", "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            full = os.path.join(dirpath, name)
            arc = os.path.relpath(full, os.path.dirname(root))
            info = zipfile.ZipInfo.from_file(full, arc)
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as fh:
                z.writestr(info, fh.read())
print("wrote", root + ".zip")
PYEOF
du -sh "$OUT" "$OUT.zip"
sha256sum "$OUT.zip"
