#!/bin/bash

set -e

### configuration ###

# DOCKER_CONFIG_DIR
#
DOCKER_CONFIG_DIR="$HOME/.docker"

# DEPLOY_WORKDIR
#
# Local data directory for docker-deploy.
#
# Will be auto-created if it doesn't exist.
#
DEPLOY_WORKDIR="$DOCKER_CONFIG_DIR/deploy"

# DOCKER_VERSION
# Which version to deploy.
#
DOCKER_VERSION=1.5.0

# DOCKER_BINARY_DOWNLOAD_HOST
#
# Where to download Docker binaries from.
#
# The actual download URL will look like this:
#
# $DOCKER_BINARY_DOWNLOAD_HOST/builds/Linux/$(uname -m)/docker-$VERSION
#
# I had to replace this with my own host because the official docker
# i386 binary at https://get.docker.com does not support daemon mode
#
DOCKER_BINARY_DOWNLOAD_HOST=http://docker.omkamra.hu

# REMOTE_TMP_DIR
#
# Where this script should be uploaded to on the remote host.
#
# This directory will be removed when the script exits.
#
REMOTE_TMP_DIR=/tmp/docker-deploy

# REMOTE_SCRIPT_PATH
#
# Location of this deploy script on remote host.
#
REMOTE_SCRIPT_PATH="$REMOTE_TMP_DIR/$(basename $0)"

# DOCKER_DIR
#
# The base directory for the Docker installation.
#
DOCKER_DIR=/opt/docker

# DOCKER_BIN_DIR
#
# The directory for the docker binary.
#
DOCKER_BIN_DIR=$DOCKER_DIR/bin

# DOCKER_BIN
#
# The full path to the docker binary.
#
DOCKER_BIN=$DOCKER_BIN_DIR/docker

# DOCKER_ETC_DIR
#
# The directory for config files used by the docker daemon.
#
DOCKER_ETC_DIR=$DOCKER_DIR/etc

# DOCKER_GRAPH_DIR
#
# Root of the docker runtime.
#
DOCKER_GRAPH_DIR=$DOCKER_DIR/graph

# DOCKER_OPTS
#
DOCKER_OPTS="--graph=$DOCKER_GRAPH_DIR --host=unix:///var/run/docker.sock --host=tcp://0.0.0.0:2376 --tlsverify --tlscacert=$DOCKER_ETC_DIR/ca.pem --tlscert=$DOCKER_ETC_DIR/cert.pem --tlskey=$DOCKER_ETC_DIR/key.pem --group=docker"

### script arguments ###

command="$1"
host="$2"

### atexit handlers ###

atexit_handlers=()

atexit() {
    local cmd
    if [ -n "$1" ]; then
        atexit_handlers+=("$1")
    else
        for cmd in "${atexit_handlers[@]}"; do
            eval "$cmd"
        done
    fi
}

trap atexit EXIT

### helper functions ###

usage() {
    echo "$(basename $0) - Deploy docker to a remote host via SSH."
    echo
    echo "Usage: $(basename $0) <command> <host>"
    echo
    echo "Valid commands:"
    echo
    echo "  docker     Deploy docker to <host>"
    echo "  cacert     Install the docker-deploy root CA cert into the trust database on <host>"
    echo
    exit 0
}

setup_workdir() {
    if [ ! -d "$DEPLOY_WORKDIR" ]; then
        echo -n "Creating work directory $DEPLOY_WORKDIR: "
        mkdir -p "$DEPLOY_WORKDIR"
        echo "done."
    fi
}

setup_cacert() {
    if [ ! -e "$DOCKER_CONFIG_DIR/ca.pem" ]; then
        echo "First time setup: generating CA key and certificate:"
        mkdir -p "$DOCKER_CONFIG_DIR"
        openssl req \
                -newkey rsa:2048 \
                -keyout "$DOCKER_CONFIG_DIR/key.pem" \
                -out "$DOCKER_CONFIG_DIR/req.pem" \
                -subj "/O=docker-deploy/CN=docker-deploy root ca" \
                -nodes
        local extfile="$DOCKER_CONFIG_DIR/extfile.cnf"
        : > "$extfile"
        echo "basicConstraints = CA:TRUE" >> "$extfile"
        echo "extendedKeyUsage = serverAuth,clientAuth" >> "$extfile"
        echo "subjectKeyIdentifier = hash" >> "$extfile"
        echo "authorityKeyIdentifier = keyid" >> "$extfile"
        openssl x509 \
                -req \
                -in "$DOCKER_CONFIG_DIR/req.pem" \
                -signkey "$DOCKER_CONFIG_DIR/key.pem" \
                -out "$DOCKER_CONFIG_DIR/ca.pem" \
                -days 3650 \
                -extfile "$extfile"
        echo "We use the CA cert as our client certificate:"
        cp -v "$DOCKER_CONFIG_DIR/ca.pem" "$DOCKER_CONFIG_DIR/cert.pem"
    fi
}

