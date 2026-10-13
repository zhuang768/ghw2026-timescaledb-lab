#!/usr/bin/env bash
set -euo pipefail

# Reproduce the isolated source build. Requires a C compiler, make, Python 3,
# zlib/OpenSSL development headers, and tar. Nothing is installed globally.
LAB_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$LAB_ROOT"
mkdir -p sources build runtime

curl --fail --location https://ftp.postgresql.org/pub/source/v17.7/postgresql-17.7.tar.bz2 -o sources/postgresql-17.7.tar.bz2
curl --fail --location https://ftp.postgresql.org/pub/source/v17.7/postgresql-17.7.tar.bz2.sha256 -o sources/postgresql-17.7.tar.bz2.sha256
(cd sources && shasum -a 256 -c postgresql-17.7.tar.bz2.sha256)
curl --fail --location https://github.com/timescale/timescaledb/archive/refs/tags/2.22.1.tar.gz -o sources/timescaledb-2.22.1.tar.gz
curl --fail --location https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.1.tar.gz -o sources/pgvector-0.8.1.tar.gz
tar -xf sources/postgresql-17.7.tar.bz2 -C sources
tar -xf sources/timescaledb-2.22.1.tar.gz -C sources
tar -xf sources/pgvector-0.8.1.tar.gz -C sources

python3 -m venv build/tools
build/tools/bin/python -m pip install --disable-pip-version-check --no-input cmake==3.31.6

# On Apple Silicon this uses an already installed OpenSSL; on other platforms
# configure can find system development headers or use supplied CPPFLAGS/LDFLAGS.
if [[ -d /opt/homebrew/opt/openssl@3 ]]; then
  export CPPFLAGS="${CPPFLAGS:-} -I/opt/homebrew/opt/openssl@3/include"
  export LDFLAGS="${LDFLAGS:-} -L/opt/homebrew/opt/openssl@3/lib"
fi
mkdir -p build/postgres
(
  cd build/postgres
  ../../sources/postgresql-17.7/configure --prefix="$LAB_ROOT/runtime" --without-icu --without-readline --with-openssl
  make -j"${LAB_JOBS:-6}"
  make install
)
build/tools/bin/cmake -S sources/timescaledb-2.22.1 -B build/timescaledb \
  -DPG_CONFIG="$LAB_ROOT/runtime/bin/pg_config" -DCMAKE_BUILD_TYPE=Release \
  -DREGRESS_CHECKS=OFF -DWARNINGS_AS_ERRORS=OFF
build/tools/bin/cmake --build build/timescaledb -j"${LAB_JOBS:-6}"
build/tools/bin/cmake --install build/timescaledb
(
  cd sources/pgvector-0.8.1
  make -j"${LAB_JOBS:-6}" PG_CONFIG="$LAB_ROOT/runtime/bin/pg_config"
  make install PG_CONFIG="$LAB_ROOT/runtime/bin/pg_config"
)

