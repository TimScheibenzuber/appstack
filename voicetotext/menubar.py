#!/usr/bin/env python3
"""
voicetotext (menu bar) — a local dictation tool that lives in the macOS menu
bar, with options and a transcription history.

Run directly:
    python menubar.py

Features:
  • Menu bar icon that reflects state (idle / recording / transcribing).
  • Global hotkey (default F8) and a "Start/Stop Dictation" menu item.
  • Options submenu: auto-paste, restore-clipboard, and hotkey choice.
  • History submenu: recent transcriptions — click one to re-copy it.
  • "Start at Login" toggle (installs a macOS LaunchAgent).

The heavy speech model loads on a background thread at launch, and each
transcription runs on a worker thread, so the menu stays responsive. All UI
mutations are funneled back onto the main thread via a queue drained by a
rumps Timer (Cocoa menus are not thread-safe).
"""

from __future__ import annotations

import queue
import threading
import time

import rumps

from core import (
    IDLE,
    PROCESSING,
    RECORDING,
    AudioRecorder,
    Config,
    HistoryStore,
    TextInjector,
    Transcriber,
    err,
    info,
    install_launch_agent,
    launch_agent_installed,
    parse_hotkey,
    uninstall_launch_agent,
    warn,
)

# Menu bar status glyphs.
ICON_IDLE = "🎙️"
ICON_RECORDING = "🔴"
ICON_PROCESSING = "⏳"
ICON_LOADING = "⌛"

HOTKEY_CHOICES = ["f7", "f8", "f9", "f10"]
HISTORY_MENU_LIMIT = 12  # how many items to show in the menu (store keeps more)


def _fmt_history_title(item: dict) -> str:
    """One-line label for a history entry: 'HH:MM  the spoken text…'."""
    ts = item.get("ts", 0)
    try:
        clock = time.strftime("%H:%M", time.localtime(ts))
    except Exception:
        clock = "--:--"
    text = " ".join((item.get("text") or "").split())
    if len(text) > 48:
        text = text[:47] + "…"
    return f"{clock}  {text}"


