# Common compiler flags for release builds
FLAGS := "--mm:orc --panics:on -d:useMalloc --threads:on -d:release --opt:size --passL:-flto --passC:-flto -d:strip -d:MaxThreadPoolSize=4 --outdir:build"

acap_name := "sauron"
build_dir := "build"
entry_point := "src/sauron.nim"

# Architecture-specific directories and output files
build_dir_aarch64 := build_dir/"aarch64"
build_dir_armv7 := build_dir/"armv7"
build_dir_amd64 := build_dir/"amd64"
eap_aarch64 := build_dir_aarch64/acap_name +"_aarch64.eap"
eap_armv7 := build_dir_armv7/acap_name +"_armv7.eap"

default:
    just --list

# Build for aarch64
build-aarch64 *args:
    @just _setup-build-dir {{ build_dir_aarch64 }}
    nim c --cpu:arm64 --os:linux {{ FLAGS }} --out:{{ build_dir_aarch64 }}/{{ acap_name }} {{ args }} {{ entry_point }}
    @just _capture-env {{ build_dir_aarch64 }}

# Build for amd64
build-amd64 *args:
    @just _setup-build-dir {{ build_dir_amd64 }}
    nim c --cpu:amd64 --os:linux {{ FLAGS }} --out:{{ build_dir_amd64 }}/{{ acap_name }} {{ args }} {{ entry_point }}
    @just _capture-env {{ build_dir_amd64 }}

# Build for armv7
build-armv7 *args:
    @just _setup-build-dir {{ build_dir_armv7 }}
    nim c --cpu:arm --os:linux {{ FLAGS }} --out:{{ build_dir_armv7 }}/{{ acap_name }} {{ args }} {{ entry_point }}
    @just _capture-env {{ build_dir_armv7 }}

# Build binary for all archs
build: 
    just build-aarch64
    just build-armv7
    just build-amd64

# Build aarch64 and armv7 acap
build-acap: 
    just build-acap-aarch64
    just build-acap-armv7 

# Build armv7 acap
build-acap-armv7: 
    just build-armv7
    cp {{ build_dir_armv7 }}/{{ acap_name }} ./{{ acap_name }}
    cp acap/armv7/manifest.json ./manifest.json
    cp acap/param.conf ./param.conf
    cp acap/LICENSE ./LICENSE
    cp acap/package.conf ./package.conf
    @tar cvfz {{ eap_armv7 }} {{ acap_name }} manifest.json param.conf LICENSE package.conf
    @rm {{ acap_name }} manifest.json param.conf LICENSE package.conf

# Build aarch64 acap
build-acap-aarch64: 
    just build-aarch64
    cp {{ build_dir_aarch64 }}/{{ acap_name }} ./{{ acap_name }}
    cp acap/aarch64/manifest.json ./manifest.json
    cp acap/param.conf ./param.conf
    cp acap/LICENSE ./LICENSE
    cp acap/package.conf ./package.conf
    @tar cvfz {{ eap_aarch64 }} {{ acap_name }} manifest.json param.conf LICENSE package.conf
    @rm {{ acap_name }} manifest.json param.conf LICENSE package.conf

# Build aarch64 and armv7 via docker container
docker-build: 
    @docker build -t builder .
    docker run -v "{{ justfile_directory() }}:/root/src" -w "/root/src" builder just build-acap
    @docker run -v "{{ justfile_directory() }}:/root/src" -w "/root/src" builder chown -R --reference=.gitignore ./build

build-debug:
    nim c --mm:orc -d:useMalloc --threads:on --lineDir:on --debuginfo --debugger:native -d:MaxThreadPoolSize=4 {{ entry_point }} 

# Format according to nim standards
format:
    find . -name '*.nim' -exec nimpretty {} +

# Send armv7 binary to device
scp-armv7 ip user="root" pwd="pass":
    sshpass -p {{ pwd }} scp {{ build_dir_armv7 }}/{{ acap_name }} {{ user }}@{{ ip }}:/usr/local/packages/{{ acap_name }}/

# Build and send arch64 binary to device
scp-new-aarch64 ip user="root" pwd="pass":
    @just build-aarch64
    sshpass -p scp {{ pwd }} {{ build_dir_aarch64 }}/{{ acap_name }} {{ user }}@{{ ip }}:/usr/local/packages/{{ acap_name }}/

# Build and send armv7 binary to device
scp-new-armv7 ip user="root" pwd="pass":
    @just build-armv7
    sshpass -p scp {{ pwd }} {{ build_dir_armv7 }}/{{ acap_name }} {{ user }}@{{ ip }}:/usr/local/packages/{{ acap_name }}/

# Send arch64 binary to device
scp-aarch64 ip user="root" pwd="pass":
    sshpass -p {{ pwd }} scp {{ build_dir_aarch64 }}/{{ acap_name }} {{ user }}@{{ ip }}:/usr/local/packages/{{ acap_name }}/

# Install dependencies
setup:
    nimble install --depsOnly

# Install and start armv7 acap on remote device
install-armv7-eap-remote ip user="root" pwd="pass": docker-build
    # sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "acapctl stop {{ acap_name }}"
    sshpass -p {{ pwd }} scp -o StrictHostKeyChecking=no {{ eap_armv7 }} {{ user }}@{{ ip }}:/tmp/{{ acap_name }}
    sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "acapctl install /tmp/{{ acap_name }} && acapctl start {{ acap_name }}"
    sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "rm /tmp/{{ acap_name }}"

# Install and start aarch64 acap on remote device
install-aarch64-eap-remote ip user="root" pwd="pass": docker-build
    sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "acapctl stop {{ acap_name }}"
    sshpass -p {{ pwd }} scp -o StrictHostKeyChecking=no {{ eap_aarch64 }} {{ user }}@{{ ip }}:/tmp/{{ acap_name }}
    sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "acapctl install /tmp/{{ acap_name }} && acapctl start {{ acap_name }}"
    sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "rm /tmp/{{ acap_name }}"

# Run test suite in container
docker-test:
    @docker build -t builder .
    docker run -v "{{ justfile_directory() }}:/root/src" -w "/root/src" builder just test

# Helper to capture environment
_capture-env path:
    @gcc --version > {{ path }}/gcc_info.txt
    @nim --version > {{ path }}/nim_info.txt

# Helper to clean and set up the build directory
_setup-build-dir path:
    @mkdir -p {{ path }}
    @rm -rf {{ path }}/*
