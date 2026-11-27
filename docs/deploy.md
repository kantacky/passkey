# デプロイ手順

このリポジトリは CI/CD を使わず、ローカルの `gcloud` CLI と Cloudflare `cf` CLI から手動デプロイする。対象環境は本番のみで、構成は設計書 `docs/design.md` の §1、§9、§10 に従う。

## 1. 前提ツール

- mise: Bun 1.4.5 と Node 26.13.1 を `mise.toml` から入れる。
- Bun / Node: `mise install` で入れる。`cf` は npm 依存 (`web/package.json` の `cf` 1.0.0-rc.6) を `bunx cf` 経由で使う。
- Google Cloud CLI (`gcloud`): 認証済みであること。PostgreSQL 18 と `gcloud sql users assign-roles` を使うため最新版に近いものを使う。mise で管理している場合はそのインストールを使う。
- swiftly: server をローカルでビルド・テストするときに使う。Cloud Build でのデプロイそのものには不要。
- Xcode: iOS の Team ID と Associated Domains を設定するときに使う。
- Cloudflare アカウント: `kantacky.com` ゾーンが Cloudflare で有効化済みであること。
- GCP プロジェクト: デプロイ先として作成済みで、課金が有効であること。未作成なら Google Cloud コンソールで作成して課金を有効化する。

初回だけ、次を実行する。

```sh
mise install
cd web && bun install && cd ..
gcloud auth login
gcloud config set project <GCP_PROJECT_ID>
```

## 2. 設定値の場所

デプロイ固有の値は、次の YAML 先頭にある `substitutions` に集約する。

- `server/deploy/cloudbuild-infra.yaml`: 初回インフラ構成
- `server/deploy/cloudbuild.yaml`: 通常のサーバーデプロイ

Cloud Build には設定ファイルをインクルードする仕組みがないため、両方に出る `_GCP_PROJECT_ID`、`_REGION`、`_VPC_NETWORK`、`_VPC_SUBNET`、`_CLOUD_SQL_INSTANCE`、`_DATABASE_NAME`、各サービスアカウント名は同じ値に揃える。`__GCP_PROJECT_ID__` だけは必ず実際のプロジェクト ID に置き換える。Cloud Run 用 YAML (`cloudrun-*.yaml`) はテンプレートで、`__REGION__` などのプレースホルダは手で編集せず、`cloudbuild.yaml` が各デプロイの値とイメージタグで置換する。

主な既定値:

| 値 | 既定 |
| --- | --- |
| リージョン | `asia-northeast1` |
| Artifact Registry リポジトリ | `passkey` |
| VPC / サブネット | `passkey-vpc` / `passkey-subnet` |
| Cloud SQL インスタンス / DB | `passkey-postgres` / `passkey` |
| Cloud Run サービス | `passkey-server` |
| Cloud Run Job | `passkey-migrate`, `passkey-cleanup` |
| サービスアカウント | `passkey-infra`, `passkey-cloudbuild`, `passkey-server`, `passkey-migrator`, `passkey-scheduler`, `passkey-web-proxy` |
| RP ID / Mailgun ドメイン | `passkey.kantacky.com` / `mail.passkey.kantacky.com` |

Web 側の値は `web/cloudflare.config.ts` にある。`CLOUD_RUN_URL` と `APPLE_TEAM_ID` は後述の初回セットアップで実値に置き換える。

## 3. 初回セットアップ

### 3.1 インフラ実行用サービスアカウントのブートストラップ

`cloudbuild-infra.yaml` は専用サービスアカウント `passkey-infra` で実行される。このアカウントは `passkey-cloudbuild` を含むサービスアカウントを作る側なので、例外的に最初だけ手動で作る。`_INFRA_SA_NAME` を変える場合は、この節の `passkey-infra` も同じ名前に読み替える。`passkey-cloudbuild` は infra build が作成し、以後の通常デプロイ専用の権限だけを持つ。プロジェクトオーナー以外が実行する場合は、ビルドを submit するユーザーに Cloud Build Editor (`roles/cloudbuild.builds.editor`) と Service Usage Consumer (`roles/serviceusage.serviceUsageConsumer`) も必要である。

