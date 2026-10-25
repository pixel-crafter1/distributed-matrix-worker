#!/usr/bin/env bash
# ==============================================================================
# Standalone Code-Server State Backup & Google Drive Sync Script
# High-Speed Multi-Core (pigz) Archiving of Workspace, .claude chats, & configs
# Clean & Fast: Syncs in ~10 seconds with atomic .partial promotion
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-gdrive:coolify-relay-state/code_server-state}"
STAGE_DIR="/tmp/code_server_stage"
WORKSPACE_DIR="/home/runner/workspace"
CLAUDE_DIR="/home/runner/.claude"
CONFIG_DIR="/home/runner/.config/code-server"
LOCAL_ARCHIVE="$STAGE_DIR/code_server_bundle.tar.gz"

echo "[SYNC] === Initiating Code-Server Full Workspace & Chat Sync ==="
mkdir -p "$STAGE_DIR"

# 1. Clean scratch/temp files before packing
rm -rf "$WORKSPACE_DIR"/**/__pycache__ "$WORKSPACE_DIR"/**/.pytest_cache 2>/dev/null || true

# 2. Archive entire workspace, claude chat history, and code-server config
echo "[SYNC] Packaging workspace, .claude sessions, and code-server configs..."
TARGETS_TO_PACK=()
[ -d "$WORKSPACE_DIR" ] && TARGETS_TO_PACK+=("workspace")
[ -d "$CLAUDE_DIR" ] && TARGETS_TO_PACK+=(".claude")
[ -f "/home/runner/.claude.json" ] && TARGETS_TO_PACK+=(".claude.json")
[ -d "$CONFIG_DIR" ] && TARGETS_TO_PACK+=(".config/code-server")
[ -d "/home/runner/.local/share/code-server" ] && TARGETS_TO_PACK+=(".local/share/code-server")

if [ ${#TARGETS_TO_PACK[@]} -eq 0 ]; then
  echo "[SYNC] Warning: No directories found to pack. Aborting sync."
  exit 0
fi

# Guard: Never overwrite cloud state with an empty workspace
WORKSPACE_FILES=$(find "$WORKSPACE_DIR" -mindepth 1 2>/dev/null | wc -l || echo 0)
if [ "$WORKSPACE_FILES" -eq 0 ]; then
  echo "[SYNC] Guard Triggered: Workspace is completely empty. Skipping state upload to prevent blank overwrites."
  exit 0
fi

if command -v pigz >/dev/null 2>&1; then
  tar -cpf - -C /home/runner --warning=no-file-changed "${TARGETS_TO_PACK[@]}" | pigz -p 4 -1 > "$LOCAL_ARCHIVE"
else
  tar -czpf "$LOCAL_ARCHIVE" -C /home/runner --warning=no-file-changed "${TARGETS_TO_PACK[@]}"
fi

ARCHIVE_SIZE=$(du -sh "$LOCAL_ARCHIVE" | cut -f1)
echo "[SYNC] Archive created successfully ($ARCHIVE_SIZE). Uploading to cloud storage..."

# 3. Resilient atomic upload via .partial
rclone copyto "$LOCAL_ARCHIVE" "$STORAGE_TARGET/code_server_bundle.tar.gz.partial" \
  --drive-chunk-size=256M \
  --drive-upload-cutoff=32M \
  --buffer-size=64M \
  --use-mmap \
  --retries=5 \
  --timeout=3m

rclone moveto "$STORAGE_TARGET/code_server_bundle.tar.gz.partial" "$STORAGE_TARGET/code_server_bundle.tar.gz"
echo "[SYNC] Full Code-Server state synchronized successfully ($ARCHIVE_SIZE)."
