# デプロイ手順

このリポジトリは CI/CD を使わず、ローカルの Terraform・Google Cloud CLI・Cloudflare `cf` CLI から手動デプロイする。対象環境は本番のみで、構成は設計書 `docs/design.md` の §1、§9、§10 に従う。

GCP インフラの正本は `infra/` の Terraform、通常のサーバーデプロイは `server/deploy/cloudbuild.yaml`、Cloud Run の実行時テンプレートは `server/deploy/cloudrun-*.yaml` である。以前の `server/deploy/cloudbuild-infra.yaml` と bootstrap 用 `passkey-infra` サービスアカウントは廃止した。

## 1. 前提ツール

- mise: Bun 1.4.5、Node 26.13.1、Terraform 1.17.2 を `mise.toml` から入れる。
- Bun / Node: `mise install` で入れる。`cf` は npm 依存 (`web/package.json` の `cf` 1.0.0-rc.6) を `bunx cf` 経由で使う。
- Google Cloud CLI (`gcloud`): 認証済みであること。PostgreSQL 18 と Cloud Run の複数コンテナを扱うため最新版に近いものを使う。mise で管理している場合はそのインストールを使う。
- swiftly: server をローカルでビルド・テストするときに使う。Cloud Build でのデプロイそのものには不要。
- Xcode: iOS の Team ID と Associated Domains を設定するときに使う。
- Cloudflare アカウント: `kantacky.com` ゾーンが Cloudflare で有効化済みであること。
- GCP プロジェクト: デプロイ先として作成済みで、課金が有効であること。未作成なら Google Cloud コンソールで作成して課金を有効化する。Terraform を実行するアカウントには、プロジェクトオーナー相当の広い権限が必要である。

初回だけ、次を実行する。

```sh
mise install
cd web && bun install && cd ..
gcloud auth login
gcloud auth application-default login
gcloud config set project kantacky
```

Terraform の Google provider は Application Default Credentials (ADC) を使う。`gcloud auth login` だけでは不足する環境があるため、`gcloud auth application-default login` も行う。

## 2. 設定値の場所

デプロイ固有の値は `infra/terraform.tfvars` に集約する。このファイルはコミットするが、秘密値は入れない。プロジェクト ID は `kantacky`（`project_id = "kantacky"`）。リージョン、VPC、Cloud SQL、Cloud Run、サービスアカウント、RP ID、Mailgun ドメインなどもここで変更する。

例外が 2 つある。

1. Terraform state のバケット名: GCS backend は変数を参照できないため、`infra/backend.tf` の `bucket` を直接編集する。`terraform init -backend-config` などの CLI 引数は使わない。
2. Cloud Build 実行サービスアカウント名: Cloud Build は step 実行前に `serviceAccount` の identity を決めるため、このフィールドは `infra/terraform.tfvars` を読めない。既定の `passkey-cloudbuild` を変える場合だけ、`server/deploy/cloudbuild.yaml` の `serviceAccount` も同じ名前に編集する。ビルド開始時に tfvars との一致を検査する。

`server/deploy/cloudrun-*.yaml` はテンプレートである。`__REGION__` などのプレースホルダは手で編集せず、`cloudbuild.yaml` が `infra/terraform.tfvars` の値とイメージタグで置換する。

主な既定値:

| 値 | 既定 |
| --- | --- |
| リージョン | `asia-northeast1` |
| Artifact Registry リポジトリ | `passkey` |
| VPC / サブネット | `passkey-vpc` / `passkey-subnet` |
| Cloud SQL インスタンス / DB | `passkey-postgres` / `passkey` |
| Cloud Run サービス | `passkey-server` |
| Cloud Run Job | `passkey-migrate`, `passkey-cleanup` |
| サービスアカウント | `passkey-cloudbuild`, `passkey-server`, `passkey-migrator`, `passkey-scheduler`, `passkey-web-proxy` |
| RP ID / Mailgun ドメイン | `passkey.kantacky.com` / `mail.passkey.kantacky.com` |

Web 側の値は `web/cloudflare.config.ts` にある。`CLOUD_RUN_URL` と `APPLE_TEAM_ID` は後述の初回セットアップで実値に置き換える。

## 3. 初回セットアップ

### 3.1 Terraform state バケットの作成

state バケットは Terraform 管理外なので、Terraform を使う前に 1 回だけ `gcloud` で作る。バケット名はグローバルで一意である必要がある。バケット名は `kantacky-passkey-terraform-state` とし、`infra/backend.tf` にも同じ名前を書いてある。別名にする場合は両方を合わせる。

```sh
PROJECT_ID=kantacky
STATE_BUCKET="${PROJECT_ID}-passkey-terraform-state"

gcloud storage buckets create "gs://${STATE_BUCKET}" \
  --project "$PROJECT_ID" \
  --location=asia-northeast1 \
  --uniform-bucket-level-access \
  --public-access-prevention

gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
```

既存バケットを使う場合は、自分のプロジェクトのバケットであること、バージョニング・uniform bucket-level access・public access prevention が有効であることを確認する。

### 3.2 Terraform でインフラを作成

`infra/terraform.tfvars` の `project_id` を実際のプロジェクト IDに書き換えたことを確認し、次を実行する。backend や変数を CLI 引数で渡す必要はない。

```sh
cd infra
terraform init
terraform plan
terraform apply
cd ..
```

Terraform は次を作成する。

- 必要な Google Cloud API の有効化
- VPC、サブネット、Private Services Access 用 IP 範囲と peering
- Artifact Registry リポジトリ
- `passkey-cloudbuild`、`passkey-server`、`passkey-migrator`、`passkey-scheduler`、`passkey-web-proxy` のサービスアカウントと IAM
- Cloud SQL for PostgreSQL 18（private IP のみ、IAM DB 認証、自動バックアップ、PITR、削除保護）
- `passkey` データベースと IAM DB ユーザー
- DB ロール（`passkey-server@<project>.iam` に `pg_read_all_data` / `pg_write_all_data`、`passkey-migrator@<project>.iam` に `cloudsqlsuperuser`）
- Secret Manager の `mailgun-api-key` の枠（値は入っていない）
- Cloud Run サービスと migrate / cleanup Job（プレースホルダイメージ）
- `passkey-web-proxy` と `passkey-scheduler` に対する resource 単位の `roles/run.invoker`
- 1 時間ごとの Cloud Scheduler `passkey-cleanup-hourly`

DB ロールも Terraform の `google_sql_user.database_roles` で付与するため、初回の手動 SQL / `gcloud sql users assign-roles` は不要である。

Cloud Run サービスと Job は、まだアプリイメージが存在しないためプレースホルダイメージで作られる。Terraform は `lifecycle.ignore_changes` で revision template（サービスは traffic も）を無視し、以後のイメージ・コンテナ構成は通常デプロイ側が所有する。初回の Terraform 作成時点では Secret の値がなくてもよいように、プレースホルダ側は `MAILGUN_API_KEY` を参照しない。Secret 参照は通常デプロイの Cloud Run テンプレートで追加される。

`passkey-web-proxy` のサービスアカウント鍵は Terraform では作らない。鍵の内容が Terraform state に残るのを避けるため、後述の Worker 設定で `gcloud` から作成する。

### 3.3 Mailgun

1. Mailgun で送信ドメイン `mail.passkey.kantacky.com` を作成し、US / EU のリージョンを選ぶ。
2. 表示された SPF、DKIM、MX、DMARC 用レコードを Cloudflare DNSに登録する。DMARC は設計どおり最初は `p=none` にする。
3. Mailgun 側でドメイン検証が済んだら、開封・クリックトラッキングを無効化する。
4. EU リージョンを選んだ場合は、`infra/terraform.tfvars` の `mailgun_api_base_url` を `https://api.eu.mailgun.net` に変える。この値は次回の通常デプロイ時に Cloud Run テンプレートへ反映される。
5. Sending API key を Secret Manager に登録する。Secret の値は Terraform に入れない。

