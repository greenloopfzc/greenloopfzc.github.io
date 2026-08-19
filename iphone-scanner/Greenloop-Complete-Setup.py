import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
VENDOR = ROOT / "python-packages"
sys.path[:0] = [
    str(VENDOR),
    str(VENDOR / "win32"),
    str(VENDOR / "win32" / "lib"),
    str(VENDOR / "pywin32_system32"),
]
if os.name == "nt" and (VENDOR / "pywin32_system32").is_dir():
    os.add_dll_directory(str(VENDOR / "pywin32_system32"))

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.mobile_config import MobileConfigService


SKIP_SETUP_PANES = [
    "Location", "Restore", "SIMSetup", "Android", "AppleID", "IntendedUser",
    "TOS", "Siri", "ScreenTime", "Diagnostics", "SoftwareUpdate", "Passcode",
    "Biometric", "Payment", "Zoom", "DisplayTone", "HomeButtonSensitivity",
    "CloudStorage", "TapToSetup", "Keyboard", "PreferredLanguage",
    "SpokenLanguage", "WatchMigration", "OnBoarding", "Privacy",
    "iMessageAndFaceTime", "AppStore", "Safety", "Welcome", "Appearance",
    "WiFi", "Display", "Tone", "LanguageAndLocale", "TouchID",
    "TrueToneDisplay", "Registration", "DeviceToDeviceMigration", "Accessibility",
    "ExpressLanguage", "Language", "Region", "DeviceProtection", "Wallpaper",
    "Intelligence", "AdditionalPrivacySettings", "SafetyAndHandling", "Tips", "All",
]


async def complete_setup(udid: str) -> dict:
    pairing_cache = (
        Path(os.environ.get("LOCALAPPDATA", tempfile.gettempdir()))
        / "Greenloop"
        / "CableReader"
        / "pairing-cache"
    )
    pairing_cache.mkdir(parents=True, exist_ok=True)
    lockdown = await create_using_usbmux(
        serial=udid,
        connection_type="USB",
        autopair=True,
        pairing_records_cache_folder=pairing_cache,
    )
    try:
        async with MobileConfigService(lockdown) as mobile_config:
            await mobile_config.hello()
            existing = await mobile_config.get_cloud_configuration() or {}

            # Never replace or weaken an existing supervised/managed configuration.
            # Greenloop also never erases, restores, reboots, or restarts the phone.
            if existing.get("IsSupervised") or existing.get("IsMDMUnremovable"):
                raise RuntimeError(
                    "This iPhone already has a supervised or managed configuration. "
                    "Greenloop stopped without changing it."
                )

            configuration = dict(existing)
            configuration.update(
                {
                    "AllowPairing": True,
                    "CloudConfigurationUIComplete": True,
                    "ConfigurationSource": 0,
                    "ConfigurationWasApplied": True,
                    "IsMDMUnremovable": False,
                    "IsMandatory": False,
                    "IsMultiUser": False,
                    "IsSupervised": False,
                    "PostSetupProfileWasInstalled": True,
                    "SkipSetup": SKIP_SETUP_PANES,
                }
            )

            await mobile_config.set_cloud_configuration(configuration)
            await mobile_config.flush()
            confirmed = await mobile_config.get_cloud_configuration() or {}
            if not confirmed.get("CloudConfigurationUIComplete"):
                raise RuntimeError(
                    "Apple did not confirm Skip Setup. Greenloop stopped safely without "
                    "resetting or restarting the phone."
                )

        return {
            "ok": True,
            "udid": udid,
            "skipSetupCompleted": True,
            "setupAssistantCompleted": True,
            "homeScreenReady": True,
            "engine": "Apple MCInstall",
            "restarting": False,
        }
    finally:
        await lockdown.close()


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1].strip():
        print(json.dumps({"ok": False, "message": "A single iPhone UDID is required."}))
        return 2
    try:
        result = asyncio.run(complete_setup(sys.argv[1].strip()))
        print(json.dumps(result))
        return 0
    except Exception as error:
        message = str(error).strip() or (
            f"{type(error).__name__}: Apple did not accept the Skip Setup request."
        )
        print(
            json.dumps(
                {"ok": False, "message": message, "errorType": type(error).__name__}
            )
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
