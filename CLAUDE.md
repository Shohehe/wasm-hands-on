# CLAUDE.md

Wasm vs Containers ベンチマーク比較プロジェクト。

## 環境

- **ツールチェーン**: devbox（`devbox run --` でコマンド実行。デバッグ時は `devbox shell` で対話シェル）
- **K8s**: k3d クラスタ `wasm-cluster`
- **レジストリ**: ホスト側 `k3d-myregistry.localhost:5050` / クラスタ内 `myregistry:5050`（同一レジストリ、参照名が異なる）
- **DB**: PostgreSQL（`db` namespace、DB名 `crm_wasm` / `crm_containers` で分離）

## クイックスタート

```bash
# セットアップ（クラスタ作成 → ビルド → デプロイ → smoke test）
devbox run -- ./scripts/setup-all.sh

# 全ベンチマーク実行
devbox run -- ./scripts/bench-all.sh

# クリーンアップ
devbox run -- ./scripts/cleanup.sh        # クラスタ + レジストリ
devbox run -- ./scripts/cleanup.sh --all  # + Docker イメージ + ビルド成果物
```

## 個別操作

```bash
# Spin ビルド & push（spin.toml のあるディレクトリで実行）
cd spin-crm/gateway && spin build && spin registry push k3d-myregistry.localhost:5050/spin-crm-gateway:latest --insecure

# Axum ビルド & import
docker build -t axum-crm-gateway:latest axum-crm/gateway/
devbox run -- k3d image import axum-crm-gateway:latest -c wasm-cluster

# デプロイ更新
devbox run -- kubectl rollout restart deployment -n wasm
devbox run -- kubectl rollout restart deployment -n containers

# smoke test
devbox run -- bash scripts/smoke.sh
```

## ディレクトリ構成

```
wasm-hands-on/
├── spin-crm/           # Spin (Wasm) サービス
│   ├── gateway/        #   API Gateway + /compute エンドポイント
│   ├── customer-service/
│   └── order-service/
├── axum-crm/           # Axum (Container) サービス
│   ├── gateway/        #   API Gateway + /compute エンドポイント
│   ├── customer-service/
│   └── order-service/
├── k8s/
│   ├── postgres.yaml   # 共有 PostgreSQL
│   ├── wasm/           # SpinApp マニフェスト
│   └── containers/     # Deployment マニフェスト
├── scripts/
│   ├── setup-all.sh    # 一括セットアップ
│   ├── bench-all.sh    # 全ベンチマーク実行
│   ├── cleanup.sh      # クリーンアップ
│   └── smoke.sh        # 動作確認
├── tests/
│   ├── load-test.js        # k6: CRUD ベンチマーク
│   ├── cpu-bound-test.js   # k6: CPU バウンドベンチマーク
│   ├── availability-test.sh
│   └── resource-test.sh
└── devbox.json
```

## エンドポイント

| パス | 説明 | DB |
|------|------|-----|
| GET /healthz | ヘルスチェック | なし |
| GET /compute?n=1000 | フィボナッチ(n) CPUバウンド | なし |
| GET /customers | 顧客一覧 | あり |
| POST /customers | 顧客作成 | あり |
| GET /customers/{id} | 顧客取得 | あり |
| DELETE /customers/{id} | 顧客削除 | あり |
| POST /orders | 注文作成（顧客存在チェック） | あり |
