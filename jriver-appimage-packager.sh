#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly INSTALLJRMC_URL="https://git.bryanroessler.com/bryan/installJRMC/raw/branch/master/installJRMC"

DEFAULT_BUILD_ROOT="/var/lib/jriver-appimage"
if (( EUID != 0 )); then
  DEFAULT_BUILD_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}/jriver-appimage"
fi

BUILD_ROOT="${BUILD_ROOT:-${DEFAULT_BUILD_ROOT}}"
OUTPUT_DIR="${OUTPUT_DIR:-${BUILD_ROOT}/output}"
APPDIR="${APPDIR:-${BUILD_ROOT}/AppDir}"
FINAL_APPDIR="${APPDIR}"
WORK_APPDIR="${BUILD_ROOT}/AppDir.work"
STAGING_DIR="${STAGING_DIR:-${BUILD_ROOT}/staging}"
LOG_DIR="${LOG_DIR:-${BUILD_ROOT}/logs}"
MANIFEST_DIR="${MANIFEST_DIR:-${BUILD_ROOT}/manifests}"
BASELINE_DIR="${BASELINE_DIR:-${BUILD_ROOT}/baselines}"
EXPORT_DIR="${EXPORT_DIR:-}"

APP_NAME="JRiver Media Center"
PACKAGE_NAME="${PACKAGE_NAME:-mediacenter35}"
PINNED_JRIVER_VERSION="${PINNED_JRIVER_VERSION:-35.0.54}"
INSTALL_USER="${JRIVER_INSTALL_USER:-${SUDO_USER:-${USER}}}"
VENDOR_ROOT="/usr/lib/jriver/Media Center 35"
VENDOR_LAUNCHER="/usr/bin/mediacenter35"
DISABLE_STARTUP_GUARD="${JRIVER_APPIMAGE_DISABLE_STARTUP_GUARD:-0}"

SKIP_PREREQS=0
SKIP_INSTALL=0
KEEP_WORK=0
BASELINE_LABEL=""

APPIMAGE_TOOL_VERSION="continuous"
APPIMAGE_ARCH=""
APPIMAGE_TOOL_URL=""
APPIMAGE_TOOL_PATH=""

JRIVER_VERSION="unknown"
PRIMARY_BINARY=""
PRIMARY_BINARY_REL=""
PATCHED_VENDOR_LAUNCHER=""
CHROMIUM_PAYLOAD_SOURCE=""
DESKTOP_ID="jriver-mediacenter.desktop"
ICON_BASENAME="jriver-mediacenter"
readonly STARTUP_PATCH_SITE_OFFSET=$((0xca7dce))
readonly STARTUP_PATCH_STUB_OFFSET=$((0x87a120))
readonly STARTUP_PATCH_SITE_ORIG_HEX="488bbf38020000"
readonly STARTUP_PATCH_SITE_HEX="e94d23bdff9090"
readonly STARTUP_PATCH_STUB_ORIG_HEX="c3662e0f1f8400000000000f1f440000c3662e0f1f8400000000000f1f44"
readonly STARTUP_PATCH_STUB_HEX="488bbf380200004885ff740d488b7608488b07ff90f0000000e9a4dc4200"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Build a JRiver Media Center AppImage from the installed Debian package inside
the jriver distrobox.

Options:
  --build-root PATH     Override the container-local build root.
  --baseline-label ID   Record a known-good artifact baseline under BUILD_ROOT/baselines/ID.
  --export-dir PATH     Copy the finished AppImage and manifests to PATH.
  --install-user USER   Run installJRMC as USER. Default: ${INSTALL_USER}
  --skip-prereqs        Skip apt/appimagetool prerequisite setup.
  --skip-install        Skip JRiver installation refresh.
  --keep-work           Keep any existing AppDir and staging files.
  -h, --help            Show this help text.

Environment:
  JRIVER_APPIMAGE_DISABLE_STARTUP_GUARD=1
                        Skip the CActionWindowArray startup guard patch.
EOF
}

msg() {
  printf '[%s] %s\n' "$1" "$2"
}