```sh
read -rs MAILGUN_API_KEY
printf '%s' "$MAILGUN_API_KEY" | gcloud secrets versions add mailgun-api-key \
  --data-file=- \
  --project kantacky
unset MAILGUN_API_KEY
```

### 3.4 最初のサーバーデプロイ

Secret に少なくとも 1 つのバージョンが入った状態で、リポジトリ直下から実行する。

```sh
gcloud builds submit --config server/deploy/cloudbuild.yaml .
```

このビルドは `infra/terraform.tfvars` を読み、linux/amd64 イメージのビルドと push、`passkey-migrate` へのテンプレート適用と実行、`passkey-server` の適用、`passkey-cleanup` の適用を行う。IAM 付与やインフラ作成は行わない。イメージタグは手動 submit でも必ず存在する Cloud Build の `$BUILD_ID` なので、空の `$COMMIT_SHA` 問題はない。

ビルドは `passkey-cloudbuild` サービスアカウントとして実行される。プロジェクトオーナー以外が submit する場合は、そのユーザーに Cloud Build Editor (`roles/cloudbuild.builds.editor`)、Service Usage Consumer (`roles/serviceusage.serviceUsageConsumer`)、および `passkey-cloudbuild` 上の Service Account User (`roles/iam.serviceAccountUser`) が必要である。

デプロイ後、Cloud Run URL を取得する。

```sh
gcloud run services describe passkey-server \
  --region asia-northeast1 \
  --project kantacky \
  --format='value(status.url)'
```

### 3.5 Cloudflare Worker

1. `web/cloudflare.config.ts` を編集する。
   - `CLOUD_RUN_URL`: 直前に取得した URL（例: `https://passkey-server-xxxxxxxxxx-an.a.run.app`）
   - `APPLE_TEAM_ID`: Apple Developer Team ID
   - `RP_ID` とドメインは既定で `passkey.kantacky.com`
2. `passkey-web-proxy` の鍵を作る。鍵ファイルは絶対にコミットしない。

```sh
mkdir -p "$HOME/.config/passkey"
chmod 700 "$HOME/.config/passkey"
gcloud iam service-accounts keys create "$HOME/.config/passkey/passkey-web-proxy-key.json" \
  --iam-account passkey-web-proxy@kantacky.iam.gserviceaccount.com \
  --project kantacky
chmod 600 "$HOME/.config/passkey/passkey-web-proxy-key.json"
```

3. Cloudflare にログインする。

```sh
cd web
bunx cf auth login
```

4. 初回デプロイ用の secrets file を作る。`web/cloudflare.config.ts` の `bindings.secret()` は必須 Secret として扱われるため、まだ Worker が存在しない初回は Secret なしではデプロイできない。JSON 形式で作り、dotenv の `$VAR` 展開を避ける。

```sh
SECRETS_FILE="$HOME/.config/passkey/cloudflare-secrets.json"
bun -e 'const key=await Bun.file(Bun.env.HOME + "/.config/passkey/passkey-web-proxy-key.json").json(); console.log(JSON.stringify({GOOGLE_SERVICE_ACCOUNT_KEY: JSON.stringify(key)}))' \
  > "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"
```

5. クライアントをビルドし、Secret 付きで初回デプロイする。

```sh
bun run build:client
bunx cf deploy --secrets-file "$HOME/.config/passkey/cloudflare-secrets.json"
rm "$HOME/.config/passkey/cloudflare-secrets.json"
cd ..
```

2 回目以降は Worker が既に存在するので、`bun run deploy` は既存の `GOOGLE_SERVICE_ACCOUNT_KEY` を引き継ぐ。`bun run deploy` は `web/package.json` の定義どおり、`bun run build:client && cf deploy` を実行する。`$HOME/.config/passkey/passkey-web-proxy-key.json` は安全に保管するか削除する。鍵ファイルと secrets file をリポジトリには置かないこと。

`passkey.kantacky.com` のカスタムドメインは `web/cloudflare.config.ts` の `domains` でデプロイ時に設定される。ゾーンのネームサーバーが Cloudflare を向いていない場合は、先にレジストラ側で変更する。

