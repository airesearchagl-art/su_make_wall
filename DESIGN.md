# MakeWall Plugin — 実装計画 & アーキテクチャ設計

SketchUp向け「壁描画ツール」プラグイン。Revitの壁ツールに相当する操作感を提供する。

---

## 1. ファイル構成

SketchUp Extension Warehouse のパッケージング規約（`SketchupExtension` + `Sketchup.register_extension`）と、
RubyGems 的なモジュール分離の慣習に従った構成。

```
su_make_wall/
├── su_make_wall.rb              # ★ ローダー（Extensionsフォルダ直下に置く唯一のファイル）
└── su_make_wall/
    ├── main.rb                  # Extension の初期化・メニュー登録
    ├── tool.rb                  # Sketchup::Tool サブクラス（MakeWallTool）
    ├── wall_builder.rb          # ジオメトリ生成ロジック（Tool から分離）
    ├── parameters.rb            # パラメータ保持用 struct / バリデーション
    ├── ui_dialog.rb             # HtmlDialog ラッパー（Step4 以降で実装）
    ├── constants.rb             # 定数定義（デフォルト値・単位など）
    └── dialogs/
        └── settings.html        # HtmlDialog の UI テンプレート
```

### 各ファイルの責務

| ファイル | 責務 |
|---|---|
| `su_make_wall.rb` | `SketchupExtension` 登録、ロード可否チェック |
| `main.rb` | メニュー追加、ツール起動、Extension ライフサイクル |
| `tool.rb` | マウスイベント処理、プレビュー描画（`draw`）、ツール状態管理 |
| `wall_builder.rb` | 座標計算 → Group/Face 生成 → PushPull（純粋な計算・ジオメトリ操作） |
| `parameters.rb` | thickness / height / justification の保持と検証 |
| `ui_dialog.rb` | HtmlDialog の open/close、JS↔Ruby ブリッジ |
| `constants.rb` | `DEFAULT_HEIGHT = 2400.mm` など定数の一元管理 |

### 命名規則・モジュール構造

```ruby
module SuMakeWall
  module Constants; end
  class Parameters; end
  class WallBuilder; end
  class Tool; end          # Sketchup::Tool をミックスイン的に使う
  class UiDialog; end
end
```

> **理由**: トップレベルの汚染を防ぎ、他プラグインとの名前衝突を回避する。

---

## 2. UI アプローチ

### 比較検討

| 観点 | `UI.inputbox` | `UI::HtmlDialog` |
|---|---|---|
| 実装コスト | 極めて低い（1〜2行） | 中程度（HTML/CSS/JS + ブリッジ） |
| 見た目 | OS ネイティブダイアログ（古風） | 完全カスタム（モダン） |
| リアルタイム反映 | 不可（OK を押すまで待つ） | 可能（入力変更でプレビューを即時更新） |
| 拡張性 | 低い（項目追加に手間） | 高い（タブ追加・スライダーなど自由） |
| 学習コスト | なし | HTML/CSS/JS の知識が必要 |
| 初回の動作確認 | 最速 | セットアップに時間がかかる |

### 採用戦略（段階的移行）

```
Step 1-3: UI.inputbox
    ↓ ジオメトリが正しく動くことを確認してから
Step 4:   UI::HtmlDialog に置き換え
```

**Step 1〜3 での `UI.inputbox` 実装（シンプル）:**

```ruby
prompts  = ["Height (mm)", "Thickness (mm)", "Justification (center/left/right)"]
defaults = ["2400", "150", "center"]
input    = UI.inputbox(prompts, defaults, "Wall Parameters")
return unless input  # キャンセル時

height        = input[0].to_f.mm
thickness     = input[1].to_f.mm
justification = input[2].downcase.to_sym
```

**Step 4 での `UI::HtmlDialog` 設計指針:**

- ダイアログはモードレス（ツールと並行して操作可能）
- `dialog.add_action_callback("paramsChanged")` でパラメータ変更を Ruby 側へ通知
- ダイアログを閉じてもパラメータは `Parameters` オブジェクトに保持し続ける
- SketchUp の Toolbar にアイコンボタンを追加し、ダイアログの開閉をトグル

---

## 3. ツールクラス（Sketchup::Tool）の設計

### 状態遷移

```
IDLE → [左クリック] → DRAWING → [左クリック] → 壁生成 → DRAWING (連続)
                                              → [ESC/右クリック] → IDLE
```

```ruby
# tool.rb 骨格
module SuMakeWall
  class Tool

    STATE_IDLE    = :idle
    STATE_DRAWING = :drawing

    def initialize(params)
      @params  = params          # SuMakeWall::Parameters
      @state   = STATE_IDLE
      @start_pt = nil            # Geom::Point3d
      @end_pt   = nil            # Geom::Point3d（マウス追従中）
      @ip_start = Sketchup::InputPoint.new
      @ip_end   = Sketchup::InputPoint.new
    end

    # --- Sketchup::Tool 必須メソッド ---

    def activate
      # カーソル変更、ステータスバー更新
      update_ui
    end

    def deactivate(view)
      view.invalidate
    end

    def resume(view)
      update_ui
      view.invalidate
    end

    def suspend(view)
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      @ip_end.pick(view, x, y)
      pt = @ip_end.position

      case @state
      when STATE_IDLE
        @start_pt = pt
        @ip_start.copy!(@ip_end)
        @state = STATE_DRAWING

      when STATE_DRAWING
        commit_wall(@start_pt, pt)    # ジオメトリ確定
        @start_pt = pt                # 終点を次の始点に（連続描画）
        @ip_start.copy!(@ip_end)
      end

      view.invalidate
    end

    def onRButtonDown(flags, x, y, view)
      # 連続描画を中断して IDLE に戻る
      reset_tool
      view.invalidate
    end

    def onMouseMove(flags, x, y, view)
      @ip_end.pick(view, x, y, @ip_start)   # @ip_start を渡すと軸ロック推定が改善
      @end_pt = @ip_end.position
      view.tooltip = @ip_end.tooltip
      view.invalidate
    end

    def onKeyDown(key, repeat, flags, view)
      if key == VK_ESCAPE
        reset_tool
        view.invalidate
      end
    end

    def draw(view)
      # InputPoint のハイライト描画（スナップ点の十字など）
      @ip_end.draw(view) if @state == STATE_DRAWING

      # プレビュー壁のラバーバンド描画
      draw_preview(view) if @state == STATE_DRAWING && @start_pt && @end_pt
    end

    def getExtents
      # draw() で描画する範囲を返す（カメラの fitTo に利用される）
      bb = Geom::BoundingBox.new
      bb.add(@start_pt) if @start_pt
      bb.add(@end_pt)   if @end_pt
      bb
    end

    def enableVCB?
      true   # VCB（Value Control Box）で長さ入力を受け付ける
    end

    def onUserText(text, view)
      # "3000" または "3000mm" と入力されたら壁の長さを確定
      # 現在の方向を保ちつつ長さだけを上書きして commit
    end

    private

    def commit_wall(pt1, pt2)
      WallBuilder.new(@params).build(pt1, pt2)
    end

    def draw_preview(view)
      verts = WallBuilder.preview_vertices(@start_pt, @end_pt, @params)
      return unless verts

      # 底面の輪郭（4点）
      view.drawing_color = Sketchup::Color.new(0, 120, 215, 180)  # 青半透明
      view.draw(GL_LINE_LOOP, verts[:bottom])

      # 上面の輪郭
      top = verts[:bottom].map { |p| Geom::Point3d.new(p.x, p.y, p.z + @params.height) }
      view.draw(GL_LINE_LOOP, top)

      # 縦辺4本
      verts[:bottom].each_with_index do |bp, i|
        tp = top[i]
        view.draw(GL_LINES, [bp, tp])
      end
    end

    def reset_tool
      @state    = STATE_IDLE
      @start_pt = nil
      @end_pt   = nil
    end

    def update_ui
      Sketchup.status_text = "始点をクリック | ESC: キャンセル"
    end
  end
end
```

### メソッド役割一覧

| メソッド | 役割 |
|---|---|
| `activate` | ツール起動時の初期化、カーソル・ステータスバー設定 |
| `deactivate` | ツール終了時のクリーンアップ |
| `onLButtonDown` | 始点/終点の記録と壁生成のトリガー |
| `onRButtonDown` | 連続描画の中断（IDLE へ戻す） |
| `onMouseMove` | `InputPoint` の更新と再描画要求 |
| `onKeyDown` | ESC でのキャンセル処理 |
| `draw` | ラバーバンド（プレビュー壁）と InputPoint ハイライトの描画 |
| `getExtents` | draw() の描画範囲をエンジンに伝える |
| `enableVCB?` | VCB（寸法入力欄）の有効化 |
| `onUserText` | VCB からの寸法入力を受け取り壁確定 |

