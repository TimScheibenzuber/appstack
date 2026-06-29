#!/usr/bin/env python3
"""
voicetotext core engine — shared by the CLI (main.py) and the menu bar app
(menubar.py).

Contains the platform building blocks (audio capture, Parakeet/MLX
transcription, clipboard + paste automation), persistent settings/history,
and small helpers. Everything here is import-light: the heavy, platform
specific dependencies (sounddevice, mlx, parakeet-mlx, pyperclip, pynput) are
imported lazily inside the classes that need them so this module imports
cleanly anywhere.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import threading
import time
import wave
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Constants & paths
# ---------------------------------------------------------------------------

DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
SAMPLE_RATE = 16_000  # Parakeet expects 16 kHz mono
CHANNELS = 1

APP_DIR = Path.home() / ".voicetotext"
CONFIG_PATH = APP_DIR / "config.json"
HISTORY_PATH = APP_DIR / "history.json"

# Recording lifecycle states.
IDLE, RECORDING, PROCESSING = "idle", "recording", "processing"


# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------

def info(msg: str) -> None:
    print(f"  {msg}", flush=True)


def ok(msg: str) -> None:
    print(f"  \033[92m✓\033[0m {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"  \033[93m!\033[0m {msg}", flush=True)


def err(msg: str) -> None:
    print(f"  \033[91m✗\033[0m {msg}", flush=True)


# ---------------------------------------------------------------------------
# macOS permission guidance
# ---------------------------------------------------------------------------

MIC_HELP = """
  ┌─ Microphone permission required ───────────────────────────────────────┐
  │ macOS blocked microphone access. Grant it here:                        │
  │   System Settings → Privacy & Security → Microphone                    │
  │   → enable your terminal app (Terminal / iTerm / VS Code).             │
  │ Then fully quit and reopen the terminal and run this script again.     │
  └────────────────────────────────────────────────────────────────────────┘
"""

ACCESSIBILITY_HELP = """
  ┌─ Accessibility permission required ────────────────────────────────────┐
  │ Listening for a global hotkey and simulating Cmd+V both require the     │
  │ Accessibility permission. Grant it here:                                │
  │   System Settings → Privacy & Security → Accessibility                  │
  │   → enable your terminal app (Terminal / iTerm / VS Code).             │
  │ Also check Input Monitoring for the same app if the hotkey is silent.  │
  │ Then fully quit and reopen the terminal and run this script again.     │
  └────────────────────────────────────────────────────────────────────────┘
