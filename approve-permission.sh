#!/usr/bin/env bash
set -euo pipefail

KEY_PATH="${1:-}"

if [[ -z "${KEY_PATH}" ]]; then
  echo "Usage: ./approve-permission.sh <path-to-private-key>"
  exit 1
fi

# Normalize path for bash tools
# (Allow passing Windows path like E:\path\file.pem; convert to /e/path/file.pem if running under Git Bash/MSYS)
uname_out="$(uname -s || true)"

echo "approve-permission.sh: OS=${uname_out}"
echo "approve-permission.sh: KEY_PATH=${KEY_PATH}"

# Detect Windows (Git Bash / MSYS / MINGW)
if [[ "${uname_out}" =~ (MINGW|MSYS|CYGWIN) ]]; then
  # Convert Windows path to a Windows-native path that icacls accepts
  # If user passes /e/... keep it; if passes E:\... keep it.
  WIN_KEY_PATH="${KEY_PATH}"

  # If path looks like /e/.... then convert to E:\....
  if [[ "${KEY_PATH}" =~ ^/([a-zA-Z])/(.*) ]]; then
    drive="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
    rest="${rest//\//\\}"
    WIN_KEY_PATH="${drive^^}:\\${rest}"
  fi

  echo "Detected Windows shell. Using icacls on: ${WIN_KEY_PATH}"

  # Use cmd.exe to avoid quoting edge cases with icacls in bash
  cmd.exe /c "icacls \"${WIN_KEY_PATH}\" /inheritance:r" > /dev/null
  cmd.exe /c "icacls \"${WIN_KEY_PATH}\" /remove \"NT AUTHORITY\\Authenticated Users\" \"BUILTIN\\Users\" Everyone" > /dev/null
  cmd.exe /c "icacls \"${WIN_KEY_PATH}\" /grant:r \"%USERNAME%:R\" SYSTEM:F \"BUILTIN\\Administrators\":F" > /dev/null
  cmd.exe /c "icacls \"${WIN_KEY_PATH}\"" || true

  echo "ACL updated successfully (Windows)."
  exit 0
fi

# Linux / macOS / WSL
if [[ ! -f "${KEY_PATH}" ]]; then
  echo "Key file not found: ${KEY_PATH}"
  exit 1
fi

echo "Detected Unix-like OS. Applying chmod 600 to: ${KEY_PATH}"
chmod 600 "${KEY_PATH}"
ls -l "${KEY_PATH}" || true

echo "Permission updated successfully (Unix-like)."