### プレビュー（ラバーバンド）の描画アプローチ

- `draw()` は `view.invalidate` のたびに呼ばれる → マウス追従でリアルタイム更新
- `view.draw(GL_LINE_LOOP, points)` でワイヤーフレームを描画
- 塗りつぶしプレビューが必要な場合は `GL_POLYGON` + `view.drawing_color` に alpha を設定
- **重要**: `draw()` 内の描画はビューをダーティにしないため、Operation を開かずに安全に描ける

---

## 4. ジオメトリ計算ロジック

### 問題の定義

始点 `P1`, 終点 `P2`, パラメータ（厚み `t`, 高さ `h`, 基準線 `j`）から
壁の底面を構成する **4頂点** を求める。

```
      左オフセット(d_left)       右オフセット(d_right)
          ←→                        ←→
P1 ──────────────────────────────────── P2    ← 基準線
          ┌──────────────────────────┐
          │            壁            │
          └──────────────────────────┘
    v3(左後)                         v2(右後)
          v0(左前)                   v1(右前)
```

### ベクトル計算

```ruby
# wall_builder.rb
module SuMakeWall
  class WallBuilder

    def initialize(params)
      @params = params
    end

    # ジオメトリを確定してグループを作成
    def build(pt1, pt2)
      verts = compute_bottom_vertices(pt1, pt2)
      return unless verts

      model = Sketchup.active_model
      model.start_operation("Make Wall", true)

      begin
        group    = model.active_entities.add_group
        entities = group.entities

        # 底面の Face を作成
        face = entities.add_face(verts)
        # PushPull で高さを出す（法線方向へ押し出し）
        face.pushpull(-@params.height)   # 負値 = 上方向（Z+）

        model.commit_operation
        group
      rescue => e
        model.abort_operation
        raise e
      end
    end

    # プレビュー用：頂点だけ計算して返す（ジオメトリ生成なし）
    def self.preview_vertices(pt1, pt2, params)
      new(params).send(:compute_vertices_hash, pt1, pt2)
    end

    private

    # 底面の4頂点を計算（反時計回り = SketchUp の表面法線が上向きになる順）
    def compute_bottom_vertices(pt1, pt2)
      h = compute_vertices_hash(pt1, pt2)
      return nil unless h
      # add_face は配列の順番で面を張る
      [h[:bottom][0], h[:bottom][1], h[:bottom][2], h[:bottom][3]]
    end

    def compute_vertices_hash(pt1, pt2)
      # 1. 壁の方向ベクトル（XY 平面に投影）
      dir = (pt2 - pt1)
      dir.z = 0.0
      return nil if dir.length < 0.001  # 同一点はスキップ

      dir.normalize!

      # 2. 法線ベクトル（壁の厚み方向）= dir を Z 軸まわりに 90° 回転
      #    Geom::Vector3d#transform + Geom::Transformation.rotation で計算
      normal = Geom::Vector3d.new(-dir.y, dir.x, 0.0)  # 左手側が +normal

      # 3. 基準線に応じたオフセット量を決定
      t = @params.thickness
      case @params.justification
      when :center
        d_left  =  t / 2.0
        d_right = -t / 2.0
      when :left
        d_left  =  0.0
        d_right = -t
      when :right
        d_left  =  t
        d_right =  0.0
      end

      # 4. 4頂点を算出（底面 Z = pt1.z）
      # normal 方向が「左」、-normal 方向が「右」
      v0 = pt1.offset(normal,  d_left)
      v1 = pt2.offset(normal,  d_left)
      v2 = pt2.offset(normal, -d_right)  # d_right は負値なので注意
      v3 = pt1.offset(normal, -d_right)

      # ※ add_face の頂点順序を反時計回りにして法線を上向きにする
      # 上面の Z 座標は底面 + height
      bottom = [v0, v1, v2, v3]
      top    = bottom.map { |p| Geom::Point3d.new(p.x, p.y, p.z + @params.height) }

      { bottom: bottom, top: top }
    end
  end
end
```

### Justification（基準線）とオフセットの対応図

```
Justification: center
                   P1 ──── P2    ← 基準線（center）
         ┌──────────┤        ├──────────┐
         │  t/2     │        │    t/2   │
         └──────────┴────────┴──────────┘

Justification: left
P1 ──── P2    ← 基準線（left端）
┌─────────────────────────────────────┐
│              t                      │
└─────────────────────────────────────┘

Justification: right
                           P1 ──── P2    ← 基準線（right端）
┌─────────────────────────────────────┐
│              t                      │
└─────────────────────────────────────┘
```

