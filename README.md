# Nmap-Script

`nmap-easy.sh` is a friendly wrapper around [nmap](https://nmap.org). It asks
you simple questions, or takes flags, checks your input, runs the right nmap
command, saves the results in every format and prints a clean summary.

> ⚠️ Only scan hosts and networks you own or have written permission to test.

## Features

- **Interactive menu** or **one-line mode** for scripts and repeat scans
- **9 scan profiles**: discover, quick, standard, full, udp, os, vuln, aggressive, custom
- **Two-phase full scan**: finds open ports across all 65535 quickly, then runs
  version detection and default scripts on those ports only
- **Checks your input**: IPs, ranges, CIDR, hostnames, port lists and speed
- **Flexible targets**: `192.168.1.5`, `192.168.1.1-254`, `10.0.0.0/24`,
  `scanme.nmap.org`, several at once, or a file with one target per line
- **Saves everything** with `-oA`: `.nmap` (readable), `.gnmap` (for grep), `.xml` (for other tools),
  using timestamped names so old results are never overwritten
- **Summary table** of hosts, open ports, services and versions
- **Handles root for you**: uses a SYN scan when it runs as root and offers `sudo` for
  profiles that need it, then gives the output files back to your user
- Prints the exact nmap command so you can learn the flags
- **Updates itself** from GitHub with `-u`, and checks the download before replacing anything
- Works with the macOS bash 3.2 that comes with the system and with Linux bash

## Install

```bash
# macOS
brew install nmap
# Debian / Ubuntu / Kali
sudo apt install nmap

git clone https://github.com/itsmrroot/Nmap-Script.git
cd Nmap-Script
chmod +x nmap-easy.sh
```

Optional, to run it from anywhere as `nmap-easy`:

```bash
sudo cp nmap-easy.sh /usr/local/bin/nmap-easy
```

## Update

```bash
./nmap-easy.sh -u     # update to the latest version
./nmap-easy.sh -v     # show the installed version
```

The updater downloads the latest `nmap-easy.sh` from this repository and only
replaces your copy if the download is a valid script **and** a newer version.
If the script is installed in a system folder, run `sudo nmap-easy -u`.

## Usage

Interactive:

```bash
./nmap-easy.sh
```

One-line:

```bash
./nmap-easy.sh -t 192.168.1.1-254 -s discover          # who is online?
./nmap-easy.sh -t 192.168.1.10 -s quick -p 22,80,443   # specific ports
./nmap-easy.sh -t scanme.nmap.org                       # standard scan
sudo ./nmap-easy.sh -t 10.0.0.0/24 -s full -y           # everything, no prompt
./nmap-easy.sh -i targets.txt -s vuln -o ~/results      # targets from a file
./nmap-easy.sh -t 10.0.0.5 -s custom -x "-sV --script http-title" -p 80,443
```

| Option | Meaning |
|---|---|
| `-t TARGET` | Target(s); put several in quotes: `-t "10.0.0.1 10.0.0.5"` |
| `-i FILE` | Read targets from a file |
| `-s PROFILE` | Scan profile (default `standard`); `-l` lists them |
| `-p PORTS` | `22,80,443`, `1-1024`, or `-` for all |
| `-T 0-5` | Speed (default 4) |
| `-o DIR` | Output directory (default `./scans`) |
| `-n NAME` | Base name for result files |
| `-x "FLAGS"` | Extra raw nmap flags |
| `-y` | Skip the confirmation question |
| `-l` | List scan profiles |
| `-u` | Update to the latest version |
| `-v` | Show version |
| `-h` | Help |

## Profiles

| # | Profile | What it does | Root |
|---|---|---|---|
| 1 | `discover` | Ping sweep to find live hosts | |
| 2 | `quick` | Top 100 TCP ports | |
| 3 | `standard` | Top 1000 TCP ports + `-sV -sC` | |
| 4 | `full` | All TCP ports, then `-sV -sC` on the open ones | |
| 5 | `udp` | Top 100 UDP ports | yes |
| 6 | `os` | OS detection + versions | yes |
| 7 | `vuln` | Versions + NSE `vuln` scripts | |
| 8 | `aggressive` | `-A` (OS, versions, scripts, traceroute) | yes |
| 9 | `custom` | Your own flags via `-x` / the prompt | |

## Inspired by

- [21y4d/nmapAutomator](https://github.com/21y4d/nmapAutomator): the two-phase full scan
- [NazmulHarun/nmap-automator](https://github.com/NazmulHarun/nmap-automator)
- [lisandrogallo/simple-nmap-script](https://github.com/lisandrogallo/simple-nmap-script)
- [fxinfo24/NmapScanner](https://github.com/fxinfo24/NmapScanner)
