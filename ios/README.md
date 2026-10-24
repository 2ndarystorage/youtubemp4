# おうち動画保存 — iPhone単体版 v1.1

iPhone / iPad内でYouTube動画の取得・MP4保存・再生・区間切り取りを行うSwiftUIアプリです。利用時はMac、外付けSSD、自宅Wi-Fi、接続キー、変換サーバーを必要としません。インターネット接続とiPhone本体の空き容量が必要です。

## 変更内容

- Mac接続欄、接続キー、サーバーAPI呼び出し、履歴ポーリングを削除しました。
- YouTubeKit 0.4.9（MIT）をSwift Package Managerで組み込み、`methods: [.local]` を指定しています。外部抽出サービスへのremote fallbackは使用しません。
- URLから動画IDを検証し、指定上限以下で端末が再生可能なMP4映像を選択します。
- 映像・音声が同じファイルなら両トラックを検証してMP4保存します。
- 映像・音声が別々の場合は、それぞれを取得し、Apple AVFoundationで結合・再エンコードしてMP4を書き出します。
- キャンセルボタン、転送段階の進捗、書き出し中の表示を用意しました。再エンコード中の割合・完了予想時間は表示しません。
- ローカルネットワーク利用権限とATSのHTTP制限緩和を削除しました。

YouTubeへのアクセス自体はインターネット経由です。「単体」は抽出・結合・保存の処理場所がiPhoneである意味で、YouTubeからの取得までオフラインでできる意味ではありません。

## インストール

iOS / iPadOS 16以降、Xcode 15以降（依存ライブラリはSwift 5.9以降）が対象です。対応するOS・Xcodeの組み合わせでビルドしてください。

現在提供しているのはソースプロジェクトです。署名済みIPAやTestFlight配布は未作成です。初回ビルド・インストールにはMacのXcodeと自分のApple Accountを使います。インストール後の動画処理ではMacは不要です。

```bash
git pull --ff-only
open ios/YouTubeMP4/YouTubeMP4.xcodeproj
```

1. XcodeがYouTubeKitパッケージを取得するのを待ちます。
2. TARGETS → YouTubeMP4 → Signing & Capabilitiesで自分のTeamを選択します。必要ならBundle Identifierを自分専用の値に変更します。
3. iPhoneを接続して実行先に選択し、▶でビルド・インストールします。端末の信頼や開発者モードの案内が出た場合は従います。

ソースを変更しただけでは、すでにインストールしたアプリは更新されません。再ビルド・インストールしてください。同じBundle Identifierで更新すれば保存領域を継続利用できる構成ですが、アプリ削除時には保存データも削除されます。

## 使い方

1. アプリへ単体のYouTube動画URLを貼り付けます。通常のwatch URL、youtu.be、Shortsなどに対応します。
2. 画質上限（360p / 720p / 1080p）を選びます。
3. 「iPhoneで取得・MP4保存」を押します。
4. 完了後に「保存した動画」から再生します。
5. 再生画面で開始・終了位置を選び、別のMP4へ切り取れます。
6. 「ファイルに保存・共有」でファイルアプリ等へ書き出せます。

処理中はアプリを開いたままにしてください。取得処理中は自動ロックを抑止し、終了後に元の設定へ戻します。ホーム画面へ移動した場合や画面をロックした場合の完了保証・自動再開は実装していません。

## 制限

- YouTubeKitは非公式の抽出ライブラリです。公開動画でもYouTube側の仕様変更・地域・接続環境・HTTP 403などで取得できない場合があります。取得失敗時に外部変換サーバーへ切り替えません。
- ログイン、Cookie取り込み、有料・非公開・年齢制限動画やアクセス制限の回避には対応しません。配信中ライブと再生リストの一括取得も対象外です。
- 画質は上限です。指定した解像度の取得を保証しません。対応形式がなければエラーにします。
- 開始前の空き容量は1GiB以上を目安にチェックしますが、必要量を保証するものではありません。映像＋音声＋完成MP4の合計容量が必要です。切り取りは追加ファイルを作ります。
- 取得ファイルは個別に2GiBまでです。サーバーの上限とは別の端末内制限です。上限超過で転送をキャンセルした場合、通信中断として表示されることがあります。
- 同時処理は1件です。未完了のダウンロードの再開・キューの永続化は未実装です。
- 完成動画はアプリのDocumentsに保存します。一時データは処理終了時に片付けますが、OSがアプリを強制終了した場合は一時ファイルが残る場合があります。
- ファイルアプリの「このiPhone内 → おうち動画保存」へ公開する設定です。写真アプリ専用の保存ボタンや共有拡張は未実装です。
- 元のMac版Webアプリは別機能として残っています。iPhone単体版からは呼び出しません。

## 検証範囲

作成環境にはXcodeとiOS SDKがありません。Swift構文検査、Info.plist・共有スキーム読み込み、XcodeプロジェクトとSwift Package Managerの参照整合性を確認します。これらはSwiftの型チェック・Apple SDKでのビルド・実機検証の代替にはなりません。

GitHub Actionsに署名不要のiOS Simulatorビルドを追加しています。実行結果はリポジトリのActionsで確認できます。実機のYouTube取得・音声付きMP4保存・再生・切り取りが成功したことは、まだ確認していません。

## 使用ライブラリと一次資料

- YouTubeKit：https://github.com/alexeichhorn/YouTubeKit/tree/0.4.9
- YouTubeKit MITライセンス：アプリ内「使用ライブラリとライセンス」に表示し、ソースにも同梱しています。
- Apple動画プレーヤー：https://developer.apple.com/documentation/avkit/videoplayer
- Apple動画書き出し：https://developer.apple.com/documentation/avfoundation/avassetexportsession
- Xcode：https://developer.apple.com/xcode/
- YouTube利用条件：https://www.youtube.com/static?template=terms

取得・保存する権限とYouTubeの利用条件を確認した動画に使用してください。