```sh
PROJECT_ID=<GCP_PROJECT_ID>
INFRA_SA="passkey-infra@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud services enable cloudbuild.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com \
  --project "$PROJECT_ID"

gcloud iam service-accounts create passkey-infra \
  --display-name "passkey: infrastructure bootstrap" \
  --project "$PROJECT_ID" 2>/dev/null || true

for role in \
  roles/logging.logWriter \
  roles/storage.objectViewer \
  roles/serviceusage.serviceUsageAdmin \
  roles/compute.networkAdmin \
  roles/artifactregistry.admin \
  roles/cloudsql.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/resourcemanager.projectIamAdmin \
  roles/secretmanager.admin \
  roles/run.admin \
  roles/cloudscheduler.admin
do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:$INFRA_SA" \
    --role "$role"
done

# 実行者がこのサービスアカウントをビルド実行 identity として使えるようにする。
gcloud iam service-accounts add-iam-policy-binding "$INFRA_SA" \
  --member "user:$(gcloud config get-value account)" \
  --role roles/iam.serviceAccountUser
```

`passkey-infra` は広い権限を持つので鍵は作らず、インフラの初期化・変更時だけ使う。通常デプロイには使わない。

### 3.2 インフラ構成の実行

2 つの `cloudbuild-*.yaml` の `_GCP_PROJECT_ID` を実際のプロジェクト ID に置き換え、必要ならリージョンや CIDR も調整したうえで、リポジトリ直下から実行する。

```sh
gcloud builds submit --config server/deploy/cloudbuild-infra.yaml .
```

このビルドは冪等で、不足しているものだけを作る。内容は次のとおり。

- API の有効化
- VPC、サブネット、Private Services Access 用 IP 範囲と peering
- Artifact Registry リポジトリ
- `passkey-cloudbuild`、`passkey-server`、`passkey-migrator`、`passkey-scheduler`、`passkey-web-proxy` のサービスアカウント
- Cloud SQL for PostgreSQL 18（private IP のみ、IAM DB 認証、自動バックアップ、PITR、削除保護）
- `passkey` データベースと IAM DB ユーザー
- Secret Manager の `mailgun-api-key` の枠（値は入っていない）
- 1 時間ごとの Cloud Scheduler `passkey-cleanup-hourly`

DB 権限はこのビルドで次のように付与する。

- `passkey-migrator@<project>.iam`: `cloudsqlsuperuser`（マイグレーション用の DDL。PostgreSQL にはグローバルな DDL-only の事前定義ロールがないため、専用のマイグレーションアカウントに限定して使う）
- `passkey-server@<project>.iam`: `pg_read_all_data` と `pg_write_all_data`（SELECT / INSERT / UPDATE / DELETE の DML。DDL は持たない）。これらは PostgreSQL 既定ロールなのでインスタンス内の全データベースに効く。Cloud SQL インスタンスを他アプリと共有する場合は、Data API で専用ロールを作る構成に置き換える。

Cloud Run サービスと Job はまだ存在しないので、`passkey-web-proxy` と `passkey-scheduler` への resource 単位の `roles/run.invoker` は、最初の通常デプロイで付与される。

### 3.3 Mailgun

1. Mailgun で送信ドメイン `mail.passkey.kantacky.com` を作成し、US / EU のリージョンを選ぶ。
2. 表示された SPF、DKIM、MX、DMARC 用レコードを Cloudflare DNS に登録する。DMARC は設計どおり最初は `p=none` にする。
3. Mailgun 側でドメイン検証が済んだら、開封・クリックトラッキングを無効化する。
4. EU リージョンを選んだ場合は、`server/deploy/cloudbuild.yaml` の `_MAILGUN_API_BASE_URL` を `https://api.eu.mailgun.net` に変える。
5. Sending API key を Secret Manager に登録する。

