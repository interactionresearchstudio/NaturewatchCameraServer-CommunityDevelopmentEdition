# NaturewatchCameraServer - Community Development edition

This is the Community Development branch for the My Naturewatch Camera. It is a Python server 
that captures a video stream from a Pi Camera and serves it as a .mjpg 
through a control website to another device. The website can be used to start 
a photo capture or video capture based on motion detected in the frame. The 
software is designed to run on a Raspberry Pi Zero 2 W so that you can make your 
own low-cost wildlife camera.

Part of the My Naturewatch project by the Interaction Research Studio, in collaboration with the RCA.

# Differences between versions

- This branch is experimental, and is not intended to replace the original software when a "plug-and-play" experience is required.
- Updated to Raspberry Pi OS based on Bookworm.
- Support for newer Pi Cameras with picamera2, like Pi Camera Module 3 (many thanks to [caracoluk](https://github.com/caracoluk) and [Vincent-Stragier](https://github.com/Vincent-Stragier)).
- WiFi and hotspot now controlled by NetworkManager.
- Additional features and camera controls in the settings panel.

These updates now should make it easier for community members to adapt and update the MyNaturewatch Camera software, with newer libaries and tools.

# Supported Devices

- [ ] Pi 1 A/B/+
- [ ] Pi 2
- [ ] Pi Zero W
- [x] Pi 3 A/B/+
- [x] Pi 4
- [x] Pi Zero 2 W
- [x] Pi 5

# How to install

1. Either clone the repository and build software locally, fork the repository and run the Github Actions build, or download the latest commit build.
2. Uncompress the built zip file and burn this to an SD card. We recommend using [Raspberry Pi Imager](https://www.raspberrypi.com/software/) for this.
3. Alternatively, flash the latest Raspberry Pi OS (Lite) image to an SD card and then follow the steps in [README_RASPBIAN_INSTALL.md](README_RASPBIAN_INSTALL.md) to install the software manually.

## Configuring the wifi setup

The device automatically creates a hotspot network named MyNatureWatch-12345, with the numbers being a unique ID.

**NOTE:** If you want to connect the device to your home network via wifi you will need to disable the wifi
hotspot service by logging into the device and running

```bash
$ sudo systemctl disable --now wifisetup.service
```

If you do not do this your wifi settings will be overridden when it restarts.

## Access the interface

The website is then accessible through its IP address:

	http://10.42.0.1
	
If your device is Bonjour compatible, you can also use:

	http://mynaturewatchcamera.local/
	

## Reporting bugs

Please provide as much information as possible. If you'd like to open an issue about a
possible bug, please do so here and include as much information as possible. You can 
also open an issue if you would like to request a new feature. 

## Pull requests

If you'd like to submit a pull request, please let us know whether you're submitting a
new feature, or a bug fix. Make sure to do a self review, and test on at least one type 
of Raspberry Pi. Please don't be offended if it takes us some time to fit your PR in! 
We will respond to every single one of them and let you know if we're evaluating it for 
a full release.

## Support

If you require support, please head over to the [My Naturewatch Forum](https://mynaturewatch.net/forum).


