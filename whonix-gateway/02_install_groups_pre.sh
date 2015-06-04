#!/bin/bash -e
# vim: set ts=4 sw=4 sts=4 et :

# ==============================================================================
#                           WHONIX 11 - WIP NOTES
# ==============================================================================
# 
# TODO - FIX:
# ------------------------------------------------------------------------------
# - dialog boxes partial display as semi-transparent (wheezy + jessie)
#   - test to see if that is still case with gnome enabled workstation [yes]
#   - possible QT or TrollTech.conf issue? [don't think so]
#   - seems to be a kde issue; Fedora AppVMs also affected
#
# ==============================================================================

source "${SCRIPTSDIR}/vars.sh"
source "${SCRIPTSDIR}/distribution.sh"

##### '-------------------------------------------------------------------------
debug ' Installing and building Whonix'
##### '-------------------------------------------------------------------------


#### '--------------------------------------------------------------------------
info ' Trap ERR and EXIT signals and cleanup (umount)'
#### '--------------------------------------------------------------------------
trap cleanup ERR
trap cleanup EXIT

if ! [ -f "${INSTALLDIR}/${TMPDIR}/.whonix_prepared_groups" ]; then
    #### '----------------------------------------------------------------------
    info ' Installing extra packages from Whonix 30_dependencies'
    #### '----------------------------------------------------------------------
    source "${WHONIX_DIR}/buildconfig.d/30_dependencies"
    aptInstall ${whonix_build_script_build_dependency}

    touch "${INSTALLDIR}/${TMPDIR}/.whonix_prepared_groups"
fi


# ==============================================================================
# chroot Whonix build script
# ==============================================================================
    #### '----------------------------------------------------------------------
    info " Setting whonix build type (${TEMPLATE_FLAVOR})"
    #### '----------------------------------------------------------------------
    if [ "${TEMPLATE_FLAVOR}" == "whonix-gateway" ]; then
        BUILD_TYPE="whonix-gateway"
    elif [ "${TEMPLATE_FLAVOR}" == "whonix-workstation" ]; then
        BUILD_TYPE="whonix-workstation"
    else
        error "Incorrent Whonix type \"${TEMPLATE_FLAVOR}\" selected.  Not building Whonix modules"
        error "You need to set TEMPLATE_FLAVOR environment variable to either"
        error "whonix-gateway OR whonix-workstation"
        exit 1
    fi

    #### '----------------------------------------------------------------------
    info ' Setting whonix build options'
    #### '----------------------------------------------------------------------
    whonix_build_options=(
        "--flavor ${BUILD_TYPE}"
        "--"
        "--build"
        "--arch amd64"
        "--freshness current"
        "--target qubes"
        "--kernel linux-image-amd64"
        "--headers linux-headers-amd64"
        "--unsafe-io true"
        "--report minimal"
        "--verifiable minimal"
        "--allow-uncommitted true"
        "--allow-untagged true"
        "--sanity-tests false"
    )

    if [ "${TEMPLATE_FLAVOR}" == "whonix-workstation" ] && [ "${WHONIX_INSTALL_TB}" -eq 1 ]; then
        whonix_build_options+=("--tb close")
    fi

    # Some Additional Whonix build options
    # ====================================
    #    --target root \
    #    --unsafe-io true \
    #    --tb close  # Install tor-browser \
    #    --allow-uncommitted true \
    #    --allow-untagged true \
    #    --testing-frozen-sources  # Jessie; no current sources \

# ==============================================================================
# chroot Whonix pre build script
# ==============================================================================
read -r -d '' WHONIX_BUILD_SCRIPT_PRE <<EOF || true
################################################################################
# This script is executed from chroot most likely as the user 'user'
# 
# - The purpose is to do a few pre-fixups that are directly related to whonix
#   build process
# - Then, finally, call 'whonix_build_post' as sudo with a clean (no) ENV
#
################################################################################

# ------------------------------------------------------------------------------
# Whonix expects haveged to be started
# ------------------------------------------------------------------------------
sudo /etc/init.d/haveged start

# ------------------------------------------------------------------------------
# Use sudo with clean ENV to build Whonix; any ENV options will be set there
# ------------------------------------------------------------------------------
sudo /home/user/whonix_build ${whonix_build_options[@]}
EOF

# ==============================================================================
# chroot Whonix build script
# ==============================================================================
read -r -d '' WHONIX_BUILD_SCRIPT <<'EOF' || true
#!/bin/bash -e
# vim: set ts=4 sw=4 sts=4 et :

# ------------------------------------------------------------------------------
# Prevents Whonix makefile use of shared memory 'sem_open: Permission denied'
# ------------------------------------------------------------------------------
echo tmpfs /dev/shm tmpfs defaults 0 0 >> /etc/fstab
mount /dev/shm

