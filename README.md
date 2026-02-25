# wasm-hands-on

Zenn記事「コンテナ vs WebAssembly — 同じRust実装をKubernetesで動かして比較してみた」のサンプルリポジトリ。

## 構成

同一仕様のCRMマイクロサービスを **Spin (Wasm)** と **Axum (Container)** の両方でRust実装し、k3d上で比較する。

```
spin-crm/           # Spin (Wasm) サービス
├── gateway/         #   API Gateway + CPUバウンドベンチマーク
├── customer-service/#   顧客CRUD
└── order-service/   #   注文CRUD（顧客存在チェック付き）

axum-crm/           # Axum (Container) サービス
├── gateway/         #   API Gateway + CPUバウンドベンチマーク
├── customer-service/#   顧客CRUD
└── order-service/   #   注文CRUD

k8s/
├── postgres.yaml    # 共有 PostgreSQL (namespace: db)
├── wasm/            # SpinApp CRD マニフェスト (namespace: wasm)
└── containers/      # Deployment マニフェスト (namespace: containers)

tests/
├── load-test.js         # k6: CRUDベンチマーク（Read/Write/Inter-Service/Mixed）
├── cpu-bound-test.js    # k6: CPUバウンドベンチマーク（フィボナッチ）
├── scale-test.js        # k6: スケーラビリティテスト（1→100 VUs）
├── error-test.js        # k6: エラーパステスト（400/404/502）
├── availability-test.sh # Pod kill → リカバリ計測
├── coldstart-test.sh    # コールドスタート計測（0→1スケール）
├── resource-test.sh     # リソース効率比較
└── ping-db-test.js      # k6: DB接続レイテンシ
```

## 前提条件

- Docker Desktop（containerd イメージストア有効化推奨）
- [devbox](https://www.jetify.com/devbox)

devbox が Rust, Spin CLI, k6, kubectl, k3d, Helm をまとめてインストールします。

### ピン留めバージョン

| ツール | バージョン |
|--------|-----------|
| k3d shim image | `ghcr.io/spinframework/containerd-shim-spin/k3d:v0.22.0` |
| cert-manager | v1.14.3 |
| spin-operator | v0.6.1 |
| Spin CLI | v3.5.1 / spin-sdk v5.1.1 |
| k6 | v1.5.0 |
| PostgreSQL | 16-alpine |

## セットアップ（ワンコマンド）

クラスタ作成からビルド・デプロイ・動作確認まで一括で実行します。

```bash
devbox run -- ./scripts/setup-all.sh
```

### 動作確認

```bash
devbox run -- bash scripts/smoke.sh
```

## ベンチマーク（ワンコマンド）

全テスト一括実行。結果は `results/<timestamp>/` に自動保存されます。

```bash
devbox run -- ./scripts/bench-all.sh
```

実行されるテスト:
1. **エラーパステスト** — 400/404/502系のレスポンス確認
2. **CRUD負荷テスト** — Read/Write/Inter-Service/Mixed
3. **CPUバウンドテスト** — フィボナッチ計算
4. **スケーラビリティテスト** — 1→100 VUsでの性能変化
5. **可用性テスト** — Pod kill→リカバリ時間
6. **コールドスタートテスト** — 0→1スケールの起動時間
7. **リソース比較** — CPU/メモリ使用量

### 個別実行

```bash
# port-forward（バックグラウンド）
devbox run -- kubectl port-forward -n wasm svc/gateway 9090:80 &
devbox run -- kubectl port-forward -n containers svc/gateway 9091:80 &

# CRUD 負荷テスト
devbox run -- k6 run -e BASE_URL=http://localhost:9090 tests/load-test.js   # Wasm
devbox run -- k6 run -e BASE_URL=http://localhost:9091 tests/load-test.js   # Container

# CPU バウンドテスト
devbox run -- k6 run -e BASE_URL=http://localhost:9090 tests/cpu-bound-test.js   # Wasm
devbox run -- k6 run -e BASE_URL=http://localhost:9091 tests/cpu-bound-test.js   # Container

# スケーラビリティテスト
devbox run -- k6 run -e BASE_URL=http://localhost:9090 tests/scale-test.js   # Wasm
devbox run -- k6 run -e BASE_URL=http://localhost:9091 tests/scale-test.js   # Container

# エラーパステスト
devbox run -- k6 run -e BASE_URL=http://localhost:9090 tests/error-test.js   # Wasm
devbox run -- k6 run -e BASE_URL=http://localhost:9091 tests/error-test.js   # Container

# 可用性テスト
devbox run -- ./tests/availability-test.sh wasm gateway 5
devbox run -- ./tests/availability-test.sh containers gateway 5

# コールドスタートテスト
devbox run -- ./tests/coldstart-test.sh wasm gateway 5
devbox run -- ./tests/coldstart-test.sh containers gateway 5

# リソース比較
devbox run -- ./tests/resource-test.sh
```

### JSON結果出力

k6テストは `SUMMARY_JSON` 環境変数でJSON結果ファイルを指定できます:

```bash
devbox run -- k6 run -e BASE_URL=http://localhost:9090 \
  -e SUMMARY_JSON=results/crud-wasm.json \
  tests/load-test.js
```

## アーキテクチャの違い（ベンチマーク解釈の注意点）

### 接続プーリング

| | Spin (Wasm) | Axum (Container) |
|--|-------------|------------------|
| **DBコネクション** | リクエスト毎に新規接続 | コネクションプール（max 5） |
| **理由** | Wasm runtime の制約（ステートレス） | Tokio async runtime で接続再利用可能 |
| **影響** | `conn;dur=` が毎回 1-5ms | `conn;dur=` がプール取得時 0.01-0.1ms |

これは Wasm の現在の制約であり、ベンチマークの公平性の問題ではありません。
実運用でもこの差は発生するため、そのまま比較するのが適切です。

### 認証情報について

このプロジェクトのDB認証情報（`crm:crm`）はローカル開発専用です。
k3d クラスタ内でのみ使用され、外部公開されません。

## クリーンアップ

```bash
# クラスタ + レジストリ + port-forward を削除
devbox run -- ./scripts/cleanup.sh

# 上記 + Docker イメージ + Rust ビルド成果物も削除
devbox run -- ./scripts/cleanup.sh --all
```

## 参考

- [SpinKube](https://www.spinkube.dev/)
- [Spin Framework](https://spinframework.dev/v3/)
- [Axum](https://github.com/tokio-rs/axum)
- [k6](https://k6.io/)