create_remote_tmp_dir() {
    local host="$1"
    echo -n "Creating remote tmp directory root@$host:$REMOTE_TMP_DIR: "
    ssh root@$host mkdir -p "$REMOTE_TMP_DIR"
    echo "done."
    atexit "echo -n \"Removing remote tmp directory root@$host:$REMOTE_TMP_DIR: \" && ssh root@$host rm -rf \"$REMOTE_TMP_DIR\" && echo \"done.\""
}

upload_deploy_script() {
    local host="$1"
    echo -n "Copying $0 to root@$host:$REMOTE_SCRIPT_PATH: "
    scp -q $0 root@$host:"$REMOTE_SCRIPT_PATH"
    echo "done."
}

upload_cacert() {
    local host="$1"
    local target_path="$2"
    echo -n "Uploading CA certificate to root@$host:$target_path: "
    scp -q "$DOCKER_CONFIG_DIR/ca.pem" root@$host:"$target_path"
    echo "done."
}

remote_deploy() {
    local host="$1"; shift
    echo "Executing command as root@$host: $REMOTE_SCRIPT_PATH $*"
    ssh root@$host /bin/bash "$REMOTE_SCRIPT_PATH" "$@"
}

is_ip() {
    [[ "$1" =~ ^[0-9.]+ ]]
}

resolve_host() {
    local host="$1"
    if is_ip "$host"; then
        echo "$host"
    else
        host "$host" | sed -re 's/.* has address ([0-9.]+)/\1/'
    fi
}

upload_certs() {
    local host="$1"
    local ip="$(resolve_host "$host")"
    if ! is_ip "$ip"; then
        echo "Can't resolve the IP address of $host."
        exit 1
    fi
    if [ ! -e "$DEPLOY_WORKDIR/$ip/cert.pem" ]; then
        echo "Generating TLS key and certificate for $host:"
        mkdir -p "$DEPLOY_WORKDIR/$ip"
        openssl req \
                -newkey rsa:2048 \
                -keyout "$DEPLOY_WORKDIR/$ip/key.pem" \
                -out "$DEPLOY_WORKDIR/$ip/req.pem" \
                -subj "/O=docker-deploy/CN=$host" \
                -nodes
        local extfile="$DEPLOY_WORKDIR/$ip/extfile.cnf"
        : > "$extfile"
        echo "subjectAltName = IP:$ip" >> "$extfile"
        echo "extendedKeyUsage = serverAuth" >> "$extfile"
        openssl x509 \
                -req \
                -in "$DEPLOY_WORKDIR/$ip/req.pem" \
                -out "$DEPLOY_WORKDIR/$ip/cert.pem" \
                -CA "$DOCKER_CONFIG_DIR/ca.pem" \
                -CAkey "$DOCKER_CONFIG_DIR/key.pem" \
                -CAserial "$DOCKER_CONFIG_DIR/serial" \
                -CAcreateserial \
                -days 3650 \
                -extfile "$extfile"
    fi
    echo -n "Uploading CA cert to $DOCKER_ETC_DIR/ca.pem: "
    scp -q "$DOCKER_CONFIG_DIR/ca.pem" root@$host:"$DOCKER_ETC_DIR/ca.pem"
    echo "done."
    echo -n "Uploading host key to $DOCKER_ETC_DIR/key.pem: "
    scp -q "$DEPLOY_WORKDIR/$ip/key.pem" root@$host:"$DOCKER_ETC_DIR/key.pem"
    echo "done."
    echo -n "Uploading host cert to $DOCKER_ETC_DIR/cert.pem: "
    scp -q "$DEPLOY_WORKDIR/$ip/cert.pem" root@$host:"$DOCKER_ETC_DIR/cert.pem"
    echo "done."
}

executable_exists() {
    type -p "$1" > /dev/null
}

