# voicetotext

A lightweight, **fully local** voice-to-text dictation tool for Apple Silicon
Macs — a minimal Superwhisper-style workflow:

> Press **F8** → speak → press **F8** again → the transcription is typed into
> whatever app you're in.

Transcription runs on-device with **NVIDIA Parakeet** via Apple's **MLX**
runtime. No audio or text ever leaves your machine.

---

## Requirements

- **Apple Silicon Mac (M1/M2/M3/M4…)** — MLX and `parakeet-mlx` are
  Apple-Silicon only.
- **Python 3.11+**
- `ffmpeg` (only needed for the temp-WAV fallback path): `brew install ffmpeg`

> The cross-platform parts (audio capture, clipboard, hotkey) install and run
> elsewhere, but the speech model itself requires Apple Silicon.

---

## Setup

Using [`uv`](https://github.com/astral-sh/uv) (recommended):

```bash
cd voicetotext
uv venv --python 3.11 .venv
source .venv/bin/activate
uv pip install -r requirements.txt
```

Or with stock `venv`/`pip`:

```bash
cd voicetotext
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

On the **first run** the Parakeet weights (~600 MB) are downloaded from
Hugging Face and cached locally.

---

## Usage

```bash
source .venv/bin/activate
python main.py
```

- Press **F8** to start recording, **F8** again to stop and transcribe.
- The text is copied to the clipboard and pasted into the active app.
- Press **Ctrl+C** in the terminal to quit.

### Options

```bash
python main.py --list-devices            # list microphones, then exit
python main.py --hotkey f9               # use a different toggle key
python main.py --device 2                # pick a specific input device
python main.py --model mlx-community/parakeet-tdt-0.6b-v3
python main.py --no-paste                # copy only, don't simulate Cmd+V
python main.py --no-restore-clipboard    # keep the transcription on clipboard
```

You can also use the helper:

```bash
./run.sh
```

---

## macOS Permissions (important)

macOS will block the app until you grant two permissions to **the terminal app
you launch it from** (Terminal, iTerm, or VS Code's integrated terminal):

1. **Microphone** — to record audio
   `System Settings → Privacy & Security → Microphone` → enable your terminal.

2. **Accessibility** (and often **Input Monitoring**) — to capture the global
   F8 hotkey and to simulate **Cmd+V**
   `System Settings → Privacy & Security → Accessibility` → enable your
   terminal. If the hotkey seems dead, also enable it under **Input
   Monitoring**.

After changing these, **fully quit and reopen** the terminal, then run again.
The script prints targeted instructions if it detects a permission failure.

---

## How it works

| Stage          | Implementation                                                        |
| -------------- | --------------------------------------------------------------------- |
| Global hotkey  | `pynput` keyboard listener on a background thread (debounced repeat)  |
| Recording      | `sounddevice` input stream → in-memory float32 buffer (16 kHz mono)   |
| Transcription  | `parakeet-mlx` log-mel front-end + `model.generate` (no disk writes)  |
| Paste          | `pyperclip` clipboard + simulated `Cmd+V` via `pynput`                |

Heavy transcription runs on a worker thread so the hotkey stays responsive,
and a temp-WAV fallback covers any version drift in the in-memory model API.

---

## Troubleshooting

- **Hotkey does nothing** → grant Accessibility + Input Monitoring, then
  restart the terminal.
- **`PortAudioError` on start** → grant Microphone permission.
- **`parakeet-mlx` import error** → you're not on Apple Silicon, or the deps
  didn't install; re-run `pip install -r requirements.txt` on an M-series Mac.
- **Wrong microphone** → `python main.py --list-devices` then `--device N`.
