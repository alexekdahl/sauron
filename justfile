# Common compiler flags for release builds
FLAGS := "--mm:arc --threads:off --panics:off -d:release --opt:size -d:danger --stackTrace:off -d:strip --passC:-flto --passL:-flto --passC:-ffunction-sections --passC:-fdata-sections --passL:-Wl,--gc-sections --outdir:build"

acap_name := "sauron"
build_dir := "build"
entry_point := "src/sauron.nim"

# Architecture-specific directories and output files
build_dir_aarch64 := build_dir/"aarch64"
build_dir_armv7 := build_dir/"armv7"
build_dir_amd64 := build_dir/"amd64"
build_dir_mipsle := build_dir/"mipsle"
eap_aarch64 := build_dir_aarch64/acap_name +"_aarch64.eap"
eap_armv7 := build_dir_armv7/acap_name +"_armv7.eap"
eap_mipsle := build_dir_mipsle/acap_name +"_mipsle.eap"

# Release version on github
release version: docker-build
    just _semver_check {{ version }}
    gh release create {{ version }} --generate-notes {{ eap_aarch64 }} {{ eap_armv7 }} {{ eap_mipsle }}

# Build for aarch64
build-aarch64 *args:
    @just _setup-build-dir {{ build_dir_aarch64 }}
    nim c --cpu:arm64 --os:linux {{ FLAGS }} --out:{{ build_dir_aarch64 }}/{{ acap_name }} {{ args }} {{ entry_point }}
    @just _capture-env {{ build_dir_aarch64 }}
    upx --ultra-brute --lzma {{ build_dir_aarch64 }}/{{ acap_name }}

# Build for armv7
build-armv7 *args:
    @just _setup-build-dir {{ build_dir_armv7 }}
    nim c --cpu:arm --os:linux {{ FLAGS }} --out:{{ build_dir_armv7 }}/{{ acap_name }} {{ args }} {{ entry_point }}
    @just _capture-env {{ build_dir_armv7 }}

# Build for mipsle
build-mipsle *args:
    @just _setup-build-dir {{ build_dir_mipsle }}
    nim c --cpu:mipsel --os:linux  {{ FLAGS }} --out:{{ build_dir_mipsle }}/{{ acap_name }} {{ args }} {{ entry_point }}
    @just _capture-env {{ build_dir_mipsle }}
    upx --ultra-brute --lzma {{ build_dir_mipsle }}/{{ acap_name }}

# Build binary for all archs
build: 
   just build-aarch64
   just build-armv7
   just build-mipsle

# Build aarch64 and armv7 acap
build-acap: 
    just build-acap-aarch64
    just build-acap-armv7 
    just build-acap-mipsle

# Build armv7 acap
build-acap-armv7: 
    just build-armv7
    cp {{ build_dir_armv7 }}/{{ acap_name }} ./{{ acap_name }}
    cp acap/armv7/manifest.json ./manifest.json
    cp acap/package.conf ./package.conf
    @tar cvfz {{ eap_armv7 }} {{ acap_name }} manifest.json LICENSE package.conf
    @rm {{ acap_name }} manifest.json package.conf

# Build aarch64 acap
build-acap-aarch64: 
    just build-aarch64
    cp {{ build_dir_aarch64 }}/{{ acap_name }} ./{{ acap_name }}
    cp acap/aarch64/manifest.json ./manifest.json
    cp acap/package.conf ./package.conf
    @tar cvfz {{ eap_aarch64 }} {{ acap_name }} manifest.json LICENSE package.conf
    @rm {{ acap_name }} manifest.json package.conf

# Build mipsle acap
build-acap-mipsle: 
    just build-mipsle
    cp {{ build_dir_mipsle }}/{{ acap_name }} ./{{ acap_name }}
    cp acap/mipsle/manifest.json ./manifest.json
    cp acap/package.conf ./package.conf
    @tar cvfz {{ eap_mipsle }} {{ acap_name }} manifest.json LICENSE package.conf
    @rm {{ acap_name }} manifest.json package.conf

# Build aarch64, mipsle and armv7 via docker container
docker-build: 
    @docker build -t builder .
    docker run -v "{{ justfile_directory() }}:/root/src" -w "/root/src" builder just build-acap
    @docker run -v "{{ justfile_directory() }}:/root/src" -w "/root/src" builder chown -R --reference=.gitignore ./build

