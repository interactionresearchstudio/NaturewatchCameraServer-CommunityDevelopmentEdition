# Installing on Raspbian / Raspberry Pi OS Lite

On a fresh install of Raspberry Pi OS Lite (formerly Raspbian Lite), you can
install the Naturewatch Camera Server software by following these steps. One
advantage to using this method is that you can take advantage of the latest
Raspberry Pi OS updates and features, and you can customize the installation in
Raspberry Pi Imager before flashing the SD card (for example, enabling SSH on
first boot).

## On your Raspberry Pi

### Update and install necessary packages:

```bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y coreutils p7zip-full qemu-user-static python3-git python3-picamera2 git python3-pip python3-libcamera libcap-dev ffmpeg python3-flask python3-numpy python3-opencv python3-kms++
```

### Clone the Naturewatch Camera Server repository

```bash
cd /home/pi
git clone https://github.com/interactionresearchstudio/NaturewatchCameraServer-CommunityDevelopmentEdition.git NaturewatchCameraServer
```

### Copy the frontend build files

Run `build_node_app.sh` on your main machine and copy the `build` folder to the
Pi, to `/home/pi/NaturewatchCameraServer/naturewatch_camera_server/static/client/build`. Or you can
download the build folder from a GH workflow run. Once you have the build folder
in place, continue here:

### Set up the Python virtual environment and install dependencies

```bash
cd /home/pi/NaturewatchCameraServer
python -m venv --system-site-packages /home/pi/NaturewatchCameraServer/.venv
/home/pi/NaturewatchCameraServer/.venv/bin/pip install -r requirements.txt
```

### Set up the service

Uncomment the commented lines to enable WiFi hotspot.

```bash
cd /home/pi/NaturewatchCameraServer
export DIR=$(pwd)
TEMPLATES="${DIR}/helpers"
sed -e "s|\${path}|/home/pi|g" "${TEMPLATES}/python.naturewatch.service" > "./python.naturewatch.service"
# sed -e "s|\${path}|/home/pi|g" "${TEMPLATES}/wifisetup.service" > "./wifisetup.service"
sudo cp python.naturewatch.service "/etc/systemd/system/"
sudo chmod 644 /etc/systemd/system/python.naturewatch.service
# sudo chmod 644 /etc/systemd/system/wifisetup.service
sudo systemctl daemon-reload
sudo systemctl enable python.naturewatch.service
# sudo systemctl enable wifisetup.service
sudo systemctl start python.naturewatch.service
# systemctl start wifisetup.service
(sudo crontab -l 2>/dev/null; echo "# Start watchdog script at boot time") | sudo crontab -
(sudo crontab -l 2>/dev/null; echo "@reboot ${TEMPLATES}/watchdog.sh > /dev/null 2>&1") | sudo crontab -

sudo systemctl status python.naturewatch.service
```