### コーナーの留め継ぎ（マイター）処理（Step5 以降の発展課題）

連続描画した壁のコーナーを綺麗につなぐには、前セグメントと現セグメントの **角の二等分線** を求め、
その方向に各壁端部の頂点をオフセットする。

```
壁A方向ベクトル: dirA
壁B方向ベクトル: dirB
二等分線: (dirA + dirB).normalize

オフセット量 = (thickness / 2) / sin(θ/2)
（θ = 壁A と壁B のなす角）
```

実装上は前セグメントの Group を生成後に `group.entities` を直接編集するか、
頂点を事前に計算してから一括で Group を作るアプローチのどちらかを選択する。
**初期実装ではマイターは省略し、各壁を独立 Group として生成すること。**

---

## 5. 段階的開発ステップ（マイルストーン）

各ステップで **必ず動作確認** してから次へ進む。

---

### Step 1: ツール登録と基本的な線引き確認

**目標:** SketchUp のメニューおよび右クリックコンテキストメニューからツールを起動し、クリックで点が打てることを確認する。

**実装内容:**
- `su_make_wall.rb`（ローダー）を作成
- `main.rb` にメニュー登録とツール起動コードを追加
  - **拡張機能メニュー（Plugins）** に「MakeWall」を追加
  - **右クリック コンテキストメニュー** にも「MakeWall」を追加（`UI.add_context_menu_handler` を使用）
    - ハンドラはモデルのロード後に一度だけ登録（`@menus_registered` フラグで二重登録を防止）
- `tool.rb` に骨格だけの `Tool` クラスを作成（`onLButtonDown` でクリック座標を `puts` するだけ）
- `parameters.rb` に `Parameters` struct を作成（デフォルト値のみ）

**コンテキストメニュー実装例:**
```ruby
UI.add_context_menu_handler do |context_menu|
  context_menu.add_separator
  context_menu.add_item('MakeWall') { SuMakeWall.activate_tool }
end
```

**確認項目:**
- [ ] Plugins メニューに「MakeWall」が表示される
- [ ] 右クリックのコンテキストメニューに「MakeWall」が表示される
- [ ] クリックするとコンソールに座標が出力される
- [ ] ESC でツールが終了する

---

### Step 2: 2D の底面ポリゴン生成

**目標:** 始点と終点の 2 クリックで、XY 平面上に壁の底面（厚みを持つ長方形 Face）が生成される。

**実装内容:**
- `wall_builder.rb` に `compute_bottom_vertices` を実装
- `tool.rb` の `onLButtonDown` で 2 点目クリック時に `WallBuilder#build` を呼ぶ（`pushpull` は高さ 0）
- `UI.inputbox` でパラメータ入力（thickness + justification のみ）

**確認項目:**
- [ ] Center/Left/Right それぞれで正しい位置に Face が生成される
- [ ] 厚みの値が反映される
- [ ] 傾いた方向（斜め 45° など）でも正しく生成される

---

### Step 3: 高さの押し出し（PushPull）とグループ化

**目標:** 生成された壁が 3D のグループとして立ち上がる。

**実装内容:**
- `WallBuilder#build` に `face.pushpull(-@params.height)` を追加
- `entities.add_group` でセグメントを個別グループに包む
- `UI.inputbox` に height を追加

**確認項目:**
- [ ] 指定した高さで壁が立ち上がる
- [ ] Outliner でグループとして表示される
- [ ] 連続クリックで複数の壁グループが生成される

---

### Step 4: ラバーバンド（3D プレビュー）の実装

**目標:** マウス移動中に壁の仮形状がリアルタイムで表示される。コーナー処理で**トリムされる端部を赤くハイライト**し、どの頂点が変形するかをユーザーに事前に伝える。

**実装内容:**
- `tool.rb` の `draw()` に `draw_preview` を実装
- `WallBuilder.preview_vertices` クラスメソッドを実装（ジオメトリ生成なし）
- `onMouseMove` で `view.invalidate` を呼び、`@end_pt` を更新
- **ビジュアルフィードバック:**
  - 通常の壁プレビュー: 青色ワイヤーフレーム（`Constants::PREVIEW_COLOR`）
  - コーナートリム対象の端部（始点側で前セグメントとの接合が発生する頂点）: 赤色ハイライト（`Constants::PREVIEW_COLOR_TRIM`）
  - トリムされる端部の辺を赤で太線描画し、「ここが変形します」を視覚化

