#!/usr/bin/env bash
# ==============================================================================
# Standalone Code-Server State Hydration Engine
# Restores full workspace, .claude chat sessions, configs, and shell setups
# 100% Host-Safe: Zero OpenSSH Daemons, Zero Port 22 Listeners, Zero Backdoors
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-gdrive:coolify-relay-state/coolify-state}"
FALLBACK_STORAGE_TARGET="gdrive:coolify-relay-state/code_server-state"
LEGACY_VOLUMES_TARGET="gdrive:coolify-relay-state/coolify-state/volumes_bundle.tar.gz"
STAGE_DIR="/tmp/code_server_stage"
WORKSPACE_DIR="/home/runner/workspace"
CLAUDE_DIR="/home/runner/.claude"
CONFIG_DIR="/home/runner/.config/code-server"

echo "[HYDRATE] === Initializing Standalone Code-Server Environment ==="

mkdir -p "$STAGE_DIR" "$WORKSPACE_DIR" "$CLAUDE_DIR" "$CONFIG_DIR"
sudo chown -R runner:docker "$WORKSPACE_DIR" "$CLAUDE_DIR" /home/runner/.config /home/runner/.local 2>/dev/null || true

# 1. Check for dedicated Code-Server State Archive across all possible storage targets
echo "[HYDRATE] Checking for existing code_server_bundle.tar.gz on cloud storage..."
CODE_SERVER_ARCHIVE_VALID=false
BUNDLE_SOURCE=""

POSSIBLE_TARGETS=(
  "gdrive:coolify-relay-state/coolify-state"
  "gdrive:coolify-relay-state/code_server-state"
  "${STORAGE_TARGET}"
  "${1:-}"
)

for target in "${POSSIBLE_TARGETS[@]}"; do
  [ -z "$target" ] && continue
  echo "[HYDRATE] Probing $target/code_server_bundle.tar.gz ..."
  if rclone ls "$target/code_server_bundle.tar.gz" >/dev/null 2>&1; then
    BUNDLE_SOURCE="$target/code_server_bundle.tar.gz"
    echo "[HYDRATE] SUCCESS: Found code_server_bundle.tar.gz at $BUNDLE_SOURCE!"
    break
  fi
done

if [ -n "$BUNDLE_SOURCE" ]; then
  echo "[HYDRATE] Downloading $BUNDLE_SOURCE to local stage..."
  rclone copyto "$BUNDLE_SOURCE" "$STAGE_DIR/code_server_bundle.tar.gz" \
    --drive-chunk-size=256M --buffer-size=64M --retries=5 --timeout=5m

  # Check if archive actually has workspace files (more than 15 entries)
  ENTRY_COUNT=$(tar -tzf "$STAGE_DIR/code_server_bundle.tar.gz" 2>/dev/null | wc -l || echo 0)
  echo "[HYDRATE] Archive entries count: $ENTRY_COUNT"
  if [ "$ENTRY_COUNT" -gt 15 ]; then
    echo "[HYDRATE] Extracting full workspace, .claude chats, and environment configs..."
    if command -v pigz >/dev/null 2>&1; then
      pigz -dc "$STAGE_DIR/code_server_bundle.tar.gz" | tar -xpf - -C /home/runner
    else
      tar -xzpf "$STAGE_DIR/code_server_bundle.tar.gz" -C /home/runner
    fi
    CODE_SERVER_ARCHIVE_VALID=true
    echo "[HYDRATE] Native code-server state restored successfully!"
  else
    echo "[HYDRATE] Notice: code_server_bundle.tar.gz is empty or incomplete ($ENTRY_COUNT entries). Falling back to volumes_bundle.tar.gz!"
  fi
fi

# 2. Migration Path: Extract from legacy Coolify Docker volumes bundle
if [ "$CODE_SERVER_ARCHIVE_VALID" != "true" ] && (rclone ls "$LEGACY_VOLUMES_TARGET" >/dev/null 2>&1); then
  echo "[HYDRATE] Downloading legacy volumes_bundle.tar.gz from Coolify backup..."
  rclone copyto "$LEGACY_VOLUMES_TARGET" "$STAGE_DIR/volumes_bundle.tar.gz" \
    --drive-chunk-size=256M --buffer-size=64M --retries=5 --timeout=3m

  MIGRATE_TEMP="/tmp/legacy_volume_extract"
  mkdir -p "$MIGRATE_TEMP"
  echo "[HYDRATE] Unpacking legacy volumes to search for /config, /workspace, and .claude..."
  if command -v pigz >/dev/null 2>&1; then
    pigz -dc "$STAGE_DIR/volumes_bundle.tar.gz" | tar -xpf - -C "$MIGRATE_TEMP" 2>/dev/null || true
  else
    tar -xzpf "$STAGE_DIR/volumes_bundle.tar.gz" -C "$MIGRATE_TEMP" 2>/dev/null || true
  fi

  # Deep search across all extracted volumes for files
  echo "[HYDRATE] Scanning extracted volumes for Claude sessions, configs, and projects..."

  # 1. Restore Claude sessions
  find "$MIGRATE_TEMP" -type d -name ".claude" 2>/dev/null | while read -r cdir; do
    echo "[HYDRATE] Found Claude history at $cdir. Restoring..."
    cp -rn "$cdir/." "$CLAUDE_DIR/" 2>/dev/null || true
  done

  # 2. Restore any .claude.json
  find "$MIGRATE_TEMP" -name ".claude.json" -exec cp -n {} /home/runner/ \; 2>/dev/null || true

  # 3. Restore all project directories, python scripts, bots, and shell files
  find "$MIGRATE_TEMP" -type d \( -name "workspace" -o -name "project" -o -name "projects" \) 2>/dev/null | while read -r wdir; do
    echo "[HYDRATE] Found workspace at $wdir. Restoring to $WORKSPACE_DIR..."
    cp -rn "$wdir/." "$WORKSPACE_DIR/" 2>/dev/null || true
  done

  # 4. Extract any sub-folders that look like user projects
  find "$MIGRATE_TEMP" -mindepth 2 -maxdepth 4 -type d \( -name "*bot*" -o -name "*grabber*" -o -name "*Vault*" -o -name "startup_scripts*" -o -name "*manga*" -o -name "*tts*" \) 2>/dev/null | while read -r pdir; do
    echo "[HYDRATE] Found project folder $(basename "$pdir"). Restoring..."
    cp -rn "$pdir" "$WORKSPACE_DIR/" 2>/dev/null || true
  done

  # 5. Extract all startup scripts
  find "$MIGRATE_TEMP" -maxdepth 5 -type f -name "*.sh" 2>/dev/null | while read -r sfile; do
    cp -n "$sfile" "$WORKSPACE_DIR/" 2>/dev/null || true
  done

  rm -rf "$MIGRATE_TEMP"
fi

# 3. Bi-directional Claude Code chat session & memory bridging across workspace roots
mkdir -p "$CLAUDE_DIR/projects/-config-workspace" "$CLAUDE_DIR/projects/-home-runner-workspace"
if [ -d "$CLAUDE_DIR/projects/-config-workspace" ] && [ -d "$CLAUDE_DIR/projects/-home-runner-workspace" ]; then
  echo "[HYDRATE] Bridging Claude persistent memories and past chat sessions bi-directionally..."
  for f in "$CLAUDE_DIR/projects/-config-workspace"/*; do
    fname=$(basename "$f")
    [ "$fname" = "*" ] && continue
    if [ ! -e "$CLAUDE_DIR/projects/-home-runner-workspace/$fname" ]; then
      if [ -d "$f" ]; then
        cp -rn "$f" "$CLAUDE_DIR/projects/-home-runner-workspace/" 2>/dev/null || true
      else
        ln "$f" "$CLAUDE_DIR/projects/-home-runner-workspace/$fname" 2>/dev/null || cp -n "$f" "$CLAUDE_DIR/projects/-home-runner-workspace/" 2>/dev/null || true
      fi
    fi
  done
  for f in "$CLAUDE_DIR/projects/-home-runner-workspace"/*; do
    fname=$(basename "$f")
    [ "$fname" = "*" ] && continue
    if [ ! -e "$CLAUDE_DIR/projects/-config-workspace/$fname" ]; then
      if [ -d "$f" ]; then
        cp -rn "$f" "$CLAUDE_DIR/projects/-config-workspace/" 2>/dev/null || true
      else
        ln "$f" "$CLAUDE_DIR/projects/-config-workspace/$fname" 2>/dev/null || cp -n "$f" "$CLAUDE_DIR/projects/-config-workspace/" 2>/dev/null || true
      fi
    fi
  done
fi

# 4. Ensure permissions and directories are clean
sudo chown -R runner:docker "$WORKSPACE_DIR" "$CLAUDE_DIR" /home/runner/.config /home/runner/.local 2>/dev/null || true
[ -f "/home/runner/.claude.json" ] && sudo chown runner:docker /home/runner/.claude.json 2>/dev/null || true
RESTORED_COUNT=$(find "$WORKSPACE_DIR" -mindepth 1 2>/dev/null | wc -l || echo 0)
echo "[HYDRATE] Hydration complete. $RESTORED_COUNT files available in $WORKSPACE_DIR."

# 5. Compatibility Bridge: Set up /config directory & runtime environments
sudo mkdir -p /config /home/runner/.hermes /home/runner/.suwayomi_state
sudo chown -R runner:docker /config /home/runner/.hermes /home/runner/.suwayomi_state
ln -sfn "$WORKSPACE_DIR" /config/workspace
ln -sfn /home/runner/.hermes /config/.hermes
ln -sfn /home/runner/.suwayomi_state /config/suwayomi_state
ln -sf "$WORKSPACE_DIR"/start*.sh /config/ 2>/dev/null || true

# Step 5b: Persistent virtualenv symlink to workspace & automated fallback bootstrap
if [ -d "$WORKSPACE_DIR/.hermes-venv" ]; then
  echo "[HYDRATE] Linking persistent virtualenv $WORKSPACE_DIR/.hermes-venv -> /config/hermes-venv..."
  ln -sfn "$WORKSPACE_DIR/.hermes-venv" /config/hermes-venv
elif [ ! -x "/config/hermes-venv/bin/python" ]; then
  echo "[HYDRATE] Initializing fresh runtime environment in $WORKSPACE_DIR/.hermes-venv..."
  python3 -m venv "$WORKSPACE_DIR/.hermes-venv"
  ln -sfn "$WORKSPACE_DIR/.hermes-venv" /config/hermes-venv
  /config/hermes-venv/bin/pip install --upgrade pip setuptools wheel --no-cache-dir
  /config/hermes-venv/bin/pip install --no-cache-dir \
    aiohttp "telethon==1.44.0" tgcrypto cryptg \
    pyTelegramBotAPI requests cryptography flask APScheduler PyGithub psutil Pillow curl_cffi \
    fastapi uvicorn websockets python-dotenv miniaudio pydantic numpy playwright beautifulsoup4 "certifi==2026.5.20" hermes-agent
fi
