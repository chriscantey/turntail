# Broadcasting

This guide sets up a station: a Raspberry Pi next to your turntable that sends your records to the hub, so your friends hear them on the page. It takes about an hour, most of it waiting for the Pi. Every step happens on your own phone, computer and Pi, and nobody else needs to touch them.

<p align="center">
  <img src="station-parts.jpg" width="560" alt="A Raspberry Pi 3A+, a red Behringer UCA222 audio interface and an RCA cable on a sideboard, a turntable behind them">
</p>

## What you need

| Part | Notes |
|---|---|
| A Raspberry Pi 3 Model A+, Pi 4 or Pi 5 | The 3A+ and Pi 5 are tested, and the Pi 4 should work the same. Another Debian machine, like an old laptop, should work too: skip steps 2 to 4, keep its own name in place of `<station name>-station`, and know that setup turns off MagicDNS on it. The 3A+ is the cheapest that does the job. Raspberry Pi's [product page](https://www.raspberrypi.com/products/raspberry-pi-3-model-a-plus/) lists approved resellers for your country, or in the US try [Adafruit](https://www.adafruit.com/product/4027). |
| The right power supply for it | Pi 4 and Pi 5 take USB-C, the 3A+ takes micro-USB (5 V 2.5 A, [Adafruit](https://www.adafruit.com/product/1995)). The official Raspberry Pi supply for your board is the safe choice. |
| A microSD card | 8 GB or larger. Everything on it gets erased. |
| A USB audio interface with a stereo line input | We use the Behringer UCA222 ([Amazon](https://www.amazon.com/dp/B0023BYDHK), [Sweetwater](https://www.sweetwater.com/store/detail/UCA222--behringer-u-control-uca222-usb-audio-interface), [B&H](https://www.bhphotovideo.com/c/product/1821212-REG/behringer_uca222_16_bit_48khz_2_channel_usb_audio.html)). Any USB audio interface that works without a driver should work, and setup finds it by itself. |
| A stereo RCA cable | Red and white plugs at both ends, from the turntable to the interface. |
| A turntable with a LINE output | Many have a LINE/PHONO switch on the back. If yours only has a PHONO output, either put a phono preamp between the turntable and the interface, or use a [Behringer UFO202](https://www.sweetwater.com/store/detail/UFO202--behringer-u-phono-ufo202-usb-audio-interface) instead of the UCA222. It's the same kind of interface with a phono preamp built in. We haven't tested it yet. |
| A computer | Mac, Windows or Linux, to write the card and to type a few commands into the Pi. |
| Your Wi-Fi name and password | The Pi joins your Wi-Fi. |
| A Tailscale account | Free for personal use. The [listening guide](listening.md) covers making one. |

This guide assumes you are already a listener: you followed the [listening guide](listening.md), and the page plays on your phone. That matters for the Pi, because it can only reach the hub through a Tailscale account that has accepted the hub's share.

From whoever runs the hub you then get **one line with three values**: the hub name, your station name and your station password. It looks like this:

```
HUB=turntail.example-tailnet.ts.net MOUNT=alice MOUNT_PW=Xq3...
```

The password is yours alone. Keep that line somewhere private.

## 1. Send the hub owner your login

1. Open the [Machines page](https://login.tailscale.com/admin/machines) of your Tailscale admin console, signed in with the account you listen with. The hub is listed there, marked as shared with you. That is the account the Pi will use too.
2. Find your login on the [Users page](https://login.tailscale.com/admin/users), under your name. It is usually an email address, or something like `alice@github` if you signed in with GitHub.
3. Send that login to the hub owner. They add it to the hub so your station is allowed to broadcast, and they send you back the line with your three values.

You can carry on with steps 2 to 5 while you wait for the line.

## 2. Write the card

1. On your computer, install and open [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
2. Choose your device: Raspberry Pi 4, Raspberry Pi 5, or Raspberry Pi 3 for the 3A+.
3. Choose the operating system: **Raspberry Pi OS (other)**, then **Raspberry Pi OS Lite (64-bit)**.
4. Choose your microSD card.
5. Fill in the OS settings below. Recent versions of Imager walk you through them one page at a time after you choose the card. Older versions ask about OS customization when you press Next, and the settings are behind **Edit settings**.

    | Setting | What to put |
    |---|---|
    | Hostname | `station` |
    | Username and password | Your own choice. Write them down, you need them in step 4. |
    | Wi-Fi | Your Wi-Fi name and password, and your country. |
    | Time zone and keyboard | Yours. |
    | SSH | Turned on, with password authentication. |
    | Raspberry Pi Connect | Leave it off. |

6. Write the card and wait until Imager says it is finished.

## 3. Plug everything in

1. Put the card in the Pi.
2. Plug the USB audio interface into a USB port on the Pi.
3. Connect the RCA cable from the turntable's output to the interface's **INPUT** jacks, red to red and white to white. The UCA222 also has OUTPUT jacks, and those are the wrong ones. If the turntable has a LINE/PHONO switch, set it to **LINE**.
4. Plug in the power last.

The first boot takes a few minutes while the Pi sets itself up, and a 3A+ is slower than a Pi 4 or 5. Give it five minutes.

## 4. Log in to the Pi

On your computer, open a terminal. On a Mac that is the Terminal app, on Windows it is PowerShell. Type this, with the username you chose in step 2:

```
ssh <username>@station.local
```

Answer `yes` when it asks about the fingerprint, then type the password you chose. You are in when the prompt changes to something like `<username>@station:~ $`. Everything from here on is typed into that window.

If it says it cannot find `station.local`, wait another minute and try again. If you would rather not use a terminal on your computer, a keyboard and monitor plugged into the Pi work too: log in there with the same username and password, and type the same commands.

## 5. Get Turntail onto the Pi

```
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/chriscantey/turntail.git
```

## 6. Run setup with your three values

When the line with your three values has arrived, type `sudo `, paste the line, then type ` bash ~/turntail/station/setup.sh` and press Enter. The whole thing looks like this:

```
sudo HUB=<hub name> MOUNT=<station name> MOUNT_PW=<station password> bash ~/turntail/station/setup.sh
```

Setup prints a heading for each stage, starting with `== packages`. Installing the packages takes several minutes, longer on a 3A+. Then it installs Tailscale.

## 7. Log the Pi in to Tailscale as yourself

At `== tailscale`, setup prints `Log this device in to YOUR tailnet (the one you accepted the share with):` and then a link that starts with `https://login.tailscale.com/`. It waits there until you use the link.

1. Copy the link and open it in a browser on your computer.
2. Sign in with the **same Tailscale account you used in step 1**, and connect the device.

The Pi joins your Tailscale network as an ordinary device, logged in as you, and it shows up in your Machines list as `<station name>-station`. It uses no auth key and no tags, because a tagged device cannot use a shared machine. If you ever need to log the Pi in again, run `sudo tailscale logout` and then the step 6 command.

Setup carries on by itself. These are the lines that matter:

- `hub port 8000 reachable` means the Pi can reach the hub, and the hub has let your login in to send audio.
- `using hw:CARD=...` names the audio interface it found, for the UCA222 something like `hw:CARD=CODEC,DEV=0 (CODEC [USB Audio CODEC] ...)`.
- `== done.` is the last line.

If it stops with `cannot reach <hub>:8000`, either the hub owner has not added your login yet, or the Pi is logged in to a different Tailscale account than the one that accepted the share. For the first, ask the hub owner. For the second, run `sudo tailscale logout`, then the step 6 command again and sign in with the right account. Setup is safe to run as many times as you like.

If it prints `WARNING: no USB audio capture device found`, check that the interface is plugged in, then run the step 6 command again.

## 8. Check the sound

Put a record on, then run:

```
sudo turntail-station test 10
```

It records ten seconds from the interface and prints two numbers. Look at `max_volume`:

- **Above -20 dB** is good.
- **Between -30 and -20 dB** is a little quiet. Turn it up with `sudo turntail-station gain 6`. The test always measures the input before gain, so its numbers stay the same. Listen on the page to hear the difference.
- **Around -50 dB or lower** means no signal. Check the LINE/PHONO switch, that the cable goes into INPUT, and that the record is actually playing.

The test pauses the stream for those ten seconds, so run it before you go live, not during.

Then run:

```
sudo turntail-station status
```

The `service` line should say `active` and the `hub` line should say `reachable`.

## 9. Go live

On your phone or laptop, with Tailscale on, open the page address. Under **Stations** your station shows "source connected", and below that there is a **Your station** card.

<p align="center">
  <img src="page-streamer-phone.jpg" width="320" alt="The page for a streamer who is on the air, with the Your station card, the platter box and the wrap-up buttons">
</p>

1. Press **Go live**. If someone else is on the air, the button says **Ask for the next slot** instead, and you go on when their turn ends.
2. Drop the needle.
3. Press play at the top of the page to hear yourself a few seconds late.

When you are done, press **Stop streaming**. If the page says your station has no source connected, run `sudo turntail-station status` on the Pi and look at the `hub` line.

While you are on, the card shows how long is left, has buttons to wrap up early, and has a box for what is on the platter. Type the record's name and pick it from the list, and everyone sees the title, and the cover if the hub has a Discogs token.

## 10. Turn off key expiry for the station

Tailscale logs a device out after 180 days unless you turn that off, and the station would just stop with no visible reason. In your [Machines page](https://login.tailscale.com/admin/machines), open the menu on the `<station name>-station` row and choose **Disable key expiry**.

## Day to day

The Pi starts streaming by itself whenever it has power. It sends to the hub all the time it is on, about 115 MB an hour, whether or not you are on the air. If that matters on your connection, switch it off between sessions.

```
sudo turntail-station status              what it is doing, can it reach the hub
sudo turntail-station test 10             record ten seconds, print how loud it is
sudo turntail-station gain 3              a little louder (or -3 for quieter, 0 to reset)
sudo turntail-station source turntable    send the turntable (the default)
sudo turntail-station source demo         a spoken clock instead, to check the delay
sudo turntail-station source off          stop sending until you switch it back
sudo turntail-station devices             list the audio devices the Pi can record from
sudo turntail-station logs                follow what the station is doing (Ctrl-C to stop)
```

To get back into the Pi later, it is the same `ssh <username>@station.local` from step 4.

## If something is off

- **No sound on the page, but you are live.** Run `sudo turntail-station test 10` with the record playing and read the numbers as in step 8.
- **The interface is missing.** `sudo turntail-station devices` lists what the Pi can record from. If your interface is not there, unplug it and plug it back in, then run the step 6 command again.
- **`status` says NOT reachable.** Check that Tailscale is still logged in with `tailscale status`, that the hub still appears in your Machines list, and ask the hub owner whether your login is still on the hub.
- **Quiet and thin, or a hum.** That is usually a turntable set to PHONO going into a line input, or a loose ground wire. Set the switch to LINE, and connect the turntable's ground wire if it has one.
