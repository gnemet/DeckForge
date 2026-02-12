#!/bin/bash

# DeckForge Multi-Platform Release Generator
# Generates 4 distributions: win11online, win11offline, linuxOn, linuxOff

set -e

APP_NAME="DeckForge"
VERSION=$(grep -oP 'version: "\K[^"]+' config.yaml || echo "0.2.0")
RELEASE_DIR="releases"

echo "🎯 Building Release Bundle for v$VERSION..."

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# Common function to create a bundle
create_bundle() {
    local platform=$1    # win or linux
    local mode=$2        # online or offline
    local label=$3       # win11online, etc.
    local target_dir="$RELEASE_DIR/$label"
    
    echo "📦 Creating $label..."
    mkdir -p "$target_dir/uploads" "$target_dir/thumbnails"
    
    # Copy binary
    if [ "$platform" == "win" ]; then
        cp "$RELEASE_DIR/bin/DeckForge.exe" "$target_dir/DeckForge.exe"
        cat <<EOF > "$target_dir/RUN.bat"
@echo off
DeckForge.exe
pause
EOF
    else
        cp "$RELEASE_DIR/bin/slideforge_linux" "$target_dir/slideforge"
        chmod +x "$target_dir/slideforge"
        cat <<EOF > "$target_dir/run.sh"
#!/bin/bash
./slideforge
EOF
        chmod +x "$target_dir/run.sh"
    fi
    
    # Handle Config
    cp config.yaml "$target_dir/config.yaml"
    if [ "$mode" == "offline" ]; then
        sed -i 's/active_provider: "gemini"/active_provider: "local"/' "$target_dir/config.yaml"
    else
        sed -i 's/active_provider: "local"/active_provider: "gemini"/' "$target_dir/config.yaml"
    fi
    
    # Create ZIP
    cd "$RELEASE_DIR"
    zip -r "$label.zip" "$label" > /dev/null
    cd ..
    
    echo "✅ $label.zip created."
}

# 1. Compile Binaries
mkdir -p "$RELEASE_DIR/bin"

echo "🚀 Compiling Windows binary..."
GOOS=windows GOARCH=amd64 go build -o "$RELEASE_DIR/bin/DeckForge.exe" ./cmd/server

echo "🚀 Compiling Linux binary..."
GOOS=linux GOARCH=amd64 go build -o "$RELEASE_DIR/bin/slideforge_linux" ./cmd/server

# 2. Generate Bundles
create_bundle "win"   "online"  "win11online"
create_bundle "win"   "offline" "win11offline"
create_bundle "linux" "online"  "linuxOn"
create_bundle "linux" "offline" "linuxOff"

echo "------------------------------------------------"
echo "All release artifacts ready in $RELEASE_DIR/"
ls -lh "$RELEASE_DIR"/*.zip
echo "------------------------------------------------"
