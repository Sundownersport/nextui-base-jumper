# BaseOS Updater

A NextUI pak that updates [BaseOS](https://github.com/pvaibhav/BaseOS) on Anbernic RG XX devices over WiFi.

It checks for a newer BaseOS release, downloads your model's `.bosupd` to the root of the SD card, verifies it against the release's `SHA256SUMS` and restarts. BaseOS applies the update at boot and deletes the file.

## Install

Get it from the Pak Store, or download `BaseOS.Updater.pak.zip` from [Releases](https://github.com/SundownerSport/nextui-baseos-updater/releases), unzip it into a folder named `BaseOS Updater.pak` and copy that folder to `Tools/h700/` on your SD card.

## Use

Connect to WiFi, then open **Tools > BaseOS Updater**. Keep the device charged or plugged in while BaseOS installs the update.

Log: `.userdata/h700/logs/BaseOS Updater.txt`

## Credits

Screens use [minui-presenter](https://github.com/josegonzalez/minui-presenter) (MIT, see `bin/minui-presenter.LICENSE`).
