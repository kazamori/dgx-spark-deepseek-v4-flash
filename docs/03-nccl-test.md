# 3. NCCL による通信テスト

vLLM のテンソル並列（TP=2）は、2 台の GPU の間で NCCL の集団通信を使う。
LLM を導入する前に、NCCL が CX-7 の RoCE を使って十分な帯域を出せることを確認する。
手順は NVIDIA の [dgx-spark-playbooks（NCCL for Multiple Sparks）](https://github.com/NVIDIA/dgx-spark-playbooks/blob/main/nvidia/nccl/README.md) に従う。

## NCCL と nccl-tests のビルド

spark1 のホームディレクトリでビルドし、できたものを spark2 にコピーする。
NCCL は GB10 向け（`sm_121`）にソースからビルドする。

```bash
sudo apt-get update && sudo apt-get install -y libopenmpi-dev

git clone -b v2.30.7-1 https://github.com/NVIDIA/nccl.git ~/nccl/
cd ~/nccl/ && make -j src.build NVCC_GENCODE="-gencode=arch=compute_121,code=sm_121"
```

環境変数は `~/nccl-env.sh` にまとめる（[configs/nccl-env.sh](../configs/nccl-env.sh)）。
管理用 IF の 3 行は、mpirun の制御通信に使う IF（この環境では Wi-Fi の `wlP9s9`）にする。

```bash
export CUDA_HOME="/usr/local/cuda"
export MPI_HOME="/usr/lib/aarch64-linux-gnu/openmpi"
export NCCL_HOME="$HOME/nccl/build/"
export LD_LIBRARY_PATH="$NCCL_HOME/lib:$CUDA_HOME/lib64/:$MPI_HOME/lib:$LD_LIBRARY_PATH"
export UCX_NET_DEVICES=wlP9s9
export NCCL_SOCKET_IFNAME=wlP9s9
export OMPI_MCA_btl_tcp_if_include=wlP9s9
```

nccl-tests は、検証に使ったコミットに固定してビルドする。

```bash
git clone https://github.com/NVIDIA/nccl-tests.git ~/nccl-tests/
git -C ~/nccl-tests checkout b4d5beebca8a76cf01335f724d154b9b9d394d96
source ~/nccl-env.sh
cd ~/nccl-tests/ && make MPI=1 NCCL_HOME=$NCCL_HOME MPI_HOME=$MPI_HOME CUDA_HOME=$CUDA_HOME
```

このコミットでは `device_api/gin` のビルドがリンクエラーになるが、今回使う `all_gather_perf` と `all_reduce_perf` は生成される。

```
$ ls ~/nccl-tests/build/all_gather_perf ~/nccl-tests/build/all_reduce_perf
~/nccl-tests/build/all_gather_perf
~/nccl-tests/build/all_reduce_perf
```

ビルドしたものを spark2 の同じパスにコピーする。

```bash
scp -r ~/nccl spark2:
scp -r ~/nccl-tests spark2:
```

## テストの実行

spark1 から mpirun で両機にプロセスを起動する。
`-H` には管理用 LAN の IP（spark1: 192.168.160.37、spark2: 192.168.160.21）を指定する。

```bash
source ~/nccl-env.sh
MPI="mpirun -np 2 -H 192.168.160.37:1,192.168.160.21:1 \
  --mca plm_rsh_agent 'ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' \
  -x LD_LIBRARY_PATH=$LD_LIBRARY_PATH -x NCCL_DEBUG=INFO"

eval $MPI hostname        # spark-a4bb と spark-af6b が表示されれば準備完了

eval $MPI $HOME/nccl-tests/build/all_gather_perf -b 16G -e 16G -f 2
eval $MPI $HOME/nccl-tests/build/all_reduce_perf -b 256M -e 4G -f 2
```

`NCCL_DEBUG=INFO` のログに `via NET/IB` と出ていれば、NCCL は TCP ではなく RoCE を使っている。
`GDR 0` は GPUDirect RDMA を使っていないことを示す。

```
spark-a4bb:186444:186444 [0] NCCL INFO Channel 63/0 : 0[0] -> 1[0] [send] via NET/IB/1
spark-a4bb:186444:186444 [0] NCCL INFO Connected all rings, use ring PXN 0 GDR 0
```

## 結果

| # | 検証項目 | 結果 | 期待値 | 判定 |
|---|---|---|---|---|
| 1 | NCCL の経路 | `via NET/IB`、`GDR 0` | NET/IB | ✅ |
| 2 | all_gather（16GiB） | algbw 46.79 / busbw 23.40GB/s（平均 23.72） | 15GB/s 以上 | ✅ |
| 3 | all_reduce（256MiB〜4GiB） | busbw 21.4〜24.1GB/s（平均 23.21） | 15GB/s 以上 | ✅ |
| 4 | 結果の正しさ | `#wrong 0`、`Out of bounds values : 0 OK` | 0 | ✅ |

busbw はリンク上の実効帯域で、GB/s に 8 を掛けると Gb/s になる。
all_reduce の 4GiB 時の 24.11GB/s は約 193Gb/s であり、ライン レート（200Gb/s）の約 98% にあたる。

all_reduce は vLLM の TP で主に使われる集団通信である。
2 ノードでは algbw と busbw が等しくなる。

| size | time（µs）out / in | algbw（GB/s）out / in | busbw（GB/s）out / in | #wrong |
|---|---|---|---|---|
| 256MiB | 12539.2 / 12574.7 | 21.41 / 21.35 | 21.41 / 21.35 | 0 / 0 |
| 512MiB | 23450.5 / 23274.6 | 22.89 / 23.07 | 22.89 / 23.07 | 0 / 0 |
| 1GiB | 45463.1 / 45337.4 | 23.62 / 23.68 | 23.62 / 23.68 | 0 / 0 |
| 2GiB | 89664.4 / 89762.9 | 23.95 / 23.92 | 23.95 / 23.92 | 0 / 0 |
| 4GiB | 178165 / 178251 | 24.11 / 24.10 | 24.11 / 24.10 | 0 / 0 |

256MiB の行の size 欄はログから切れていたため、`-b 256M` の指定と time の値から判断した。

### 公開されている測定値との比較

| 出典 | 条件 | 値 |
|---|---|---|
| この環境 | 直結、MTU 9000、2 系統 | all_reduce busbw 21.4〜24.1GB/s |
| [tsuru_mitsu（note）](https://note.com/gb10_tsurumitsu/n/n1c5efc62a92e) | 直結、MTU 9000 | AllReduce 256MiB 約 172Gbps（約 21.5GB/s） |
| [multimodalflow](https://multimodalflow.net/en/blog/dgx-spark-dual-node-nccl-rdma/) | 直結 | all-reduce 約 10.2GB/s |