### 3.6 iOS

- Xcode の Signing & Capabilities で、アプリ target に Apple Developer Team を設定する。
- `ios/Passkey/Passkey.entitlements` は本番用に `webcredentials:passkey.kantacky.com` と `applinks:passkey.kantacky.com` が入っている。
- 開発用は `Passkey.development.entitlements` の `?mode=developer` を使う。
- Bundle ID を変える場合は、`web/worker/index.ts` の AASA にある `com.kantacky.Passkey` も合わせて変える必要がある（現在の値を使うなら変更不要）。

## 4. 通常デプロイ

順序は必ず migrate → service → Worker とする。マイグレーションは後方互換（expand → contract）で書く。

### 4.1 migrate と server

リポジトリ直下で次だけを実行する。

```sh
gcloud builds submit --config server/deploy/cloudbuild.yaml .
```

このビルド内で `passkey-migrate` が先に実行され、成功した場合だけ `passkey-server` が更新される。`passkey-cleanup` も同じイメージに更新される。マイグレーションが失敗した場合はビルドが止まり、サービスは更新されない。

Cloud Run の実行時テンプレートに影響する値（例: `origin`、`mailgun_api_base_url`）を `infra/terraform.tfvars` で変えた場合も、このコマンドで反映される。リソース名・VPC・サービスアカウント等のインフラ値を変えた場合は、先に `cd infra && terraform plan && terraform apply` を実行する。

### 4.2 Worker

Cloud Run URL、RP ID、Apple Team ID に変更がないことを確認し、次を実行する。

```sh
cd web
bun run deploy
cd ..
```

Worker だけを変更した場合でも、server 側と API 互換性があることを確認してからデプロイする。server API に依存する変更は、先に server をデプロイする。

## 5. 確認手順

デプロイ後に次を確認する。

```sh
# migrate Job の最新実行が成功していること
gcloud run jobs executions list \
  --job passkey-migrate \
  --region asia-northeast1 \
  --project kantacky \
  --limit 1

# Cloud Run サービスの状態と URL
gcloud run services describe passkey-server \
  --region asia-northeast1 \
  --project kantacky

# Web が返ること
curl -fsSI https://passkey.kantacky.com/ | sed -n '1,8p'

# AASA が JSON で返ること
curl -fsS https://passkey.kantacky.com/.well-known/apple-app-site-association

# Worker → Cloud Run の IAM 認証と API 到達。未認証なのでアプリの JSON で 401 が返ればよい
curl -i https://passkey.kantacky.com/api/v1/me
```

`/api/v1/me` が HTML の 403 になる場合は Cloud Run IAM で拒否されている。Worker の Secret、対象サービスアカウント、`roles/run.invoker`、Cloud Run URL を確認する。アプリの JSON で 401 になる場合は認証基盤まで到達している。

Apple CDN 側の AASA も確認する。キャッシュで反映が遅れることがある。

```sh
curl -fsS 'https://app-site-association.cdn-apple.com/a/v1/passkey.kantacky.com'
```

最後にブラウザでサインアップからサインインまで行い、Mailgun のメール到達、パスキー作成、セッション表示を確認する。iOS は実機で Web 作成済みパスキーによるサインインと、アプリ作成パスキーによる Web サインインを確認する。

## 6. ロールバック

### 6.1 Cloud Run サービス

リビジョンを確認し、直前の正常リビジョンへ 100% 戻す。

```sh
gcloud run revisions list \
  --service passkey-server \
  --region asia-northeast1 \
  --project kantacky

gcloud run services update-traffic passkey-server \
  --region asia-northeast1 \
  --project kantacky \
  --to-revisions=<REVISION_NAME>=100
```

マイグレーション自体は自動では巻き戻さない。expand 段階の変更は旧バージョンでも動く設計にする。contract 済みの変更やデータを壊す変更がある場合は、個別の復旧手順とバックアップ / PITR からの復元を検討する。

