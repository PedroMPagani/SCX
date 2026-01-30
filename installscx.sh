#!/bin/bash

# --- SCX & SCX_LOADER AUTOMATED INSTALLER ---

# Stop on any error
set -e

echo ">>> [1/8] Stopping existing services..."
# We stop these first to ensure we can overwrite the binary files
sudo systemctl stop scx_loader 2>/dev/null || true
sudo systemctl stop scx.service 2>/dev/null || true

echo ">>> [2/8] Updating System and Installing Dependencies..."
sudo apt update
sudo apt install -y build-essential cmake pkg-config libelf-dev \
    libseccomp-dev libbpf-dev clang llvm pahole git curl \
    protobuf-compiler libssl-dev

echo ">>> [3/8] Installing/Updating Rust..."
# Check if rustup is installed, if not, install it
if ! command -v rustup &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
else
    rustup update
fi
# Ensure we are on stable
rustup default stable

echo ">>> [4/8] Building SCX Schedulers (The Fix)..."
# Clean previous clones if they exist to avoid conflicts
rm -rf scx
git clone https://github.com/sched-ext/scx.git
cd scx

# Build the entire workspace (Compiles all schedulers at once)
echo "   -> Compiling workspace..."
cargo build --release

# Install ONLY the executables to /usr/bin
echo "   -> Installing schedulers to /usr/bin..."
# This command finds files in target/release that start with scx_, are files (not folders), and are executable
find target/release -maxdepth 1 -type f -name "scx_*" -executable -exec sudo cp {} /usr/bin/ \;

cd ..

echo ">>> [5/8] Building SCX Loader..."
rm -rf scx-loader
git clone https://github.com/sched-ext/scx-loader.git
cd scx-loader
cargo build --release

echo ">>> [6/8] Installing SCX Loader Files..."
# Install Binaries
sudo install -Dm755 target/release/scx_loader /usr/bin/scx_loader
sudo install -Dm755 target/release/scxctl /usr/bin/scxctl

# Install Systemd Service
sudo install -Dm644 services/scx_loader.service /usr/lib/systemd/system/scx_loader.service

# Install DBus Service
sudo install -Dm644 services/org.scx.Loader.service /usr/share/dbus-1/system-services/org.scx.Loader.service

# Install DBus Config
sudo install -Dm644 configs/org.scx.Loader.conf /usr/share/dbus-1/system.d/org.scx.Loader.conf

# Install Polkit Policy (Required for permissions)
sudo install -Dm644 configs/org.scx.Loader.policy /usr/share/polkit-1/actions/org.scx.Loader.policy

# Install Config file
# We ensure the directory exists and install the file as 'config.toml'
sudo mkdir -p /usr/share/scx_loader/
sudo install -Dm644 configs/scx_loader.toml /usr/share/scx_loader/config.toml

cd ..

echo ">>> [7/8] Reloading System Services..."
sudo systemctl daemon-reload
sudo systemctl reload dbus

# Enable and Start the Loader
sudo systemctl enable --now scx_loader

echo ">>> [8/8] Verifying and Switching..."
sleep 2 # Wait for service to initialize

if systemctl is-active --quiet scx_loader; then
    echo "SUCCESS: scx_loader is running!"
else
    echo "WARNING: scx_loader failed to start. Dumping logs:"
    journalctl -u scx_loader -n 20 --no-pager
    exit 1
fi

# Switch to LAVD
echo ">>> Switching scheduler to LAVD..."
/usr/bin/scxctl start -s p2dq --mode server
/usr/bin/scxctl switch -s p2dq --mode server
echo "DONE! Current status:"
/usr/bin/scxctl get
