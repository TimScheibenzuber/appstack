#!/usr/bin/env python3
"""
voicetotext (CLI) — a lightweight, local, push-to-toggle dictation tool for
Apple Silicon Macs (similar in spirit to Superwhisper).

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

For a menu bar UI with history and start-at-login, run `python menubar.py`.

Press the hotkey (default F8) to start recording, press it again to stop and
transcribe. Press Ctrl+C in this terminal to quit.
"""

from __future__ import annotations

import argparse
import platform
import sys
import threading
import time

import numpy as np

from core import (
    DEFAULT_MODEL,
    IDLE,
    PROCESSING,
    RECORDING,
    MIC_HELP,
    ACCESSIBILITY_HELP,
    AudioRecorder,
    Config,
    HistoryStore,
    TextInjector,
    Transcriber,
    err,
    info,
    ok,
    parse_hotkey,
    warn,
)


# ---------------------------------------------------------------------------
# Application orchestration / state machine
# ---------------------------------------------------------------------------

class DictationApp:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.recorder = AudioRecorder(cfg)
        self.transcriber = Transcriber(cfg)
        self.injector = TextInjector(cfg)
        self.history = HistoryStore(limit=cfg.history_limit)
        self._hotkey = parse_hotkey(cfg.hotkey)
        self._state = IDLE
        self._state_lock = threading.Lock()
        self._hotkey_down = False  # debounce key auto-repeat
        self._stop = threading.Event()

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
        self._set_state(RECORDING)
        print()
        ok(f"● Recording... press {self.cfg.hotkey.upper()} again to stop.")

    def _end_recording_and_transcribe(self) -> None:
        self._set_state(PROCESSING)
        audio = self.recorder.stop()
        dur = len(audio) / float(self.cfg.sample_rate) if audio.size else 0.0
        info(f"■ Stopped ({dur:.1f}s of audio). Transcribing...")
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
                self.history.add(text, time.time())
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
        info(f"Default input device index: {sd.default.device[0]}")
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

    # Start from persisted settings, then let CLI flags override.
    cfg = Config.load()
    cfg.model = args.model
    cfg.hotkey = args.hotkey
    cfg.device = args.device
    if args.no_paste:
        cfg.auto_paste = False
    if args.no_restore_clipboard:
        cfg.restore_clipboard = False

    try:
        app = DictationApp(cfg)
    except ImportError as e:
        err(f"A required dependency is missing: {e}")
        info("Install dependencies with:  pip install -r requirements.txt")
        return 1

    return app.run()


if __name__ == "__main__":
    raise SystemExit(main())
