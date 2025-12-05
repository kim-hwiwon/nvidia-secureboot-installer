#!/bin/sh

KERNEL_SOURCE_PATH="${1:-"/usr/src/kernels/$(uname -r)"}"

# run as root if not
if [ "$(id -u)" -ne 0 ]
  then
  sudo true || { printf " *** Run as root! ***\n" >&2; exit 1; } || exit 1
  printf " - Not a root account. Running as sudo from now on...\n"
  sudo "$0" "$@"; exit "$?"
fi

uid_before_sudo="${SUDO_UID:-0}"

certutil -d /etc/pki/pesign -n 'nvidia-signer' -L >/dev/null 2>/dev/null
key_exists=$?
mokutil --list-enrolled --short | grep "^[0-9a-f]* nvidia-signer\$" >/dev/null 2>/dev/null
mok_exists=$?

if [ "$key_exists" -ne 0 ] || [ "$mok_exists" -ne 0 ]
then

  printf "\n\n ### Signing Key Generation Mode ###\n\n\n"


  trap 'ret=$?; [ -n "$tmpdir" ] && rm -rf "$tmpdir"; exit $?' INT TERM HUP QUIT EXIT
  tmpdir="$(mktemp -d)" || exit 1


  if [ "$mok_exists" -eq 0 ]
  then
    printf " - MOK already exists in shim, while no key for it found!\n   You need to request removing it first.\n"
    (
      cd "$tmpdir" || exit 1
      mokutil -x || exit 1
      mok_idx="$(mokutil --list-enrolled --short | grep -n "^[0-9a-f]* nvidia-signer\$" | cut -d: -f1)" || exit 1
      mok_file="MOK-$(printf "%04d" "$mok_idx").der" || exit 1
      printf " - Enter the password when needed on [Delete MOK] stage during the next reboot.\n"
      mokutil --delete "$mok_file" || exit 1
      printf " + MOK remove request finished!\n   Now reboot the device and complete [Delete MOK] stage.\n"
      exit 0
    ) || exit 1
    exit 0
  else
    certutil -d /etc/pki/pesign -n 'nvidia-signer' -F
  fi

  efikeygen --dbdir /etc/pki/pesign --self-sign --module --common-name "CN=nvidia-signer" --nickname 'nvidia-signer' || exit 1
  certutil -d /etc/pki/pesign -n 'nvidia-signer' -Lr > "$tmpdir"/cer || exit 1
  printf " - Enter the password when needed on [Enroll MOK] stage during the next reboot.\n"
  mokutil --import "$tmpdir"/cer || exit 1
  rm -rf "$tmpdir"
  trap - INT TERM HUP QUIT EXIT
  printf " + MOK enroll request finished!\n   Now reboot the device and complete [Enroll MOK] stage.\n"


else

  printf "\n\n ### Driver Installation Mode ###\n\n\n"


  driver_runfile="$(ls runfile/NVIDIA-*.run 2>/dev/null | sort --rev | head -n1)"

  if ! nvidia-smi >/dev/null 2>/dev/null
  then
    if [ -n "$driver_runfile" ] && [ -x "$driver_runfile" ]
    then
      trap 'ret=$?; [ -n "$tmpdir" ] && umount "$tmpdir" 2>/dev/null; rm -rf "$tmpdir"; exit $?' INT TERM HUP QUIT EXIT
      tmpdir="$(mktemp -d)" || exit 1
      mount -t tmpfs tmpfs "$tmpdir" || exit 1
      chmod 0000 "$tmpdir" || exit 1
      tmp_pwfile="$tmpdir"/pw
      tr -dc 0-9A-Za-z < /dev/random | head -c100 > "$tmp_pwfile" || exit 1

      printf " - Exporting keys for signing driver...\n"
      pk12util -w "$tmp_pwfile" -o "$tmpdir"/p12 -n 'nvidia-signer' -d /etc/pki/pesign || exit 1
      openssl pkcs12 -passin "file:$tmp_pwfile" -in "$tmpdir"/p12 -out "$tmpdir"/cer -clcerts -nokeys -nodes || exit 1
      openssl pkcs12 -passin "file:$tmp_pwfile" -in "$tmpdir"/p12 -out "$tmpdir"/priv -nocerts -nodes || exit 1

      printf " - Installing NVIDIA driver '%s'...\n" "$driver_runfile"
      "$driver_runfile" --module-signing-hash="SHA256" -X --tmpdir="$tmpdir" --dkms --module-signing-secret-key="$tmpdir"/priv --module-signing-public-key="$tmpdir"/cer --kernel-source-path="$KERNEL_SOURCE_PATH" || exit 1

      umount "$tmpdir" || exit 1
      rm -rf "$tmpdir" || exit 1
      trap - INT TERM HUP QUIT EXIT
    else

      printf " * No available NVIDIA driver runfile exists in the directory 'runfile'!\n" >&2
      exit 1

    fi
  else
      printf " - NVIDIA driver exists and running. Skipped driver installation.\n"
  fi


  cuda_runfile="$(ls runfile/cuda_*.run 2>/dev/null | sort --rev | head -n1)"

  if ! [ -d "/usr/local/cuda" ] && [ -n "$cuda_runfile" ] && [ -x "$cuda_runfile" ]
  then
    printf " - Installing cuda toolkit '%s'...\n" "$cuda_runfile"
    "$cuda_runfile" --silent --toolkit || exit 1
  elif [ -d "/usr/local/cuda" ]
  then
    printf " - Cuda is already installed on '/usr/local/cuda'. Skipped cuda installation.\n"
  else
    printf " - No available cuda runfile exists in the directory 'runfile'. Skipped cuda installation.\n"
  fi


fi
