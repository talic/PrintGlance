# PrintGlance

PrintGlance is a small icon in the Mac menu bar. While your Bambu printer is printing, it shows how far the job has got and what time it should finish. You do not need Bambu Studio open.

PrintGlance runs only on your Mac. It talks only to the printer whose IP address you enter, on your Wi-Fi. It does not use the internet or Bambu's cloud. It does not pause, stop, or start prints. It only asks for status and shows it.

## What you need

- A Mac with macOS 14 or later
- A Bambu printer on the **same Wi-Fi** as the Mac
- Three values from the printer: **IP address**, **serial number**, and **access code**

## Get the values from the printer

1. On the printer screen, open **Settings**.
2. Open the **LAN** or **Network** page (the name varies by model).
3. Write down **IP**, **Access code**, and **Serial**.

If **Serial** is not on that page, look under **Settings** for device info, or on the sticker on the printer.

The Mac and the printer must be on the same Wi-Fi network. Guest Wi-Fi that isolates devices does not work.

## Install PrintGlance

1. Open the [latest PrintGlance release](https://github.com/talic/PrintGlance/releases/latest).
2. Download **PrintGlance.zip** and double-click it to unzip.
3. Drag **PrintGlance** into the **Applications** folder.
4. Control-click **PrintGlance** and choose **Open**. Click **Open** again if macOS asks.
5. If you do not see a printer icon in the menu bar, turn PrintGlance on in **System Settings > Menu Bar**.

## Connect to your printer

1. Click the printer icon in the menu bar.
2. If the printer form is not already open, click **…** and choose **Printer**.
3. Enter the IP address, serial number, and access code. Name is optional.
4. Click **Save**.

When a print is running, the menu bar shows percent and finish time. Click the icon for more detail.

The access code stays on this Mac. PrintGlance does not send it to the internet.

To start PrintGlance when you log in, click **…** and turn on **Open at Login**. To quit, click **…** and choose **Quit**.

## If it cannot connect

- Mac and printer are on the same Wi-Fi
- IP address and access code match the printer's LAN or Network page
- The printer is switched on

## License

MIT. See the `LICENSE` file.
