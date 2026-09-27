# 6. トラブルシューティング

構築中に起きた問題と、その原因と対処を記録する。

## ネットワーク

| 事象 | 原因 | 対処 | 再発防止 |
|---|---|---|---|
| 両機で使っているポートが違っていた（f0 と f1） | 結線時の取り違え | 両機を f0 にそろえた | 両機で同じ物理ポートを使う（NVIDIA の推奨） |
| `ib_write_bw` の帯域が 13.49Gb/s しか出ない | 稼働中にケーブルを抜き差ししたことで、CX-7 が電力を絞った状態になった `[推定]` | 両機を再起動した（再起動後は 108.94Gb/s） | 稼働中はケーブルを抜き差ししない。抜き差しした場合は再起動する（`cx7-pcie-hotplug` が有効なため） |
| 起動時に `insufficient power on the PCIe slot (27W)` と出る | 正常に 200Gb/s 出ている状態でも出るという報告がある `[出典あり]` | 対処しない | 帯域は `ib_write_bw` で判断する |
| nccl-tests のビルドで `nccl.h` が見つからない | `NCCL_HOME` が未設定 | `~/nccl-env.sh` を読み込み、make にパスを明示した | 環境変数はファイルにまとめて管理する |
| nccl-tests の `device_api/gin` でリンクエラーになる | nccl-tests が OpenMPI の C++ バインディングを参照している `[推定]` | 今回は使わないので無視した（必要なバイナリは生成される） | nccl-tests のコミットを固定する |

ケーブルを挿し直したあとの再起動で、`dmesg` には次のように出る。

```
$ sudo dmesg | grep -iE 'insufficient power|PCIe bandwidth|cx7-pcie-hotplug'
[    0.103426] pci 000f:01:00.0: 0.000 Gb/s available PCIe bandwidth, limited by Unknown x0 link at 000f:00:00.0 (capable of 32.000 Gb/s with 2.5 GT/s PCIe x16 link)
[    1.150104] mlx5_core 0000:01:00.0: 126.028 Gb/s available PCIe bandwidth (32.0 GT/s PCIe x4 link)
[    1.533198] mlx5_core 0000:01:00.0: mlx5_pcie_event:326:(pid 12): Detected insufficient power on the PCIe slot (27W).
...
[    5.309621] cx7-pcie-hotplug MTKP0001:00: PCIe hotplug driver initialized successfully
[    5.406738] cx7-pcie-hotplug MTKP0001:00: Hotplug enabled
```

`000f:01:00.0` は CX-7 ではなく GPU のデバイスである。
統合メモリ構成なので、この PCIe 帯域の表示は問題にならない `[推定]`。

## LLM の構築と起動

| 事象 | 原因 | 対処 | 備考 |
|---|---|---|---|
| Hugging Face の `unauthenticated requests` の警告 | トークン未設定 | `.env.dspark` に `HF_TOKEN` を設定した | 公式の重みは同意の手続きがなく、トークンは必須ではない |
| `status-…sh` でヘッドだけ `permission denied ... docker.sock` になる | 今のシェルに docker グループが反映されていない | `newgrp docker` を実行した | 恒久的にはログインし直す |
| `logs-…sh` を grep しても KV キャッシュの値が出ない | 既定では直近 160 行しか表示しない | `TAIL=all` で全体を取得した | |
| `logs-…sh` に `NET/IB` の行が出ない | `NCCL_DEBUG=WARN` のため | RDMA のカウンタで確認する（未実施） | |
| 起動時に `.env.dspark is mode 664` の警告が出る | `.env.dspark` を他のユーザーも読める | `chmod 600 .env.dspark` | `HF_TOKEN` などの秘密情報を含む |
| 起動時に `serving an UNAUTHENTICATED API on 0.0.0.0:8888` の警告が出る | `VLLM_HOST=0.0.0.0` で API キーが未設定 | 意図した設定なので対処していない | 「[LLM の構築](04-llm-deploy.md#vllm_host-についての注意)」を参照 |
| start スクリプトが終了コード 3 で終わる | すでに起動している | 対処不要 | 片方だけ再起動した場合は stop、start する |

レシピの `.env.dspark.example` のコメントによると、起動が NCCL の初期化で数分止まる場合は、`NCCL_GIN_ENABLE=0` にすると comm-init が約 2 分から約 13 秒に短くなったという実測がある `[出典あり]`。
帯域には影響しないとのことである。
この環境では変更していない。

## 起動ログに出る警告

次の警告は起動のたびに出る。
影響の有無は確認していない。

```
WARNING [vllm.py:1648] max_num_scheduled_tokens is set to 8162 based on the speculative decoding settings. This may lead to suboptimal performance. Consider increasing max_num_batched_tokens to accommodate the additional draft token slots, or decrease num_speculative_tokens or max_num_seqs.
WARNING [vllm.py:2149] Model Runner V2 does not yet support the thinking_token_budget request parameter. Set VLLM_USE_V2_MODEL_RUNNER=0 if this is required.
```

`SymmMemCommunicator: Device capability 12.1 not supported` の警告も出る。
GB10 では SymmMem が使えないため、vLLM は all-reduce に `PYNCCL` を使う。