```sh
read -rs MAILGUN_API_KEY
printf '%s' "$MAILGUN_API_KEY" | gcloud secrets versions add mailgun-api-key \
  --data-file=- \
  --project <GCP_PROJECT_ID>
unset MAILGUN_API_KEY
```

### 3.4 最初のサーバーデプロイ

Secret に少なくとも 1 つのバージョンが入った状態で、リポジトリ直下から実行する。

```sh
gcloud builds submit --config server/deploy/cloudbuild.yaml .
```

この 1 コマンドで、linux/amd64 イメージのビルドと push、`passkey-migrate` の適用と実行、`passkey-server` の適用、`passkey-cleanup` の適用、Worker / Scheduler 用 SA への `roles/run.invoker` 付与まで行う。イメージタグは手動 submit でも必ず存在する Cloud Build の `$BUILD_ID` なので、空の `$COMMIT_SHA` 問題はない。

デプロイ後、Cloud Run URL を取得する。

```sh
gcloud run services describe passkey-server \
  --region asia-northeast1 \
  --project <GCP_PROJECT_ID> \
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
  --iam-account passkey-web-proxy@<GCP_PROJECT_ID>.iam.gserviceaccount.com \
  --project <GCP_PROJECT_ID>
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
  --project <GCP_PROJECT_ID> \
  --limit 1

# Cloud Run サービスの状態と URL
gcloud run services describe passkey-server \
  --region asia-northeast1 \
  --project <GCP_PROJECT_ID>

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
  --project <GCP_PROJECT_ID>

gcloud run services update-traffic passkey-server \
  --region asia-northeast1 \
  --project <GCP_PROJECT_ID> \
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
     --iam-account passkey-web-proxy@<GCP_PROJECT_ID>.iam.gserviceaccount.com \
     --project <GCP_PROJECT_ID>
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
     --iam-account passkey-web-proxy@<GCP_PROJECT_ID>.iam.gserviceaccount.com \
     --project <GCP_PROJECT_ID>
   ```

6. さらに 7 日間問題がなければ削除する。

   ```sh
   gcloud iam service-accounts keys delete "$OLD_KEY_ID" \
     --iam-account passkey-web-proxy@<GCP_PROJECT_ID>.iam.gserviceaccount.com \
     --project <GCP_PROJECT_ID>
   ```

鍵 ID は次で確認できる。

```sh
gcloud iam service-accounts keys list \
  --iam-account passkey-web-proxy@<GCP_PROJECT_ID>.iam.gserviceaccount.com \
  --project <GCP_PROJECT_ID> \
  --managed-by=user
```

## 8. 運用メモ

- `server/deploy/cloudbuild.yaml` の substitutions を変えた場合は、次回の通常デプロイに反映される。
- `db-f1-micro` の PostgreSQL は既定で `max_connections` が 25 程度なので、サーバー側プール 10 に対して Cloud Run `maxScale` は 2 にしてある。スケールアウトが必要なら、先に Cloud SQL の tier / `max_connections` と接続予算を見直す。
- `server/deploy/cloudbuild-infra.yaml` は冪等だが、Cloud SQL や VPC の既存設定をすべて強制的に追従させるものではない。インフラ値を変えるときは変更内容を確認してから再実行する。
- `passkey-cloudbuild` は通常デプロイに必要な `roles/logging.logWriter`、`roles/storage.objectViewer`、`roles/artifactregistry.writer`、`roles/run.admin` と、server / migrator 両サービスアカウント上の `roles/iam.serviceAccountUser` だけを持つ。広いインフラ権限は分離された `passkey-infra` に残るため、infra 再実行時にも権限を付け直す必要はない。
- Cloud SQL を削除するには、まず削除保護を解除する必要がある。削除するとバックアップ運用に影響するため、本番では原則行わない。
- Secret Manager の `mailgun-api-key` を更新した場合、Cloud Run サービスは次のリビジョン作成時に新しい値を読む。通常デプロイを行うか、サービスを更新して再起動する。