class VoiceToTextApp(rumps.App):
    def __init__(self):
        super().__init__("voicetotext", title=ICON_LOADING, quit_button=None)

        self.cfg = Config.load()
        self.history = HistoryStore(limit=self.cfg.history_limit)

        # Engine pieces (constructed lazily so missing deps surface clearly).
        self.recorder: AudioRecorder | None = None
        self.injector: TextInjector | None = None
        self.transcriber = Transcriber(self.cfg)

        self._state = IDLE
        self._state_lock = threading.Lock()
        self._hotkey_down = False
        self._model_ready = False
        self._ui_queue: "queue.Queue" = queue.Queue()
        self._listener = None

        self._build_menu()

        # Drain cross-thread UI updates on the main thread.
        self._timer = rumps.Timer(self._drain_ui, 0.15)
        self._timer.start()

        # Load the model and start the hotkey listener off the main thread.
        threading.Thread(target=self._startup, daemon=True).start()

    # ------------------------------------------------------------------ menu
    def _build_menu(self) -> None:
        self.toggle_item = rumps.MenuItem("Start Dictation", callback=self._on_toggle_click)
        self.status_item = rumps.MenuItem("Loading model…", callback=None)

        self.history_menu = rumps.MenuItem("History")
        self.options_menu = rumps.MenuItem("Options")

        # Options: auto-paste / restore-clipboard toggles.
        self.autopaste_item = rumps.MenuItem("Auto-paste (Cmd+V)", callback=self._toggle_autopaste)
        self.autopaste_item.state = int(self.cfg.auto_paste)
        self.restore_item = rumps.MenuItem("Restore clipboard after paste", callback=self._toggle_restore)
        self.restore_item.state = int(self.cfg.restore_clipboard)

        # Options: hotkey chooser submenu.
        self.hotkey_menu = rumps.MenuItem("Hotkey")
        for hk in HOTKEY_CHOICES:
            mi = rumps.MenuItem(hk.upper(), callback=self._make_hotkey_setter(hk))
            mi.state = int(hk == self.cfg.hotkey)
            self.hotkey_menu.add(mi)

        self.options_menu.add(self.autopaste_item)
        self.options_menu.add(self.restore_item)
        self.options_menu.add(self.hotkey_menu)

        self.login_item = rumps.MenuItem("Start at Login", callback=self._toggle_login)
        self.login_item.state = int(launch_agent_installed())

        self.menu = [
            self.toggle_item,
            self.status_item,
            None,
            self.history_menu,
            None,
            self.options_menu,
            self.login_item,
            None,
            rumps.MenuItem("Quit voicetotext", callback=self._on_quit),
        ]
        self._refresh_history_menu()

    def _refresh_history_menu(self) -> None:
        """Rebuild the History submenu from the store (main thread only)."""
        for key in list(self.history_menu.keys()):
            del self.history_menu[key]
        if not self.history.items:
            empty = rumps.MenuItem("(no transcriptions yet)", callback=None)
            self.history_menu.add(empty)
            return
        for idx, item in enumerate(self.history.items[:HISTORY_MENU_LIMIT]):
            mi = rumps.MenuItem(_fmt_history_title(item),
                                callback=self._make_history_copier(idx))
            self.history_menu.add(mi)
        self.history_menu.add(None)
        self.history_menu.add(rumps.MenuItem("Clear History", callback=self._clear_history))

    # -------------------------------------------------------- UI thread pump
    def _drain_ui(self, _timer) -> None:
        try:
            while True:
                fn = self._ui_queue.get_nowait()
                try:
                    fn()
                except Exception as e:
                    warn(f"UI update error: {e}")
        except queue.Empty:
            pass

    def _ui(self, fn) -> None:
        """Schedule a callable to run on the main thread."""
        self._ui_queue.put(fn)

    def _set_icon(self, glyph: str) -> None:
        self._ui(lambda: setattr(self, "title", glyph))

    def _set_status(self, text: str) -> None:
        self._ui(lambda: setattr(self.status_item, "title", text))

    def _set_toggle_label(self, text: str) -> None:
        self._ui(lambda: setattr(self.toggle_item, "title", text))

    # --------------------------------------------------------------- startup
    def _startup(self) -> None:
        # 1) Build clipboard/keyboard injector (needs pynput + pyperclip).
        try:
            self.injector = TextInjector(self.cfg)
        except Exception as e:
            self._set_status(f"Injector unavailable: {e}")
        # 2) Audio recorder (needs PortAudio/sounddevice).
        try:
            self.recorder = AudioRecorder(self.cfg)
        except Exception as e:
            self._set_status(f"Audio unavailable: {e}")

        # 3) Start the global hotkey listener.
        try:
            from pynput import keyboard  # noqa: PLC0415
            self._hotkey = parse_hotkey(self.cfg.hotkey)
            self._listener = keyboard.Listener(
                on_press=self._on_press, on_release=self._on_release)
            self._listener.start()
        except Exception as e:
            self._set_status(f"Hotkey listener failed: {e}")

        # 4) Load the speech model (slow; first run downloads weights).
        self._set_status("Loading model…")
        try:
            self.transcriber.load()
            self._model_ready = True
            self._set_icon(ICON_IDLE)
            self._set_status(f"Ready · {self.cfg.hotkey.upper()} to dictate")
        except Exception as e:
            self._set_icon("⚠️")
            self._set_status(f"Model failed: {e}")
            err(str(e))

    # ------------------------------------------------------------ hotkey I/O
    def _on_press(self, key) -> None:
        if key != self._hotkey or self._hotkey_down:
            return
        self._hotkey_down = True
        try:
            self._toggle()
        except Exception as e:
            err(f"Hotkey error: {e}")

    def _on_release(self, key) -> None:
        if key == self._hotkey:
            self._hotkey_down = False

    def _on_toggle_click(self, _sender) -> None:
        self._toggle()

    # ---------------------------------------------------------- state engine
    def _set_state(self, state: str) -> None:
        with self._state_lock:
            self._state = state

    def _toggle(self) -> None:
        if not self._model_ready or self.recorder is None:
            self._set_status("Model still loading — please wait…")
            return
        with self._state_lock:
            state = self._state
        if state == IDLE:
            self._begin_recording()
        elif state == RECORDING:
            self._end_recording()
        # PROCESSING: ignore until done.

    def _begin_recording(self) -> None:
        try:
            self.recorder.start()
        except PermissionError:
            self._set_status("Microphone denied — see Privacy settings")
            return
        except Exception as e:
            self._set_status(f"Record error: {e}")
            return
        self._set_state(RECORDING)
        self._set_icon(ICON_RECORDING)
        self._set_status("● Recording… press hotkey to stop")
        self._set_toggle_label("Stop Dictation")

    def _end_recording(self) -> None:
        self._set_state(PROCESSING)
        self._set_icon(ICON_PROCESSING)
        self._set_status("Transcribing…")
        self._set_toggle_label("Start Dictation")
        audio = self.recorder.stop()
        threading.Thread(target=self._process, args=(audio,), daemon=True).start()

    def _process(self, audio) -> None:
        try:
            if audio is None or audio.size == 0:
                self._set_status("No audio captured")
                return
            t0 = time.time()
            text = self.transcriber.transcribe(audio)
            took = time.time() - t0
            if not text:
                self._set_status("Transcription was empty")
                return
            self.history.add(text, time.time())
            self._ui(self._refresh_history_menu)
            self._set_status(f"Done in {took:.1f}s · {len(text)} chars")
            if self.injector is not None:
                self.injector.inject(text)
        except Exception as e:
            self._set_status(f"Error: {e}")
            err(f"Transcription failed: {e}")
        finally:
            self._set_state(IDLE)
            self._set_icon(ICON_IDLE)

    # ---------------------------------------------------------- menu actions
    def _toggle_autopaste(self, sender) -> None:
        self.cfg.auto_paste = not self.cfg.auto_paste
        sender.state = int(self.cfg.auto_paste)
        self.cfg.save()

    def _toggle_restore(self, sender) -> None:
        self.cfg.restore_clipboard = not self.cfg.restore_clipboard
        sender.state = int(self.cfg.restore_clipboard)
        self.cfg.save()

    def _make_hotkey_setter(self, hk: str):
        def setter(_sender) -> None:
            self.cfg.hotkey = hk
            self.cfg.save()
            # Reflect the radio-style selection.
            for key in self.hotkey_menu.keys():
                self.hotkey_menu[key].state = int(key == hk.upper())
            # Re-bind the live listener.
            try:
                self._hotkey = parse_hotkey(hk)
                self._set_status(f"Hotkey set to {hk.upper()}")
            except Exception as e:
                self._set_status(f"Bad hotkey: {e}")
        return setter

    def _make_history_copier(self, idx: int):
        def copier(_sender) -> None:
            try:
                text = self.history.items[idx]["text"]
            except (IndexError, KeyError):
                return
            if self.injector is not None:
                self.injector.copy(text)
                self._set_status("Copied from history")
            else:
                rumps.notification("voicetotext", "History", text)
        return copier

    def _clear_history(self, _sender) -> None:
        self.history.clear()
        self._refresh_history_menu()
        self._set_status("History cleared")

    def _toggle_login(self, sender) -> None:
        try:
            if launch_agent_installed():
                uninstall_launch_agent()
                sender.state = 0
                self._set_status("Start at Login disabled")
            else:
                install_launch_agent()
                sender.state = 1
                self._set_status("Start at Login enabled")
        except Exception as e:
            self._set_status(f"Login toggle failed: {e}")

    def _on_quit(self, _sender) -> None:
        try:
            if self._listener is not None:
                self._listener.stop()
            if self.recorder is not None and self._state == RECORDING:
                self.recorder.stop()
        finally:
            rumps.quit_application()


def main() -> int:
    try:
        VoiceToTextApp().run()
    except ImportError as e:
        err(f"A required dependency is missing: {e}")
        info("Install with:  pip install -r requirements.txt  (on Apple Silicon)")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