die() {
  msg ERROR "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

as_root() {
  if (( EUID == 0 )); then
    "$@"
    return
  fi

  command -v sudo >/dev/null 2>&1 || die "This step requires root privileges or sudo"
  sudo "$@"
}

run_step() {
  local name="$1"
  shift
  mkdir -p "${LOG_DIR}"
  msg STEP "${name}"
  {
    "$@"
  } > >(tee "${LOG_DIR}/${name}.log") 2> >(tee "${LOG_DIR}/${name}.err" >&2)
}

sanitize_name() {
  local value="$1"
  value="${value#/}"
  value="${value//\//_}"
  value="${value// /_}"
  printf '%s\n' "${value}"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

relative_origin_path() {
  local source_path="$1"
  local target_path="$2"

  python3 - "$source_path" "$target_path" <<'PY'
import os
import sys

source_dir = os.path.dirname(os.path.realpath(sys.argv[1]))
target_dir = os.path.realpath(sys.argv[2])
print(os.path.relpath(target_dir, source_dir))
PY
}

build_direct_runtime_shim() {
  local runtime_libdir="$1"
  local shim_source="${STAGING_DIR}/jriver-pathshim.c"
  local shim_output="${runtime_libdir}/libjriver-pathshim.so"
  local compiler="${CC:-cc}"

  command -v "${compiler}" >/dev/null 2>&1 || compiler="gcc"
  command -v "${compiler}" >/dev/null 2>&1 || die "Missing required compiler for direct runtime shim: cc or gcc"

  cat >"${shim_source}" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static void *(*real_dlopen)(const char *, int) = NULL;
static int (*real_access)(const char *, int) = NULL;
static int (*real_open)(const char *, int, ...) = NULL;
static int (*real_openat)(int, const char *, int, ...) = NULL;
static int (*real_open64)(const char *, int, ...) = NULL;
static int (*real_openat64)(int, const char *, int, ...) = NULL;
static FILE *(*real_fopen)(const char *, const char *) = NULL;
static FILE *(*real_fopen64)(const char *, const char *) = NULL;
static FILE *(*real_freopen)(const char *, const char *, FILE *) = NULL;
static FILE *(*real_freopen64)(const char *, const char *, FILE *) = NULL;
static FILE *(*real_popen)(const char *, const char *) = NULL;
static int (*real_stat)(const char *, struct stat *) = NULL;
static int (*real_lstat)(const char *, struct stat *) = NULL;
static int (*real_stat64)(const char *, struct stat64 *) = NULL;
static int (*real_lstat64)(const char *, struct stat64 *) = NULL;
static int (*real_faccessat)(int, const char *, int, int) = NULL;
static int (*real_newfstatat)(int, const char *, struct stat *, int) = NULL;
static int (*real_fstatat64)(int, const char *, struct stat64 *, int) = NULL;
static int (*real___fxstatat)(int, int, const char *, struct stat *, int) = NULL;
static int (*real___fxstatat64)(int, int, const char *, struct stat *, int) = NULL;
static int (*real_statx)(int, const char *, int, unsigned int, struct statx *) = NULL;
static ssize_t (*real_readlink)(const char *, char *, size_t) = NULL;
static char *(*real_realpath)(const char *, char *) = NULL;
static int (*real_execve)(const char *, char *const[], char *const[]) = NULL;
static int (*real_execveat)(int, const char *, char *const[], char *const[], int) = NULL;
static int (*real_posix_spawn)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const[], char *const[]) = NULL;
static int (*real_posix_spawnp)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const[], char *const[]) = NULL;
static int (*real_system)(const char *) = NULL;

#define LOAD_REAL(symbol) real_##symbol = dlsym(RTLD_NEXT, #symbol)

__attribute__((constructor))
static void initialize_real_functions(void) {
  LOAD_REAL(dlopen);
  LOAD_REAL(access);
  LOAD_REAL(open);
  LOAD_REAL(openat);
  LOAD_REAL(open64);
  LOAD_REAL(openat64);
  LOAD_REAL(fopen);
  LOAD_REAL(fopen64);
  LOAD_REAL(freopen);
  LOAD_REAL(freopen64);
  LOAD_REAL(popen);
  LOAD_REAL(stat);
  LOAD_REAL(lstat);
  LOAD_REAL(stat64);
  LOAD_REAL(lstat64);
  LOAD_REAL(faccessat);
  LOAD_REAL(newfstatat);
  LOAD_REAL(fstatat64);
  LOAD_REAL(__fxstatat);
  LOAD_REAL(__fxstatat64);
  LOAD_REAL(statx);
  LOAD_REAL(readlink);
  LOAD_REAL(realpath);
  LOAD_REAL(execve);
  LOAD_REAL(execveat);
  LOAD_REAL(posix_spawn);
  LOAD_REAL(posix_spawnp);
  LOAD_REAL(system);
}

static inline void ensure_real_functions(void) {
  if (!real_dlopen) {
    initialize_real_functions();
  }
}

static const char *map_jriver_path(const char *path, char *buffer, size_t buffer_size) {
  const char *appdir = getenv("APPDIR");
  static const char launcher_path[] = "/usr/bin/mediacenter35";
  static const char payload_prefix[] = "/usr/lib/jriver/Media Center 35";
  static const char runtime_prefix[] = "/usr/lib/jriver-runtime";

  if (!path || !appdir) {
    return path;
  }

  if (strcmp(path, launcher_path) == 0) {
    snprintf(buffer, buffer_size, "%s/usr/bin/mediacenter35.vendor", appdir);
    return buffer;
  }

  if (strncmp(path, payload_prefix, sizeof(payload_prefix) - 1) == 0) {
    snprintf(buffer, buffer_size, "%s/usr/lib/jriver/Media Center 35%s", appdir, path + sizeof(payload_prefix) - 1);
    return buffer;
  }

  if (strncmp(path, runtime_prefix, sizeof(runtime_prefix) - 1) == 0) {
    snprintf(buffer, buffer_size, "%s/usr/lib/jriver-runtime%s", appdir, path + sizeof(runtime_prefix) - 1);
    return buffer;
  }

  return path;
}

static const char *rewrite_jriver_references(const char *text, char *buffer, size_t buffer_size) {
  const char *appdir = getenv("APPDIR");
  static const char launcher_path[] = "/usr/bin/mediacenter35";
  static const char launcher_replacement[] = "/usr/bin/mediacenter35.vendor";
  static const char payload_prefix[] = "/usr/lib/jriver/Media Center 35";
  static const char runtime_prefix[] = "/usr/lib/jriver-runtime";
  static const struct {
    const char *needle;
    const char *replacement;
  } replacements[] = {
    { launcher_path, launcher_replacement },
    { payload_prefix, payload_prefix },
    { runtime_prefix, runtime_prefix },
  };
  const char *cursor = text;
  size_t used = 0;
  int changed = 0;

  if (!text || !appdir) {
    return text;
  }

  while (*cursor != '\0') {
    const char *next_match = NULL;
    const char *replacement = NULL;
    size_t needle_length = 0;
    size_t index;

    for (index = 0; index < sizeof(replacements) / sizeof(replacements[0]); ++index) {
      const char *candidate = strstr(cursor, replacements[index].needle);
      if (!candidate) {
        continue;
      }

      if (!next_match || candidate < next_match) {
        next_match = candidate;
        replacement = replacements[index].replacement;
        needle_length = strlen(replacements[index].needle);
      }
    }

    if (!next_match) {
      size_t tail_length = strlen(cursor);
      if (used + tail_length + 1 > buffer_size) {
        return text;
      }
      memcpy(buffer + used, cursor, tail_length + 1);
      return changed ? buffer : text;
    }

    if (used + (size_t)(next_match - cursor) + 1 > buffer_size) {
      return text;
    }

    memcpy(buffer + used, cursor, (size_t)(next_match - cursor));
    used += (size_t)(next_match - cursor);

    {
      int written = snprintf(buffer + used, buffer_size - used, "%s%s", appdir, replacement);
      if (written < 0 || (size_t)written >= buffer_size - used) {
        return text;
      }
      used += (size_t)written;
    }

    cursor = next_match + needle_length;
    changed = 1;
  }

  if (used + 1 > buffer_size) {
    return text;
  }

  buffer[used] = '\0';
  return changed ? buffer : text;
}

void *dlopen(const char *filename, int flags) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_dlopen(map_jriver_path(filename, mapped, sizeof(mapped)), flags);
}

int access(const char *pathname, int mode) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_access(map_jriver_path(pathname, mapped, sizeof(mapped)), mode);
}

int open(const char *pathname, int flags, ...) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  if ((flags & O_CREAT) != 0) {
    va_list args;
    mode_t mode;

    va_start(args, flags);
    mode = (mode_t)va_arg(args, int);
    va_end(args);
    return real_open(map_jriver_path(pathname, mapped, sizeof(mapped)), flags, mode);
  }

  return real_open(map_jriver_path(pathname, mapped, sizeof(mapped)), flags);
}

int openat(int dirfd, const char *pathname, int flags, ...) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  if ((flags & O_CREAT) != 0) {
    va_list args;
    mode_t mode;

    va_start(args, flags);
    mode = (mode_t)va_arg(args, int);
    va_end(args);
    return real_openat(dirfd, map_jriver_path(pathname, mapped, sizeof(mapped)), flags, mode);
  }

  return real_openat(dirfd, map_jriver_path(pathname, mapped, sizeof(mapped)), flags);
}

int open64(const char *pathname, int flags, ...) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  if ((flags & O_CREAT) != 0) {
    va_list args;
    mode_t mode;

    va_start(args, flags);
    mode = (mode_t)va_arg(args, int);
    va_end(args);
    return real_open64(map_jriver_path(pathname, mapped, sizeof(mapped)), flags, mode);
  }

  return real_open64(map_jriver_path(pathname, mapped, sizeof(mapped)), flags);
}

int openat64(int dirfd, const char *pathname, int flags, ...) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  if ((flags & O_CREAT) != 0) {
    va_list args;
    mode_t mode;

    va_start(args, flags);
    mode = (mode_t)va_arg(args, int);
    va_end(args);
    return real_openat64(dirfd, map_jriver_path(pathname, mapped, sizeof(mapped)), flags, mode);
  }

  return real_openat64(dirfd, map_jriver_path(pathname, mapped, sizeof(mapped)), flags);
}

int __open_2(const char *pathname, int flags) {
  return open(pathname, flags);
}

int __open64_2(const char *pathname, int flags) {
  return open64(pathname, flags);
}

int __openat_2(int dirfd, const char *pathname, int flags) {
  return openat(dirfd, pathname, flags);
}

int __openat64_2(int dirfd, const char *pathname, int flags) {
  return openat64(dirfd, pathname, flags);
}

FILE *fopen(const char *pathname, const char *mode) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_fopen(map_jriver_path(pathname, mapped, sizeof(mapped)), mode);
}

FILE *fopen64(const char *pathname, const char *mode) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_fopen64(map_jriver_path(pathname, mapped, sizeof(mapped)), mode);
}

FILE *freopen(const char *pathname, const char *mode, FILE *stream) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_freopen(map_jriver_path(pathname, mapped, sizeof(mapped)), mode, stream);
}

FILE *freopen64(const char *pathname, const char *mode, FILE *stream) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_freopen64(map_jriver_path(pathname, mapped, sizeof(mapped)), mode, stream);
}

FILE *popen(const char *command, const char *type) {
  char mapped[8192];

  ensure_real_functions();

  return real_popen(rewrite_jriver_references(command, mapped, sizeof(mapped)), type);
}

int stat(const char *pathname, struct stat *stat_buffer) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_stat(map_jriver_path(pathname, mapped, sizeof(mapped)), stat_buffer);
}

