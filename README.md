# PentagramSimulator (五行シミュレーター)

> [!CAUTION]
> **注意：このシミュレーションを実行すると、世界に影響を与える可能性があります。**
> 本プログラムは五行思想（木・火・土・金・水）の相互作用を計算するための高度なエミュレーションです。実行中の環境や周囲の事象に予期せぬ変化が生じる可能性があることをご理解の上、ご使用ください。

## 概要
五行の相生・相剋関係を粒子系としてシミュレートする Metal ベースのアプリケーションです。
ベイズ最適化（Bayesian Optimization）を用いた平衡状態の探索機能を備えています。

## システム要件
- **OS**: macOS 14.0以上 / iOS 17.0以上
- **開発環境**: Xcode 15.0以上 / Swift 5.9以上
- **GPU**: Metal 対応デバイス

## ビルド・実行方法

### 1. リポジトリをクローン
```bash
git clone git@github.com:ToyotakaTodoroki/PentagramSimulator.git
cd PentagramSimulator
```

### 2. コマンドラインからの実行
Swift Package Manager を使用して直接ビルド・実行できます。
```bash
swift run
```

### 3. Xcode を使用する場合
`Package.swift` を Xcode で開くことで、GUI 環境での開発・デバッグが可能です。
```bash
open Package.swift
```

## セキュリティ・プライバシー
本プロジェクトは、外部への通信やデータの送信は一切行いません。シミュレーションはすべてローカルの GPU 上で完結します。

## ライセンス
MIT License
