#!/usr/bin/env python3
"""
voicetotext — a lightweight, local, push-to-toggle dictation tool for Apple
Silicon Macs (similar in spirit to Superwhisper).

Pipeline:
    [F8] -> record mic (16 kHz mono, in-memory) -> [F8] -> transcribe with
    NVIDIA Parakeet via MLX -> copy to clipboard -> simulate Cmd+V into the
    frontmost app.

Everything runs locally on-device. The speech model (parakeet-mlx + mlx) is
Apple-Silicon only; the rest of the stack is cross-platform.

Usage:
    python main.py                       # start the background listener
    python main.py --list-devices        # show input devices and exit
    python main.py --hotkey f9           # use a different toggle key
    python main.py --model mlx-community/parakeet-tdt-0.6b-v3

Press the hotkey (default F8) to start recording, press it again to stop and
transcribe. Press Ctrl+C in this terminal to quit.
"""

from __future__ import annotations

import argparse
import platform
import sys
import tempfile
import threading
import time
import wave
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
SAMPLE_RATE = 16_000  # Parakeet expects 16 kHz mono
CHANNELS = 1


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


# ---------------------------------------------------------------------------
# Small console helpers
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
        # Import here so the module imports cleanly even if PortAudio is missing
        import sounddevice as sd  # noqa: PLC0415
        self._sd = sd

    def _callback(self, indata, frames, time_info, status):  # PortAudio thread
        if status:
            # Input overflow/underflow etc. — count but keep going.
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
                blocksize=0,  # let PortAudio pick an optimal block size
            )
            self._stream.start()
        except self._sd.PortAudioError as e:
            # Most commonly a denied microphone permission on macOS.
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
        # Collapse to mono if a multi-channel device sneaks in.
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
        except Exception as e:  # network / model-id / disk errors
            raise RuntimeError(
                f"Failed to load model '{self.cfg.model}': {e}"
            ) from e
        ok(f"Model ready in {time.time() - t0:.1f}s")

    @property
    def sample_rate(self) -> int:
        """The model's expected sample rate, falling back to the config value."""
        try:
            return int(self._model.preprocessor_config.sample_rate)
        except Exception:
            return self.cfg.sample_rate

    def transcribe(self, audio: np.ndarray) -> str:
        if self._model is None:
            raise RuntimeError("Model is not loaded.")
        if audio.size == 0:
            return ""

        # Primary path: feed the in-memory buffer straight to the model via the
        # log-mel front-end — no disk writes.
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
        # generate() may return a single result or a list (one per batch item).
        if isinstance(result, (list, tuple)):
            result = result[0]
        return (result.text or "").strip()

    def _transcribe_via_tempfile(self, audio: np.ndarray) -> str:
        """Fallback: write a small temp WAV and use the high-level API."""
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
            # Give the target app a moment to read the clipboard before restore.
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
# Application orchestration / state machine
# ---------------------------------------------------------------------------

IDLE, RECORDING, PROCESSING = "idle", "recording", "processing"


