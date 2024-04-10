#!/bin/bash
set -eo pipefail

# Default to B
ver="${1:-b}"
[[ $# -ge 1 ]] && shift 1
if [[ $# -ge 0 ]]; then
  armbian_extra_flags=("$@")
  echo "Passing additional args to Armbian ${armbian_extra_flags[*]}"
else
  armbian_extra_flags=("")
fi

C=$(pwd)
A=../../armbian-master
P="rockpi-4${ver}"
B="current"
T="rockpi-4${ver}"
K="rockchip64"

KERNELPATCH="no"
PATCH_PREFIX="volumio-"
KERNELCONFIGURE="no"

# Make sure we grab the right version
ARMBIAN_VERSION=$(cat ${A}/VERSION)

# Custom patches
echo "Adding custom patches"
ls "${C}/patches/"
mkdir -p "${A}"/userpatches/kernel/"${K}"-"${B}"/
rm -rf "${A}"/userpatches/kernel/"${K}"-"${B}"/*.patch

for patchfile in "${C}/patches/"*.patch; do
  if [ ! "${patchfile}/" == "${C}/patches/*.patch/" ]; then
    echo "Adding ${patchfile}"
    cp "${patchfile}" "${A}"/userpatches/kernel/"${K}"-"${B}"
  fi  
done

# Custom kernel Config
if [ -e "${C}"/kernel-config/linux-"${K}"-"${B}".config ]
then
  echo "Copy custom Kernel config"
  ls "${C}"/kernel-config/linux-"${K}"-"${B}".config
  cp "${C}"/kernel-config/linux-"${K}"-"${B}".config "${A}"/userpatches/
fi

# Select specific Kernel and/or U-Boot version
rm -rf "${A}"/userpatches/lib.config
if [ -e "${C}"/kernel-ver/"${P}".config ]
then
  echo "Copy specific kernel/uboot version config"
  cp "${C}"/kernel-ver/"${P}"*.config "${A}"/userpatches/lib.config
fi

if [ -d "${A}"/output/debs ]; then
  echo "Cleaning previous .deb builds"
  rm -rf "${A}"/output/debs/*
fi

cd ${A}
ARMBIAN_HASH=$(git rev-parse --short HEAD)
#echo "Building for $P -- with Armbian ${ARMBIAN_VERSION} -- $B"
#./compile.sh BOARD="${T}" BRANCH="${B}" RELEASE=buster KERNEL_CONFIGURE=no EXTERNAL=yes BUILD_KSRC=no BUILD_DESKTOP=no BUILD_ONLY=u-boot,kernel,armbian-firmware "${armbian_extra_flags[@]}"

echo "Building for $P -- with Armbian ${ARMBIAN_VERSION} -- $B"

./compile.sh ARTIFACT_IGNORE_CACHE=yes BOARD=${T} BRANCH=${B} uboot 

if [ $KERNELPATCH == yes ]; then
  ./compile.sh ARTIFACT_IGNORE_CACHE=yes BOARD=${T} BRANCH=${B} kernel-patch 
  
  # Note: armbian patch files are applied in alphabetic order!!!
  # To make sure that user patches are applied after Armbian's own patches, use a unique pre-fix"
  if [ -f ./output/patch/kernel-"${K}"-"${B}".patch ]; then
    cp ./output/patch/kernel-"${K}"-"${B}".patch "${C}"/patches/"${PATCH_PREFIX}"-kernel-"${K}"-"${B}".patch
    cp "${C}"/patches/"${PATCH_PREFIX}"-kernel-"${K}"-"${B}".patch ./userpatches/kernel/"${K}"-"${B}"/
    rm ./output/patch/kernel-"${K}"-"${B}".patch
  fi
fi

if [ $KERNELCONFIGURE == yes ]; then
  ./compile.sh ARTIFACT_IGNORE_CACHE=yes BOARD=${T} BRANCH=${B} kernel-config 
  cp ./userpatches/linux-"${K}"-"${B}".config "${C}"/kernel-config/
fi

./compile.sh CLEAN_LEVEL=images,debs,make-kernel ARTIFACT_IGNORE_CACHE=yes BOARD=${T} BRANCH=${B} kernel

./compile.sh ARTIFACT_IGNORE_CACHE=yes BOARD=${T} BRANCH=${B} firmware 

echo "Done!"

cd "${C}"
echo "Creating platform ${P} files"
[[ -d ${P} ]] && rm -rf "${P}"
mkdir -p "${P}"/u-boot
mkdir -p "${P}"/lib/firmware
mkdir -p "${P}"/boot/overlay-user
# Keep a copy for later just in case
cp "${A}/output/debs/linux-headers-${B}-${K}_${ARMBIAN_VERSION}"* "${C}"

dpkg-deb -x "${A}/output/debs/linux-dtb-${B}-${K}_${ARMBIAN_VERSION}"* "${P}"
dpkg-deb -x "${A}/output/debs/linux-image-${B}-${K}_${ARMBIAN_VERSION}"* "${P}"
dpkg-deb -x "${A}/output/debs/linux-u-boot-${T}-${B}_${ARMBIAN_VERSION}"* "${P}"
dpkg-deb -x "${A}/output/debs/armbian-firmware_${ARMBIAN_VERSION}"* "${P}"

# Remove unnecessary firmware files
echo "Remove unused firmware"
rm -rf "${P}"/lib/firmware/qcom
rm -rf "${P}"/lib/firmware/dvb*

# Copy bootloader stuff
cp "${P}"/usr/lib/linux-u-boot-${B}-*/u-boot.itb "${P}/u-boot"
cp "${P}"/usr/lib/linux-u-boot-${B}-*/idbloader.img "${P}/u-boot"

mv "${P}"/boot/dtb* "${P}"/boot/dtb
mv "${P}"/boot/vmlinuz* "${P}"/boot/Image

# Clean up unneeded parts
rm -rf "${P}/lib/firmware/.git"
rm -rf "${P:?}/usr" "${P:?}/etc"

# Compile and copy over overlay(s) files
for dts in "${C}"/overlay-user/overlays-"${P}"/*.dts; do
  dts_file=${dts%%.*}
  if [ -s "${dts_file}.dts" ]
  then
    echo "Compiling ${dts_file}"
    dtc -O dtb -o "${dts_file}.dtbo" "${dts_file}.dts"
    cp "${dts_file}.dtbo" "${P}"/boot/overlay-user
  fi
done

# Change name for audio interface(s)
if [ ${ver} = "b" ]
then
  echo "Changing Audio interface name(s) for $P"
  dtc -I dtb -O dts "${P}"/boot/dtb/rockchip/rk3399-rock-pi-4b.dtb -o "${P}"/boot/dtb/rockchip/rk3399-rock-pi-4b.dts
  sed -i "s/Analog/Analog-ES8316/g" "${P}"/boot/dtb/rockchip/rk3399-rock-pi-4b.dts
  dtc -I dts -O dtb -o "${P}"/boot/dtb/rockchip/rk3399-rock-pi-4b.dtb "${P}"/boot/dtb/rockchip/rk3399-rock-pi-4b.dts
  rm "${P}"/boot/dtb/rockchip/rk3399-rock-pi-4b.dts
fi

# Add extras
if [ -e "${C}"/extras/extras-"${P}"/asound.state ]
then
  echo "Copy asound.state config file"
  mkdir -p "${P}"/var/lib/alsa
  cp "${C}"/extras/extras-"${P}"/asound.state "${P}"/var/lib/alsa/asound.state
fi

# Copy and compile boot script
cp "${A}"/config/bootscripts/boot-"${K}".cmd "${P}"/boot/boot.cmd
mkimage -C none -A arm -T script -d "${P}"/boot/boot.cmd "${P}"/boot/boot.scr

# Signal mainline kernel
touch "${P}"/boot/.next

# Prepare boot parameters
cp "${C}"/bootparams/"${P}".armbianEnv.txt "${P}"/boot/armbianEnv.txt

echo "Creating device tarball.."
XZ_OPT=-9 tar cJf "${P}_${B}.tar.xz" "$P"

echo "Renaming tarball for Build scripts to pick things up"
mv "${P}_${B}.tar.xz" "${P}.tar.xz"
KERNEL_VERSION="$(basename ./"${P}"/boot/config-*)"
KERNEL_VERSION=${KERNEL_VERSION#*-}
echo "Creating a version file Kernel: ${KERNEL_VERSION}"
cat <<EOF >"${C}/version"
BUILD_DATE=$(date +"%m-%d-%Y")
ARMBIAN_VERSION=${ARMBIAN_VERSION}
ARMBIAN_HASH=${ARMBIAN_HASH}
KERNEL_VERSION=${KERNEL_VERSION}
EOF

echo "Cleaning up.."
rm -rf "${P}"
