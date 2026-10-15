"""Hysteria2 manager: user / node management with traffic accounting."""
import os
import subprocess

__version__ = "0.1.0"
REPO_URL = "https://github.com/Jackchen0514/hysteria-manager"


def commit():
    """Installed commit: VERSION file written by install.sh / update.sh, else the git checkout."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        with open(os.path.join(root, "VERSION")) as f:
            return f.read().strip()
    except OSError:
        pass
    try:
        return subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=5).stdout.decode().strip()
    except Exception:
        return ""