semver_ge() {
    local a="$1"
    local b="$2"
    if [ -z "$a" -a -z "$b" ]; then
        return 0
    elif [ -n "$a" -a -z "$b" ]; then
        return 0
    elif [ -z "$a" -a -n "$b" ]; then
        return 1
    fi
    local a_head="${a%%.*}"
    local b_head="${b%%.*}"
    if [ "$a_head" -gt "$b_head" ]; then
        return 0
    elif [ "$a_head" -lt "$b_head" ]; then
        return 1
    fi
    local a_tail="${a#[0-9]*}"; a_tail="${a_tail#.}"
    local b_tail="${b#[0-9]*}"; b_tail="${b_tail#.}"
    semver_ge "$a_tail" "$b_tail"
}

check_docker() {
    if executable_exists docker && [ "$(readlink -f "$(type -p docker)")" != "$DOCKER_BIN" ]; then
        echo "Docker is already present on the remote system, but it was installed from a different source."
        echo "Before running $(basename $0), please remove the other version."
        exit 1
    fi
}

check_kernel() {
    local minimum_version="$1"
    local installed_version="$(uname -r)"
    echo -n "Linux kernel version $installed_version: "
    if semver_ge "$installed_version" "$minimum_version"; then
        echo "ok."
    else
        echo "too low, docker needs $minimum_version or later."
        exit 1
    fi
}

check_iptables() {
    local minimum_version="$1"
    if ! executable_exists iptables; then
        echo "iptables is not installed"
        exit 1
    fi
    local installed_version="$(iptables --version | sed -re 's/^.*v([0-9.]+).*$/\1/')"
    echo -n "iptables version $installed_version: "
    if semver_ge "$installed_version" "$minimum_version"; then
        echo "ok."
    else
        echo "too low, docker needs $minimum_version or later."
        exit 1
    fi
}

check_git() {
    local minimum_version="$1"
    if ! executable_exists git; then
        echo "git is not installed"
        exit 1
    fi
    local installed_version="$(git --version | sed -re 's/^.*version ([0-9.]+).*$/\1/')"
    echo -n "git version $installed_version: "
    if semver_ge "$installed_version" "$minimum_version"; then
        echo "ok."
    else
        echo "too low, docker needs $minimum_version or later."
        exit 1
    fi
}

check_ps() {
    if ! executable_exists ps; then
        echo "ps is not installed"
        exit 1
    fi
    echo "ps: found"
}

check_xz() {
    local minimum_version="$1"
    if ! executable_exists xz; then
        echo "xz utils are not installed"
        exit 1
    fi
    local installed_version="$(xz --version | head -n 1 | sed -re 's/^.* ([0-9.]+).*$/\1/')"
    echo -n "xz utils version $installed_version: "
    if semver_ge "$installed_version" "$minimum_version"; then
        echo "ok."
    else
        echo "too low, docker needs $minimum_version or later."
        exit 1
    fi
}

check_cgroups() {
    if [ ! -e /proc/cgroups ]; then
        echo "Docker needs a cgroups-enabled kernel."
        exit 1
    fi
    if [ ! -d /sys/fs/cgroup ]; then
        echo "/sys/fs/cgroup doesn't exist."
        exit 1
    fi
    if grep -v '^#' /etc/fstab | grep -q cgroup; then
        echo "cgroups mounted from fstab, no good."
        exit 1
    fi
}

check_apparmor() {
    if [ -e "/sys/module/apparmor" -a "$(cat /sys/module/apparmor/parameters/enabled)" = "Y" ]; then
        if ! executable_exists apparmor_parser; then
            echo "AppArmor installed, but apparmor_parser not found."
            exit 1
        fi
    fi
}

check_dirs() {
    for dir in /etc/default /var/run; do
        if [ ! -d "$dir" ]; then
            echo "$dir directory required but it doesn't exist on the system."
            exit 1
        fi
    done
}

create_group() {
    local group="$1"
    echo -n "Creating system group $group: "
    groupadd -f -r "$group"
    echo "done."
}

download_docker() {
    MACHINE="$(uname -m)"
    if [ "$MACHINE" = "i686" ]; then
        MACHINE=i386
    fi
    DOCKER_URL="$DOCKER_BINARY_DOWNLOAD_HOST/builds/Linux/$MACHINE/docker-${DOCKER_VERSION}"
    for dir in "$DOCKER_BIN_DIR" "$DOCKER_ETC_DIR" "$DOCKER_GRAPH_DIR"; do
        echo -n "Creating directory $dir: "
        mkdir -m 0755 -p "$dir"
        echo "done."
    done
    DOCKER_BIN_TMP="$DOCKER_BIN.tmp"
    echo "Downloading docker binary from $DOCKER_URL to $DOCKER_BIN_TMP:"
    wget -O "$DOCKER_BIN_TMP" --progress=dot:mega "$DOCKER_URL"
    echo "Download complete."
    mv -v "$DOCKER_BIN_TMP" "$DOCKER_BIN"
    chmod -v 755 "$DOCKER_BIN"
    ln -sfv "$DOCKER_BIN" /usr/local/bin/docker
}

