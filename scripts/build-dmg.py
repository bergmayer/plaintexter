"""Package a stapled app without changing its signed contents or Finder metadata."""
import pathlib
import subprocess
import sys

import dmgbuild
from ds_store import DSStore

root = pathlib.Path(__file__).resolve().parent.parent
app, output = map(pathlib.Path, sys.argv[1:])
mount = None


def verify_copy(mount_point, settings):
    copied_app = str(pathlib.Path(mount_point) / "Plaintexter.app")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", copied_app], check=True)
    subprocess.run(["xcrun", "stapler", "validate", copied_app], check=True)


def on_event(event):
    global mount
    if event.get("type") == "command::finished" and event.get("command") == "hdiutil::attach":
        for entity in event["output"]["system-entities"]:
            if "mount-point" in entity:
                mount = pathlib.Path(entity["mount-point"])
    if event.get("type") == "operation::finished" and event.get("operation") == "dsstore::create":
        # Current Finder uses vstl for the initial view; retain dmgbuild's icvl as well.
        with DSStore.open(str(mount / ".DS_Store"), "r+") as store:
            store["."]["vstl"] = ("type", b"icnv")


dmgbuild.build_dmg(str(output), "Plaintexter", settings_file=str(root / "scripts/dmg-settings.py"),
                  defines={"app": str(app), "background": str(root / ".build/dmg-artwork/background.png")},
                  settings={"create_hook": verify_copy}, callback=on_event)
