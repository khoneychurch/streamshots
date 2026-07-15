#!/usr/bin/env python3
"""iPhone Capture Tool — screenshots and screen recordings from a USB-connected iPhone."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, font as tkfont

APP_DIR = Path(__file__).resolve().parent
HELPER_SCRIPT = APP_DIR / "ios_screen_helper.swift"
CONFIG_DIR = Path.home() / ".config" / "iphone-capture-tool"
CONFIG_PATH = CONFIG_DIR / "config.json"
DEFAULT_SAVE_FOLDER = str(Path.home() / "Pictures" / "iPhone Captures")

STATUS_IDLE = "Idle"
STATUS_COLOR_NORMAL = "#333333"
STATUS_COLOR_ERROR = "#cc0000"
STATUS_COLOR_OK = "#006600"

WEBP_QUALITY = 75
VIDEO_EXTS = {".mp4", ".mov"}
# Fallbacks for when the app is launched without Homebrew's bin dirs in PATH.
CWEBP_FALLBACKS = ("/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp")


def find_cwebp() -> str | None:
    found = shutil.which("cwebp")
    if found:
        return found
    for candidate in CWEBP_FALLBACKS:
        if Path(candidate).is_file():
            return candidate
    return None


def load_config() -> dict:
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def save_config(data: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def next_capture_filename(folder: Path, kind: str) -> str:
    """Next shared sequence: {SaveFolderName}_00001_pic.png or _00002_video.mp4."""
    prefix = folder.name or "capture"
    ext = ".png" if kind == "pic" else ".mp4"
    suffix = kind  # "pic" or "video"
    patterns = [
        re.compile(rf"^{re.escape(prefix)}_(\d{{5}})_(?:pic|video)\.(?:png|mov|mp4)$", re.I),
        re.compile(rf"^{re.escape(prefix)}_(?:pic|vid)(\d{{5}})\.(?:png|mov|mp4)$", re.I),
    ]
    max_num = 0
    if folder.is_dir():
        for path in folder.iterdir():
            if not path.is_file():
                continue
            for pattern in patterns:
                match = pattern.match(path.name)
                if match:
                    max_num = max(max_num, int(match.group(1)))
                    break
    return f"{prefix}_{max_num + 1:05d}_{suffix}{ext}"


class CaptureHelper:
    """Long-running Swift helper that exposes the USB iPhone screen mirror."""

    def __init__(self) -> None:
        self._proc: subprocess.Popen[str] | None = None
        self._lock = threading.Lock()
        self.device_name: str | None = None

    def start(self) -> tuple[str | None, str | None]:
        """Start helper; return (device_name, error_message)."""
        self.stop()
        swift = shutil.which("swift")
        if not swift:
            return None, "Swift not found — install Xcode Command Line Tools: xcode-select --install"
        if not HELPER_SCRIPT.is_file():
            return None, f"Missing helper script: {HELPER_SCRIPT}"

        try:
            self._proc = subprocess.Popen(
                [swift, str(HELPER_SCRIPT)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
        except OSError as exc:
            self._proc = None
            return None, str(exc)

        try:
            line = self._readline(timeout=15)
        except TimeoutError:
            self.stop()
            return None, "Timed out waiting for iPhone screen mirror"

        if line is None:
            err = self._drain_stderr()
            self.stop()
            return None, err or "Capture helper exited unexpectedly"

        if line.startswith("error:"):
            self.stop()
            return None, line.removeprefix("error:")

        if line.startswith("ready:"):
            self.device_name = line.removeprefix("ready:")
            return self.device_name, None

        self.stop()
        return None, line or "Unexpected helper response"

    def stop(self) -> None:
        proc = self._proc
        self._proc = None
        self.device_name = None
        if proc is None:
            return
        try:
            if proc.stdin and proc.poll() is None:
                proc.stdin.write("quit\n")
                proc.stdin.flush()
        except OSError:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()

    def screenshot(self, path: Path) -> str | None:
        return self._command(f"screenshot {path}")

    def start_recording(self, path: Path) -> str | None:
        response = self._command(f"record {path}")
        if response is None:
            return None
        if response == "recording":
            return None
        return response.removeprefix("error:") if response.startswith("error:") else response

    def stop_recording(self) -> str | None:
        response = self._command("stop")
        if response is None:
            return None
        if response == "ok":
            return None
        return response.removeprefix("error:") if response.startswith("error:") else response

    def _command(self, command: str) -> str | None:
        with self._lock:
            proc = self._proc
            if proc is None or proc.poll() is not None:
                return "Capture helper is not running — click Refresh"
            assert proc.stdin is not None
            assert proc.stdout is not None
            try:
                proc.stdin.write(command + "\n")
                proc.stdin.flush()
                line = self._readline(timeout=120, proc=proc)
            except OSError as exc:
                return str(exc)
            except TimeoutError:
                return "Command timed out"
        if line is None:
            err = self._drain_stderr()
            return err or "Capture helper exited unexpectedly"
        return line

    def _readline(self, timeout: float, proc: subprocess.Popen[str] | None = None) -> str | None:
        proc = proc or self._proc
        if proc is None or proc.stdout is None:
            return None
        result: list[str | None] = [None]

        def reader() -> None:
            try:
                result[0] = proc.stdout.readline().strip() if proc.stdout else None
            except OSError:
                result[0] = None

        thread = threading.Thread(target=reader, daemon=True)
        thread.start()
        thread.join(timeout)
        if thread.is_alive():
            raise TimeoutError
        return result[0]

    def _drain_stderr(self) -> str | None:
        proc = self._proc
        if proc is None or proc.stderr is None:
            return None
        try:
            err = proc.stderr.read().strip()
        except OSError:
            return None
        return err or None


class IPhoneCaptureApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("iPhone Capture Tool")
        self.root.resizable(False, False)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

        config = load_config()
        self.save_folder = tk.StringVar(
            value=config.get("save_folder", DEFAULT_SAVE_FOLDER)
        )

        self.helper = CaptureHelper()
        self.recording = False
        self.recording_started_at: float | None = None
        self._timer_job: str | None = None
        self._filename_lock = threading.Lock()

        self._build_ui()
        self.root.bind("<space>", self._on_space_screenshot)
        self._refresh_all()

    def _build_ui(self) -> None:
        pad = {"padx": 12, "pady": 6}
        frame = tk.Frame(self.root, padx=4, pady=4)
        frame.pack(fill=tk.BOTH, expand=True)

        folder_row = tk.Frame(frame)
        folder_row.pack(fill=tk.X, **pad)
        tk.Label(folder_row, text="Save folder:").pack(side=tk.LEFT)
        self.folder_label = tk.Label(
            folder_row,
            textvariable=self.save_folder,
            anchor=tk.W,
            width=42,
            wraplength=320,
        )
        self.folder_label.pack(side=tk.LEFT, padx=(8, 8), fill=tk.X, expand=True)
        tk.Button(folder_row, text="Choose Folder…", command=self._choose_folder).pack(
            side=tk.RIGHT
        )

        btn_row = tk.Frame(frame)
        btn_row.pack(fill=tk.X, **pad)
        self.screenshot_btn = tk.Button(
            btn_row, text="Take Screenshot", width=18, command=self._take_screenshot
        )
        self.screenshot_btn.pack(side=tk.LEFT, padx=(0, 8))
        self.record_btn = tk.Button(
            btn_row,
            text="Start Recording",
            width=18,
            bg="#2ecc71",
            activebackground="#27ae60",
            command=self._toggle_recording,
        )
        self.record_btn.pack(side=tk.LEFT)

        refresh_row = tk.Frame(frame)
        refresh_row.pack(fill=tk.X, **pad)
        self.refresh_btn = tk.Button(
            refresh_row, text="Refresh", width=10, command=self._refresh_all
        )
        self.refresh_btn.pack(side=tk.LEFT)
        self.webp_btn = tk.Button(
            refresh_row,
            text="Convert All to WebP",
            width=18,
            command=self._convert_to_webp,
        )
        self.webp_btn.pack(side=tk.RIGHT)

        status_frame = tk.Frame(frame)
        status_frame.pack(fill=tk.X, **pad)
        self.status_label = tk.Label(
            status_frame,
            text=STATUS_IDLE,
            anchor=tk.W,
            fg=STATUS_COLOR_NORMAL,
            font=tkfont.Font(size=11),
        )
        self.status_label.pack(fill=tk.X)

    def _set_status(self, text: str, *, error: bool = False, ok: bool = False) -> None:
        color = STATUS_COLOR_ERROR if error else STATUS_COLOR_OK if ok else STATUS_COLOR_NORMAL
        self.status_label.config(text=text, fg=color)

    def _choose_folder(self) -> None:
        folder = filedialog.askdirectory(
            title="Choose save folder",
            initialdir=self.save_folder.get() or DEFAULT_SAVE_FOLDER,
        )
        if folder:
            self.save_folder.set(folder)
            save_config({"save_folder": folder})

    def _ensure_save_folder(self) -> Path | None:
        folder = Path(self.save_folder.get())
        try:
            folder.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            self._set_status(f"Cannot create save folder: {exc}", error=True)
            return None
        return folder

    def _set_capture_enabled(self, enabled: bool) -> None:
        state = tk.NORMAL if enabled else tk.DISABLED
        self.screenshot_btn.config(state=state)
        if not self.recording:
            self.record_btn.config(state=state)

    def _refresh_all(self) -> None:
        if self.recording:
            return
        self.refresh_btn.config(state=tk.DISABLED)
        self._set_status("Scanning for iPhone screen mirror…")

        def work() -> None:
            name, err = self.helper.start()
            self.root.after(0, lambda: self._on_refresh_done(name, err))

        threading.Thread(target=work, daemon=True).start()

    def _on_refresh_done(self, device_name: str | None, error: str | None) -> None:
        self.refresh_btn.config(state=tk.NORMAL)
        if error:
            self._set_capture_enabled(False)
            self._set_status(error, error=True)
            return
        if device_name is None:
            self._set_capture_enabled(False)
            self._set_status(
                "No iPhone detected — connect via USB, unlock, and trust this Mac",
                error=True,
            )
            return
        self._set_capture_enabled(True)
        self._set_status(f"Ready — {device_name}")

    def _next_filename(self, folder: Path, kind: str) -> str:
        with self._filename_lock:
            return next_capture_filename(folder, kind)

    def _on_space_screenshot(self, _event: tk.Event | None = None) -> None:
        if str(self.screenshot_btn.cget("state")) == str(tk.NORMAL):
            self._take_screenshot()

    def _take_screenshot(self) -> None:
        if self.recording or self.helper.device_name is None:
            return
        if str(self.screenshot_btn.cget("state")) != str(tk.NORMAL):
            return
        folder = self._ensure_save_folder()
        if folder is None:
            return

        filename = self._next_filename(folder, "pic")
        dest = folder / filename
        self.screenshot_btn.config(state=tk.DISABLED)
        self._set_status("Capturing screenshot…")

        def work() -> None:
            err = self.helper.screenshot(dest)
            if err and err != "ok":
                self.root.after(0, lambda: self._on_screenshot_done(False, err, filename))
            else:
                self.root.after(0, lambda: self._on_screenshot_done(True, None, filename))

        threading.Thread(target=work, daemon=True).start()

    def _on_screenshot_done(
        self, success: bool, error: str | None, filename: str
    ) -> None:
        if self.helper.device_name is not None and not self.recording:
            self.screenshot_btn.config(state=tk.NORMAL)
        if success:
            self._set_status(f"Screenshot saved: {filename}", ok=True)
        else:
            self._set_status(f"Screenshot failed: {error}", error=True)

    def _toggle_recording(self) -> None:
        if self.recording:
            self._stop_recording()
        else:
            self._start_recording()

    def _start_recording(self) -> None:
        if self.recording or self.helper.device_name is None:
            return
        folder = self._ensure_save_folder()
        if folder is None:
            return

        filename = self._next_filename(folder, "video")
        dest = folder / filename
        self._recording_filename = filename
        self._recording_dest = dest
        self.record_btn.config(state=tk.DISABLED)
        self._set_status("Starting recording…")

        def work() -> None:
            err = self.helper.start_recording(dest)

            def ui_done() -> None:
                if err:
                    self._set_status(f"Failed to start recording: {err}", error=True)
                    self.record_btn.config(state=tk.NORMAL)
                    return
                self.recording = True
                self.recording_started_at = time.monotonic()
                self.record_btn.config(
                    text="Stop Recording",
                    bg="#e74c3c",
                    activebackground="#c0392b",
                    state=tk.NORMAL,
                )
                self.screenshot_btn.config(state=tk.DISABLED)
                self._update_recording_status()

            self.root.after(0, ui_done)

        threading.Thread(target=work, daemon=True).start()

    def _update_recording_status(self) -> None:
        if not self.recording or self.recording_started_at is None:
            return
        elapsed = int(time.monotonic() - self.recording_started_at)
        mins, secs = divmod(elapsed, 60)
        self._set_status(f"Recording… {mins:02d}:{secs:02d}")
        self._timer_job = self.root.after(1000, self._update_recording_status)

    def _cancel_recording_timer(self) -> None:
        if self._timer_job is not None:
            self.root.after_cancel(self._timer_job)
            self._timer_job = None

    def _stop_recording(self) -> None:
        if not self.recording:
            return
        self._cancel_recording_timer()
        filename = getattr(self, "_recording_filename", "recording.mp4")
        self._set_status("Saving and compressing video…")
        self.record_btn.config(state=tk.DISABLED)

        def work() -> None:
            err = self.helper.stop_recording()
            self.recording = False
            self.recording_started_at = None

            def ui_done() -> None:
                self.record_btn.config(
                    text="Start Recording",
                    bg="#2ecc71",
                    activebackground="#27ae60",
                )
                if self.helper.device_name is not None:
                    self._set_capture_enabled(True)
                if err:
                    self._set_status(f"Recording error: {err}", error=True)
                else:
                    self._set_status(f"Recording saved: {filename}", ok=True)

            self.root.after(0, ui_done)

        threading.Thread(target=work, daemon=True).start()

    def _convert_to_webp(self) -> None:
        folder = Path(self.save_folder.get())
        if not folder.is_dir():
            self._set_status("Save folder does not exist yet — capture something first", error=True)
            return
        cwebp = find_cwebp()
        if cwebp is None:
            self._set_status("cwebp not found — install with: brew install webp", error=True)
            return

        pngs = sorted(
            p for p in folder.iterdir() if p.is_file() and p.suffix.lower() == ".png"
        )
        videos = sorted(
            p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in VIDEO_EXTS
        )
        if not pngs and not videos:
            self._set_status("No PNG or video files found in save folder", error=True)
            return

        dest_dir = folder.parent / f"{folder.name}_webp"
        try:
            dest_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            self._set_status(f"Cannot create output folder: {exc}", error=True)
            return

        self.webp_btn.config(state=tk.DISABLED)
        self._set_status("Converting to WebP…")

        def work() -> None:
            converted = copied = skipped = 0
            errors: list[str] = []
            total = len(pngs)

            for index, png in enumerate(pngs, start=1):
                dest = dest_dir / f"{png.stem}.webp"
                if dest.exists():
                    skipped += 1
                    continue
                self.root.after(
                    0,
                    lambda i=index: self._set_status(f"Converting {i}/{total} to WebP…"),
                )
                result = subprocess.run(
                    [cwebp, "-quiet", "-q", str(WEBP_QUALITY), str(png), "-o", str(dest)],
                    capture_output=True,
                    text=True,
                )
                if result.returncode == 0:
                    converted += 1
                else:
                    errors.append(png.name)
                    dest.unlink(missing_ok=True)

            for video in videos:
                dest = dest_dir / video.name
                if dest.exists():
                    skipped += 1
                    continue
                try:
                    shutil.copy2(video, dest)
                    copied += 1
                except OSError:
                    errors.append(video.name)

            def ui_done() -> None:
                self.webp_btn.config(state=tk.NORMAL)
                if errors:
                    self._set_status(
                        f"WebP finished with errors — failed: {', '.join(errors[:3])}"
                        + ("…" if len(errors) > 3 else ""),
                        error=True,
                    )
                else:
                    parts = [f"{converted} converted", f"{copied} videos copied"]
                    if skipped:
                        parts.append(f"{skipped} skipped")
                    self._set_status(
                        f"WebP done ({', '.join(parts)}) → {dest_dir.name}", ok=True
                    )

            self.root.after(0, ui_done)

        threading.Thread(target=work, daemon=True).start()

    def _on_close(self) -> None:
        self._cancel_recording_timer()
        if self.recording:
            try:
                self.helper.stop_recording()
            except OSError:
                pass
            self.recording = False
        self.helper.stop()
        self.root.destroy()


def main() -> None:
    root = tk.Tk()
    IPhoneCaptureApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