class DictationApp:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.recorder = AudioRecorder(cfg)
        self.transcriber = Transcriber(cfg)
        self.injector = TextInjector(cfg)
        self._hotkey = parse_hotkey(cfg.hotkey)
        self._state = IDLE
        self._state_lock = threading.Lock()
        self._hotkey_down = False  # debounce key auto-repeat
        self._record_started = 0.0
        self._stop = threading.Event()

    # --- state helpers -----------------------------------------------------
    def _set_state(self, state: str) -> None:
        with self._state_lock:
            self._state = state

    # --- hotkey callbacks --------------------------------------------------
    def _on_press(self, key) -> None:
        if key != self._hotkey or self._hotkey_down:
            return
        self._hotkey_down = True
        try:
            self._toggle()
        except Exception as e:  # never let the listener thread die
            err(f"Unexpected error handling hotkey: {e}")

    def _on_release(self, key) -> None:
        if key == self._hotkey:
            self._hotkey_down = False

    def _toggle(self) -> None:
        with self._state_lock:
            state = self._state

        if state == IDLE:
            self._begin_recording()
        elif state == RECORDING:
            self._end_recording_and_transcribe()
        else:  # PROCESSING
            warn("Still transcribing the previous clip — please wait.")

    # --- actions -----------------------------------------------------------
    def _begin_recording(self) -> None:
        try:
            self.recorder.start()
        except PermissionError:
            err("Microphone access was denied.")
            print(MIC_HELP)
            return
        except Exception as e:
            err(f"Could not start recording: {e}")
            return
        self._record_started = time.time()
        self._set_state(RECORDING)
        print()
        ok(f"● Recording... press {self.cfg.hotkey.upper()} again to stop.")

    def _end_recording_and_transcribe(self) -> None:
        self._set_state(PROCESSING)
        audio = self.recorder.stop()
        dur = len(audio) / float(self.cfg.sample_rate) if audio.size else 0.0
        info(f"■ Stopped ({dur:.1f}s of audio). Transcribing...")
        # Do the heavy lifting off the listener thread so the hotkey stays live.
        threading.Thread(target=self._process, args=(audio,), daemon=True).start()

    def _process(self, audio: np.ndarray) -> None:
        try:
            if audio.size == 0:
                warn("No audio captured.")
                return
            t0 = time.time()
            text = self.transcriber.transcribe(audio)
            took = time.time() - t0
            if text:
                ok(f"Transcribed in {took:.1f}s: “{text}”")
                self.injector.inject(text)
            else:
                warn("Transcription was empty.")
        except Exception as e:
            err(f"Transcription failed: {e}")
        finally:
            self._set_state(IDLE)
            info(f"Ready. Press {self.cfg.hotkey.upper()} to dictate.")

    # --- run loop ----------------------------------------------------------
    def run(self) -> int:
        # Load the model up-front so the first dictation isn't slow.
        try:
            self.transcriber.load()
        except RuntimeError as e:
            err(str(e))
            return 1

        from pynput import keyboard  # noqa: PLC0415

        print_banner(self.cfg)
        listener = keyboard.Listener(
            on_press=self._on_press, on_release=self._on_release
        )
        listener.start()
        # Give pynput a beat to attach; on macOS this surfaces permission issues.
        time.sleep(0.3)
        if not listener.running:
            err("Global hotkey listener failed to start.")
            print(ACCESSIBILITY_HELP)
            return 1

        ok(f"Listening. Press {self.cfg.hotkey.upper()} to start/stop dictation.")
        info("Press Ctrl+C here to quit.\n")
        try:
            while not self._stop.is_set():
                time.sleep(0.2)
        except KeyboardInterrupt:
            print()
            info("Shutting down...")
        finally:
            listener.stop()
            if self._state == RECORDING:
                self.recorder.stop()
        return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def print_banner(cfg: Config) -> None:
    print()
    print("  ┌──────────────────────────────────────────────┐")
    print("  │   voicetotext · local dictation (Parakeet)     │")
    print("  └──────────────────────────────────────────────┘")
    info(f"Hotkey       : {cfg.hotkey.upper()}")
    info(f"Model        : {cfg.model}")
    info(f"Audio        : {cfg.sample_rate} Hz mono, in-memory")
    info(f"Auto-paste   : {'on' if cfg.auto_paste else 'off'}")
    print()


def check_platform() -> None:
    if platform.system() != "Darwin":
        warn(f"Detected {platform.system()} — this tool targets macOS.")
        warn("The Parakeet/MLX model only runs on Apple Silicon; the rest of")
        warn("the pipeline (audio, clipboard, hotkey) will still import.")
    elif platform.machine() != "arm64":
        warn("Detected Intel Mac — MLX requires Apple Silicon (M-series).")


def list_devices() -> int:
    try:
        import sounddevice as sd
    except Exception as e:
        err(f"Could not import sounddevice: {e}")
        return 1
    print(sd.query_devices())
    try:
        default_in = sd.default.device[0]
        info(f"Default input device index: {default_in}")
    except Exception:
        pass
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="voicetotext",
        description="Local push-to-toggle dictation for Apple Silicon (Parakeet/MLX).",
    )
    p.add_argument("--model", default=DEFAULT_MODEL, help="HF model id for parakeet-mlx")
    p.add_argument("--hotkey", default="f8", help="Toggle key, e.g. f8, f9, or a single char")
    p.add_argument("--device", type=int, default=None, help="Input device index (see --list-devices)")
    p.add_argument("--list-devices", action="store_true", help="List audio input devices and exit")
    p.add_argument("--no-paste", action="store_true", help="Copy to clipboard but do not auto-paste")
    p.add_argument("--no-restore-clipboard", action="store_true", help="Leave transcription on the clipboard")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])

    if args.list_devices:
        return list_devices()

    check_platform()

    cfg = Config(
        model=args.model,
        hotkey=args.hotkey,
        device=args.device,
        auto_paste=not args.no_paste,
        restore_clipboard=not args.no_restore_clipboard,
    )

    try:
        app = DictationApp(cfg)
    except ImportError as e:
        err(f"A required dependency is missing: {e}")
        info("Install dependencies with:  pip install -r requirements.txt")
        return 1

    return app.run()


if __name__ == "__main__":
    raise SystemExit(main())