### 6.2 Cloudflare Worker

バージョン ID を確認し、以前のバージョンを 100% にする。

```sh
cd web
bunx cf workers versions list --worker passkey-web
bunx cf workers deployments create \
  --worker passkey-web \
  --strategy percentage \
  --versions '[{"version_id":"<VERSION_ID>","percentage":100}]'
cd ..
```

Secret が変わっているためにロールバックが拒否される場合は、Secret を戻すか、影響を理解したうえで `--bypass-deployment-checks` を使う。

## 7. `passkey-web-proxy` 鍵のローテーション

90 日ごとに行う。同時に有効な鍵は最大 2 つまでにする。

1. 新しい鍵を作る。

   ```sh
   mkdir -p "$HOME/.config/passkey"
   chmod 700 "$HOME/.config/passkey"
   gcloud iam service-accounts keys create "$HOME/.config/passkey/passkey-web-proxy-key-new.json" \
     --iam-account passkey-web-proxy@kantacky.iam.gserviceaccount.com \
     --project kantacky
   chmod 600 "$HOME/.config/passkey/passkey-web-proxy-key-new.json"
   ```

2. Cloudflare の Secret を新しい鍵で更新する。

   ```sh
   cd web
   bunx cf workers secrets update GOOGLE_SERVICE_ACCOUNT_KEY \
     --worker passkey-web \
     --type secret_text \
     < "$HOME/.config/passkey/passkey-web-proxy-key-new.json"
   cd ..
   ```

3. `curl -i https://passkey.kantacky.com/api/v1/me` でアプリの JSON 401 が返ることを確認し、必要ならブラウザでサインインを確認する。
4. Cloud Audit Logs で旧鍵が 24 時間使われていないことを確認する。
5. 旧鍵 ID を確認して無効化する。

   ```sh
   OLD_KEY_ID=<OLD_KEY_ID>
   gcloud iam service-accounts keys disable "$OLD_KEY_ID" \
     --iam-account passkey-web-proxy@kantacky.iam.gserviceaccount.com \
     --project kantacky
   ```

6. さらに 7 日間問題がなければ削除する。

   ```sh
   gcloud iam service-accounts keys delete "$OLD_KEY_ID" \
     --iam-account passkey-web-proxy@kantacky.iam.gserviceaccount.com \
     --project kantacky
   ```

鍵 ID は次で確認できる。

```sh
gcloud iam service-accounts keys list \
  --iam-account passkey-web-proxy@kantacky.iam.gserviceaccount.com \
  --project kantacky \
  --managed-by=user
```

## 8. 運用メモ

- インフラ変更は `infra/terraform.tfvars` または `infra/*.tf` を編集し、`cd infra && terraform plan && terraform apply` で行う。`terraform apply` だけでは Cloud Run のアプリイメージは更新されない。アプリ変更は通常デプロイを使う。
- Terraform state には Mailgun API キーと `passkey-web-proxy` 鍵を入れない。Secret Manager の値登録とサービスアカウント鍵作成は、この文档の `gcloud` / Cloudflare 手順で行う。
- `db-f1-micro` の PostgreSQL は既定で `max_connections` が 25 程度なので、サーバー側プール 10 に対して Cloud Run `maxScale` は 2 にしてある。スケールアウトが必要なら、先に Cloud SQL の tier / `max_connections` と接続予算を見直す。
- `passkey-cloudbuild` は通常デプロイに必要な `roles/logging.logWriter`、`roles/storage.objectViewer`、`roles/run.admin`、Artifact Registry の `roles/artifactregistry.writer`、server / migrator 両サービスアカウント上の `roles/iam.serviceAccountUser` を持つ。広いインフラ権限は持たせない。
- Cloud SQL は Terraform 側と GCP 側の両方で削除保護が有効である。削除するには両方を解除する必要があるが、本番では原則行わない。
- Secret Manager の `mailgun-api-key` を更新した場合、Cloud Run サービスは次のリビジョン作成時に新しい値を読む。通常デプロイを行うか、サービスを更新して再起動する。
