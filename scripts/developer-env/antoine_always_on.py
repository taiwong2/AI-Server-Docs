"""Action of the \\AI-AntoineEnv scheduled task (runs as poopl, at startup).

Tai lifted Antoine's time limits on 2026-09-29: his environment (pp-antoine)
runs all the time instead of only during booked sessions, and holds the box
awake while it does. The security wall is unchanged: pp-boot.sh's firewall,
no root, interop and automount off.

Every 30 s it makes sure the environment is up (sshd running). If the distro
was terminated -- by `wsl --shutdown`, a crash, or the end of an old-style
booked session -- it re-applies pp-boot.sh, rewrites ~/.gpu-env (both GPUs,
no reservation), restarts the keepalive and runs ~/autorun.sh once.

It listens on 127.0.0.1:HOLD_PORT, which is in jobqueue.json busy_ports, so
the sleep gate keeps the box awake.

Kill switch: create state\\ai-admin\\antoine-always-on.disabled. The hold
port closes (the box may sleep again) and the env is no longer restarted; it
is not terminated -- `wsl --terminate pp-antoine` does that.
"""
import datetime
import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import config  # noqa: E402

DISTRO, USER = "pp-antoine", "antoine"
HOLD_PORT = 8897
DISABLED = os.path.join(config.ROOT, "state", "ai-admin", "antoine-always-on.disabled")
LOG = os.path.join(config.ROOT, "logs", "antoine-always-on.log")
NOWIN = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def log(msg):
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} {msg}\n")
    except OSError:
        pass


def wsl(user, *cmd, timeout=120):
    return subprocess.run([config.WSL, "-d", DISTRO, "-u", user, "--", *cmd],
                          capture_output=True, text=True, errors="replace",
                          timeout=timeout, creationflags=NOWIN)


def env_up():
    try:
        return wsl("root", "pgrep", "-x", "sshd", timeout=60).returncode == 0
    except subprocess.TimeoutExpired:
        return False


def write_gpu_env():
    wsl("root", "sh", "-c",
        f"printf '# no GPU reservation needed: both 3090s visible\\nunset CUDA_VISIBLE_DEVICES\\n'"
        f" > /home/{USER}/.gpu-env && chown {USER}:{USER} /home/{USER}/.gpu-env")


def bring_up():
    """Start the keepalive; if the env was down, also boot it and run autorun."""
    if env_up():   # already running (e.g. inside a booked session): just adopt it
        write_gpu_env()
        log(f"env {DISTRO} already up; keepalive only")
        return subprocess.Popen([config.WSL, "-d", DISTRO, "-u", "root", "--", "sleep", "infinity"],
                                creationflags=NOWIN)
    boot = wsl("root", "/usr/local/sbin/pp-boot.sh")
    write_gpu_env()
    keep = subprocess.Popen([config.WSL, "-d", DISTRO, "-u", "root", "--", "sleep", "infinity"],
                            creationflags=NOWIN)
    subprocess.Popen([config.WSL, "-d", DISTRO, "-u", USER, "--", "bash", "-lc",
                      'if [ -x ~/autorun.sh ]; then echo "== always-on start $(date)" >> ~/autorun.log; '
                      '~/autorun.sh >> ~/autorun.log 2>&1; fi'], creationflags=NOWIN)
    log(f"env {DISTRO} up (boot rc={boot.returncode})")
    return keep


def main():
    log("keeper START")
    hold = None
    keep = None
    while True:
        if os.path.exists(DISABLED):
            if hold:
                hold.close()
                hold = None
                log("disabled: hold released, env no longer restarted")
        else:
            if not hold:
                try:
                    hold = socket.create_server(("127.0.0.1", HOLD_PORT))
                    log(f"hold START on {HOLD_PORT}")
                except OSError as e:
                    log(f"hold FAILED on {HOLD_PORT}: {e}")
            if keep is None or keep.poll() is not None or not env_up():
                if keep and keep.poll() is None:
                    keep.kill()
                try:
                    keep = bring_up()
                except Exception as e:  # keep trying; never exit
                    log(f"bring_up FAILED: {e}")
        time.sleep(30)


if __name__ == "__main__":
    main()
