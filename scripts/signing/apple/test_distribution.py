"""Run without certificates or network: python3 -m unittest discover -s scripts/signing/apple."""
import copy
import datetime
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("verify_distribution", HERE / "verify-distribution.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.team = "TESTTEAMID"
        self.bundle = "example.test"
        self.identifier = self.team + "." + self.bundle
        self.group = self.team + ".example.test.icloud-credentials"
        self.info = {"CFBundleIdentifier": self.bundle, "AppGroupIdentifier": "group.example.test", "CloudContainerIdentifier": "iCloud.example.test", "CloudKeychainAccessGroup": self.group}
        self.entitlements = {
            "application-identifier": self.identifier,
            "com.apple.developer.team-identifier": self.team,
            "com.apple.security.application-groups": ["group.example.test"],
            "com.apple.developer.icloud-container-identifiers": ["iCloud.example.test"],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-environment": "Production",
            "aps-environment": "production",
            "keychain-access-groups": [self.identifier, self.group],
        }
        self.profile = {"TeamIdentifier": [self.team], "ExpirationDate": datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=10), "Entitlements": copy.deepcopy(self.entitlements)}

    def check(self):
        return verify.verify_entitlements(self.info, self.entitlements, self.profile, self.team, True)

    def test_valid_distribution(self):
        self.assertEqual(self.check(), self.info)

    def test_profile_prefix_wildcard_for_keychain(self):
        self.profile["Entitlements"]["keychain-access-groups"] = [self.team + ".*"]
        self.check()

    def test_profile_environment_array(self):
        for value in ("Production", ["Production"], ["Development", "Production"]):
            with self.subTest(value=value):
                self.profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = value
                self.check()

    def test_profile_environment_rejects_lookalikes_and_malformed_values(self):
        for value in (None, [], "", "Development", "NotProduction", "ProductionExtra", "Production*",
                      ["NotProduction"], ["ProductionExtra"], ["Production", None], ["Production", 1],
                      {"Production": True}, 1, ("Production",)):
            with self.subTest(value=value):
                self.profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = value
                with self.assertRaises(ValueError):
                    self.check()

    def test_profile_cloud_services_accept_exact_service_or_all_services_wildcard(self):
        for value in ("CloudKit", ["CloudKit"], "*", ["*"], ["CloudDocuments", "*"]):
            with self.subTest(value=value):
                self.profile["Entitlements"]["com.apple.developer.icloud-services"] = value
                self.assertEqual(self.check(), self.info)

    def test_profile_cloud_services_reject_lookalikes_and_malformed_values(self):
        for value in (None, [], "", "CloudDocuments", "Cloud*", "CloudKit*", "NotCloudKit",
                      ["Cloud*"], ["NotCloudKit"], {"CloudKit": True}, 1, ["*", 1]):
            with self.subTest(value=value):
                self.profile["Entitlements"]["com.apple.developer.icloud-services"] = value
                with self.assertRaises(ValueError):
                    self.check()

    def test_app_cloud_services_require_explicit_cloudkit_without_wildcards(self):
        self.profile["Entitlements"]["com.apple.developer.icloud-services"] = "*"
        for value in (None, [], "CloudKit", "*", ["*"], ["CloudKit", "*"], ["CloudKit", "Cloud*"],
                      ["CloudKit*"], ["NotCloudKit"], {"CloudKit": True}, ["CloudKit", 1]):
            with self.subTest(value=value):
                self.entitlements["com.apple.developer.icloud-services"] = value
                with self.assertRaises(ValueError):
                    self.check()

    def test_profile_service_wildcard_does_not_relax_other_cloud_capabilities(self):
        self.profile["Entitlements"]["com.apple.developer.icloud-services"] = "*"
        for source in (self.entitlements, self.profile["Entitlements"]):
            for key, value in (("com.apple.developer.icloud-container-identifiers", ["iCloud.other"]),
                               ("com.apple.developer.icloud-container-environment", "Development"),
                               ("aps-environment", "development"),
                               ("keychain-access-groups", [self.identifier])):
                with self.subTest(app=source is self.entitlements, key=key):
                    original = source[key]
                    source[key] = value
                    with self.assertRaises(ValueError):
                        self.check()
                    source[key] = original

    def test_wrong_cloud_environment_rejected(self):
        self.entitlements["com.apple.developer.icloud-container-environment"] = "Development"
        with self.assertRaises(ValueError):
            self.check()

    def test_missing_or_development_push_entitlement_rejected(self):
        for source in (self.entitlements, self.profile["Entitlements"]):
            for value in (None, "development", "$(APS_ENVIRONMENT)"):
                with self.subTest(source=source is self.entitlements, value=value):
                    source["aps-environment"] = value
                    with self.assertRaises(ValueError):
                        self.check()
            source["aps-environment"] = "production"

    def test_mac_requires_its_platform_push_entitlement(self):
        with self.assertRaises(ValueError):
            verify.verify_entitlements(self.info, self.entitlements, self.profile, self.team, True, "macos")
        for source in (self.entitlements, self.profile["Entitlements"]):
            source["com.apple.developer.aps-environment"] = source.pop("aps-environment")
        self.assertEqual(verify.verify_entitlements(self.info, self.entitlements, self.profile, self.team, True, "macos"), self.info)

    def test_default_keychain_must_remain_first(self):
        self.entitlements["keychain-access-groups"].reverse()
        with self.assertRaises(ValueError):
            self.check()

    def test_unresolved_container_rejected(self):
        self.info["CloudContainerIdentifier"] = "$(ICLOUD_CONTAINER_IDENTIFIER)"
        with self.assertRaises(ValueError):
            self.check()

    def test_expired_profile_rejected(self):
        self.profile["ExpirationDate"] = datetime.datetime(2020, 1, 1)
        with self.assertRaises(ValueError):
            self.check()

    def test_team_mismatch_rejected(self):
        self.profile["TeamIdentifier"] = ["OTHERTEAM"]
        with self.assertRaises(ValueError):
            self.check()

    def test_development_signature_rejected(self):
        self.entitlements["get-task-allow"] = True
        with self.assertRaises(ValueError):
            self.check()

    def test_missing_profile_capability_rejected(self):
        for key in ("keychain-access-groups", "com.apple.developer.icloud-services", "com.apple.developer.icloud-container-identifiers", "com.apple.security.application-groups"):
            with self.subTest(key=key):
                original = self.profile["Entitlements"].pop(key)
                with self.assertRaises(ValueError):
                    self.check()
                self.profile["Entitlements"][key] = original

    def test_widget_does_not_have_icloud(self):
        with self.assertRaises(ValueError):
            verify.verify_entitlements(self.info, self.entitlements, self.profile, self.team, False)

    def widget_values(self, platform):
        info = {"CFBundleIdentifier": self.bundle + ".widget", "AppGroupIdentifier": "group.example.test"}
        identifier_key = "com.apple.application-identifier" if platform == "macos" else "application-identifier"
        entitlements = {
            identifier_key: self.identifier + ".widget",
            "com.apple.developer.team-identifier": self.team,
            "com.apple.security.application-groups": ["group.example.test"],
        }
        profile = copy.deepcopy(self.profile)
        profile["Entitlements"] = dict(entitlements, **{"keychain-access-groups": [self.team + ".*"]})
        return info, entitlements, profile

    def test_widget_accepts_no_keychain_access_or_authorized_own_default_group(self):
        for platform in ("ios", "macos"):
            info, entitlements, profile = self.widget_values(platform)
            self.assertEqual(verify.verify_entitlements(info, entitlements, profile, self.team, False, platform), info)
            for groups in ([], [self.identifier + ".widget"]):
                for allowed in ([self.team + ".*"], [self.identifier + ".widget"]):
                    with self.subTest(platform=platform, groups=groups, allowed=allowed):
                        entitlements["keychain-access-groups"] = groups
                        profile["Entitlements"]["keychain-access-groups"] = allowed
                        self.assertEqual(verify.verify_entitlements(info, entitlements, profile, self.team, False, platform), info)

    def test_widget_rejects_each_cloud_and_push_entitlement_independently(self):
        forbidden = {
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-identifiers": ["iCloud.example.test"],
            "com.apple.developer.icloud-container-environment": "Production",
            "aps-environment": "production",
            "com.apple.developer.aps-environment": "production",
        }
        for platform in ("ios", "macos"):
            for key, value in forbidden.items():
                with self.subTest(platform=platform, key=key):
                    info, entitlements, profile = self.widget_values(platform)
                    entitlements[key] = value
                    with self.assertRaises(ValueError):
                        verify.verify_entitlements(info, entitlements, profile, self.team, False, platform)

    def test_widget_rejects_shared_foreign_or_malformed_keychain_groups(self):
        for platform in ("ios", "macos"):
            for groups in ([self.group], [self.identifier + ".widget", self.group], [self.identifier],
                           [self.team + ".another-app"], [self.team + ".*"], [None], None,
                           self.identifier + ".widget", {self.identifier + ".widget": True}):
                with self.subTest(platform=platform, groups=groups):
                    info, entitlements, profile = self.widget_values(platform)
                    entitlements["keychain-access-groups"] = groups
                    with self.assertRaises(ValueError):
                        verify.verify_entitlements(info, entitlements, profile, self.team, False, platform)

    def test_widget_own_keychain_group_requires_profile_authorization(self):
        for platform in ("ios", "macos"):
            for allowed in ([], [self.group], ["OTHERTEAM.*"], None, self.team + ".*", [self.team + ".*", None]):
                with self.subTest(platform=platform, allowed=allowed):
                    info, entitlements, profile = self.widget_values(platform)
                    entitlements["keychain-access-groups"] = [self.identifier + ".widget"]
                    profile["Entitlements"]["keychain-access-groups"] = allowed
                    with self.assertRaises(ValueError):
                        verify.verify_entitlements(info, entitlements, profile, self.team, False, platform)

    def test_export_options_are_local_production(self):
        common = {"teamID": self.team, "iCloudContainerEnvironment": "Production", "destination": "export"}
        ios = dict(common, method="release-testing")
        mac = dict(common, method="developer-id")
        verify.verify_options(ios, mac, self.team)
        for key, value in (("destination", "upload"), ("iCloudContainerEnvironment", "Development"), ("teamID", "another-team"), ("method", "development")):
            with self.subTest(key=key):
                with self.assertRaises(ValueError):
                    verify.verify_options(dict(ios, **{key: value}), mac, self.team)

    def test_main_entitlements_preserve_default_access(self):
        for file in (ROOT / 'apps/apple/UCASSignIn/Resources/UCASSignIn.entitlements', ROOT / 'apps/apple/UCASSignInMac/Resources/UCASSignInMac.entitlements'):
            values = plistlib.loads(file.read_bytes())
            self.assertEqual(values['keychain-access-groups'], ['$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)', '$(ICLOUD_KEYCHAIN_ACCESS_GROUP)'])

    def test_push_capabilities_are_limited_to_main_apps(self):
        apple = ROOT / 'apps/apple'
        ios = plistlib.loads((apple / 'UCASSignIn/Resources/UCASSignIn.entitlements').read_bytes())
        mac = plistlib.loads((apple / 'UCASSignInMac/Resources/UCASSignInMac.entitlements').read_bytes())
        self.assertEqual(ios['aps-environment'], '$(APS_ENVIRONMENT)')
        self.assertEqual(mac['com.apple.developer.aps-environment'], '$(APS_ENVIRONMENT)')
        for name in ('UCASSignInWidget.entitlements', 'UCASSignInMacWidget.entitlements'):
            widget = plistlib.loads((apple / 'UCASSignInWidget' / name).read_bytes())
            self.assertNotIn('aps-environment', widget)
            self.assertNotIn('com.apple.developer.aps-environment', widget)
        info = plistlib.loads((apple / 'UCASSignIn/Resources/Info.plist').read_bytes())
        self.assertIn('remote-notification', info['UIBackgroundModes'])

    def test_missing_signing_config_never_falls_back(self):
        import os
        env = {k: v for k, v in os.environ.items() if not k.startswith('UCAS_')}
        for script in ('apple.sh', 'apple-latest-sdk.sh'):
            result = subprocess.run(['bash', str(ROOT / 'scripts/publish/platforms' / script), '--signed'], capture_output=True, env=env)
            self.assertEqual(result.returncode, 2)
            self.assertIn(b'requires UCAS_APPLE_TEAM_ID', result.stderr)

    def test_ci_blocks_non_manual_or_non_main(self):
        import os
        for event, ref in (('pull_request', 'refs/heads/main'), ('workflow_dispatch', 'refs/heads/feature')):
            env = dict(os.environ, GITHUB_ACTIONS='true', GITHUB_EVENT_NAME=event, GITHUB_REF=ref)
            result = subprocess.run(['bash', str(HERE / 'ci-release.sh')], capture_output=True, env=env)
            self.assertEqual(result.returncode, 2)
            self.assertIn(b'manual dispatch on main', result.stderr)


