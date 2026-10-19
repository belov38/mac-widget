"""Static configuration for the pve widget collector."""
import os

# chip name -> (sensor id, label); order defines output order
SENSOR_LABELS = {
    "coretemp-isa-0000": ("cpu", "CPU"),
    "nvme-pci-ae00": ("nvme970", "NVMe 970"),
    "nvme-pci-8100": ("nvmep310", "NVMe P310"),
    "spd5118-i2c-0-50": ("dimm_a0", "DIMM A0"),
    "spd5118-i2c-0-51": ("dimm_a1", "DIMM A1"),
    "spd5118-i2c-0-52": ("dimm_b0", "DIMM B0"),
    "spd5118-i2c-0-53": ("dimm_b1", "DIMM B1"),
    "ice-pci-0100": ("e810", "E810"),
    "r8169_0_ab00:00-mdio-0": ("rtl8127", "RTL8127"),
}

# chip name -> feature holding the temperature reading
SENSOR_FEATURES = {
    "coretemp-isa-0000": "Package id 0",
    "nvme-pci-ae00": "Composite",
    "nvme-pci-8100": "Composite",
}
DEFAULT_FEATURE = "temp1"

CPU_TEMP = (85.0, 95.0)

# (pve storage name, display label)
STORAGES = [("vmdata", "vmdata"), ("local-lvm", "local-lvm"), ("local", "root")]

# Only this Tailscale login (set by tailscale serve) may read the snapshot; empty denies everyone.
ALLOWED_LOGIN = os.environ.get("PVEWIDGET_ALLOWED_LOGIN", "")
PORT = 9184
