"""Find the newest stable Xcode installed locally or listed on a GitHub runner."""
import os
from pathlib import Path
import plistlib
import re
import sys


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def latest_installed(candidates):
    best_version = ()
    best_dir = None
    for path in candidates:
        if not path:
            continue
        path = Path(path)
        developer = path / "Contents/Developer" if path.suffix == ".app" else path
        developer = developer.resolve()
        if not os.access(developer / "usr/bin/xcodebuild", os.X_OK):
            continue
        contents = developer.parent
        if re.search(r"beta|preview|candidate|rc[\d ._-]*$|gm[ ._-]*seed", contents.parent.stem, re.I):
            continue
        try:
            info = plistlib.loads((contents / "Info.plist").read_bytes())
            license_info = plistlib.loads((contents / "Resources/LicenseInfo.plist").read_bytes())
        except (OSError, plistlib.InvalidFileException):
            continue
        version = info.get("CFBundleShortVersionString", "")
        if info.get("CFBundleIdentifier") != "com.apple.dt.Xcode" or license_info.get("licenseType") != "GM":
            continue
        if not re.fullmatch(r"\d+(?:\.\d+)*", version):
            continue
        key = version_key(version)
        if key > best_version:
            best_version, best_dir = key, developer
    if best_dir is None:
        raise ValueError("没有找到 Xcode 正式版。请将 Xcode 安装到 Applications，或用 DEVELOPER_DIR 指定其位置。")
    return best_dir


def latest_runner(catalog):
    index = (catalog / "README.md").read_text()
    # Only standard, published Arm64 labels can be used by these packaging jobs.
    label_cells = re.findall(r"^\|[^|\n]+\|\s*arm64\s*\|([^|\n]+)\|", index, re.M | re.I)
    labels = re.findall(r"`((?:xcode|macos)-\d+)`", " ".join(label_cells))
    choices = []
    for label in labels:
        inventory = (catalog / "images/macos" / f"{label}-arm64-Readme.md").read_text()
        versions = re.findall(
            r"^\|\s*(\d+(?:\.\d+)*)(?:\s+\(default\))?\s*\|[^|\n]+\|"
            r"\s*/Applications/Xcode(?:_[\d.]+)?\.app\s*\|", inventory, re.M)
        if versions:
            version = max(map(version_key, versions))
            # Prefer the matching Xcode image when several images carry the same release.
            choices.append((version, label == f"xcode-{version[0]}", label))
    if not choices:
        raise ValueError("GitHub runner 镜像清单中没有可用的 Xcode 正式版。")
    return max(choices)[2]


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["installed"]:
            print(latest_installed(sys.argv[2:]))
        elif len(sys.argv) == 3 and sys.argv[1] == "runner":
            print(latest_runner(Path(sys.argv[2])))
        else:
            sys.exit("Usage: apple_xcode.py installed [PATH ...] | runner RUNNER_IMAGES_DIR")
    except (OSError, ValueError) as error:
        sys.exit(str(error))
