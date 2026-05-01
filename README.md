# WebGPU Path Tracer

WebGPU の compute shader 上で動くインタラクティブなパストレーサー。GLTF シーンを読み込み、リアルタイムにマテリアル / カメラを編集しながらレンダリングできる。

**🌐 デモ**: https://daikiad.github.io/webgpu-path-tracer/

> ⚠️ WebGPU 対応ブラウザが必要です (Chrome/Edge 113+、Safari 18+ on macOS 15+)。

## 機能

- WebGPU compute shader によるリアルタイムパストレーシング
- BVH (Bounding Volume Hierarchy) によるレイ-三角形交差の高速化
- タイル分割 + 累積バッファによるプログレッシブレンダリング
- マテリアル: `Diffuse` / `Specular` / `Dielectrics` / `GGX` / `Light` / `Smoke (Henyey–Greenstein)`
- GLTF (.glb) シーンローダ
- OrbitControls + Three.js デバッグオーバーレイ
- lil-gui によるパラメータ編集 (カメラ / マテリアル / レンダリング設定)
- 編集中は自動でプレビュー解像度に切り替えてチラつきを抑制
- レンダリング結果の PNG エクスポート

## 動かし方

```bash
npm install
npm run dev      # http://localhost:9000
```

その他のスクリプト:

```bash
npm run build         # 本番ビルド (dist/ 出力)
npm test              # vitest によるユニットテスト
npm run type-check    # tsc --noEmit
```

## 技術スタック

- **WebGPU** + **WGSL** (compute shader)
- TypeScript / webpack
- [three.js](https://threejs.org/) — GLTFLoader / OrbitControls / デバッグオーバーレイ
- [webgpu-utils](https://github.com/greggman/webgpu-utils) — WGSL 構造体の JS 側ミラー
- [gl-matrix](https://glmatrix.net/) — 行列演算
- [lil-gui](https://lil-gui.georgealways.com/) — UI

## ファイル構成

| ファイル | 役割 |
| --- | --- |
| [src/main.ts](src/main.ts) | エントリ + フレームループ |
| [src/PathTracer.ts](src/PathTracer.ts) | WebGPU リソース管理 + compute dispatch |
| [src/shader.wgsl](src/shader.wgsl) | パストレーシング compute shader |
| [src/Scene.ts](src/Scene.ts) | BVH 構築 + GLTF ローダ + シーン編集 |
| [src/Material.ts](src/Material.ts) | マテリアル定義 (BRDF / 媒質) |
| [src/Camera.ts](src/Camera.ts) | カメラ + OrbitControls + デバッグ overlay |
| [src/ui.ts](src/ui.ts) | lil-gui パネル組み立て |