# =============================================================================
# WHONIX BUILD COMMAND
# =============================================================================
#$eatmydata_maybe /home/user/Whonix/whonix_build 

pushd /home/user/Whonix
    env LD_PRELOAD=${LD_PRELOAD:+$LD_PRELOAD:}libeatmydata.so \
        /home/user/Whonix/whonix_build $@ || { exit 1; }
popd
EOF


##### '-------------------------------------------------------------------------
debug ' Preparing Whonix for installation'
##### '-------------------------------------------------------------------------
if [ -f "${INSTALLDIR}/${TMPDIR}/.whonix_prepared_groups" ] && ! [ -f "${INSTALLDIR}/${TMPDIR}/.whonix_prepared" ]; then
    info "Preparing Whonix system"

    #### '----------------------------------------------------------------------
    info ' Initializing Whonix submodules'
    #### '----------------------------------------------------------------------
    pushd "${WHONIX_DIR}"
    {
        su $(logname || echo $SUDO_USER) -c "git submodule update --init --recursive";
    }
    popd

    #### '----------------------------------------------------------------------
    info ' Adding a user account for Whonix to build with'
    #### '----------------------------------------------------------------------
    chroot id -u 'user' >/dev/null 2>&1 || \
    {
        # UID needs match host user to have access to Whonix sources
        chroot groupadd -f user
        [ -n "$SUDO_UID" ] && USER_OPTS="-u $SUDO_UID"
        chroot useradd -g user $USER_OPTS -G sudo,audio -m -s /bin/bash user
        if [ `chroot id -u user` != 1000 ]; then
            chroot useradd -g user -u 1000 -M -s /bin/bash user-placeholder
        fi
    }

    #### '----------------------------------------------------------------------
    info ' Removing apt-listchanges if it exists,so no prompts appear'
    #### '----------------------------------------------------------------------
    #      Whonix does not handle this properly, but aptInstall packages will
    aptRemove apt-listchanges || true

    #### '----------------------------------------------------------------------
    debug 'XXX: Whonix10/11 HACK'
    #### '----------------------------------------------------------------------
    rm -f "${INSTALLDIR}/etc/network/interfaces"
    cat > "${INSTALLDIR}/etc/network/interfaces" <<'EOF'
# interfaces(5) file used by ifup(8) and ifdown(8)
# Include files from /etc/network/interfaces.d:
source-directory /etc/network/interfaces.d
EOF

    #### '----------------------------------------------------------------------
    info ' Copying additional files required for build'
    #### '----------------------------------------------------------------------
    copyTree "files"

    touch "${INSTALLDIR}/${TMPDIR}/.whonix_prepared"
fi


##### '-------------------------------------------------------------------------
debug ' Installing Whonix code base'
##### '-------------------------------------------------------------------------
if [ -f "${INSTALLDIR}/${TMPDIR}/.whonix_prepared" ] && ! [ -f "${INSTALLDIR}/${TMPDIR}/.whonix_installed" ]; then

    #### '----------------------------------------------------------------------
    info ' Create Whonix directory (/home/user/Whonix)'
    #### '----------------------------------------------------------------------
    if ! [ -d "${INSTALLDIR}/home/user/Whonix" ]; then
        chroot su user -c 'mkdir -p /home/user/Whonix'
    fi

    #### '----------------------------------------------------------------------
    info " Bind Whonix source directory (${BUILDER_DIR}/${SRC_DIR}/Whonix)"
    #### '----------------------------------------------------------------------
    mount --bind "${BUILDER_DIR}/${SRC_DIR}/Whonix" "${INSTALLDIR}/home/user/Whonix"

    #### '----------------------------------------------------------------------
    info ' Installing Whonix build scripts'
    #### '----------------------------------------------------------------------
    echo "${WHONIX_BUILD_SCRIPT_PRE}" > "${INSTALLDIR}/home/user/whonix_build_pre"
    chmod 0755 "${INSTALLDIR}/home/user/whonix_build_pre"
    cat "${INSTALLDIR}/home/user/whonix_build_pre"

    echo "${WHONIX_BUILD_SCRIPT}" > "${INSTALLDIR}/home/user/whonix_build"
    chmod 0755 "${INSTALLDIR}/home/user/whonix_build"

    #### '----------------------------------------------------------------------
    info ' Bind /dev/pts for build'
    #### '----------------------------------------------------------------------
    mount --bind /dev "${INSTALLDIR}/dev"
    mount --bind /dev/pts "${INSTALLDIR}/dev/pts"

    #### '----------------------------------------------------------------------
    info 'Executing whonix_build script now...'
    #### '----------------------------------------------------------------------
    if [ "x${BUILD_LOG}" != "x" ]; then
        chroot su user -c "/home/user/whonix_build_pre" 3>&2 2>&1 | tee -a ${BUILD_LOG} || { exit 1; }
    else
        chroot su user -c "/home/user/whonix_build_pre" || { exit 1; }
    fi

    touch "${INSTALLDIR}/${TMPDIR}/.whonix_installed"
