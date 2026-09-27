# 1. 初期セットアップ

2 台の DGX Spark それぞれに OS をセットアップし、ハードウェア情報とソフトウェアのバージョンを確認する。
この章の作業は両機で同じように行う。

## OS の初回セットアップ

DGX Spark にディスプレイとキーボードを接続し、初回起動時のセットアップを進めて Ubuntu（DGX OS）を起動できる状態にする。
初回起動時の設定内容は記録していない。

## ハードウェア情報の確認

ハードウェア情報を確認するツールを入れる。

```bash
sudo apt install -y inxi lshw hwloc-nox nvtop
```

`inxi -Fxxxza -y 80` と `nvidia-smi -a` で確認した主な項目は次のとおりである（2026-09-07 時点）。

| 項目 | 値 |
|---|---|
| 製品 | NVIDIA DGX Spark（NVIDIA_DGX_Spark v: A.7） |
| CPU | ARMv8、20 コア（aarch64） |
| GPU | NVIDIA GB10（Blackwell）、GPU UUID `GPU-464fd8f4-75b5-54e4-dcd3-2ffbc71ebe45`、GPU PDI `0xf98aadff6aaf1bb8` |
| メモリ | 128 GiB（CPU と GPU の統合メモリ） |
| ストレージ | NVMe SSD 3.73 TiB（Samsung MZALC4T0HBL1-00B07） |
| ネットワーク | ConnectX-7（MT2910）×4 IF、Realtek 10GbE（`enP7s7`）`[推定]`、Wi-Fi（`wlP9s9`） |

GPU UUID と GPU PDI は、`inxi` と `nvidia-smi -a` を実行した spark1 の値である。

`nvidia-smi` では、統合メモリ構成のため `Memory-Usage` が `Not Supported` と表示される。

```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 580.178.04             Driver Version: 580.178.04     CUDA Version: 13.0     |
+-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|=========================================+========================+======================|
|   0  NVIDIA GB10                    On  |   0000000F:01:00.0 Off |                  N/A |
| N/A   44C    P0             11W /  N/A  | Not Supported          |      0%      Default |
+-----------------------------------------+------------------------+----------------------+
```

## ファームウェアと OS の更新

パッケージとファームウェアを更新して再起動する。

```bash
sudo apt update
sudo apt dist-upgrade
sudo fwupdmgr refresh
sudo fwupdmgr upgrade
sudo reboot
```

ConnectX-7 のファームウェアのバージョンは `fwupdmgr get-devices` で確認できる。
出力にはシリアル番号も含まれるので、共有するときはバージョンの行だけを抜き出す。

```
├─MT2910 Family (ConnectX-7):
│ └─MT2910 Family (ConnectX-7) (Composite):
│       現在のバージョン: 28.45.4028
│       GUID:             479999c8-4487-580a-aaae-2b8cb961952a ← PCI\VEN_15B3&DEV_1021&COMPONENT_fw&FW.PSID_NVD0000000087
```

## ソフトウェアのバージョン

両機は同じバージョンである。
作業期間中に OTA 更新を行ったので、時点ごとに記録する。

| 項目 | 2026-09-07 | 2026-09-27 | 確認コマンド |
|---|---|---|---|
| DGX OS | 7.5.0（OTA） | 7.6.0（2026-09-23 に OTA） | `cat /etc/dgx-release` |
| Ubuntu | 24.04.4 LTS | 24.04.5 LTS | `cat /etc/os-release` |
| カーネル | `6.17.0-1032-nvidia` | `7.0.0-1019-nvidia` | `uname -r` |
| NVIDIA ドライバ | 580.173.02 | 580.178.04 | `nvidia-smi` |
| CUDA | 13.0 | 13.0（nvcc 13.0.88） | `nvidia-smi`、`nvcc --version` |
| ConnectX-7 ファームウェア | 記録なし | 28.45.4028（PSID NVD0000000087） | `fwupdmgr get-devices` |

DGX OS の初期ビルドは 7.2.3（2025-10-04）である。
