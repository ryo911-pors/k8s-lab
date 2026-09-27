# RESULTS

EKS の GPU ノードで vLLM を動かした実験結果。実験ごとに追記する。

## 環境

| 項目 | 値 |
|---|---|
| クラスタ | EKS 1.36（us-east-1）、Terraform で構築 |
| GPU ノード | g5.xlarge × 1（NVIDIA A10G 23GB、4 vCPU）、AMI `AL2023_x86_64_NVIDIA` |
| CPU ノード | t3.medium × 2 |
| GPU の認識 | NVIDIA device plugin（Helm chart 0.20.1） |
| vLLM | `vllm/vllm-openai:v0.30.0` |
| モデル | Qwen/Qwen2.5-0.5B-Instruct（bf16） |

## 1. 起動（2026-09-26）

| 観察 | 値 |
|---|---|
| Pod 作成 → Running（初回、イメージ 9GB の pull 込み） | 4分33秒 |
| 2回目以降の起動（イメージはノードにキャッシュ済み） | 約1分半で READY |
| モデル本体の GPU メモリ | 0.93 GiB |
| KV キャッシュに割り当てられた GPU メモリ | 18.51 GiB（1,617,120 tokens） |
| 32,768 tokens のリクエストの最大同時数（vLLM の見積り） | 49.35 |

**わかったこと**

- readinessProbe が無いと、vLLM がモデルを読み込み中でも `READY 1/1` になる（約1分以上のずれ）。`/health` を probe にすると準備完了まで READY にならない。
- GPU 1枚でローリングアップデートすると、新しい Pod が `Insufficient nvidia.com/gpu` で Pending のまま進まない。`strategy: Recreate` が必要（代わりに入れ替え中は止まる）。
- `replicas: 2` にしても2台目は Pending。GPU クォータ 4 vCPU = g5.xlarge 1台が天井。
- Service を `vllm` という名前で Pod より先に作ると、K8s が `VLLM_PORT=tcp://<ClusterIP>:80` を Pod に自動注入し（service links）、vLLM が `ValueError: VLLM_PORT ... appears to be a URI` で起動失敗する。Pod を先に作った初回は再現しなかった（作る順番で結果が変わる）。`enableServiceLinks: false` で解消。
- NVIDIA device plugin は Terraform の `helm_release` で入れる。`terraform apply` 1回で GPU が `allocatable: 1` になるところまで揃う。

## 2. 同時リクエスト数とスループット

`vllm bench serve` を Pod の中から実行。入力 256 tokens / 出力 128 tokens のランダムな質問。

```
kubectl exec deploy/vllm -- vllm bench serve --model Qwen/Qwen2.5-0.5B-Instruct \
  --dataset-name random --random-input-len 256 --random-output-len 128 \
  --num-prompts <N> --max-concurrency <C>
```

| 同時数 | 問題数 | Output token throughput (tok/s) | Mean TPOT (ms) | Mean TTFT (ms) |
|---|---|---|---|---|
| 1 | 50 | 291.48 | 3.34 | 15.04 |
| 10 | 200 | 2381.32 | 3.82 | 51.88 |
| 50 | 500 | 7165.01 | 5.80 | 151.48 |
| 100 | 1000 | 9943.78 | 8.08 | 254.95 |
| 200 | 2000 | 10134.74 | 15.55 | 507.06 |

**わかったこと（2026-09-27）**

- 1 → 10: throughput ×8.2、TPOT +14%。1人のときは GPU がほぼ遊んでいた（vLLM がリクエストをまとめて1回の forward に載せる = continuous batching の効果）。
- 10 → 50: throughput ×3.0。伸びが鈍り始める。
- 50 → 100: throughput ×1.39、TPOT ×1.39。人数を増やした分だけ1人ずつ遅くなる領域に入った。
- 100 → 200: throughput ×1.02（ほぼ横ばい、約 10,000 tok/s）、TPOT ×1.92、TTFT ×2。**A10G 1枚・0.5B モデルの天井は約 10,000 output tok/s**。ここから先は待ち時間が延びるだけ。
- KV キャッシュ（1,617,120 tokens）は 200 × 384 tokens ≈ 77k tokens に対して十分余裕があり、天井の原因ではない（計算側が先に詰まった）。
- 但し書き: ベンチのクライアントも vLLM と同じ Pod 内で動かしている。高い同時数ではクライアント側の CPU が影響している可能性がある。
- ベンチ中（同時数200）に `nvidia-smi` を1秒ごとに見ると、`utilization.gpu` はほぼ 100% に張り付き、`memory.used` は 22,004 MiB のまま変わらなかった。KV キャッシュは起動時に確保済みで、負荷で増えない。**メモリは余っていて、計算が埋まっている** → 天井は計算側、の裏付け。
- ただし `utilization.gpu` は「何かのカーネルが動いていた時間の割合」であり、SM（演算器）を使い切っているという意味ではない。使い切り度合いを見るにはプロファイラ（Nsight など）が必要。