**赤ハイライトの判定ロジック（Step 7 マイターと連動）:**
```
前セグメントの方向ベクトル prev_dir が存在 かつ
現セグメントの方向ベクトル curr_dir との角度差が閾値以上
  → @start_pt 側の2頂点（v0, v3）を赤でマーク
```

**確認項目:**
- [ ] マウス追従でワイヤーフレームの壁プレビューが表示される
- [ ] 始点をクリックしていない状態ではプレビューが表示されない
- [ ] ESC または右クリックでプレビューが消える
- [ ] 連続描画中、コーナーになる始点端が赤くハイライトされる

---

### Step 5: InputPoint の洗練（スナップ・推定軸）

**目標:** 既存ジオメトリへのスナップや、SketchUp の推定（青・赤・緑軸ロック）が正しく機能する。

**実装内容:**
- `onMouseMove` で `@ip_end.pick(view, x, y, @ip_start)` を正しく使用
- `draw()` で `@ip_end.draw(view)` を呼び、スナップ点のハイライトを描画
- VCB（`enableVCB?` / `onUserText`）で数値入力をサポート

**確認項目:**
- [ ] 既存エッジの端点にスナップする
- [ ] Shift キーで軸ロックができる
- [ ] VCB に「3000」と入力すると 3000mm の壁が生成される

---

### Step 6: HtmlDialog への UI 移行（オプション）

**目標:** モードレスダイアログでパラメータを随時変更できるようにする。

**実装内容:**
- `ui_dialog.rb` と `dialogs/settings.html` を作成
- `dialog.add_action_callback` で JS → Ruby のパラメータ更新ブリッジを実装
- Toolbar アイコンの追加

**確認項目:**
- [ ] ダイアログを開いたままツールが使える
- [ ] ダイアログのスライダーを動かすとプレビューが変わる
- [ ] ダイアログを閉じてもパラメータが保持される

---

### Step 7: コーナーのマイター処理（発展）

**目標:** 連続描画した壁のコーナーが留め継ぎで綺麗につながる。マイター計算前後でのビジュアルフィードバックを強化する。

**実装内容:**
- `WallBuilder` に前セグメントの方向ベクトルを渡す API を追加
- 二等分線とオフセット量の計算ロジックを実装
- コーナー角度が鋭すぎる場合（< 10°）はマイター省略のフォールバック処理
- **赤ハイライトの本実装（Step 4 で確保したフック点を利用）:**
  - マイター計算で変形する頂点（`v0`, `v3` = 始点側）をプレビュー描画中に赤でハイライト
  - マイター後の確定形状に切り替わる瞬間を強調するアニメーション（色のフェードなど）は将来課題

**確認項目:**
- [ ] 90° コーナーで隙間・重なりなく接合される
- [ ] 45° コーナーで正しいマイター角になる
- [ ] 180°（直線）では通常の壁と同一になる
- [ ] プレビュー中、コーナーになる端部が赤くハイライトされ、確定後に通常色に戻る

---

## 付録: 実装上の注意点

### Units（単位）の扱い

SketchUp の内部単位はインチ。`2400.mm` や `150.mm` のように Ruby の Numeric 拡張を使うと
モデルの単位設定に依存せず確実にミリメートル値を渡せる。

```ruby
# NG: 生の数値
height = 2400

# OK: 単位付き
height = 2400.mm
```

### Operation の使い方

```ruby
model.start_operation("Make Wall", true)   # 第2引数 true = Undo スタックに積む
# ... ジオメトリ操作 ...
model.commit_operation
# エラー時は model.abort_operation
```

### `add_face` の頂点順序

SketchUp は頂点の順序で表面の法線方向を決定する。
底面（Z が低い面）の法線を **上向き（Z+）** にするには、
頂点を **反時計回り（上から見て）** で渡す必要がある。
`pushpull` の符号はこの法線方向に依存するため、頂点順序に注意。

### `face.pushpull` の方向

```ruby
face.pushpull(-@params.height)  # 法線方向（上）へ押し出す場合は負値
# または
face.pushpull(@params.height, true)  # 第2引数 true = 既存の面を修正しない
```

実際の符号は法線方向と height の正負によって変わるため、Step3 で実験して確認する。
