#!/usr/bin/env bash
set -euo pipefail
set -x

#=============================
# Configurable variables
#=============================
: "${WORK_DIR:=${HOME}/ws}"          # 作業ディレクトリ（任意で上書き可）
: "${HOME:=/root}"                  # root を想定
: "${BRANCH_NEOVIM:=master}"        # neovim のブランチ: stable or master
: "${DOTFILES_REPO:=https://github.com/NasParagas/dotfiles.git}"

export HOME
export DEBIAN_FRONTEND=noninteractive

# 環境の基本 PATH（nvm / cargo を後から通す）
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#=============================
# Pre-checks
#=============================
if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

mkdir -p "${WORK_DIR}"

#=============================
# APT: 基本パッケージの導入
#=============================
# リストを掃除してから更新
rm -rf /var/lib/apt/lists/*
apt clean
apt update -y

# パッケージ群をインストール（--no-install-recommends で軽量化）
apt install -y --no-install-recommends \
  git \
  vim \
  wget \
  curl \
  ca-certificates \
  openssl \
  build-essential \
  unzip \
  ninja-build \
  gettext \
  cmake \
  llvm \
  clang \
  libclang-dev \
  libssl-dev \
  libopencv-dev \
  openssh-server \
  pkg-config \
  libtool \
  autoconf \
  automake

# APT キャッシュ削除
rm -rf /var/lib/apt/lists/*

#=============================
# Rust / Cargo（tree-sitter-cli 用）
#=============================
# rustup 非対話でインストール（-y）
# 既に存在する場合はスキップ
if [[ ! -x "${HOME}/.cargo/bin/rustc" ]]; then
  # shellcheck disable=SC1117
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y
fi

# cargo の PATH を現在シェルに反映
if [[ -f "${HOME}/.cargo/env" ]]; then
  # shellcheck disable=SC1090
  source "${HOME}/.cargo/env"
fi

# tree-sitter CLI（必要なら）
if ! command -v tree-sitter >/dev/null 2>&1; then
  cargo install tree-sitter-cli || true
fi

# システム全体に PATH を通す（再ログイン時にも有効化）
install -d /etc/profile.d
cat >/etc/profile.d/cargo_path.sh <<'EOF'
# cargo
if [ -f "$HOME/.cargo/env" ]; then
  . "$HOME/.cargo/env"
fi
EOF
chmod 644 /etc/profile.d/cargo_path.sh

#=============================
# Node.js / npm: nvm → n
#=============================
# nvm インストール（root のホームに入る点に注意）
if [[ ! -d "${HOME}/.nvm" ]]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi

# 現在のシェルに nvm をロード
export NVM_DIR="${HOME}/.nvm"
# shellcheck disable=SC1090
[ -s "${NVM_DIR}/nvm.sh" ] && . "${NVM_DIR}/nvm.sh"

# とりあえず Node v24 を入れる（Dockerfile 相当）
nvm install 24
node -v
npm -v

# グローバルに 'n' を入れて、最新安定へスイッチ
npm install -g n
# 'n' は /usr/local 以下を書き換えるため root 前提
n latest
n prune

# 'n' で入れた Node を優先
hash -r
node -v
npm -v

#=============================
# （任意）LSP/ツール例：pyright 等
#=============================
# 好みに応じて増減してください
npm install -g pyright typescript typescript-language-serve yarn

#=============================
# Neovim: ソースからビルド & インストール
#=============================
cd "${WORK_DIR}"

# 既存の neovim ディレクトリがあれば削除（クリーンビルド）
if [[ -d "${WORK_DIR}/neovim" ]]; then
  rm -rf "${WORK_DIR}/neovim"
fi

git clone https://github.com/neovim/neovim --branch "${BRANCH_NEOVIM}" --depth 1
cd neovim

# RelWithDebInfo でビルド
make CMAKE_BUILD_TYPE=RelWithDebInfo
make install

# ソースは削除して軽量化
cd "${WORK_DIR}"
rm -rf "${WORK_DIR}/neovim"

#=============================
# dotfiles: 取得してシンボリック設定
#=============================
cd "${WORK_DIR}"

if [[ -d "${WORK_DIR}/dotfiles" ]]; then
  # 既存がある場合は更新（変更取り込み）
  cd "${WORK_DIR}/dotfiles"
  git pull --rebase --autostash || true
else
  git clone "${DOTFILES_REPO}"
  cd "${WORK_DIR}/dotfiles"
fi

# dotfiles 内のセットアップスクリプトを実行
# これが root の $HOME に対してリンクを張る点に注意
if [[ -x "./setup_config_symlink.sh" ]]; then
  ./setup_config_symlink.sh
else
  echo "WARN: setup_config_symlink.sh not found or not executable in dotfiles repo." >&2
fi

cd "${WORK_DIR}"

#=============================
# 仕上げ: 環境変数の永続化
#=============================
# nvm をログイン時に自動ロード
cat >/etc/profile.d/nvm.sh <<'EOF'
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh"
fi
EOF
chmod 644 /etc/profile.d/nvm.sh

# 追加の PATH が必要ならここで /etc/profile.d に追記可能

echo "Neovim environment setup completed successfully."
