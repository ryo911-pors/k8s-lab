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
- （9/29 追記）GPU のクロック・電力に余裕があり、API サーバの CPU も 8割を超えていたので、「天井は GPU の計算」とは言い切れない。上の 4. を参照。

## 3. GPU ノードの自動追加（Cluster Autoscaler）にかかる時間（2026-09-28）

Cluster Autoscaler（Pod Identity で IAM 権限を付与、`helm_release`）を入れ、GPU ノードグループを `max_size = 2` にした。
vLLM を1台で起動したあと `kubectl scale --replicas=2` し、2台目が READY になるまでを K8s のイベントと EC2 の起動時刻から分解した。

| 段階 | かかった時間 | 割合 |
|---|---|---|
| Pending → Autoscaler が増設を依頼（`TriggeredScaleUp`） | 31秒 | 6% |
| EC2 起動 → ノードが Ready | 40秒 | 8% |
| device plugin が GPU を報告 → Pod が配置される | 11秒 | 2% |
| **イメージ（8.7GB）の pull** | **5分21秒** | **64%** |
| vLLM の準備（モデル読み込み 8秒、コンパイル・warmup 31秒ほか） | 1分37秒 | 19% |
| **合計** | **8分21秒** | |

- 「GPU を増やす」こと自体（上の3行）は 1分22秒。全体の 3分の2 は新しいノードへのイメージの pull。**縮めるならここ**。
- `max node group size reached` のイベントで、Terraform の `max_size = 2` の天井で止まることも確認できた。

## 4. GPU 2台でのスループット（2026-09-28〜29）

負荷をかける側は、vLLM とは別の Pod（`loadgen.yaml`）で、CPU ノード（t3.medium）から `vllm bench serve` を実行した。
CPU ノードのディスクが 20GB だと、vLLM のイメージで Evicted になったため、50GB にした。

| 条件（2026-09-29、入力 256 / 出力 128 tokens、同時数200/台） | Output throughput (tok/s) |
|---|---|
| GPU 1台（負荷用 Pod 1つ） | 9,400 / 9,524 |
| GPU 2台（負荷用 Pod 2つを別々のノードに置き、各 GPU に直接） | 9,459 + 9,427 = **18,886（×2.0）** |
| 同上・2回目 | 9,373 + 9,427 = 18,800（×2.0） |
| GPU 1台に負荷用 Pod 2つから 100ずつ | 4,731 + 4,704 = 9,435（1つのときと同じ） |

- **GPU を足した分だけ、そのまま捌ける量が増える（×2.0）**。
- 9/28 に「2台で ×1.66〜1.85」と出たのは、**負荷用 Pod 1つ（t3.medium 1台）で2台分を投げていた**ため。送る側が詰まっていた。
- 送る側を増やしても GPU 1台の値は変わらなかったので、9/29 の 9,400 は送る側ではなくサーバ側の天井。

**未解決: 1台の天井が日によって違う**
- 9/28: 約 11,300 tok/s、9/29: 約 9,400 tok/s（同じ g5.xlarge、同じ設定、同じ測り方）。
- 9/29 の負荷中の GPU は、クロック 1,710 MHz（最大値）、電力 175〜214 W / 上限 300 W、温度 40〜48℃、スロットル理由なし。**GPU の速度制限は起きていない**。
- 同じときの vLLM の CPU 使用率は、API サーバ 82〜84%、EngineCore 58〜61%（コア1つあたり）。API サーバは単一のプロセスなので、**同時数が多いと CPU 側も天井の候補**。
- 9/28 は CPU を記録していなかったため、原因は特定できていない。**比べてよいのは、同じ日・同じ構成で測った比率だけ**。今後は測るたびに `nvidia-smi` と CPU 使用率も記録する。

## 5. イメージ pull を縮める（2026-09-30）

pull 中の GPU ノード全体を1秒ごとに記録した（`pullmon.yaml`：受信量、CPU、ディスク書込、一番忙しいスレッド）。
毎回、GPU ノードを 0 台に戻してから vLLM を置き、CA が 0→1 台に増やしたときの pull を測った。

