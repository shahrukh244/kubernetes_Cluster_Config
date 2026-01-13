#!/usr/bin/env python3

import curses
import time
from datetime import datetime
import sys

PROC_FILE = "/proc/drbd"
REFRESH_INTERVAL = 1
MAX_HISTORY = 12
last_screen_data = None


def read_drbd():
    try:
        with open(PROC_FILE, "r") as f:
            return f.read().rstrip().splitlines()
    except Exception as e:
        return [f"ERROR: {str(e)}", f"Is DRBD loaded? Check {PROC_FILE} exists"]


def detect_state(lines):
    text = " ".join(lines)

    if "cs:WFConnection" in text:
        return "WAITING_SECONDARY", "🕒 Waiting for Secondary Node Disk"

    if "cs:SyncSource" in text:
        for line in lines:
            if "resync:" in line:
                parts = line.split()
                for part in parts:
                    if "resync:" in part:
                        return "SYNCING", f"🔄 Syncing disks: {part.split(':')[1]}"
        return "SYNCING", "🔄 Secondary node disk online, waiting for sync to complete"

    if "cs:Connected" in text and "ds:UpToDate/UpToDate" in text and "oos:0" in text:
        return "DONE", "✅ DRBD SYNC COMPLETE - Resources fully synchronized"

    return "UNKNOWN", f"❓ Unknown DRBD state"


def render_final_screen(data):
    """Print last screen content as plain text after curses exit"""
    if not data:
        return
    
    print("\n" + "="*80)
    print("FINAL DRBD STATUS (captured at exit):")
    print("="*80)
    print(f"Timestamp: {data['time']}")
    print("\nCURRENT DRBD STATUS (/proc/drbd):")
    for line in data['drbd_lines'][:8]:
        print(line)
    print("\nLATEST STATUS MESSAGE:")
    print(data['message'])
    print("\nSTATE CHANGE HISTORY:")
    print("-"*80)
    for t, msg in data['history'][-MAX_HISTORY:]:
        print(f"[{t}] {msg}")
    print("="*80)


def main(stdscr):
    global last_screen_data
    
    curses.curs_set(0)
    stdscr.nodelay(True)
    history = []
    last_message = None

    while True:
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        lines = read_drbd()
        state, message = detect_state(lines)

        # Update history FIRST (critical for final state capture)
        if message != last_message:
            history.append((now, message))
            history = history[-MAX_HISTORY:]
            last_message = message

        # Save current state for final output (AFTER history update)
        last_screen_data = {
            'time': now,
            'drbd_lines': lines,
            'message': message,
            'history': history.copy()  # Preserve current history state
        }

        # Clear and redraw screen
        stdscr.erase()
        height, width = stdscr.getmaxyx()

        # Header
        stdscr.addstr(0, 0, "DRBD LIVE STATUS MONITOR (Auto-exits when synced)".ljust(width-1), 
                     curses.A_BOLD | curses.A_UNDERLINE)
        stdscr.addstr(1, 0, f"Last update: {now}".ljust(width-1))

        # DRBD status
        stdscr.addstr(3, 0, "CURRENT DRBD STATUS (/proc/drbd):", curses.A_BOLD)
        for i, line in enumerate(lines[:min(8, height-15)]):
            if i+4 < height-1:
                stdscr.addstr(4+i, 0, line[:width-1])

        # Status message
        msg_line = 4 + min(8, height-15) + 1
        if msg_line+1 < height:
            stdscr.addstr(msg_line, 0, "LATEST STATUS MESSAGE:", curses.A_BOLD)
            stdscr.addstr(msg_line+1, 0, message[:width-1])

        # History
        hist_start = msg_line + 3
        if hist_start < height-3:
            stdscr.addstr(hist_start, 0, "─" * (width-1))
            stdscr.addstr(hist_start+1, 0, "STATE CHANGE HISTORY:", curses.A_BOLD)
            
            visible_history = min(MAX_HISTORY, height - hist_start - 5)
            for i, (t, msg) in enumerate(history[-visible_history:]):
                if hist_start+2+i < height-1:
                    stdscr.addstr(hist_start+2+i, 0, f"[{t}] {msg}"[:width-1])

        stdscr.refresh()

        # Exit immediately when sync complete
        if state == "DONE":
            time.sleep(0.3)  # Ensure final render
            return

        time.sleep(REFRESH_INTERVAL)


if __name__ == "__main__":
    stdscr = None
    try:
        # Initialize curses
        stdscr = curses.initscr()
        curses.noecho()
        curses.cbreak()
        if stdscr:
            stdscr.keypad(True)
        
        # Run main monitoring loop
        main(stdscr)
        
    except KeyboardInterrupt:
        pass
    finally:
        # Clean up curses
        if stdscr:
            try:
                curses.nocbreak()
                stdscr.keypad(False)
                curses.echo()
            except:
                pass
        try:
            curses.endwin()
        except:
            pass
        
        # Print final status to terminal
        if last_screen_data:
            render_final_screen(last_screen_data)
        sys.exit(0)
