# おうち動画保存 — iPhone / iPadアプリ

SwiftUIで作成したネイティブクライアントです。Macの既存サーバーへ接続し、YouTube動画URLの送信、処理履歴・進捗の表示、完成MP4のiPhoneへの転送、端末内での再生・区間切り取りができます。iOS / iPadOS 16以降が対象です。

## MacでビルドしてiPhoneへインストール

1. MacにAppleのXcodeをインストールします：https://developer.apple.com/xcode/
2. リポジトリを更新します。

```bash
git pull --ff-only
open ios/YouTubeMP4/YouTubeMP4.xcodeproj
```

3. Xcodeの「Settings → Accounts」に自分のApple Accountを追加します。
4. プロジェクト内のTARGETS → YouTubeMP4 → Signing & Capabilitiesで、自分のTeamを選びます。Bundle Identifierが競合する場合は自分専用の値へ変更します。
5. iPhoneをMacへ接続して信頼し、Xcodeの実行先として選択します。端末で開発者モードの許可を求められた場合は、設定の案内に従います。
6. Xcodeの実行ボタン（▶）でビルド・インストールします。署名や端末側の信頼設定が要求されたら、XcodeとiPhoneの表示に従います。

これはXcodeから個人端末へ入れるソースプロジェクトです。署名済みIPA、TestFlight配布、App Store公開は行っていません。署名の有効期間・再署名要否は使うApple Accountや配布方式によります。

## 使い方

1. SSDを接続し、Macで `bash start.command` を起動します。
2. iPhoneを同じWi-Fiへ接続します。
3. Macが表示した `http://192.168.…:ポート/?key=…` をiPhoneアプリの接続欄に貼り付けます。ポートが8766などになった場合も、そのURLを使います。
4. 「接続する」を押し、ローカルネットワークへのアクセスを許可します。
5. YouTube動画URLと画質を指定し、「Macで取得を開始」を押します。
6. Mac側が完了したら「iPhoneに保存」を押します。転送中はアプリを開いたままにしてください。
7. 「iPhoneに保存した動画」から開くと再生できます。Macへ接続していなくても保存済み動画は再生できます。
8. 再生画面のスライダー、現在位置ボタン、秒数入力で開始・終了を設定し、「選択区間を別のMP4に保存」を押します。
9. 「ファイルに保存・共有」から共有メニューを開きます。切り取ったMP4も別のファイルとして共有できます。

動画はアプリのDocuments内に保存されます。ファイルアプリの「このiPhone内 → おうち動画保存」からアクセスできる構成です。切り取り動画は再生画面を閉じると一覧へ反映されます。一覧を下に引いて更新することもできます。削除は一覧を左へスワイプします。Macにあるコピーは別管理です。

## 接続・保存の仕様

- サーバーAPIは既存の `/api/jobs`、`/download/ジョブID` を利用します。Webアプリと同じMacサーバーを使います。
- サーバーで使用中のポートを自動回避する既存機能にも対応します。Macを再起動した場合は新しい接続URLを貼り直します。
- 接続キーはアプリの実行中だけ保持し、UserDefaultsやファイルへ保存しません。再起動時は接続URLの入力が必要です。
- 接続はプライベートIPv4（10.x、172.16〜31.x、192.168.x）または `.local` 名だけ受け付けます。IPv6アドレスの直接入力には未対応です。
- 自宅HTTPサーバーに接続するためATSのHTTP制限を緩和しています。通信自体は暗号化されません。URL入力はアプリ内で上記の接続先に制限します。
- Macでの取得処理はiPhoneアプリを閉じても続きます。iPhoneへの転送と切り取りは前面実行を想定しており、バックグラウンド継続・中断からの再開には対応していません。
- ダウンロードを一時ファイルからDocumentsへ移動するため、iPhoneにも元動画相当の空き容量が必要です。切り取り時は書き出す分の追加容量が必要です。
- 切り取りはApple AVFoundationで再エンコードします。元動画を上書きしません。音声・映像の境界は媒体の時間精度に従い、形式や素材によって書き出しが失敗する場合があります。
- iPhoneの写真アプリへの専用保存ボタン、共有拡張、サムネイル一覧、自動接続、複数区間結合は未実装です。

## 検証と未確認事項

Swift構文パーサーによる構文検査、Info.plistと共有スキームの読み込み、Xcodeプロジェクト内参照の整合性検査は合格しました。既存Macサーバーのテスト8件も合格しています。これらはSwiftの型チェックやiOSビルドの代わりにはなりません。

作成環境はLinuxでXcode・iOS SDKがありません。Xcodeプロジェクトとソースを作成していますが、iOSアプリのビルド、署名、iPhone・iPad実機の通信・再生・書き出しは未確認です。動作保証済みのバイナリーではありません。最初に上記のXcodeビルド・実機確認を行ってください。

## Apple公式資料

- Xcode：https://developer.apple.com/xcode/
- 動画プレーヤー：https://developer.apple.com/documentation/avkit/videoplayer
- 動画書き出し：https://developer.apple.com/documentation/avfoundation/avassetexportsession
- ローカルネットワーク権限：https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription
