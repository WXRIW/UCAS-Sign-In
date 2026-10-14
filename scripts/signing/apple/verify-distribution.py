#!/usr/bin/env python3
"""Fail-closed checks for exported apps; diagnostics never print credential data."""
import datetime
import json
from pathlib import Path
import plistlib
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode == 0, f"Distribution verification command failed: {Path(args[0]).name}")
    return result.stdout


def plist(path):
    with open(path, "rb") as source:
        return plistlib.load(source)


def verify_options(ios, mac, team):
    for options in (ios, mac):
        require(options.get("teamID") == team, "ExportOptions teamID must match UCAS_APPLE_TEAM_ID")
        require(options.get("iCloudContainerEnvironment") == "Production", "ExportOptions must select Production iCloud")
        require(options.get("destination", "export") == "export", "ExportOptions must export locally, not upload")
    require(ios.get("method") in {"app-store-connect", "ad-hoc", "release-testing", "enterprise", "app-store"}, "iOS export requires a distribution method")
    require(mac.get("method") == "developer-id", "macOS export method must be developer-id")


def verify_entitlements(info, entitlements, profile, team, main, platform="ios"):
    bundle_id = info["CFBundleIdentifier"]
    profile_entitlements = profile["Entitlements"]
    application_id = entitlements.get("application-identifier", entitlements.get("com.apple.application-identifier", ""))
    require(application_id.endswith("." + bundle_id), "Application identifier does not match bundle")
    require(entitlements.get("com.apple.developer.team-identifier") == team, "Signature team mismatch")
    require(team in profile.get("TeamIdentifier", []), "Profile team mismatch")
    profile_id = profile_entitlements.get("application-identifier", profile_entitlements.get("com.apple.application-identifier"))
    require(profile_id == application_id, "Profile must explicitly authorize the bundle identifier")
    require(not entitlements.get("get-task-allow", False), "Distribution app permits debugging")
    require(not entitlements.get("com.apple.security.get-task-allow", False), "Distribution Mac app permits debugging")
    require(not profile_entitlements.get("get-task-allow", False), "Development profile in distribution app")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, datetime.datetime) and expiry.replace(tzinfo=datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc), "Profile expired or missing expiration")
    groups = entitlements.get("com.apple.security.application-groups", [])
    require(bool(groups) and set(groups) <= set(profile_entitlements.get("com.apple.security.application-groups", [])), "App Group missing from profile")
    require(info.get("AppGroupIdentifier") in groups, "App Group differs from Info.plist")
    if main:
        push_key = "com.apple.developer.aps-environment" if platform == "macos" else "aps-environment"
        require(entitlements.get(push_key) == "production", "Exported app must authorize production push notifications")
        require(profile_entitlements.get(push_key) == "production", "Profile must authorize production push notifications")
        container = info.get("CloudContainerIdentifier", "")
        keychain = info.get("CloudKeychainAccessGroup", "")
        require(container.startswith("iCloud.") and "$(" not in container, "Unresolved CloudKit container")
        require(keychain and "$(" not in keychain, "Unresolved keychain access group")
        for source in (entitlements, profile_entitlements):
            require(container in source.get("com.apple.developer.icloud-container-identifiers", []), "CloudKit container not authorized")
        app_services = entitlements.get("com.apple.developer.icloud-services", [])
        require(isinstance(app_services, list) and "CloudKit" in app_services
                and all(isinstance(service, str) and "*" not in service for service in app_services),
                "Exported app must explicitly authorize CloudKit without wildcard services")
        # A profile is an allowlist (TN3125), so Apple's all-services wildcard is
        # valid here even though the app's signed entitlement must be explicit.
        profile_services = profile_entitlements.get("com.apple.developer.icloud-services", [])
        if isinstance(profile_services, str):
            profile_services = [profile_services]
        require(isinstance(profile_services, list) and all(isinstance(service, str) for service in profile_services)
                and any(service in {"CloudKit", "*"} for service in profile_services),
                "Profile does not permit CloudKit service")
        require(entitlements.get("com.apple.developer.icloud-container-environment") == "Production", "Exported app is not using Production CloudKit")
        allowed_environment = profile_entitlements.get("com.apple.developer.icloud-container-environment", [])
        if isinstance(allowed_environment, str):
            allowed_environment = [allowed_environment]
        require(isinstance(allowed_environment, list)
                and all(isinstance(environment, str) for environment in allowed_environment)
                and "Production" in allowed_environment,
                "Profile does not permit Production CloudKit")
        access_groups = entitlements.get("keychain-access-groups", [])
        require(access_groups and access_groups[0] == application_id, "Default local keychain access group must stay first")
        require(keychain in access_groups, "Shared synchronizable keychain group missing")
        allowed_keys = profile_entitlements.get("keychain-access-groups", [])
        require(any(keychain == item or (item.endswith("*") and keychain.startswith(item[:-1])) for item in allowed_keys), "Profile does not permit shared keychain group")
    else:
        for key in ("com.apple.developer.icloud-services", "com.apple.developer.icloud-container-identifiers",
                    "com.apple.developer.icloud-container-environment"):
            require(not entitlements.get(key), "Widget must not receive CloudKit access")
        require(not entitlements.get("aps-environment") and not entitlements.get("com.apple.developer.aps-environment"), "Widget must not receive push notifications")
        access_groups = entitlements.get("keychain-access-groups", [])
        require(isinstance(access_groups, list) and all(group == application_id for group in access_groups),
                "Widget must not receive another app's keychain access")
        if access_groups:
            allowed_keys = profile_entitlements.get("keychain-access-groups", [])
            require(isinstance(allowed_keys, list) and all(isinstance(item, str) for item in allowed_keys)
                    and any(application_id == item or (item.endswith("*") and application_id.startswith(item[:-1]))
                            for item in allowed_keys),
                    "Profile does not permit the widget's default keychain group")
    return info


def verify_app(path, platform, team):
    is_mac = platform == "macos"
    command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(path))
    content = path / "Contents" if is_mac else path
    widget_name = "UCASSignInMacWidget.appex" if is_mac else "UCASSignInWidget.appex"
    widget = content / "PlugIns" / widget_name
    for bundle, main in ((path, True), (widget, False)):
        root = bundle / "Contents" if is_mac else bundle
        info = plist(root / "Info.plist")
        binary = root / "MacOS" / info["CFBundleExecutable"] if is_mac else root / info["CFBundleExecutable"]
        command("/usr/bin/lipo", str(binary), "-verify_arch", *(('arm64', 'x86_64') if is_mac else ('arm64',)))
        entitlements = plistlib.loads(command("/usr/bin/codesign", "--display", "--entitlements", ":-", str(bundle)))
        profile_file = root / ("embedded.provisionprofile" if is_mac else "embedded.mobileprovision")
        # security cms authenticates signed CMS data; codesign verifies bundle sealing.
        profile = plistlib.loads(command("/usr/bin/security", "cms", "-D", "-i", str(profile_file)))
        verify_entitlements(info, entitlements, profile, team, main, platform)
        if is_mac:
            metadata = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(bundle)], capture_output=True).stderr
            require(b"Authority=Developer ID Application:" in metadata, "Mac bundle does not use Developer ID Application")
            require(b"runtime" in metadata, "Mac bundle is missing hardened runtime")


def main(args):
    if args[0] == "options":
        verify_options(plist(args[1]), plist(args[2]), args[3])
    elif args[0] == "app":
        verify_app(Path(args[1]), args[2], args[3])
    elif args[0] == "pair":
        ios, mac = plist(Path(args[1]) / "Info.plist"), plist(Path(args[2]) / "Contents/Info.plist")
        for key in ("CloudContainerIdentifier", "CloudKeychainAccessGroup"):
            require(ios.get(key) and ios.get(key) == mac.get(key), "iOS/macOS shared iCloud configuration mismatch")
    elif args[0] == "notary":
        require(json.loads(Path(args[1]).read_text()).get("status") == "Accepted", "Notarization was not accepted")
    else:
        raise ValueError("Unknown verification mode")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, KeyError, OSError, plistlib.InvalidFileException, IndexError, TypeError):
        # Exceptions may contain local paths or embedded profile content; keep CI output generic.
        print("Distribution verification failed; check export options, signed capabilities and profiles.", file=sys.stderr)
        sys.exit(1)