int lstat(const char *pathname, struct stat *stat_buffer) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_lstat(map_jriver_path(pathname, mapped, sizeof(mapped)), stat_buffer);
}

int stat64(const char *pathname, struct stat64 *stat_buffer) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_stat64(map_jriver_path(pathname, mapped, sizeof(mapped)), stat_buffer);
}

int lstat64(const char *pathname, struct stat64 *stat_buffer) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_lstat64(map_jriver_path(pathname, mapped, sizeof(mapped)), stat_buffer);
}

int faccessat(int dirfd, const char *pathname, int mode, int flags) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_faccessat(dirfd, map_jriver_path(pathname, mapped, sizeof(mapped)), mode, flags);
}

int newfstatat(int dirfd, const char *pathname, struct stat *stat_buffer, int flags) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_newfstatat(dirfd, map_jriver_path(pathname, mapped, sizeof(mapped)), stat_buffer, flags);
}

int fstatat64(int dirfd, const char *pathname, struct stat64 *stat_buffer, int flags) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_fstatat64(dirfd, map_jriver_path(pathname, mapped, sizeof(mapped)), stat_buffer, flags);
}

int __fxstatat(int version, int dirfd, const char *pathname, struct stat *stat_buffer, int flags) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real___fxstatat(version, dirfd, map_jriver_path(pathname, mapped, sizeof(mapped)), stat_buffer, flags);
}

int __fxstatat64(int version, int dirfd, const char *pathname, struct stat *stat_buffer, int flags) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real___fxstatat64(version, dirfd, map_jriver_path(pathname, mapped, sizeof(mapped)), stat_buffer, flags);
}

int statx(int dirfd, const char *pathname, int flags, unsigned int mask, struct statx *statx_buffer) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_statx(dirfd, map_jriver_path(pathname, mapped, sizeof(mapped)), flags, mask, statx_buffer);
}

ssize_t readlink(const char *pathname, char *buffer, size_t buffer_size) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_readlink(map_jriver_path(pathname, mapped, sizeof(mapped)), buffer, buffer_size);
}

char *realpath(const char *pathname, char *resolved_path) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_realpath(map_jriver_path(pathname, mapped, sizeof(mapped)), resolved_path);
}

int execve(const char *pathname, char *const argv[], char *const envp[]) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_execve(map_jriver_path(pathname, mapped, sizeof(mapped)), argv, envp);
}

int execveat(int dirfd, const char *pathname, char *const argv[], char *const envp[], int flags) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_execveat(dirfd, map_jriver_path(pathname, mapped, sizeof(mapped)), argv, envp, flags);
}

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions, const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_posix_spawn(pid, map_jriver_path(path, mapped, sizeof(mapped)), file_actions, attrp, argv, envp);
}

int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *file_actions, const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]) {
  char mapped[PATH_MAX];

  ensure_real_functions();

  return real_posix_spawnp(pid, map_jriver_path(file, mapped, sizeof(mapped)), file_actions, attrp, argv, envp);
}

int system(const char *command) {
  char mapped[8192];

  ensure_real_functions();

  return real_system(rewrite_jriver_references(command, mapped, sizeof(mapped)));
}
EOF

  "${compiler}" -shared -fPIC -O2 -Wall -Wextra -ldl -o "${shim_output}" "${shim_source}"
  chmod 0755 "${shim_output}"
}

is_elf() {
  [[ -f "$1" ]] || return 1
  file -Lb "$1" | grep -q '^ELF '
}

read_hex_range() {
  local file_path="$1"
  local offset="$2"
  local length="$3"

  od -An -tx1 -v -j "${offset}" -N "${length}" "${file_path}" | tr -d ' \n'
}

write_hex_range() {
  local file_path="$1"
  local offset="$2"
  local hex_payload="$3"

  python3 - "${hex_payload}" <<'PY' | dd of="${file_path}" bs=1 seek="${offset}" conv=notrunc status=none
import binascii
import sys

sys.stdout.buffer.write(binascii.unhexlify(sys.argv[1]))
PY
}

apply_startup_guard_patch() {
  local binary_path="$1"
  local site_hex stub_hex

  site_hex="$(read_hex_range "${binary_path}" "${STARTUP_PATCH_SITE_OFFSET}" 7)"
  stub_hex="$(read_hex_range "${binary_path}" "${STARTUP_PATCH_STUB_OFFSET}" 30)"

  if [[ "${site_hex}" == "${STARTUP_PATCH_SITE_HEX}" && "${stub_hex}" == "${STARTUP_PATCH_STUB_HEX}" ]]; then
    msg INFO "Startup guard patch already present in $(basename "${binary_path}")"
    return
  fi

  [[ "${site_hex}" == "${STARTUP_PATCH_SITE_ORIG_HEX}" ]] || die "Unexpected bytes at startup patch site in ${binary_path}: ${site_hex}"
  [[ "${stub_hex}" == "${STARTUP_PATCH_STUB_ORIG_HEX}" ]] || die "Unexpected bytes at startup patch trampoline in ${binary_path}: ${stub_hex}"

  write_hex_range "${binary_path}" "${STARTUP_PATCH_SITE_OFFSET}" "${STARTUP_PATCH_SITE_HEX}"
  write_hex_range "${binary_path}" "${STARTUP_PATCH_STUB_OFFSET}" "${STARTUP_PATCH_STUB_HEX}"

  site_hex="$(read_hex_range "${binary_path}" "${STARTUP_PATCH_SITE_OFFSET}" 7)"
  stub_hex="$(read_hex_range "${binary_path}" "${STARTUP_PATCH_STUB_OFFSET}" 30)"
  [[ "${site_hex}" == "${STARTUP_PATCH_SITE_HEX}" ]] || die "Failed to verify startup patch site in ${binary_path}"
  [[ "${stub_hex}" == "${STARTUP_PATCH_STUB_HEX}" ]] || die "Failed to verify startup patch trampoline in ${binary_path}"

  msg INFO "Applied startup guard patch to $(basename "${binary_path}")"
}

maybe_apply_startup_guard_patch() {
  local binary_path="$1"

  if [[ "${DISABLE_STARTUP_GUARD}" == "1" ]]; then
    msg INFO "Skipping startup guard patch for $(basename "${binary_path}") because JRIVER_APPIMAGE_DISABLE_STARTUP_GUARD=1"
    return
  fi

  apply_startup_guard_patch "${binary_path}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)
      APPIMAGE_ARCH="x86_64"
      ;;
    aarch64)
      APPIMAGE_ARCH="aarch64"
      ;;
    *)
      die "Unsupported architecture for appimagetool: $(uname -m)"
      ;;
  esac

  APPIMAGE_TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/${APPIMAGE_TOOL_VERSION}/appimagetool-${APPIMAGE_ARCH}.AppImage"
  APPIMAGE_TOOL_PATH="${STAGING_DIR}/appimagetool-${APPIMAGE_ARCH}.AppImage"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --build-root)
        [[ $# -ge 2 ]] || die "--build-root requires a value"
        BUILD_ROOT="$2"
        OUTPUT_DIR="${BUILD_ROOT}/output"
        APPDIR="${BUILD_ROOT}/AppDir"
        STAGING_DIR="${BUILD_ROOT}/staging"
        LOG_DIR="${BUILD_ROOT}/logs"
        MANIFEST_DIR="${BUILD_ROOT}/manifests"
        BASELINE_DIR="${BUILD_ROOT}/baselines"
        shift 2
        ;;
      --baseline-label)
        [[ $# -ge 2 ]] || die "--baseline-label requires a value"
        BASELINE_LABEL="$2"
        shift 2
        ;;
      --export-dir)
        [[ $# -ge 2 ]] || die "--export-dir requires a value"
        EXPORT_DIR="$2"
        shift 2
        ;;
      --install-user)
        [[ $# -ge 2 ]] || die "--install-user requires a value"
        INSTALL_USER="$2"
        shift 2
        ;;
      --skip-prereqs)
        SKIP_PREREQS=1
        shift
        ;;
      --skip-install)
        SKIP_INSTALL=1
        shift
        ;;
      --keep-work)
        KEEP_WORK=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

prepare_build_root() {
  mkdir -p "${BUILD_ROOT}" "${OUTPUT_DIR}" "${STAGING_DIR}" "${BASELINE_DIR}"
  FINAL_APPDIR="${APPDIR%/}"
  WORK_APPDIR="${BUILD_ROOT}/AppDir.work"
  if (( KEEP_WORK == 0 )); then
    rm -rf "${WORK_APPDIR}"
    rm -rf "${LOG_DIR}" "${MANIFEST_DIR}"
  fi
  mkdir -p "${LOG_DIR}" "${MANIFEST_DIR}"
  mkdir -p "${WORK_APPDIR}"
  APPDIR="${WORK_APPDIR}"
}

finalize_appdir() {
  local previous_appdir="${FINAL_APPDIR}.previous"

  [[ -n "${FINAL_APPDIR}" ]] || die "Final AppDir path is not set"
  [[ -d "${APPDIR}" ]] || die "Working AppDir is missing: ${APPDIR}"

  if [[ "${APPDIR}" == "${FINAL_APPDIR}" ]]; then
    return
  fi

  rm -rf "${previous_appdir}"
  if [[ -e "${FINAL_APPDIR}" ]]; then
    mv "${FINAL_APPDIR}" "${previous_appdir}"
  fi

  if mv "${APPDIR}" "${FINAL_APPDIR}"; then
    rm -rf "${previous_appdir}"
    APPDIR="${FINAL_APPDIR}"
    return
  fi

  if [[ -e "${previous_appdir}" ]]; then
    mv "${previous_appdir}" "${FINAL_APPDIR}" || true
  fi

  die "Failed to publish rebuilt AppDir"
}

ensure_prereqs() {
  local packages=(
    appstream
    binutils
    ca-certificates
    curl
    desktop-file-utils
    file
    findutils
    gcc
    proot
    patchelf
    rsync
    squashfs-tools
    xz-utils
  )

  if (( SKIP_PREREQS == 1 )); then
    msg INFO "Skipping prerequisite installation"
  else
    as_root apt-get update
    as_root apt-get install -y "${packages[@]}"
  fi

  need_cmd curl
  need_cmd dpkg-query
  need_cmd file
  need_cmd find
  need_cmd ldd
  need_cmd patchelf
  need_cmd python3
  need_cmd proot
  need_cmd readelf
  need_cmd rsync
  need_cmd sort

  if [[ ! -x /usr/local/bin/installJRMC ]]; then
    msg INFO "Refreshing installJRMC"
    as_root curl -fsSL "${INSTALLJRMC_URL}" -o /usr/local/bin/installJRMC
    as_root chmod 0755 /usr/local/bin/installJRMC
  fi

  detect_arch
  if [[ ! -x "${APPIMAGE_TOOL_PATH}" ]]; then
    msg INFO "Downloading appimagetool"
    curl -fsSL "${APPIMAGE_TOOL_URL}" -o "${APPIMAGE_TOOL_PATH}"
    chmod 0755 "${APPIMAGE_TOOL_PATH}"
  fi
}

install_jriver() {
  local -a install_args=(--install=repo --mcversion "${PINNED_JRIVER_VERSION}" --yes --no-update)

  if (( SKIP_INSTALL == 1 )); then
    msg INFO "Skipping JRiver installation refresh"
    return
  fi

  if ! id -u "${INSTALL_USER}" >/dev/null 2>&1; then
    die "Install user does not exist: ${INSTALL_USER}"
  fi

  if (( EUID == 0 )) && [[ "${INSTALL_USER}" != "root" ]]; then
    runuser -l "${INSTALL_USER}" -- /usr/local/bin/installJRMC "${install_args[@]}"
    return
  fi

  if [[ "$(id -un)" != "${INSTALL_USER}" ]]; then
    die "Run as ${INSTALL_USER}, root, or pass --install-user with a valid account"
  fi

  /usr/local/bin/installJRMC "${install_args[@]}"
}

find_primary_binary() {
  local candidate=""
  if [[ -x "${VENDOR_ROOT}/Media Center 35" ]]; then
    candidate="${VENDOR_ROOT}/Media Center 35"
  elif [[ -x "${VENDOR_ROOT}/mediacenter35" ]]; then
    candidate="${VENDOR_ROOT}/mediacenter35"
  elif [[ -f "${VENDOR_LAUNCHER}" ]] && file -Lb --mime-type "${VENDOR_LAUNCHER}" | grep -q '^text/'; then
    candidate="$(grep -Eo '/usr/lib/jriver/Media Center 35/[^"[:space:]]+' "${VENDOR_LAUNCHER}" | head -n 1 || true)"
  fi

  [[ -n "${candidate}" ]] || die "Unable to determine JRiver primary launch binary"
  [[ -e "${candidate}" ]] || die "Primary JRiver binary not found: ${candidate}"
  PRIMARY_BINARY="${candidate}"
  PRIMARY_BINARY_REL="${candidate#/}"
}

detect_vendor_layout() {
  local package_status

  [[ -d "${VENDOR_ROOT}" ]] || die "Missing JRiver payload root: ${VENDOR_ROOT}"
  [[ -e "${VENDOR_LAUNCHER}" ]] || die "Missing JRiver launcher: ${VENDOR_LAUNCHER}"
  package_status="$(dpkg-query -W "${PACKAGE_NAME}" 2>/dev/null || true)"
  if [[ -n "${package_status}" ]]; then
    msg INFO "dpkg-query -W ${PACKAGE_NAME}: ${package_status}"
  else
    msg INFO "dpkg-query -W ${PACKAGE_NAME}: package not installed"
  fi
  JRIVER_VERSION="$(dpkg-query -W -f='${Version}\n' "${PACKAGE_NAME}" 2>/dev/null || true)"
  [[ -n "${JRIVER_VERSION}" ]] || JRIVER_VERSION="unknown"
  find_primary_binary
}

find_existing_chromium_payload() {
  local install_home payload_root

  install_home="$(getent passwd "${INSTALL_USER}" | cut -d: -f6 || true)"
  [[ -n "${install_home}" ]] || return 1

  payload_root="${install_home}/.jriver/Media Center 35/Plugins/linux_chromium64"
  [[ -f "${payload_root}/libcef.so" ]] || return 1
  [[ -f "${payload_root}/JRWebChromium" ]] || return 1
  CHROMIUM_PAYLOAD_SOURCE="${payload_root}"
  return 0
}

bootstrap_chromium_payload() {
  local bootstrap_home payload_root bootstrap_log bootstrap_err

  if find_existing_chromium_payload; then
    msg INFO "Using existing Chromium payload from ${CHROMIUM_PAYLOAD_SOURCE}"
    return
  fi

  bootstrap_home="${STAGING_DIR}/chromium-bootstrap-home"
  bootstrap_log="${LOG_DIR}/bootstrap-chromium.log"
  bootstrap_err="${LOG_DIR}/bootstrap-chromium.err"
  rm -rf "${bootstrap_home}"
  mkdir -p "${bootstrap_home}"

  timeout 45 env \
    HOME="${bootstrap_home}" \
    XDG_CONFIG_HOME="${bootstrap_home}/.config" \
    XDG_CACHE_HOME="${bootstrap_home}/.cache" \
    XDG_DATA_HOME="${bootstrap_home}/.local/share" \
    /usr/bin/mediacenter35 >"${bootstrap_log}" 2>"${bootstrap_err}" || true

  payload_root="${bootstrap_home}/.jriver/Media Center 35/Plugins/linux_chromium64"
  if [[ -f "${payload_root}/libcef.so" && -f "${payload_root}/JRWebChromium" ]]; then
    CHROMIUM_PAYLOAD_SOURCE="${payload_root}"
    msg INFO "Bootstrapped Chromium payload at ${CHROMIUM_PAYLOAD_SOURCE}"
    return
  fi

  msg INFO "Chromium payload bootstrap did not produce linux_chromium64; AppImage will rely on BuiltInBrowser or fail on CEF startup"
}

find_text_candidates() {
  local payload_root="$1"

  find "${APPDIR}/usr/bin" -type f -print0
  find "${payload_root}" -type f \( \
    -name '*.cfg' -o \
    -name '*.conf' -o \
    -name '*.desktop' -o \
    -name '*.ini' -o \
    -name '*.js' -o \
    -name '*.json' -o \
    -name '*.list' -o \
    -name '*.lua' -o \
    -name '*.plist' -o \
    -name '*.py' -o \
    -name '*.service' -o \
    -name '*.sh' -o \
    -name '*.txt' -o \
    -name '*.xml' \
  \) -print0
}

rewrite_text_path_references() {
  local root_path="$1"
  local payload_dest="$2"
  local file_path changed_marker
  local rewritten_manifest="${MANIFEST_DIR}/rewritten-text-paths.txt"

  : >"${rewritten_manifest}"

  while IFS= read -r -d '' file_path; do
    if [[ "${file_path}" == "${APPDIR}/usr/bin/"* ]]; then
      file -Lb --mime-type "${file_path}" | grep -q '^text/' || continue
    fi

    changed_marker=0

    if grep -qF "${VENDOR_ROOT}" "${file_path}"; then
      sed -i "s|${VENDOR_ROOT}|"'${APPDIR}/usr/lib/jriver/Media Center 35|g' "${file_path}"
      changed_marker=1
    fi

    if grep -qF "${VENDOR_LAUNCHER}" "${file_path}"; then
      sed -i "s|${VENDOR_LAUNCHER}|"'${APPDIR}/usr/bin/mediacenter35.vendor|g' "${file_path}"
      changed_marker=1
    fi

    if (( changed_marker == 1 )); then
      printf '%s\n' "${file_path#"${root_path}"/}" >>"${rewritten_manifest}"
    fi
  done < <(find_text_candidates "${payload_dest}")

  sort -u "${rewritten_manifest}" -o "${rewritten_manifest}"
}

find_elf_candidates() {
  find "$@" -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) -print0
}

build_target_rpath() {
  local target="$1"
  local payload_root="$2"
  local chromium_root="$3"
  local runtime_root="$4"
  local rel entry
  declare -A seen=()
  local -a entries=("\$ORIGIN")

  seen['$ORIGIN']=1

  for entry in "${payload_root}" "${chromium_root}" "${runtime_root}"; do
    [[ -d "${entry}" ]] || continue
    rel="$(relative_origin_path "${target}" "${entry}")"
    if [[ "${rel}" == "." ]]; then
      entry='$ORIGIN'
    else
      entry="\$ORIGIN/${rel}"
    fi

    if [[ -z "${seen["${entry}"]+x}" ]]; then
      entries+=("${entry}")
      seen["${entry}"]=1
    fi
  done

  local IFS=:
  printf '%s\n' "${entries[*]}"
}

record_elf_rpaths() {
  local output_file="$1"
  shift
  local candidate rpath_value

  : >"${output_file}"
  while IFS= read -r -d '' candidate; do
    is_elf "${candidate}" || continue
    rpath_value="$(patchelf --print-rpath "${candidate}" 2>/dev/null || true)"
    printf '%s\t%s\n' "${candidate#"${APPDIR}"/}" "${rpath_value}" >>"${output_file}"
  done < <(find_elf_candidates "$@")

  sort -u "${output_file}" -o "${output_file}"
}

apply_runtime_path_fixes() {
  local payload_root="$1"
  local chromium_root="$2"
  local runtime_root="$3"
  local before_manifest="${MANIFEST_DIR}/elf-rpaths-before.txt"
  local after_manifest="${MANIFEST_DIR}/elf-rpaths-after.txt"
  local changed_manifest="${MANIFEST_DIR}/patchelf-updated.txt"
  local candidate target_rpath current_rpath

  record_elf_rpaths "${before_manifest}" "${APPDIR}/usr/bin" "${payload_root}"
  : >"${changed_manifest}"

  while IFS= read -r -d '' candidate; do
    is_elf "${candidate}" || continue
    [[ "${candidate}" == "${APPDIR}/usr/bin/proot" ]] && continue

    target_rpath="$(build_target_rpath "${candidate}" "${payload_root}" "${chromium_root}" "${runtime_root}")"
    current_rpath="$(patchelf --print-rpath "${candidate}" 2>/dev/null || true)"

    if [[ "${current_rpath}" != "${target_rpath}" ]]; then
      patchelf --set-rpath "${target_rpath}" "${candidate}"
      printf '%s\t%s\n' "${candidate#"${APPDIR}"/}" "${target_rpath}" >>"${changed_manifest}"
    fi
  done < <(find_elf_candidates "${APPDIR}/usr/bin" "${payload_root}")

  sort -u "${changed_manifest}" -o "${changed_manifest}"
  record_elf_rpaths "${after_manifest}" "${APPDIR}/usr/bin" "${payload_root}"
}

audit_appdir_paths() {
  local text_manifest="${MANIFEST_DIR}/absolute-path-text-references.txt"
  local elf_manifest="${MANIFEST_DIR}/absolute-path-elf-strings.txt"
  local file_path match

  : >"${text_manifest}"
  : >"${elf_manifest}"

  while IFS= read -r -d '' file_path; do
    if [[ "${file_path}" == "${APPDIR}/usr/bin/"* ]]; then
      file -Lb --mime-type "${file_path}" | grep -q '^text/' || continue
    fi

    while IFS= read -r match; do
      printf '%s:%s\n' "${file_path#"${APPDIR}"/}" "${match}" >>"${text_manifest}"
    done < <(grep -nE '/usr/lib/jriver|/usr/bin/mediacenter35' "${file_path}" || true)
  done < <(find_text_candidates "${APPDIR}/usr/lib/jriver/Media Center 35")

  while IFS= read -r -d '' file_path; do
    is_elf "${file_path}" || continue
    while IFS= read -r match; do
      printf '%s:%s\n' "${file_path#"${APPDIR}"/}" "${match}" >>"${elf_manifest}"
    done < <(strings "${file_path}" | grep -E '/usr/lib/jriver|/usr/bin/mediacenter35' || true)
  done < <(find_elf_candidates "${APPDIR}/usr/bin" "${APPDIR}/usr/lib/jriver/Media Center 35")

  sort -u "${text_manifest}" -o "${text_manifest}"
  sort -u "${elf_manifest}" -o "${elf_manifest}"
}

write_jrweb_wrappers() {
  local payload_dest="$1"
  local chromium_dest="$2"
  local runtime_libdir="$3"
  local jrweb_path="${payload_dest}/JRWeb"
  local jrweb_real="${payload_dest}/JRWeb.real"
  local jrweb_chromium_path="${chromium_dest}/JRWebChromium"
  local jrweb_chromium_real="${chromium_dest}/JRWebChromium.real"

  if [[ -f "${jrweb_path}" && ! -f "${jrweb_real}" ]]; then
    mv "${jrweb_path}" "${jrweb_real}"
    cat >"${jrweb_path}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
payload_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
chromium_root="${payload_root}/Plugins/linux_chromium64"
runtime_root="$(cd -- "${payload_root}/../../jriver-runtime" && pwd)"

export PATH="${chromium_root}:${payload_root}${PATH:+:${PATH}}"
export LD_LIBRARY_PATH="${runtime_root}:${chromium_root}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
if [[ -f "${runtime_root}/libcef.so" ]]; then
  export LD_PRELOAD="${runtime_root}/libcef.so"
else
  unset LD_PRELOAD || true
fi

exec "${payload_root}/JRWeb.real" "$@"
EOF
    chmod 0755 "${jrweb_path}"
  fi

  if [[ -f "${jrweb_chromium_path}" && ! -f "${jrweb_chromium_real}" ]]; then
    mv "${jrweb_chromium_path}" "${jrweb_chromium_real}"
    cat >"${jrweb_chromium_path}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
chromium_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
payload_root="$(cd -- "${chromium_root}/.." && pwd)"
runtime_root="$(cd -- "${payload_root}/../jriver-runtime" && pwd)"

export PATH="${chromium_root}:${payload_root}${PATH:+:${PATH}}"
export LD_LIBRARY_PATH="${runtime_root}:${chromium_root}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
if [[ -f "${runtime_root}/libcef.so" ]]; then
  export LD_PRELOAD="${runtime_root}/libcef.so"
else
  unset LD_PRELOAD || true
fi

exec "${chromium_root}/JRWebChromium.real" "$@"
EOF
    chmod 0755 "${jrweb_chromium_path}"
  fi
}

copy_payload() {
  local payload_dest="${APPDIR}/usr/lib/jriver/Media Center 35"
  local payload_launcher="${payload_dest}/mediacenter35"
  local payload_ca_bundle="${payload_dest}/ca-certificates.crt"
  local chromium_dest="${payload_dest}/Plugins/linux_chromium64"
  local runtime_libdir="${APPDIR}/usr/lib/jriver-runtime"
  local proot_bin
  mkdir -p "${payload_dest}" "${APPDIR}/usr/bin" "${APPDIR}/usr/share/applications" "${runtime_libdir}"
  cp -a --no-preserve=ownership "${VENDOR_ROOT}/." "${payload_dest}/"
  if [[ -L "${payload_launcher}" ]]; then
    rm -f "${payload_launcher}"
    cp -a --no-preserve=ownership "${VENDOR_LAUNCHER}" "${payload_launcher}"
    chmod 0755 "${payload_launcher}"
  fi

  cp -a --no-preserve=ownership "${VENDOR_LAUNCHER}" "${APPDIR}/usr/bin/mediacenter35.vendor"
  chmod u+w "${APPDIR}/usr/bin/mediacenter35.vendor"
  maybe_apply_startup_guard_patch "${APPDIR}/usr/bin/mediacenter35.vendor"
  chmod 0755 "${APPDIR}/usr/bin/mediacenter35.vendor"

  if [[ -f "${payload_launcher}" ]] && is_elf "${payload_launcher}"; then
    chmod u+w "${payload_launcher}"
    maybe_apply_startup_guard_patch "${payload_launcher}"
    chmod 0755 "${payload_launcher}"
  fi

  proot_bin="$(command -v proot)"
  cp -a --no-preserve=ownership "${proot_bin}" "${APPDIR}/usr/bin/proot"
  chmod 0755 "${APPDIR}/usr/bin/proot"
  build_direct_runtime_shim "${runtime_libdir}"

  if [[ -L "${payload_ca_bundle}" ]]; then
    cp -aL "${payload_ca_bundle}" "${payload_ca_bundle}.tmp"
    mv -f "${payload_ca_bundle}.tmp" "${payload_ca_bundle}"
  fi

  rewrite_text_path_references "${APPDIR}" "${payload_dest}"

  if [[ -n "${CHROMIUM_PAYLOAD_SOURCE}" ]]; then
    mkdir -p "${chromium_dest}"
    rsync -a --delete "${CHROMIUM_PAYLOAD_SOURCE}/" "${chromium_dest}/"
    chmod 0755 "${chromium_dest}/JRWebChromium" 2>/dev/null || true
    chmod 0755 "${chromium_dest}/chrome-sandbox" 2>/dev/null || true
    ln -sfn "../jriver/Media Center 35/Plugins/linux_chromium64/libcef.so" "${runtime_libdir}/libcef.so"
    ln -sfn "../jriver/Media Center 35/libcryptlib.so" "${runtime_libdir}/libcryptlib.so"
    write_jrweb_wrappers "${payload_dest}" "${chromium_dest}" "${runtime_libdir}"
  fi

  if file -Lb --mime-type "${VENDOR_LAUNCHER}" | grep -q '^text/'; then
    PATCHED_VENDOR_LAUNCHER="${APPDIR}/usr/bin/mediacenter35.vendor.patched"
    cp -a --no-preserve=ownership "${VENDOR_LAUNCHER}" "${PATCHED_VENDOR_LAUNCHER}"
    sed -i "s|${VENDOR_ROOT}|"'${APPDIR}/usr/lib/jriver/Media Center 35|g' "${PATCHED_VENDOR_LAUNCHER}"
    chmod 0755 "${PATCHED_VENDOR_LAUNCHER}"
  fi

  apply_runtime_path_fixes "${payload_dest}" "${chromium_dest}" "${runtime_libdir}"
}

find_icon_source() {
  find /usr/share/icons /usr/share/pixmaps -type f \
    \( -iname '*jriver*.png' -o -iname '*jriver*.svg' -o -iname '*mediacenter*.png' -o -iname '*mediacenter*.svg' \) \
    2>/dev/null | head -n 1 || true
}

write_fallback_icon() {
  local icon_path="${APPDIR}/usr/share/icons/hicolor/scalable/apps/${ICON_BASENAME}.svg"
  mkdir -p "$(dirname "${icon_path}")"
  cat >"${icon_path}" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <rect width="256" height="256" rx="28" fill="#111827"/>
  <path d="M54 70h86c36 0 56 18 56 48 0 21-12 37-33 45l39 59h-38l-34-53H90v53H54V70zm36 29v41h47c15 0 24-8 24-20 0-13-9-21-24-21H90zm92-29h20v152h-20z" fill="#f9fafb"/>
</svg>
EOF
}

link_root_icon() {
  local target="$1"
  local extension="$2"

  ln -sf "${target}" "${APPDIR}/.DirIcon"
  ln -sf "${target}" "${APPDIR}/${ICON_BASENAME}.${extension}"
}

write_desktop_assets() {
  local desktop_path="${APPDIR}/usr/share/applications/${DESKTOP_ID}"
  local icon_source
  icon_source="$(find_icon_source)"

  cat >"${desktop_path}" <<EOF
[Desktop Entry]
Type=Application
Name=${APP_NAME}
Exec=AppRun %U
Icon=${ICON_BASENAME}
Categories=AudioVideo;Player;Audio;Video;
Terminal=false
StartupNotify=true
EOF

  ln -sf "usr/share/applications/${DESKTOP_ID}" "${APPDIR}/${DESKTOP_ID}"

  if [[ -n "${icon_source}" ]]; then
    local extension="${icon_source##*.}"
    local icon_dest="${APPDIR}/usr/share/icons/hicolor/256x256/apps/${ICON_BASENAME}.${extension}"
    mkdir -p "$(dirname "${icon_dest}")"
    cp -a "${icon_source}" "${icon_dest}"
    link_root_icon "usr/share/icons/hicolor/256x256/apps/${ICON_BASENAME}.${extension}" "${extension}"
  else
    write_fallback_icon
    link_root_icon "usr/share/icons/hicolor/scalable/apps/${ICON_BASENAME}.svg" "svg"
  fi

  desktop-file-validate "${desktop_path}" >/dev/null
}

write_launchers() {
  cat >"${APPDIR}/usr/bin/jriver-launch" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APPDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export APPDIR
payload_root="${APPDIR}/usr/lib/jriver/Media Center 35"
cd "${payload_root}"

if [[ "${JRIVER_APPIMAGE_DIRECT_ACTIVE:-0}" == "1" ]]; then
  if [[ -x "${APPDIR}/__PRIMARY_BINARY_REL__" ]]; then
    exec "${APPDIR}/__PRIMARY_BINARY_REL__" "$@"
  fi

  if [[ -x "${payload_root}/mediacenter35" ]]; then
    exec "${payload_root}/mediacenter35" "$@"
  fi
fi

if [[ -x "${APPDIR}/usr/bin/mediacenter35.vendor.patched" ]]; then
  exec "${APPDIR}/usr/bin/mediacenter35.vendor.patched" "$@"
fi

if [[ -x "${APPDIR}/usr/bin/mediacenter35.vendor" ]]; then
  exec "${APPDIR}/usr/bin/mediacenter35.vendor" "$@"
fi

if [[ -x "${APPDIR}/__PRIMARY_BINARY_REL__" ]]; then
  exec "${APPDIR}/__PRIMARY_BINARY_REL__" "$@"
fi

if [[ -x "${payload_root}/Media Center 35" ]]; then
  exec "${payload_root}/Media Center 35" "$@"
fi

if [[ -x "${payload_root}/mediacenter35" ]]; then
  exec "${payload_root}/mediacenter35" "$@"
fi

echo "Unable to find a JRiver launch target inside the AppDir" >&2
exit 1
EOF
  sed -i "s|__PRIMARY_BINARY_REL__|${PRIMARY_BINARY_REL}|g" "${APPDIR}/usr/bin/jriver-launch"
  chmod 0755 "${APPDIR}/usr/bin/jriver-launch"

  cat >"${APPDIR}/AppRun" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APPDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export APPDIR

payload_root="${APPDIR}/usr/lib/jriver/Media Center 35"
chromium_root="${payload_root}/Plugins/linux_chromium64"
runtime_root="${APPDIR}/usr/lib/jriver-runtime"
export PATH="${APPDIR}/usr/bin:${payload_root}${PATH:+:${PATH}}"
if [[ -d "${chromium_root}" ]]; then
  export PATH="${chromium_root}:${PATH}"
fi
export XDG_DATA_DIRS="${APPDIR}/usr/share${XDG_DATA_DIRS:+:${XDG_DATA_DIRS}}"
export JRIVER_APPIMAGE="1"

activate_direct_runtime_shim() {
  if [[ "${JRIVER_APPIMAGE_USE_PATH_SHIM:-1}" != "1" ]]; then
    return
  fi

  if [[ -f "${runtime_root}/libjriver-pathshim.so" ]]; then
    export LD_PRELOAD="${runtime_root}/libjriver-pathshim.so${LD_PRELOAD:+:${LD_PRELOAD}}"
  fi
}

if [[ "${JRIVER_APPIMAGE_USE_LEGACY_LD_PATH:-0}" == "1" ]]; then
  export LD_LIBRARY_PATH="${payload_root}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  if [[ -d "${chromium_root}" ]]; then
    export LD_LIBRARY_PATH="${chromium_root}:${LD_LIBRARY_PATH}"
  fi
  if [[ -d "${runtime_root}" ]]; then
    export LD_LIBRARY_PATH="${runtime_root}:${LD_LIBRARY_PATH}"
  fi
fi

if [[ "${JRIVER_APPIMAGE_USE_PRELOAD:-0}" == "1" && -f "${runtime_root}/libcef.so" ]]; then
  export LD_PRELOAD="${runtime_root}/libcef.so${LD_PRELOAD:+:${LD_PRELOAD}}"
else
  unset LD_PRELOAD || true
fi

if [[ "${JRIVER_APPIMAGE_USE_DIRECT:-0}" == "1" || "${JRIVER_APPIMAGE_NOPROOT:-0}" == "1" ]]; then
  export JRIVER_APPIMAGE_DIRECT_ACTIVE=1
  activate_direct_runtime_shim
  exec "${APPDIR}/usr/bin/jriver-launch" "$@"
fi

if [[ -x "/usr/bin/bwrap" && "${JRIVER_APPIMAGE_USE_BWRAP:-0}" == "1" ]]; then
  if /usr/bin/bwrap --bind / / --symlink /tmp /usr/lib/jriver /bin/true >/dev/null 2>&1; then
    exec /usr/bin/bwrap \
      --bind / / \
      --symlink "${APPDIR}/usr/lib/jriver" /usr/lib/jriver \
      --symlink "${APPDIR}/usr/lib/jriver-runtime" /usr/lib/jriver-runtime \
      --symlink "${APPDIR}/usr/bin/mediacenter35.vendor" /usr/bin/mediacenter35 \
      "${APPDIR}/usr/bin/jriver-launch" "$@"
  fi
fi

if [[ -x "${APPDIR}/usr/bin/proot" && "${JRIVER_APPIMAGE_USE_PROOT:-0}" == "1" ]]; then
  exec "${APPDIR}/usr/bin/proot" \
    -b "${payload_root}:/usr/lib/jriver/Media Center 35" \
    -b "${APPDIR}/usr/lib/jriver-runtime:/usr/lib/jriver-runtime" \
    -b "${APPDIR}/usr/bin/mediacenter35.vendor:/usr/bin/mediacenter35" \
    "${APPDIR}/usr/bin/jriver-launch" "$@"
fi

export JRIVER_APPIMAGE_DIRECT_ACTIVE=1
activate_direct_runtime_shim
exec "${APPDIR}/usr/bin/jriver-launch" "$@"
EOF
  chmod 0755 "${APPDIR}/AppRun"
}

should_exclude_library() {
  case "$1" in
    /lib*/ld-linux*.so*|/lib*/libc.so*|/lib*/libm.so*|/lib*/libpthread.so*|/lib*/libdl.so*|/lib*/librt.so*|/lib*/libresolv.so*|/lib*/libutil.so*|/lib*/libnsl.so*|/lib*/libanl.so*)
      return 0
      ;;
    /usr/lib*/dri/*|/usr/lib*/libEGL.so*|/usr/lib*/libGL.so*|/usr/lib*/libGLX.so*|/usr/lib*/libGLdispatch.so*|/usr/lib*/libgbm.so*|/usr/lib*/libdrm*.so*|/usr/lib*/libvulkan.so*|/usr/lib*/libva*.so*)
      return 0
      ;;
  esac
  return 1
}

copy_dependency() {
  local src="$1"
  cp -a --parents "${src}" "${APPDIR}"
  if [[ -L "${src}" ]]; then
    local resolved
    resolved="$(readlink -f "${src}")"
    if [[ -e "${resolved}" ]]; then
      cp -a --parents "${resolved}" "${APPDIR}"
    fi
  fi
}

extract_ldd_paths() {
  local line path
  while IFS= read -r line; do
    if [[ "${line}" == *' => '*' ('* ]]; then
      path="${line#*=> }"
      path="${path%% (*}"
    elif [[ "${line}" == /*' ('* ]]; then
      path="${line%% (*}"
    else
      continue
    fi

    [[ -e "${path}" ]] || continue
    printf '%s\n' "${path}"
  done
}

harvest_dependencies() {
  local bundled_manifest="${MANIFEST_DIR}/bundled-libraries.txt"
  local excluded_manifest="${MANIFEST_DIR}/excluded-libraries.txt"
  local readelf_dir="${MANIFEST_DIR}/readelf"
  local ldd_dir="${LOG_DIR}/ldd"
  local candidate=""

  mkdir -p "${readelf_dir}" "${ldd_dir}"
  : >"${bundled_manifest}"
  : >"${excluded_manifest}"

  declare -A queued=()
  declare -A copied=()
  local -a queue=()

  while IFS= read -r -d '' candidate; do
    if is_elf "${candidate}"; then
      queue+=("${candidate}")
    fi
  done < <(find "${APPDIR}/usr/lib/jriver/Media Center 35" "${APPDIR}/usr/bin" -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) -print0)

  while (( ${#queue[@]} > 0 )); do
    local target="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n "${queued["${target}"]+x}" ]] && continue
    queued["${target}"]=1

    local safe_name
    safe_name="$(sanitize_name "${target}")"
    ldd "${target}" >"${ldd_dir}/${safe_name}.txt" 2>&1 || true
    readelf -d "${target}" >"${readelf_dir}/${safe_name}.txt" 2>&1 || true

    while IFS= read -r candidate; do
      if should_exclude_library "${candidate}"; then
        printf '%s\t%s\n' "${target}" "${candidate}" >>"${excluded_manifest}"
        continue
      fi

      if [[ "${candidate}" == "${APPDIR}"/* ]]; then
        if is_elf "${candidate}"; then
          queue+=("${candidate}")
        fi
        continue
      fi

      if [[ -n "${copied["${candidate}"]+x}" ]]; then
        continue
      fi

      copied["${candidate}"]=1
      copy_dependency "${candidate}"
      printf '%s\n' "${candidate}" >>"${bundled_manifest}"

      if is_elf "${APPDIR}${candidate}"; then
        queue+=("${APPDIR}${candidate}")
      elif [[ -L "${APPDIR}${candidate}" ]]; then
        local resolved_copy
        resolved_copy="$(readlink -f "${APPDIR}${candidate}")"
        if [[ -e "${resolved_copy}" ]] && is_elf "${resolved_copy}"; then
          queue+=("${resolved_copy}")
        fi
      fi
    done < <(extract_ldd_paths <"${ldd_dir}/${safe_name}.txt")
  done

  sort -u "${bundled_manifest}" -o "${bundled_manifest}"
  sort -u "${excluded_manifest}" -o "${excluded_manifest}"
}

write_manifests() {
  local build_info="${MANIFEST_DIR}/build-info.txt"
  local tree_manifest="${MANIFEST_DIR}/appdir-tree.txt"
  audit_appdir_paths
  cat >"${build_info}" <<EOF
app_name=${APP_NAME}
package_name=${PACKAGE_NAME}
version=${JRIVER_VERSION}
install_user=${INSTALL_USER}
vendor_root=${VENDOR_ROOT}
vendor_launcher=${VENDOR_LAUNCHER}
primary_binary=${PRIMARY_BINARY}
build_root=${BUILD_ROOT}
appdir=${FINAL_APPDIR:-${APPDIR}}
output_dir=${OUTPUT_DIR}
direct_runtime_opt_in=JRIVER_APPIMAGE_USE_DIRECT=1
direct_runtime_path_shim=JRIVER_APPIMAGE_USE_PATH_SHIM=1
startup_guard_disabled=${DISABLE_STARTUP_GUARD}
EOF

  (
    cd "${APPDIR}"
    find . -mindepth 1 | LC_ALL=C sort
  ) >"${tree_manifest}"
}

build_appimage() {
  local version_slug artifact
  version_slug="${JRIVER_VERSION// /-}"
  artifact="${OUTPUT_DIR}/JRiver-Media-Center-${version_slug}-${APPIMAGE_ARCH}.AppImage"
  rm -f "${artifact}"
  ARCH="${APPIMAGE_ARCH}" VERSION="${JRIVER_VERSION}" "${APPIMAGE_TOOL_PATH}" --appimage-extract-and-run "${APPDIR}" "${artifact}"
  printf '%s\n' "${artifact}" >"${MANIFEST_DIR}/artifact-path.txt"
  cat >"${MANIFEST_DIR}/artifact-info.txt" <<EOF
artifact_path=${artifact}
artifact_name=$(basename "${artifact}")
artifact_sha256=$(sha256_file "${artifact}")
artifact_size_bytes=$(stat -c '%s' "${artifact}")
artifact_mtime=$(stat -c '%y' "${artifact}")
EOF
}

record_baseline() {
  local artifact baseline_path

  [[ -n "${BASELINE_LABEL}" ]] || return 0

  artifact="$(<"${MANIFEST_DIR}/artifact-path.txt")"
  baseline_path="${BASELINE_DIR}/${BASELINE_LABEL}"

  rm -rf "${baseline_path}"
  mkdir -p "${baseline_path}/manifests"
  cp -a "${artifact}" "${baseline_path}/"
  rsync -a "${MANIFEST_DIR}/" "${baseline_path}/manifests/"

  cat >"${baseline_path}/baseline.txt" <<EOF
label=${BASELINE_LABEL}
recorded_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
version=${JRIVER_VERSION}
arch=${APPIMAGE_ARCH}
artifact_name=$(basename "${artifact}")
artifact_sha256=$(sha256_file "${artifact}")
artifact_size_bytes=$(stat -c '%s' "${artifact}")
source_artifact=${artifact}
source_appdir=${APPDIR}
validated_runtime=launch,audio,video
validated_mode=JRIVER_APPIMAGE_USE_DIRECT=1
startup_guard_disabled=${DISABLE_STARTUP_GUARD}
EOF

  ln -sfn "${BASELINE_LABEL}" "${BASELINE_DIR}/current"
}

export_results() {
  [[ -n "${EXPORT_DIR}" ]] || return 0
  mkdir -p "${EXPORT_DIR}"
  local artifact
  artifact="$(<"${MANIFEST_DIR}/artifact-path.txt")"
  cp -a "${artifact}" "${EXPORT_DIR}/"
  rsync -a "${MANIFEST_DIR}/" "${EXPORT_DIR}/manifests/"
}

write_host_instructions() {
  local instruction_file="${MANIFEST_DIR}/host-launch.txt"
  local artifact
  artifact="$(<"${MANIFEST_DIR}/artifact-path.txt")"

  cat >"${instruction_file}" <<EOF
Host launch instructions
========================

1. Copy the artifact out of the jriver container if needed:
   ${artifact}

2. Mark it executable on the host:
   chmod +x ./$(basename "${artifact}")

3. Launch it on the host:
   ./$(basename "${artifact}")

4. Verify separately that packaging succeeded and that runtime behavior improved.
  Current known-good baseline: direct launch, audio playback, and video playback
  have been validated with JRIVER_APPIMAGE_USE_DIRECT=1.

   Build-time startup crash repro switch:
  JRIVER_APPIMAGE_DISABLE_STARTUP_GUARD=${DISABLE_STARTUP_GUARD}

5. To test the new no-namespace fast path explicitly:
  JRIVER_APPIMAGE_USE_DIRECT=1 ./$(basename "${artifact}")

   To build an artifact that reproduces the CActionWindowArray startup crash:
  JRIVER_APPIMAGE_DISABLE_STARTUP_GUARD=1 bash jriver-appimage-packager.sh --skip-prereqs

   To disable the direct-mode path shim while debugging:
   JRIVER_APPIMAGE_USE_DIRECT=1 JRIVER_APPIMAGE_USE_PATH_SHIM=0 ./$(basename "${artifact}")

6. To force the old compatibility paths for comparison:
  JRIVER_APPIMAGE_USE_PROOT=1 ./$(basename "${artifact}")
  JRIVER_APPIMAGE_USE_BWRAP=1 ./$(basename "${artifact}")
EOF
}

main() {
  parse_args "$@"
  prepare_build_root
  run_step ensure-prereqs ensure_prereqs
  run_step install-jriver install_jriver
  run_step detect-layout detect_vendor_layout
  run_step bootstrap-chromium bootstrap_chromium_payload
  run_step copy-payload copy_payload
  run_step write-assets write_desktop_assets
  run_step write-launchers write_launchers
  run_step harvest-dependencies harvest_dependencies
  run_step write-manifests write_manifests
  run_step build-appimage build_appimage
  run_step finalize-appdir finalize_appdir
  run_step record-baseline record_baseline
  run_step export-results export_results
  run_step host-instructions write_host_instructions

  msg OK "AppImage build complete"
  msg OK "Build root: ${BUILD_ROOT}"
  msg OK "Artifact: $(<"${MANIFEST_DIR}/artifact-path.txt")"
  msg OK "Manifests: ${MANIFEST_DIR}"
  if [[ -n "${EXPORT_DIR}" ]]; then
    msg OK "Export dir: ${EXPORT_DIR}"
  fi
}

main "$@"