# Format according to nim standards
format:
    find . -name '*.nim' -exec nimpretty {} +

# ---------------------------
#      Remote deployment     
# ---------------------------
# Install and start armv7 acap on remote device
install-armv7-eap-remote ip user="root" pwd="pass": docker-build
    @sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "acapctl stop {{ acap_name }}" > /dev/null 2>&1
    sshpass -p {{ pwd }} scp -o StrictHostKeyChecking=no {{ eap_armv7 }} {{ user }}@{{ ip }}:/tmp/{{ acap_name }}
    sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "acapctl install /tmp/{{ acap_name }} && acapctl start {{ acap_name }}"
    sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "rm /tmp/{{ acap_name }}"

# Install and start aarch64 acap on remote device
install-aarch64-eap-remote ip user="root" pwd="pass": docker-build
    @sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "acapctl stop {{ acap_name }}" > /dev/null 2>&1
    sshpass -p {{ pwd }} scp -o StrictHostKeyChecking=no {{ eap_aarch64 }} {{ user }}@{{ ip }}:/tmp/{{ acap_name }}
    sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "acapctl install /tmp/{{ acap_name }} && acapctl start {{ acap_name }}"
    sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "rm /tmp/{{ acap_name }}"

# Install and start mips acap on remote device
install-mipsle-eap-remote ip user="root" pwd="pass": docker-build
    @sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "acapctl stop {{ acap_name }}" > /dev/null 2>&1
    sshpass -p {{ pwd }} scp -o StrictHostKeyChecking=no {{ eap_mipsle }} {{ user }}@{{ ip }}:/tmp/{{ acap_name }}
    sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "acapctl install /tmp/{{ acap_name }} && acapctl start {{ acap_name }}"
    sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "rm /tmp/{{ acap_name }}"

# ---------------------------
#      Analys log     
# ---------------------------

# Analyse log on remote device
sauronlens ip user="root" pwd="pass": 
    @sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "cat /usr/local/packages/{{ acap_name }}/localdata/process.*" | go run tools/sauronlens/main.go

# Analyse log on remote device
plot ip user="root" pwd="pass":
    @docker build -f tools/plot/Dockerfile -t plotter:latest .
    @sshpass -p {{ pwd }} ssh -o StrictHostKeyChecking=no {{ user }}@{{ ip }} "cat /usr/local/packages/{{ acap_name }}/localdata/process.*" | docker run --rm -i -v {{ justfile_directory() }}/tools/plot:/app plotter:latest
    @open tools/plot/rss_usage.html
    @open tools/plot/cpu_usage.html
    @open tools/plot/pss_usage.html

# ---------------------------
#      Helper functions     
# ---------------------------
# Helper to capture environment
_capture-env path:
    @gcc --version > {{ path }}/gcc_info.txt
    @nim --version > {{ path }}/nim_info.txt

# Helper to clean and set up the build directory
_setup-build-dir path:
    @mkdir -p {{ path }}
    @rm -rf {{ path }}/*

# Helper to validate semver version
_semver_check version:
    #!/bin/bash
    # Extract version from package.conf
    package_major=$(grep '^APPMAJORVERSION=' acap/package.conf | cut -d '=' -f2 | tr -d '"')
    package_minor=$(grep '^APPMINORVERSION=' acap/package.conf | cut -d '=' -f2 | tr -d '"')
    package_micro=$(grep '^APPMICROVERSION=' acap/package.conf | cut -d '=' -f2 | tr -d '"')
    package_version="${package_major}.${package_minor}.${package_micro}"

    # Extract versions from various sources
    aarch64_version=$(jq -r '.acapPackageConf.setup.version' acap/aarch64/manifest.json)
    armv7_version=$(jq -r '.acapPackageConf.setup.version' acap/armv7/manifest.json)
    nimble_version=$(grep '^version' sauron.nimble | awk '{print $3}' | tr -d '"')

    versions=(
        "aarch64:$aarch64_version"
        "armv7:$armv7_version"
        "package.conf:$package_version"
        "nimble:$nimble_version"
    )

    for entry in "${versions[@]}"; do
        key="${entry%%:*}"
        ver="${entry#*:}"
        if [ {{ version }} != "$ver" ]; then
            echo "Input version $version does not match $key version ($ver)."
            exit 1
        fi
    done

    echo "All versions are the same: $version. Proceeding."
