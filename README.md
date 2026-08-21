# PrintGlance

Mac menu bar extra for a Bambu printer on your LAN. It shows remaining time and finish clock so you don't need Bambu Studio open.

PrintGlance does not open MQTT. A local feed (`print_loop.py`) subscribes read-only to the printer and serves `GET /print.json`. The extra polls `http://127.0.0.1:8080/print.json`.

## Install

1. Clone the repository:

```bash
git clone https://github.com/talic/PrintGlance.git
cd PrintGlance
```

2. Copy `.env.example` to `.env`.
3. Set `BAMBU_IP`, `BAMBU_SERIAL`, and `BAMBU_ACCESS_CODE` from the printer's WLAN screen. Enable Developer Mode on the printer if LAN MQTT refuses the connection.
4. Create the Python environment and install the extra:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
make install
```

`make install` does the following:

- Builds `PrintGlance.app`, copies it to `~/Applications`, and opens it
- Loads a LaunchAgent (`local.PrintGlance.feed`) that runs `print_loop.py` and restarts it if it exits

Install does not turn on **Open at Login**. To start the extra when you log in, turn on **Open at Login** in the extra's **…** menu. To quit the extra, choose **Quit** from that menu.

If the extra does not appear, enable it in **System Settings > Menu Bar**. Ad-hoc-signed extras can stay hidden until you do.

Feed log: `~/Library/Logs/PrintGlance-feed.log`.

To stop the feed until the next `make install`:

```bash
launchctl bootout gui/$(id -u)/local.PrintGlance.feed
```

## Desk-check the feed

```bash
source .venv/bin/activate
set -a; source .env; set +a
python bambu.py --self-test
python bambu.py --once
```

Do not run a second `print_loop.py` on the same port as the LaunchAgent.

## Optional token

`STATS_TOKEN` is off by default. If you set it on the feed, set the same value on the extra:

```bash
defaults write local.PrintGlance feedToken 'TOKEN'
```

Replace `TOKEN` with the feed token. Clients must send header `X-Stats-Token`.

## Layout

| Path | Role |
|------|------|
| `Sources/PrintGlance` | Menu bar extra |
| `print_loop.py` | LAN MQTT subscriber + `GET /print.json` |
| `bambu.py` | Snapshot merge (read-only; no pause/stop/print) |
| `print_loop.sh` | LaunchAgent entry |
| `.env.example` | Printer env vars (no secrets) |

## License

MIT. See the `LICENSE` file.