class PrivacyTests(unittest.TestCase):
    def scan(self, app):
        return subprocess.run(['bash', '-c', 'source "$1"; check_signed_release_privacy "$2"', 'scan', str(HERE / 'release-privacy.sh'), str(app)], capture_output=True)

    def test_only_explicit_profile_locations_allowed(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Example.app'
            app.mkdir()
            # Signature/profile validation precedes the scanner in the release pipeline.
            (app / 'embedded.mobileprovision').write_bytes(b'profile')
            self.assertEqual(self.scan(app).returncode, 0)
            (app / 'rogue.mobileprovision').write_bytes(b'profile')
            self.assertNotEqual(self.scan(app).returncode, 0)

    def test_private_keys_paths_and_symlinks_rejected(self):
        for filename, content in (('secret.p12', b'secret'), ('binary', b'\x00/Users/local-user/source/app.swift')):
            with self.subTest(filename=filename), tempfile.TemporaryDirectory() as temporary:
                app = Path(temporary) / 'Example.app'
                app.mkdir()
                (app / filename).write_bytes(content)
                self.assertNotEqual(self.scan(app).returncode, 0)
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Example.app'
            app.mkdir()
            (app / 'link').symlink_to('/tmp')
            self.assertNotEqual(self.scan(app).returncode, 0)

    def test_unsigned_scanners_still_forbid_profiles(self):
        # Regression test: signed exceptions do not change either unsigned mode.
        for name in ('apple.sh', 'apple-latest-sdk.sh'):
            source = (ROOT / 'scripts/publish/platforms' / name).read_text()
            start = source.index('check_release_privacy() {')
            end = source.index('\npublish_artifact()', start)
            function = source[start:end]
            with tempfile.TemporaryDirectory() as temporary:
                app = Path(temporary) / 'Example.app'
                app.mkdir()
                (app / 'embedded.mobileprovision').write_bytes(b'profile')
                result = subprocess.run(['bash', '-c', function + '\ncheck_release_privacy "$1"', 'scan', str(app)], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'embedded-provisioning', result.stderr)


if __name__ == '__main__':
    unittest.main()