fi


##### '-------------------------------------------------------------------------
debug ' Whonix Post Installation Configurations'
##### '-------------------------------------------------------------------------
if [ -f "${INSTALLDIR}/${TMPDIR}/.whonix_installed" ] && ! [ -f "${INSTALLDIR}/${TMPDIR}/.whonix_post" ]; then

    #### '----------------------------------------------------------------------
    info ' Restoring original network interfaces'
    #### '----------------------------------------------------------------------
    pushd "${INSTALLDIR}/etc/network"
    {
        if [ -e 'interfaces.backup' ]; then
            rm -f interfaces;
            ln -s interfaces.backup interfaces;
        fi
    }
    popd

    #### '----------------------------------------------------------------------
    info ' Temporarily restore original resolv.conf for remainder of install process'
    info ' (Will be restored back in jessie+whonix/04_qubes_install_post.sh)'
    #### '----------------------------------------------------------------------
    pushd "${INSTALLDIR}/etc"
    {
        if [ -e 'resolv.conf.backup' ]; then
            rm -f resolv.conf;
            cp -p resolv.conf.backup resolv.conf;
        fi
    }
    popd

    #### '----------------------------------------------------------------------
    info ' Temporarily retore original hosts for remainder of install process'
    info ' (Will be restored on initial boot)'
    #### '----------------------------------------------------------------------
    pushd "${INSTALLDIR}/etc"
    {
        if [ -e 'hosts.anondist-orig' ]; then
            rm -f hosts;
            cp -p hosts.anondist-orig hosts;
        fi
    }
    popd

    #### '----------------------------------------------------------------------
    info ' Restore default user UID set to so same in all builds regardless of build host'
    #### '----------------------------------------------------------------------
    if [ -n "`chroot id -u user-placeholder`" ]; then
        chroot userdel user-placeholder
        chroot usermod -u 1000 user
    fi

    #### '----------------------------------------------------------------------
    info 'Maybe Enable Tor'
    #### '----------------------------------------------------------------------
    if [ "${TEMPLATE_FLAVOR}" == "whonix-gateway" ] && [ "${WHONIX_ENABLE_TOR}" -eq 1 ]; then
        sed -i "s/^#DisableNetwork/DisableNetwork/g" "${INSTALLDIR}/etc/tor/torrc"
    fi

    #### '----------------------------------------------------------------------
    info ' Enable some aliases in .bashrc'
    #### '----------------------------------------------------------------------
    sed -i "s/^# export/export/g" "${INSTALLDIR}/root/.bashrc"
    sed -i "s/^# eval/eval/g" "${INSTALLDIR}/root/.bashrc"
    sed -i "s/^# alias/alias/g" "${INSTALLDIR}/root/.bashrc"
    sed -i "s/^#force_color_prompt/force_color_prompt/g" "${INSTALLDIR}/home/user/.bashrc"
    sed -i "s/#alias/alias/g" "${INSTALLDIR}/home/user/.bashrc"
    sed -i "s/alias l='ls -CF'/alias l='ls -l'/g" "${INSTALLDIR}/home/user/.bashrc"

    #### '----------------------------------------------------------------------
    info ' Remove apt-cacher-ng'
    #### '----------------------------------------------------------------------
    chroot service apt-cacher-ng stop || :
    chroot update-rc.d apt-cacher-ng disable || :
    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
        chroot apt-get.anondist-orig -y --force-yes remove --purge apt-cacher-ng

    #### '----------------------------------------------------------------------
    info ' Remove original sources.list (Whonix copied them to .../debian.list)'
    #### '----------------------------------------------------------------------
    rm -f "${INSTALLDIR}/etc/apt/sources.list"

    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
        chroot apt-get.anondist-orig update

    touch "${INSTALLDIR}/${TMPDIR}/.whonix_post"
fi


##### '-------------------------------------------------------------------------
debug ' Temporarily restore original apt-get for remainder of install process'
##### '-------------------------------------------------------------------------
pushd "${INSTALLDIR}/usr/bin" 
{
    rm -f apt-get;
    cp -p apt-get.anondist-orig apt-get;
}
popd

#### '----------------------------------------------------------------------
info ' Cleanup'
#### '----------------------------------------------------------------------
trap - ERR EXIT
trap
