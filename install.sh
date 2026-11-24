#!/bin/bash
# chmod +x install.sh

# Check for sudo permissions
if [ $EUID != 0 ]; then
    echo "Launch the script as sudo"
    sudo "$0" "$@"
    exit $?
fi

echo "-----------------------------------------"

# Extract argument passed to the script
# $1 is the installation path
INSTALLATION_PATH="$1"
echo "Installation path: $INSTALLATION_PATH"

# Get install.sh parent directory
SOURCE="${BASH_SOURCE:-0}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
    DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

# Append to config file /boot/config.txt
CONFIG_FILE="/boot/firmware/config.txt"
# echo -e "\n" >> $CONFIG_FILE
# echo -e "max_usb_current=1" >> $CONFIG_FILE # It's the default behaviour.
echo -e "\n# Deactivate the activity LED\ndtparam=act_led_trigger=none" >> $CONFIG_FILE
echo -e "dtparam=act_led_activelow=on" >> $CONFIG_FILE
echo -e "# Set CPU speed to 600MHz - fixes unstable WiFi issue" >> $CONFIG_FILE
echo -e "arm_freq=600" >> $CONFIG_FILE

# I'm not sure about the config path, so let also modify the legacy one.
CONFIG_FILE="/boot/config.txt"
echo -e "\n# Deactivate the activity LED\ndtparam=act_led_trigger=none" >> $CONFIG_FILE
echo -e "dtparam=act_led_activelow=on" >> $CONFIG_FILE
echo -e "# Set CPU speed to 600MHz - fixes unstable WiFi issue" >> $CONFIG_FILE
echo -e "arm_freq=600" >> $CONFIG_FILE

# Run every apt invocation non-interactively: this script also runs inside the
# CustomPiOS chroot during image builds, where a debconf prompt stalls forever.
# force-confdef/confold also keeps end-user installs unattended (old configs
# are kept instead of prompting); acceptable for this project's setup.
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Copy to installation path
mkdir -p $INSTALLATION_PATH/NaturewatchCameraServer >/dev/null 2>&1
cp -r $DIR $INSTALLATION_PATH >/dev/null 2>&1

# Update and upgrade
apt-get clean
apt-get update
apt-get upgrade "${APT_OPTS[@]}"
apt-get dist-upgrade "${APT_OPTS[@]}"

# Install extra packages (with specific versions) to avoid breaking the system:
# apt list python3-picamera2 git python3-pip python3-libcamera libcap-dev ffmpeg python3-flask python3-numpy python3-opencv python3-kms++ --installed
apt-get install "${APT_OPTS[@]}" python3-picamera2 --no-install-recommends
apt-get install "${APT_OPTS[@]}" git python3-pip python3-libcamera libcap-dev ffmpeg python3-flask python3-numpy python3-opencv python3-kms++

# Setup a venv
python -m venv --system-site-packages ${INSTALLATION_PATH}/NaturewatchCameraServer/.venv

# Remove unnecessary packages
apt-get autoremove -y

pushd $INSTALLATION_PATH
pushd NaturewatchCameraServer

# Install python dependencies
${INSTALLATION_PATH}/NaturewatchCameraServer/.venv/bin/pip install -r requirements.txt

echo "Adding services"
# Allows to reinstall the service
systemctl stop python.naturewatch.service >/dev/null 2>&1
systemctl stop wifisetup.service >/dev/null 2>&1

# Copy service files to /etc/systemd/system and replace ${path} with the installation path root
TEMPLATES="${DIR}/helpers"
sed -e "s|\${path}|${INSTALLATION_PATH}|g" "${TEMPLATES}/python.naturewatch.service" > "/etc/systemd/system/python.naturewatch.service"
sed -e "s|\${path}|${INSTALLATION_PATH}|g" "${TEMPLATES}/wifisetup.service" > "/etc/systemd/system/wifisetup.service"

popd
popd

echo "Enabling and starting services"
chmod 644 /etc/systemd/system/python.naturewatch.service
chmod 644 /etc/systemd/system/wifisetup.service
systemctl daemon-reload
systemctl enable python.naturewatch.service
systemctl enable wifisetup.service
systemctl start python.naturewatch.service
systemctl start wifisetup.service

# Add Watchdog script to crontab
(crontab -l 2>/dev/null; echo "# Start watchdog script at boot time") | crontab -
(crontab -l 2>/dev/null; echo "@reboot ${TEMPLATES}/watchdog.sh > /dev/null 2>&1") | crontab -