"""


# ---------------------------------------------------------------------------
# Configuration (with JSON persistence)
# ---------------------------------------------------------------------------

@dataclass
class Config:
    model: str = DEFAULT_MODEL
    hotkey: str = "f8"
    sample_rate: int = SAMPLE_RATE
    channels: int = CHANNELS
    device: int | None = None          # input device index (None = default)
    restore_clipboard: bool = True     # restore prior clipboard after paste
    auto_paste: bool = True            # simulate Cmd+V after copying
    paste_delay: float = 0.15          # seconds to let the clipboard settle
    history_limit: int = 25            # how many transcripts to retain

    # --- persistence ---
    @classmethod
    def load(cls, path: Path = CONFIG_PATH) -> "Config":
        cfg = cls()
        try:
            data = json.loads(path.read_text())
            for k, v in data.items():
                if hasattr(cfg, k):
                    setattr(cfg, k, v)
        except FileNotFoundError:
            pass
        except Exception as e:  # corrupt file — keep defaults but warn
            warn(f"Could not read config ({e}); using defaults.")
        return cfg

    def save(self, path: Path = CONFIG_PATH) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), indent=2))


# ---------------------------------------------------------------------------
# Transcription history (with JSON persistence)
# ---------------------------------------------------------------------------

class HistoryStore:
    """Append-only-ish store of recent transcriptions, newest first."""

    def __init__(self, limit: int = 25, path: Path = HISTORY_PATH):
        self.limit = limit
        self.path = path
        self.items: list[dict] = []
        self.load()

    def load(self) -> None:
        try:
            self.items = json.loads(self.path.read_text())
        except FileNotFoundError:
            self.items = []
        except Exception:
            self.items = []

    def add(self, text: str, ts: float) -> None:
        self.items.insert(0, {"text": text, "ts": ts})
        del self.items[self.limit:]
        self.save()

    def clear(self) -> None:
        self.items = []
        self.save()

    def save(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps(self.items, indent=2))
        except Exception as e:
            warn(f"Could not save history ({e}).")


# ---------------------------------------------------------------------------
# Audio recording (in-memory)
# ---------------------------------------------------------------------------

class AudioRecorder:
    """Captures mic audio into an in-memory buffer using a sounddevice stream.

    Audio never touches disk during normal operation: frames arrive via the
    PortAudio callback and are appended to a list, then concatenated on stop.
    """

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._frames: list[np.ndarray] = []
        self._stream = None
        self._lock = threading.Lock()
        self._overflows = 0
        import sounddevice as sd  # noqa: PLC0415
        self._sd = sd

    def _callback(self, indata, frames, time_info, status):  # PortAudio thread
        if status:
            self._overflows += 1
        with self._lock:
            self._frames.append(indata.copy())

    def start(self) -> None:
        with self._lock:
            self._frames = []
            self._overflows = 0
        try:
            self._stream = self._sd.InputStream(
                samplerate=self.cfg.sample_rate,
                channels=self.cfg.channels,
                dtype="float32",
                device=self.cfg.device,
                callback=self._callback,
                blocksize=0,
            )
            self._stream.start()
        except self._sd.PortAudioError as e:
            raise PermissionError(str(e)) from e

    def stop(self) -> np.ndarray:
        """Stop the stream and return mono float32 audio in [-1, 1]."""
        stream, self._stream = self._stream, None
        if stream is not None:
            try:
                stream.stop()
                stream.close()
            except Exception as e:  # pragma: no cover - defensive
                warn(f"Error closing audio stream: {e}")

        with self._lock:
            frames = self._frames
            self._frames = []

        if self._overflows:
            warn(f"{self._overflows} audio buffer overflow(s) during recording.")

        if not frames:
            return np.zeros(0, dtype=np.float32)

        audio = np.concatenate(frames, axis=0).astype(np.float32)
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        return audio


# ---------------------------------------------------------------------------
# Transcription (NVIDIA Parakeet via MLX)
# ---------------------------------------------------------------------------

class Transcriber:
    """Loads the Parakeet MLX model once and transcribes in-memory audio."""

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._model = None

    @property
    def loaded(self) -> bool:
        return self._model is not None

    def load(self) -> None:
        info(f"Loading model '{self.cfg.model}' (first run downloads weights)...")
        t0 = time.time()
        try:
            from parakeet_mlx import from_pretrained  # noqa: PLC0415
        except ImportError as e:
            raise RuntimeError(
                "parakeet-mlx / mlx are not installed. They require an Apple "
                "Silicon Mac. Install with:  pip install parakeet-mlx mlx"
            ) from e

        try:
            self._model = from_pretrained(self.cfg.model)
        except Exception as e:
            raise RuntimeError(
                f"Failed to load model '{self.cfg.model}': {e}"
            ) from e
        ok(f"Model ready in {time.time() - t0:.1f}s")

    @property
    def sample_rate(self) -> int:
        try:
            return int(self._model.preprocessor_config.sample_rate)
        except Exception:
            return self.cfg.sample_rate

    def transcribe(self, audio: np.ndarray) -> str:
        if self._model is None:
            raise RuntimeError("Model is not loaded.")
        if audio.size == 0:
            return ""
        try:
            return self._transcribe_in_memory(audio)
        except Exception as e:
            warn(f"In-memory transcription path failed ({e}); using temp WAV.")
            return self._transcribe_via_tempfile(audio)

    def _transcribe_in_memory(self, audio: np.ndarray) -> str:
        import mlx.core as mx  # noqa: PLC0415
        from parakeet_mlx.audio import get_logmel  # noqa: PLC0415

        mel = get_logmel(mx.array(audio), self._model.preprocessor_config)
        result = self._model.generate(mel)
        if isinstance(result, (list, tuple)):
            result = result[0]
        return (result.text or "").strip()

    def _transcribe_via_tempfile(self, audio: np.ndarray) -> str:
        pcm = np.clip(audio, -1.0, 1.0)
        pcm16 = (pcm * 32767.0).astype("<i2")
        tmp = Path(tempfile.gettempdir()) / f"voicetotext_{int(time.time()*1000)}.wav"
        try:
            with wave.open(str(tmp), "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(self.sample_rate)
                wf.writeframes(pcm16.tobytes())
            result = self._model.transcribe(str(tmp))
            return (result.text or "").strip()
        finally:
            tmp.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Clipboard + paste automation
# ---------------------------------------------------------------------------

class TextInjector:
    """Copies text to the clipboard and (optionally) simulates Cmd+V."""

    def __init__(self, cfg: Config):
        self.cfg = cfg
        import pyperclip  # noqa: PLC0415
        from pynput import keyboard  # noqa: PLC0415
        self._pyperclip = pyperclip
        self._keyboard = keyboard
        self._controller = keyboard.Controller()

    def copy(self, text: str) -> None:
        self._pyperclip.copy(text)

    def inject(self, text: str) -> None:
        if not text:
            warn("Nothing transcribed (empty result).")
            return

        previous = None
        if self.cfg.restore_clipboard:
            try:
                previous = self._pyperclip.paste()
            except Exception:
                previous = None

        self._pyperclip.copy(text)

        if not self.cfg.auto_paste:
            ok("Copied to clipboard (auto-paste disabled).")
            return

        time.sleep(self.cfg.paste_delay)
        try:
            self._press_paste()
            ok("Pasted into the active app.")
        except Exception as e:
            err(f"Could not simulate Cmd+V ({e}).")
            warn("Text is on your clipboard — paste it manually with Cmd+V.")
            print(ACCESSIBILITY_HELP)

        if self.cfg.restore_clipboard and previous is not None:
            time.sleep(self.cfg.paste_delay)
            try:
                self._pyperclip.copy(previous)
            except Exception:
                pass

    def _press_paste(self) -> None:
        Key = self._keyboard.Key
        with self._controller.pressed(Key.cmd):
            self._controller.press("v")
            self._controller.release("v")


# ---------------------------------------------------------------------------
# Hotkey parsing
# ---------------------------------------------------------------------------

def parse_hotkey(spec: str):
    """Map a hotkey string (e.g. 'f8', 'f9', 'a') to a pynput key object."""
    from pynput import keyboard  # noqa: PLC0415

    spec = spec.strip().lower()
    if spec.startswith("f") and spec[1:].isdigit():
        key = getattr(keyboard.Key, spec, None)
        if key is not None:
            return key
    named = getattr(keyboard.Key, spec, None)
    if named is not None:
        return named
    if len(spec) == 1:
        return keyboard.KeyCode.from_char(spec)
    raise ValueError(f"Unsupported hotkey: '{spec}'")


# ---------------------------------------------------------------------------
# Start-at-login via a macOS LaunchAgent
# ---------------------------------------------------------------------------

LAUNCH_LABEL = "com.voicetotext.menubar"
LAUNCH_AGENTS_DIR = Path.home() / "Library" / "LaunchAgents"
LAUNCH_PLIST_PATH = LAUNCH_AGENTS_DIR / f"{LAUNCH_LABEL}.plist"


def _xml_escape(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def launch_agent_plist(python_path: str, script_path: str,
                       workdir: str, logdir: str,
                       label: str = LAUNCH_LABEL) -> str:
    """Build the LaunchAgent plist XML that runs the menu bar app at login."""
    args = "".join(
        f"\n        <string>{_xml_escape(a)}</string>"
        for a in (python_path, script_path)
    )
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{_xml_escape(label)}</string>
    <key>ProgramArguments</key>
    <array>{args}
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>{_xml_escape(workdir)}</string>
    <key>StandardOutPath</key>
    <string>{_xml_escape(logdir)}/launch.out.log</string>
    <key>StandardErrorPath</key>
    <string>{_xml_escape(logdir)}/launch.err.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
"""


