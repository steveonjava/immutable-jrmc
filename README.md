# immutable-jrmc

Standalone packaging scripts for building a JRiver Media Center AppImage that works on immutable Linux hosts such as Bazzite.

## Contents

- `jriver-appimage-packager.sh`: end-to-end AppImage build script

## What This Builder Handles

- refreshes or reuses a JRiver installation inside the `jriver` distrobox
- bootstraps Chromium payload files when available
- rewrites runtime paths for relocatable AppDir execution
- applies the JRiver startup guard patch required for the current Linux build
- bundles dependent libraries into the AppDir
- emits manifests, artifact metadata, and optional known-good baselines

## Requirements

Run the build inside the `jriver` distrobox or a compatible Debian-based environment with:

- `bash`
- `curl`
- `python3`
- `gcc`
- `patchelf`
- `proot`
- `rsync`
- `squashfs-tools`
- `desktop-file-utils`
- `file`
- `binutils`

The script can install most prerequisites itself unless `--skip-prereqs` is used.

## Usage

```bash
bash jriver-appimage-packager.sh
```

Useful options:

```bash
bash jriver-appimage-packager.sh --skip-prereqs --baseline-label 2026-03-20-working
bash jriver-appimage-packager.sh --build-root "$HOME/.local/state/jriver-appimage" --export-dir "$PWD/output"
```

## Outputs

Default build root:

- non-root: `$XDG_STATE_HOME/jriver-appimage` or `$HOME/.local/state/jriver-appimage`
- root: `/var/lib/jriver-appimage`

Notable outputs:

- `output/`: built AppImage
- `manifests/`: build metadata and audits
- `baselines/`: optional preserved known-good snapshots

## Notes

The current workflow is tuned for Bazzite and similar immutable hosts where direct relocatable execution is more reliable than namespace tricks that depend on writing synthetic paths under `/usr`.
