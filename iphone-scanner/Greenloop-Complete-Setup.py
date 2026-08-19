import asyncio
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
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

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.mobile_config import MobileConfigService


def create_supervision_identity(path: Path) -> None:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Greenloop FZC"),
        x509.NameAttribute(NameOID.COMMON_NAME, "Greenloop Setup Assistant"),
    ])
    now = datetime.now(timezone.utc)
    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        + certificate.public_bytes(serialization.Encoding.PEM)
    )


async def complete_setup(udid: str) -> dict:
    pairing_cache = Path(os.environ.get("LOCALAPPDATA", tempfile.gettempdir())) / "Greenloop" / "CableReader" / "pairing-cache"
    pairing_cache.mkdir(parents=True, exist_ok=True)
    lockdown = await create_using_usbmux(
        serial=udid,
        connection_type="USB",
        autopair=True,
        pairing_records_cache_folder=pairing_cache,
    )
    try:
        with tempfile.TemporaryDirectory(prefix="greenloop-setup-") as folder:
            identity = Path(folder) / "greenloop-supervision.pem"
            create_supervision_identity(identity)
            async with MobileConfigService(lockdown) as mobile_config:
                await mobile_config.hello()
                configuration = await mobile_config.get_cloud_configuration()
                if not configuration or not configuration.get("CloudConfigurationUIComplete"):
                    await mobile_config.supervise("Greenloop FZC", identity)
                    configuration = await mobile_config.get_cloud_configuration()
                if not configuration or not configuration.get("CloudConfigurationUIComplete"):
                    raise RuntimeError("Apple did not confirm the Setup Assistant configuration.")
        return {
            "ok": True,
            "udid": udid,
            "setupAssistantCompleted": True,
            "engine": "Apple MobileConfig",
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
        message = str(error).strip() or f"{type(error).__name__}: Apple did not accept the Setup Assistant request."
        print(json.dumps({"ok": False, "message": message, "errorType": type(error).__name__}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