def launch_agent_installed(path: Path = LAUNCH_PLIST_PATH) -> bool:
    return path.exists()


def install_launch_agent(python_path: str | None = None,
                         script_path: str | None = None) -> None:
    """Write the plist and load it so the app starts at the next login."""
    python_path = python_path or sys.executable
    script_path = script_path or str(Path(__file__).with_name("menubar.py").resolve())
    APP_DIR.mkdir(parents=True, exist_ok=True)
    LAUNCH_AGENTS_DIR.mkdir(parents=True, exist_ok=True)
    workdir = str(Path(script_path).resolve().parent)
    LAUNCH_PLIST_PATH.write_text(
        launch_agent_plist(python_path, script_path, workdir, str(APP_DIR))
    )
    # Reload so the change takes effect now (errors are non-fatal).
    subprocess.run(["launchctl", "unload", str(LAUNCH_PLIST_PATH)],
                   capture_output=True)
    subprocess.run(["launchctl", "load", "-w", str(LAUNCH_PLIST_PATH)],
                   capture_output=True)


def uninstall_launch_agent() -> None:
    subprocess.run(["launchctl", "unload", "-w", str(LAUNCH_PLIST_PATH)],
                   capture_output=True)
    LAUNCH_PLIST_PATH.unlink(missing_ok=True)
