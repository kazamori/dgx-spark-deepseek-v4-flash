# 2. ノード間ネットワーク（ConnectX-7）

2 台を QSFP ケーブル 1 本で直結し、ConnectX-7（以下 CX-7）のリンクに IP を割り当てて、RDMA の帯域を確認する。
構成の全体は [システム構成図](../diagrams/system-architecture.html) を参照する。

## 構成

| 項目 | 値 | 備考 |
|---|---|---|
| 接続方式 | QSFP 直結、ケーブル 1 本 | スイッチなし |
| 使用ポート | 両機とも f0 側 | 両機で同じ物理ポートにそろえる |
| データ用 IF | `enp1s0f0np0` / `enP2p1s0f0np0` | 1 ポートが PCIe の 2 系統として見える |
| RDMA デバイス | `rocep1s0f0` / `roceP2p1s0f0` | `NCCL_IB_HCA` に指定する名前 |
| CX-7 の IP | spark1: 192.168.100.10 / 192.168.101.10<br>spark2: 192.168.100.11 / 192.168.101.11 | 2 系統を別サブネットにする |
| MTU | 9000（RoCE MTU 4096） | netplan で設定 |
| 管理用 IF | `wlP9s9`（Wi-Fi、社内 LAN） | spark1: 192.168.160.37、spark2: 192.168.160.21 |

## 結線とリンクの確認

クラスタ用のケーブルは、両機の同じ位置のポートに挿す。
この環境では両機とも f0 側にそろえた。

`ibdev2netdev` で、f0 側の 2 つの IF が両機で `Up` になっていることを確認する。

```
user@spark1:~$ ibdev2netdev
roceP2p1s0f0 port 1 ==> enP2p1s0f0np0 (Up)
roceP2p1s0f1 port 1 ==> enP2p1s0f1np1 (Down)
rocep1s0f0 port 1 ==> enp1s0f0np0 (Up)
rocep1s0f1 port 1 ==> enp1s0f1np1 (Down)
```

リンク速度を両機で確認する。
ここで表示されるのは PHY のネゴシエーション速度であり、実効帯域ではない。

```
$ sudo ethtool enp1s0f0np0 | grep -E 'Speed|Link detected'
        Speed: 200000Mb/s
        Link detected: yes
```

CX-7 はホットプラグに対応しているが、稼働中にケーブルを抜き差しすると帯域が大きく落ちることがある（「[トラブルシューティング](06-troubleshooting.md)」を参照）。
抜き差しした場合は両機を再起動する。

## IP アドレスと MTU の設定

netplan の設定ファイルを両機に置く。
設定ファイルは [configs/netplan/](../configs/netplan/) にある。

```bash
# spark1 では 40-cx7-spark1.yaml、spark2 では 40-cx7-spark2.yaml を使う
sudo cp 40-cx7-spark1.yaml /etc/netplan/40-cx7.yaml
sudo chmod 600 /etc/netplan/40-cx7.yaml
sudo netplan try      # 120 秒以内に Enter で確定する。確定しなければ自動で元に戻る
```

spark1 の設定は次のとおりである。
spark2 は末尾を `.11` にする。

```yaml
network:
  version: 2
  ethernets:
    enp1s0f0np0:
      addresses: [192.168.100.10/24]
      dhcp4: no
      mtu: 9000
    enP2p1s0f0np0:
      addresses: [192.168.101.10/24]
      dhcp4: no
      mtu: 9000
```

疎通と経路を確認する。
MTU 9000 のパケットが断片化せずに届くことも確かめる。

```
user@spark1:~$ ping -c3 192.168.100.11
64 bytes from 192.168.100.11: icmp_seq=1 ttl=64 time=1.97 ms

user@spark1:~$ ip route get 192.168.100.11
192.168.100.11 dev enp1s0f0np0 src 192.168.100.10 uid 1000

user@spark1:~$ ping -M do -s 8972 -c3 192.168.100.11
PING 192.168.100.11 (192.168.100.11) 8972(9000) bytes of data.
8980 bytes from 192.168.100.11: icmp_seq=1 ttl=64 time=0.644 ms
```

spark2 からも spark1（192.168.100.10）に向けて同じ確認を行う。

## ノード間 ssh の設定

レシピのスクリプトや mpirun は、ヘッドからワーカーへパスワードなしの ssh で接続する。
両機で鍵を作り、互いの公開鍵を登録する。

```bash
ssh-keygen -t ed25519            # 鍵がなければ作る
ssh-copy-id 192.168.100.11       # spark1 で実行する（spark2 では 192.168.100.10）
```

`~/.ssh/config` に別名を定義する（[configs/ssh/config](../configs/ssh/config)）。
両機に同じ内容を置く。

```
Host spark1
  HostName 192.168.100.10
Host spark2
  HostName 192.168.100.11
```

別名で接続できることを確認する。

```
user@spark1:~$ ssh spark2 hostname
spark-af6b
user@spark2:~$ ssh spark1 hostname
spark-a4bb
```

## RDMA 帯域の確認

`perftest` を両機に入れ、`ib_write_bw` で片方の系統の RDMA 書き込み帯域を測る。

```bash
sudo apt install -y perftest

# spark1（サーバー）
ib_write_bw -d rocep1s0f0 --report_gbits -D 10

# spark2（クライアント）
ib_write_bw -d rocep1s0f0 --report_gbits -D 10 192.168.100.10
```

MTU 9000 に設定したあとの結果は次のとおりである。
RoCE の MTU は 4096 になる。

```
 Mtu             : 4096[B]
 Link type       : Ethernet
 GID index       : 3
 #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
 65536      1249395          0.00               109.17             0.208233
```

1 系統の上限は PCIe Gen5 x4（約 126Gb/s）で決まるので、約 110Gb/s 出ていれば正常である。

## 検証結果

| # | 検証項目 | コマンド | 結果 | 期待値 | 判定 |
|---|---|---|---|---|---|
| 1 | リンクアップ | `ibdev2netdev` | f0 側の 2 IF が両機で Up | 両機で同じポートが Up | ✅ |
| 2 | リンク速度 | `ethtool enp1s0f0np0` | 200000Mb/s | 200Gb/s | ✅ |
| 3 | RDMA 帯域、1 系統（ケーブル抜き差し直後） | `ib_write_bw -d rocep1s0f0` | 13.49Gb/s | 約 110Gb/s | ❌（再起動で解消） |
| 4 | RDMA 帯域、1 系統（再起動後） | 同上 `-D 10` | 108.94Gb/s（RoCE MTU 1024） | 約 110Gb/s | ✅ |
| 5 | RDMA 帯域、1 系統（MTU 9000） | 同上 | 109.17Gb/s（RoCE MTU 4096） | 約 110Gb/s | ✅ |

NCCL を使った 2 ノード間の集団通信の検証は「[NCCL による通信テスト](03-nccl-test.md)」で行う。