| 構成 | pull 全体 | 運ぶ（受信） | 開ける（展開） |
|---|---|---|---|
| 最初（gp3 標準 125MiB/s） | 4分8秒 | 約100秒 | 約150秒 |
| gp3 400MiB/s | 2分28秒 / 2分33秒 | 約55秒 | 約100秒 |
| ＋ 大きいレイヤーを分割して並列ダウンロード | **2分17秒** | **約30秒** | 約110秒 |

### 5-1. 最初の詰まりはディスク

- ディスク書込が、pull の最初から最後まで 130MB/s（gp3 標準の上限）に張り付いていた。
- 受信 9.0GB に対して、ディスクには 29.9GB 書いていた（圧縮されたまま置く分と、展開した中身の分）。
- g5.xlarge と EBS の間の帯域は最大 437.5MB/s なので、gp3 を 400MiB/s にした（launch template）。追加は約 $0.015/時間。
- 広げたあと、iowait は平均 8% になり、ディスクは詰まらなくなった。

### 5-2. 「運ぶ」は一番大きいレイヤーで決まっていた

vllm/vllm-openai:v0.30.0（amd64）は 37 レイヤー、合計 8.73GB。**一番大きいレイヤーが 5.11GB（59%）**で、PyTorch と CUDA ライブラリを pip で入れる1つの `RUN` でできている。

- containerd は同時に3つのレイヤーを取る（`max_concurrent_downloads = 3`）。1つのレイヤーは1本の接続で取る。
- 受信は、最初 約300MB/s（小さいレイヤーを3本で）→ 後半 約100MB/s（5.11GB を1本で）。5.11GB ÷ 100MB/s ≈ 51秒で、実測の約55秒とほぼ一致。

### 5-3. 大きいレイヤーを分割して並列で取る

containerd 2.2.7 には、1つのレイヤーを分割して並列で取る機能がある（`concurrent_layer_fetch_buffer`）。
launch template の user_data（nodeadm の NodeConfig）で、4本・64MB ずつに設定した。

- **transfer サービス側に設定しただけでは効かなかった**（pull 2分28秒、受信の形も同じ）。設定がノードに入っていることは確認済み。
- 切り分けのため、GPU ノードから 5.11GB のレイヤーを curl で直接取った：1本で 65.6秒、4本に分けて 23秒。Docker Hub は分割取得に対応しており、原因は containerd 側。
- `use_local_image_pull = true` で CRI の pull をローカル pull に切り替え、そちらにも同じ設定を書くと効いた。**受信は 350〜390MB/s を保ち、「運ぶ」は約55秒 → 約30秒**。
- ただし pull 全体は 11秒しか縮まなかった。以前は運びながら展開も進んでいたが、今は「運ぶ」が先に終わり、展開を待つ形になった。

### 5-4. 残りは「開ける」

- 展開中、一番忙しいスレッドは平均 33%（90%以上の秒は0）。`igzip`（Amazon Linux で containerd が使う高速 gzip）と containerd が交互に動いており、1つの処理が CPU の上限に達しているわけではない。
- 展開は `max_concurrent_unpacks = 1`（1つずつ）。増やしても、5.11GB のレイヤーは1つの処理で展開するので、大きく縮むのは見込めない。
- **根本的には、5.11GB のレイヤーそのものを分ける（イメージを作り直す）必要がある**。

### ついでに見つかったこと：CA が GPU ノードを余分に増やす

ノードが参加した直後、device plugin が GPU を報告するまでの約10秒間に、CA が「GPU が足りない」と判断して2台目を頼むことがある（9/30 は5回中3回）。
1回は、us-east-1b で g5 の在庫がなく（`InsufficientInstanceCapacity`）、CA が台数を 2→1 に戻した。そのとき AWS が **pull 中だった1台目を終了させ**、Pod は2台目で pull をやり直した。余分なお金がかかるだけでなく、スケールアップが遅れる原因にもなる。
