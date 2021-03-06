#!/bin/sh

set -eux
env

# TODO: add support for other posix environments
container=freebsd
build_dir="${HOME}/ansible"

test_target="${TARGET:-}"
test_flags="${TEST_FLAGS:-}"

# Force ansible color output by default.
# To disable color force mode use FORCE_COLOR=0
force_color="${FORCE_COLOR:-1}"

# FIXME: these tests fail
skip_tags='test_copy,test_template,test_unarchive,test_command_shell,test_sudo,test_become,test_service,test_postgresql,test_mysql_db,test_mysql_user,test_mysql_variables,test_uri,test_get_url'

cd ~/

# ssl certificate errors using fetch, so install curl
pkg install -y curl

if [ ! -f bootstrap.sh ]; then
    curl "https://raw.githubusercontent.com/mattclay/ansible-hacking/master/bootstrap.sh" -o bootstrap.sh
fi

chmod +x bootstrap.sh
./bootstrap.sh pip -y -q

# tests require these packages
# TODO: bootstrap.sh should be capable of installing these
pkg install -y \
    bash \
    devel/ruby-gems \
    mercurial \
    rsync \
    ruby \
    subversion \
    sudo \
    zip

# TODO: bootstrap.sh should install these
pip install \
    junit-xml \
    virtualenv

# FIXME: tests assume bash is in /bin/bash
if [ ! -f /bin/bash ]; then
    ln -s /usr/local/bin/bash /bin/bash
fi

# FIXME: tests assume true is in /bin/true
if [ ! -f /bin/true ]; then
    ln -s /usr/bin/true /bin/true
fi

# FIXME: async doesn't work with ansible_python_interpreter, see: https://github.com/ansible/ansible/issues/14101
if [ ! -f /usr/bin/python ]; then
    ln -s /usr/local/bin/python /usr/bin/python
fi

# Tests assume loopback addresses other than 127.0.0.1 will work.
# Add aliases for loopback addresses used by tests.

for i in 3 4 254; do
    ifconfig lo0 alias "127.0.0.${i}" up
done

ifconfig lo0

# Since tests run as root, we also need to be able to ssh to localhost as root.
sed -i '' 's/^# *PermitRootLogin.*$/PermitRootLogin yes/;' /etc/ssh/sshd_config

# Restart sshd for configuration changes and loopback aliases to work.
service sshd restart

# Generate our ssh key and add it to our authorized_keys file.
# We also need to add localhost's server keys to known_hosts.

if [ ! -f "${HOME}/.ssh/id_rsa.pub" ]; then
    ssh-keygen -q -t rsa -N '' -f "${HOME}/.ssh/id_rsa"
    cp "${HOME}/.ssh/id_rsa.pub" "${HOME}/.ssh/authorized_keys"
    for key in /etc/ssh/ssh_host_*_key.pub; do
        pk=$(cat "${key}")
        echo "localhost ${pk}" >> "${HOME}/.ssh/known_hosts"
    done
fi

repo_name="${REPO_NAME:-ansible}"

if [ -d "${build_dir}" ]; then
    cd "${build_dir}"
elif [ "${repo_name}" = "ansible" ]; then
    git clone "${REPOSITORY_URL:-https://github.com/ansible/ansible.git}" "${build_dir}"
    cd "${build_dir}"

    if [ "${PULL_REQUEST:-false}" = "false" ]; then
        git checkout -f "${BRANCH:-devel}" --
        git reset --hard "${COMMIT:-HEAD}"
    else
        git fetch origin "pull/${PULL_REQUEST}/head"
        git checkout -f FETCH_HEAD
        git merge "origin/${BRANCH}"
    fi

    git submodule init
    git submodule sync
    git submodule update
else
    case "${repo_name}" in
        "ansible-modules-core")
            this_module_group="core"
            ;;
        "ansible-modules-extras")
            this_module_group="extras"
            ;;
        *)
            echo "Unsupported repo name: ${repo_name}"
            exit 1
            ;;
    esac

    git clone "https://github.com/ansible/ansible.git" "${build_dir}"

    cd "${build_dir}"

    git submodule init
    git submodule sync
    git submodule update

    cd "${build_dir}/lib/ansible/modules/${this_module_group}"

    if [ "${PULL_REQUEST:-false}" = "false" ]; then
        echo "Only pull requests are supported for module repositories."
        exit
    else
        git fetch origin "pull/${PULL_REQUEST}/head"
        git checkout -f FETCH_HEAD
        git merge "origin/${BRANCH}"
    fi

    cd "${build_dir}"
fi

set +u
. hacking/env-setup
set -u

cd test/integration

# FIXME: these test targets fail
sed -i '' 's/ blocks / /;' Makefile
sed -i '' 's/ pull / /;' Makefile
sed -i '' 's/ test_handlers / /;' Makefile
sed -i '' 's/ no_log / /;' Makefile

# TODO: support httptester via reverse ssh tunnel

rm -rf "/tmp/shippable"
mkdir -p "/tmp/shippable/testresults"

# TODO: enable jail test
# shellcheck disable=SC2086
JUNIT_OUTPUT_DIR="/tmp/shippable/testresults" \
    ANSIBLE_FORCE_COLOR="${force_color}" \
    ANSIBLE_CALLBACK_WHITELIST=junit \
    TEST_FLAGS="-e ansible_python_interpreter=/usr/local/bin/python2 --skip-tags '${skip_tags}' ${test_flags}" \
    container="${container}" \
    gmake ${test_target}
