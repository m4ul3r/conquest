## Setup script for downloading and configuring the LLVM-MinGW cross-compiler toolchain
## Run via: nimble setup

import std/[os, osproc, strformat, strutils]

const
  LLVM_VERSION = "20251216"
  BASE_URL = "https://github.com/mstorsjo/llvm-mingw/releases/download"

proc main() =
  # Get project root (script is in scripts/, so go up one level)
  let projectRoot = getCurrentDir()
  let toolchainsDir = projectRoot / "bin" / "toolchains"

  echo "Setting up LLVM-MinGW toolchain..."
  echo fmt"Project root: {projectRoot}"

  createDir(toolchainsDir)

  # Detect platform and select appropriate archive
  when defined(macosx):
    let archiveName = fmt"llvm-mingw-{LLVM_VERSION}-ucrt-macos-universal.tar.xz"
    let extractedName = fmt"llvm-mingw-{LLVM_VERSION}-ucrt-macos-universal"
  elif defined(linux):
    let archiveName = fmt"llvm-mingw-{LLVM_VERSION}-ucrt-ubuntu-22.04-x86_64.tar.xz"
    let extractedName = fmt"llvm-mingw-{LLVM_VERSION}-ucrt-ubuntu-22.04-x86_64"
  else:
    echo "Error: Unsupported platform. Only Linux and macOS are supported."
    quit(1)

  let
    url = fmt"{BASE_URL}/{LLVM_VERSION}/{archiveName}"
    archivePath = toolchainsDir / archiveName
    extractedPath = toolchainsDir / extractedName
    symlinkPath = toolchainsDir / "llvm-mingw"

  # Check if already setup
  if symlinkExists(symlinkPath) and dirExists(extractedPath):
    echo "Toolchain already installed at: " & symlinkPath
    echo "To reinstall, remove the existing toolchain first."
    return

  # Download the archive
  echo fmt"Downloading from: {url}"
  echo "This may take a few minutes (~77MB)..."

  let curlCmd = fmt"curl -L --progress-bar -o {archivePath} {url}"
  let downloadResult = execCmd(curlCmd)
  if downloadResult != 0:
    echo "Error: Failed to download toolchain"
    quit(1)

  # Verify download
  if not fileExists(archivePath):
    echo "Error: Downloaded file not found"
    quit(1)

  # Extract the archive
  echo "Extracting toolchain..."
  let tarCmd = fmt"tar -xf {archivePath} -C {toolchainsDir}"
  let extractResult = execCmd(tarCmd)
  if extractResult != 0:
    echo "Error: Failed to extract toolchain"
    quit(1)

  # Remove old symlink if it exists
  if symlinkExists(symlinkPath):
    removeFile(symlinkPath)
  elif fileExists(symlinkPath):
    removeFile(symlinkPath)
  elif dirExists(symlinkPath):
    removeDir(symlinkPath)

  # Create symlink
  echo fmt"Creating symlink: {symlinkPath} -> {extractedName}"
  createSymlink(extractedPath, symlinkPath)

  # Cleanup archive to save space
  echo "Cleaning up archive..."
  removeFile(archivePath)

  echo ""
  echo "Toolchain setup complete!"
  echo fmt"Installed at: {symlinkPath}"
  echo ""
  echo "You can now build ARM64 agents with: nimble server"

when isMainModule:
  main()