upstart_present() {
    [ -e "/etc/init/rcS.conf" ]
}

systemd_present() {
    executable_exists systemctl && [ -d "/etc/systemd/system" ]
}

install_init_script() {
    if upstart_present; then
        UPSTART_CONF=/etc/init/docker.conf
        echo "Detected upstart."
        echo -n "Downloading upstart job definition to $UPSTART_CONF: "
        wget -qO "$UPSTART_CONF" https://raw.githubusercontent.com/docker/docker/master/contrib/init/upstart/docker.conf
        echo "done."
    elif systemd_present; then
        SYSTEMD_CONF_DIR=/etc/systemd/system
        echo "Detected systemd."
        echo -n "Downloading service file to $SYSTEMD_CONF_DIR/docker.service: "
        wget -qO - https://raw.githubusercontent.com/docker/docker/master/contrib/init/systemd/docker.service \
             | sed -e "s#^ExecStart=.*#ExecStart=$DOCKER_BIN -d $DOCKER_OPTS#" \
             > "$SYSTEMD_CONF_DIR/docker.service"
        echo "done."
        echo -n "Downloading socket activation config to $SYSTEMD_CONF_DIR/docker.socket: "
        wget -qO - https://raw.githubusercontent.com/docker/docker/master/contrib/init/systemd/docker.socket \
             > "$SYSTEMD_CONF_DIR/docker.socket"
        echo "done."
    else
        echo "Unknown init system, consider extending the install_init_script() function."
        exit 1
    fi
    DEFAULT_CONF=/etc/default/docker
    echo -n "Installing default config to $DEFAULT_CONF: "
    cat <<EOF > $DEFAULT_CONF
DOCKER=$DOCKER_BIN
DOCKER_OPTS="$DOCKER_OPTS"
EOF
    echo "done."
}

deploy_docker() {
    check_docker
    echo "Checking Docker dependencies:"
    check_kernel 3.10
    check_iptables 1.4
    check_git 1.7
    check_ps
    check_xz 4.9
    check_cgroups
    check_apparmor
    check_dirs
    create_group docker
    echo "Downloading docker:"
    download_docker
    echo "Configuring automatic startup on boot:"
    install_init_script
}

deploy_cacert() {
    local ca_path="$1"
    if executable_exists update-ca-certificates && [ -d "/usr/local/share/ca-certificates" ]; then
        local target_path="/usr/local/share/ca-certificates/docker-deploy-ca.crt"
        echo -n "Copying CA certificate at $ca_path to $target_path: "
        cp "$ca_path" "$target_path"
        echo "done."
        echo "Updating database of trusted CA certificates:"
        update-ca-certificates
        echo "Trusted CA certificate database successfully updated."
    elif executable_exists update-ca-trust && [ -d /etc/ca-certificates/trust-source/anchors ]; then
        local target_path="/etc/ca-certificates/trust-source/anchors/docker-deploy-ca.crt"
        echo -n "Copying CA certificate at $ca_path to $target_path: "
        cp "$ca_path" "$target_path"
        echo "done."
        echo "Updating database of trusted CA certificates:"
        update-ca-trust extract
        echo "Trusted CA certificate database successfully updated."
    else
        echo "I don't know how to deploy the CA certificate. Consider extending the deploy_cacert() function."
        exit 1
    fi
}

### main ###

if [ -n "$host" ]; then
    setup_workdir
    setup_cacert
    create_remote_tmp_dir "$host"
fi

case "$command" in
    docker)
        if [ -n "$host" ]; then
            upload_deploy_script "$host"
            remote_deploy "$host" docker
            upload_certs "$host"
            upload_cacert "$host" "$REMOTE_TMP_DIR/ca.pem"
            remote_deploy "$host" cacert
        else
            deploy_docker
        fi
        ;;
    cacert)
        if [ -n "$host" ]; then
            upload_cacert "$host" "$REMOTE_TMP_DIR/ca.pem"
            remote_deploy "$host" cacert
        else
            deploy_cacert "$REMOTE_TMP_DIR/ca.pem"
        fi
        ;;
    *)
        usage
        ;;
esac

exit 0
