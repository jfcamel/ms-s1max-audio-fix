# MS-S1 MAX (Strix Halo / Gentoo) オーディオ修正記録

- **日付**: 2026-09-02
- **マシン**: Minisforum MS-S1 MAX (Strix Halo, board vendor: Shenzhen Meigao)、hostname `nitrogen`
- **カーネル**: 6.18.41-gentoo / **サウンドサーバ**: PipeWire 1.6.7 + WirePlumber
- **症状**: whisper-cli を含むあらゆるアプリで音声入力が検知されない。3.5mm ジャックに挿しても認識されない。HDMI 経由の音声出力だけは正常。

---

## 1. 結論 (TL;DR)

**BIOS が HDA コーデック (Realtek ALC245) に伝えるピン設定 (Pin Default Config) が、基板の実配線と食い違っていた。**

- BIOS は「ヘッドホン = ピン 0x21、マイク = ピン 0x19、内蔵マイク = ピン 0x12」と申告していたが、これらのピンは**どこにも配線されていない**。
- 実際のジャックは **ピン 0x17 (出力) と 0x18 (入力)** に配線されている。
- その結果、ジャック検出は常に「未接続」、録音デバイスは「実在しない内蔵マイク」がデフォルトとなり、**浮いた入力ピンを 60dB 増幅したゴミ信号**が録れていた。whisper-cli が音声を検知できなかった直接原因はこれ。

修正として、カーネルの HDA パッチ機構でピン設定を上書きした。ドライバやカーネルのバグではなく、**BIOS の設定データの誤り**をカーネル側で矯正した形。

---

## 2. 前提知識: HDA コーデックと Pin Default Config

理解に必要な最小限の仕組み:

- **HDA (High Definition Audio)** コーデックは、DAC/ADC/ミキサー/ピン (物理端子) が内部グラフとして繋がったチップ。今回は Realtek ALC245 (vendor id `0x10ec0245`)。
- コーデックのどのピンが物理的に何に繋がっているか (前面ヘッドホンジャック、内蔵スピーカー、等) は**チップ自身は知らない**。基板を設計したメーカーが **BIOS に Pin Default Config (32bit 値) を書き込み**、起動時にコーデックへ設定する。
- Linux の `snd-hda-intel` ドライバはこの Pin Default Config を読んで、「このピンはヘッドホンジャック」「このピンは使われていない」と判断し、ALSA デバイスやミキサー、ジャック検出を組み立てる (autoconfig)。
- **つまり BIOS の申告が間違っていると、ドライバは完全に正常でも、実在しない端子を有効化し、実在する端子を無効化してしまう。** 今回はまさにこれ。

Pin Default Config 32bit のフィールド (参考):

| ビット | 意味 | 例 |
|---|---|---|
| 31:30 | 接続性 (00=ジャック, 01=未接続, 10=固定内蔵) | `0x4.......` = 未接続 |
| 29:24 | 位置 (0x01=背面, 0x02=前面, ...) | |
| 23:20 | デバイス種別 (0x2=HP Out, 0xA=Mic In, ...) | |
| 19:16 | 端子形状 (0x1=3.5mm) | |
| 15:12 | 色 (0x4=緑, 0x9=ピンク) | |
| 7:4 / 3:0 | グループ番号 / シーケンス | |

`0x411111f0` は「未接続 (このピンは使うな)」を意味する慣用値。

---

## 3. 診断の経緯 (証拠の連鎖)

### 3.1 一見正常に見えた層

```
$ aplay -l          # HDMI (card0) と ALC245 Analog (card1) 両方見える
$ lsmod | grep snd  # snd_hda_intel, snd_hda_codec_alc269 など全部ロード済み
```

ドライバのロード・コーデック検出のレベルでは異常なし。「ドライバが認識されていない」ように見えたのは、この下の層の問題だった。

### 3.2 PipeWire 層の異常

`wpctl status` で **アナログ出力 sink が存在しない**。`pactl list cards` で理由が判明:

- `Headphone Jack: off` / `Mic Jack: off` — ジャック検出が「何も挿さっていない」と報告
- 唯一の出力ポート (Headphones) が unavailable → WirePlumber が出力プロファイルを無効化
- 入力は「Internal Mic」ポートが選択されていた (Phantom Jack = 常に存在扱い)

### 3.3 録音してみると「無音」ではなく「ゴミ」だった

デフォルトソース (Internal Mic = ピン 0x12) から 5 秒録音して解析:

```
rms=21546 / 32767 (ほぼフルスケール)、-32768 に張り付いた DC、クリップ多発
```

これは**どこにも配線されていない入力ピンを Mic Boost +30dB × Capture +30dB で増幅したときの典型波形**。マイクが物理的に存在しないのに、BIOS が「内蔵マイクあり (Fixed)」と申告していたせいで、これがデフォルト録音源になっていた。whisper-cli はこのゴミを受け取っていた。

### 3.4 決定的証拠: ピンの物理検出を直接読む

`hda-verb` でコーデックの各ピンに GET_PIN_SENSE (verb 0xf09) を発行。bit31 (0x80000000) が立っていれば「プラグが物理的に挿さっている」:

```
$ for nid in 0x12 0x14 0x17 0x18 0x19 0x1a 0x1b 0x21; do
    sudo hda-verb /dev/snd/hwC1D0 $nid 0xf09 0
  done
```

| ピン | BIOS の申告 | 実測 pin sense |
|---|---|---|
| 0x21 | ヘッドホンジャック (有効) | **0x0 = 何も無い** |
| 0x19 | マイクジャック (有効) | **0x0 = 何も無い** |
| 0x12 | 内蔵マイク (有効・Fixed) | 0x0 |
| **0x17** | 「未接続」として無効化 | **0x80000000 = プラグ検出!** |
| **0x18** | 「未接続」として無効化 | **0x80000000 = プラグ検出!** |

ユーザーが挿していたプラグは 0x17/0x18 で検出されていた。**BIOS が有効化しているピンと、実際に配線されているピンが完全に入れ替わっている。**

---

## 4. 適用した修正

### 4.1 ライブでの修正 (再起動不要の検証)

Gentoo カーネルに `CONFIG_SND_HDA_RECONFIG=y` があったので、sysfs から動的にピン設定を上書きして検証した:

```bash
# PipeWire を止めてデバイスを解放
systemctl --user stop wireplumber pipewire-pulse.socket pipewire-pulse pipewire.socket pipewire

# ピン設定を上書き
cd /sys/class/sound/hwC1D0            # = card1 の codec#0
echo "0x12 0x411111f0" > user_pin_configs   # 実在しない内蔵マイクを無効化
echo "0x19 0x01a19030" > user_pin_configs   # Rear Mic として残す (配線可能性あり・後述)
echo "0x21 0x411111f0" > user_pin_configs   # 未配線の HP ピンを無効化
echo "0x17 0x0221401f" > user_pin_configs   # ← 本物の出力: 前面 HP ジャック (緑)
echo "0x18 0x02a19020" > user_pin_configs   # ← 本物の入力: 前面 Mic ジャック (ピンク)
echo "0x1a 0x01a19040" > user_pin_configs   # 予備の入力候補
echo 1 > reconfig                            # コーデックを再構成

systemctl --user start pipewire.socket pipewire-pulse.socket pipewire wireplumber pipewire-pulse
```

再構成後の結果:

- `dmesg`: `autoconfig for ALC245: line_outs=1 (0x17...) type:hp` / `inputs: Front Mic=0x18, Rear Mic=0x19`
- ジャック検出が正常化: `Front Headphone Jack: on` / `Mic Jack: on` (**挿さっているものを正しく検出**)
- PipeWire にアナログ出力 sink「Ryzen HD Audio Controller Analog Stereo」が出現

### 4.2 永続化 (再起動後も有効にする)

sysfs の設定は再起動で消えるため、カーネルの **HDA patch loader** (`CONFIG_SND_HDA_PATCH_LOADER=y`) で起動時に同じ設定を適用する。

**`/lib/firmware/hda-ms-s1max.fw`** (ピン設定パッチ本体):

```
[codec]
0x10ec0245 0x1f4cb026 0        ← vendor id / subsystem id / コーデックアドレス。
                                  一致するコーデックにだけ適用される安全装置

[pincfg]
0x12 0x90a60120
0x21 0x411111f0
0x17 0x0221401f
0x18 0x411111f0
0x19 0x02a19130
0x1a 0x411111f0

[verb]
0x20 0x500 0x45
0x20 0x400 0xd689
0x20 0x500 0x4a
0x20 0x400 0xa1f0
0x20 0x500 0x67
0x20 0x400 0x3000
0x20 0x500 0x63
0x20 0x400 0x8000
0x57 0x500 0x05
0x57 0x400 0x3680
```

最終構成: 出力 = 0x17 (Front HP)、入力 = **0x12 (内蔵 DMIC x2、デフォルト) + 0x19 (ヘッドセットマイク)**。他ピンは無効。

**0x12 (Internal Mic) について**: 前面パネルの DMIC x2 はコーデックの pin 0x12 に直結しており、BIOS の申告値 `0x90a60120` ([Fixed] Mic at Int) は正しかった (診断初期に「実在しない」と誤断して一時無効化していた)。初期に 0x12 から録れたフルスケールのガベージは、Boost+Capture 合計 +60dB の過大ゲインと、CTIA COEF 設定前の状態が原因だったとみられる。現在はステレオ (L/R 独立) で高感度に動作し、音響ループバックで 440Hz=18000+ を検出。適正ゲインは Internal Mic Boost=1 (+10dB)。

**0x19 の NO_PRESENCE ビット (misc bit0) について**: 0x19 のジャック検出線は未配線で、検出を有効にすると常に「未接続」と報告されポートが unavailable 扱いになる。ALSA→PipeWire プラグインは**アクティブポートが unavailable だと `Unable to install hw params` で失敗する** (pw-record は成功するのに arecord だけ失敗する、という紛らわしい症状になる)。NO_PRESENCE を立てるとドライバは「このジャックに検出機構は無い」と解釈し、ポートは常に選択可能になる。

**`[verb]` セクションについて**: マイクを実際に動かすにはピン設定だけでは不足で、Realtek 固有の COEF レジスタで「CTIA ヘッドセットモード」を設定する必要があった (§5 参照)。`[verb]` の内容は node 0x20 (COEF インターフェース) への index/value 書き込みペアで、意味は: `0x45=0xd689` (CTIA モード、[15:10]=0x35)、`0x4a=0xa1f0` (ヘッドセット判定後の確定値)、`0x67=0x3000`、`0x63=0x8000` ([15:14]=2 — **これが CTIA variant 1。1<<14 だとマイクは死ぬ**)、coefex 0x57:05 bit14 クリア。パッチの verb は codec の init_verbs リストに入り、**ブート時と S3 レジューム時に再適用される**。runtime PM (D3→D0) については `alc225_init`/`alc225_shutup` (ドライバの hook) がこれらのレジスタを触らないことをソースで確認済みなので保持される (0x4a[5:4] のみ suspend で 3→2 になるが、その値でも動作することを実測確認済み)。

**`/etc/modprobe.d/hda-ms-s1max.conf`**:

```
options snd-hda-intel patch=hda-ms-s1max.fw,hda-ms-s1max.fw
```

`patch=` はカード順に適用されるため 2 回書いてある (card0 = GPU の HDMI audio、card1 = ALC245。HDMI 側は `[codec]` の ID が一致しないので無視される)。

**再起動後の適用確認**:

```bash
sudo dmesg | grep autoconfig
# → 「line_outs=1 (0x17/...)」「Front Mic=0x18」が出ていれば適用成功
```

### 4.3 その他の変更

- デフォルト出力 sink は従来どおり **HDMI に戻した** (`pactl set-default-sink alsa_output.pci-0000_f4_00.1.hdmi-stereo`)。前面ジャックを使うときは KDE の音声設定でアナログを選択する。

### 4.4 ALSA → PipeWire ブリッジの有効化 (再起動後に発覚した第 2 の問題)

再起動後、ピンパッチは正常適用されていた (`dmesg` に `Applying patch firmware 'hda-ms-s1max.fw'`) にもかかわらず、素の `arecord` が「device が見つからない」エラーになった。

**原因**: ALSA アプリが使う `default` デバイスが PipeWire にルーティングされていなかった。

- Gentoo の `alsa.conf` (`/usr/share/alsa/alsa.conf`) が読む設定ディレクトリは `/etc/alsa/conf.d` など (7〜15 行目の `@hooks`)
- 一方 pipewire パッケージがブリッジ設定 (`50-pipewire.conf` / `99-pipewire-default.conf`) を置くのは **`/usr/share/alsa/alsa.conf.d/`** で、こちらは読まれない
- 結果、`default` は素の ALSA 定義 (dsnoop → card 0 = HDMI) に解決され、card 0 にはキャプチャデバイスが無いため `pcm_dsnoop.c ... unable to open slave` で失敗
- `arecord -D hw:1,0` の直接指定は成功していたことから、カーネル層は正常・ALSA ユーザースペース設定の問題と切り分けられた

**修正** (Gentoo で PipeWire を使う場合の定石):

```bash
sudo mkdir -p /etc/alsa/conf.d
sudo ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d/
sudo ln -sf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d/
```

これで `arecord`/`aplay`/whisper-cli など ALSA 経由のアプリはすべて PipeWire に接続され、PipeWire のデフォルト source/sink とデバイス選択がそのまま効くようになる。以前 `speaker-test -D pulse` が失敗していたのも同根 (pulse 互換もこのブリッジ経由)。

---

## 5. マイクの本丸: Realtek CTIA ヘッドセットモード (COEF レジスタ)

ピン修正後もマイクは無音のままだった。RMS レベルだけで「0x1a がマイク線」と誤判定しかけた (実際はバイアス充電の過渡ノイズ。**ユーザーの「開始直後だけ反応する」という観察が誤りを正した**)。

### 5.1 検証方法: 音響ループバック

「ノイズか本物のマイクか」を人の声のタイミングに頼らず判定するため、**HDMI モニタのスピーカーから 440Hz トーンを再生しながら録音し、録音データに 440Hz 成分が現れるかを DFT で判定**する方法に切り替えた。マイクが物理的に生きていれば部屋の音を拾い、浮きピンなら拾わない。以後の全判定はこの方法による。

### 5.2 根本原因

ヘッドセット対応コーデックは、コンボジャックのマイク接点をコーデック内部のアナログスイッチで有効化する必要がある。この制御は Pin 設定ではなく **Realtek 固有の COEF レジスタ** (node 0x20 経由) で行われ、カーネルは `alc_headset_mode_*` 関数群 (`sound/hda/codecs/realtek/realtek.c`) で codec ごとの COEF シーケンスを持っている。

**しかし ALC245 (0x10ec0245) はこれらの関数の switch 文に列挙されていない** (同族の ALC215/225/285/289/295/299 は列挙されている)。つまりカーネルは ALC245 のヘッドセットマイクを一切設定できない。これがマイク無音の根本原因 (カーネル側の抜け)。

### 5.3 実測結果

ALC225 ファミリの COEF シーケンスを `hda-verb` で手動適用して確認:

| 状態 | 440Hz 検出 | 判定 |
|---|---|---|
| baseline (COEF 未設定) | 0 | マイク死 |
| CTIA モード variant 1 (`0x63[15:14]=2`) | **1000+** | **マイク生存!** |
| CTIA モード variant 2 (`0x63[15:14]=1`) | 0 | 死 |
| OMTP (Nokia 型) モード | 8 | 死 (このヘッドセットは CTIA) |

- コーデック自身の極性自動判定 (`alc_determine_headset_type` 相当を手動実行) も **CTIA** を返した
- マイク音声はピン **0x19** (VREF80 = ドライバのマイクデフォルトが最良)。0x18 はジャック検出線のみ、0x1a は無関係 (過渡ノイズで誤認)
- 録音の見かけの爆音ノイズ (rms 20000+) は **99.6% が 50Hz 未満の DC ドリフト**で、可聴帯域はクリーン (FFT で確認)。whisper は 16kHz リサンプル時にこの帯域を捨てるので実害なし

### 5.4 最終的な実配線まとめ

| 機能 | 実際のピン | BIOS の申告 |
|---|---|---|
| ヘッドホン出力 | 0x17 | 0x21 (誤) |
| ジャックのプラグ検出 (sense) | 0x17 (HP 側) / 0x18 (mic 側) | 0x21/0x19 (誤) |
| ジャックマイク音声 (TRRS インライン) | **0x19 + CTIA COEF 必須** | 0x19 (ピンは合っていたが COEF が無いと死) |
| **内蔵 DMIC x2 (前面パネル)** | **0x12 (ステレオ)** | 0x12 (**正しかった**) |

AMD ACP (f4:00.5) は PCI にも ACPI にも存在せず (BIOS レベルで無効)、DMIC は ACP 経由ではなくコーデック直結。SOF/ASoC ドライバは不要。

PipeWire には入力ポートが 2 つ現れる: **Internal Microphone (0x12 DMIC、デフォルト・高感度)** と Microphone (0x19 ジャック)。

### 5.5 upstream に報告すべき内容

これは Linux カーネルへ quirk を投げる価値がある:

1. `sound/hda/codecs/realtek/realtek.c` の `alc_headset_mode_unplugged` / `alc_headset_mode_ctia` / `alc_headset_mode_omtp` / `alc_headset_mode_mic_in` / `alc_determine_headset_type` の ALC225 グループ (`case 0x10ec0215:` 等) に `case 0x10ec0245:` を追加
2. `alc269.c` の quirk テーブルに `SND_PCI_QUIRK(0x1f4c, 0xb026, "Minisforum MS-S1 MAX", ...)` としてピン fixup (0x17=HP, 0x19=headset mic) + `ALC269_FIXUP_HEADSET_MODE` 系チェーンを追加

### whisper-cli 等での利用

- マイク入力: ALSA default (PipeWire 経由) がそのまま 0x19 のヘッドセットマイクを拾う
- 再生音の文字起こしにはモニターソースが使える: `alsa_output.pci-0000_f4_00.1.hdmi-stereo.monitor`
- Mic Boost は +20dB (2/3) に設定済み。音が小さければ 3、割れるなら 1 に: `amixer -c 1 cset name='Mic Boost Volume' <0-3>,<0-3>`

---

## 6. 運用メモ

### 状態確認コマンド集

```bash
cat /sys/class/sound/hwC1D0/user_pin_configs   # ライブ上書きの内容
sudo dmesg | grep autoconfig                    # ドライバのピン解釈
amixer -c 1 contents | grep -A2 "Jack'"         # ジャック検出状態
wpctl status                                    # PipeWire の sink/source
sudo hda-verb /dev/snd/hwC1D0 0x17 0xf09 0      # ピンの物理検出を直接読む
cat /proc/asound/card1/codec#0                  # コーデック全状態ダンプ
```

### 元に戻すには

```bash
sudo rm /etc/modprobe.d/hda-ms-s1max.conf /lib/firmware/hda-ms-s1max.fw
# 再起動で BIOS デフォルト (壊れた状態) に戻る
```

### カーネルアップデート時の注意

- この修正は **カーネル非依存** (`/lib/firmware/` のパッチ + modprobe オプションのみ)。カーネルを上げても firmware パッチはそのまま効く。
- ただし新カーネルの .config で **`CONFIG_SND_HDA_PATCH_LOADER=y` を維持すること** (これが無いと patch= が無視されて BIOS の壊れた設定に戻る)。`CONFIG_SND_HDA_RECONFIG` はライブ実験用なので必須ではない。
- upstream 状況 (2026-09-02 時点で torvalds master を確認): ALC245 はヘッドセットモード関数群に未対応のまま。将来カーネル側に対応 + 本機の quirk (subsys 0x1f4c:b026) が入った場合、このローカルパッチは冗長になるが無害 (同じ値の二重適用)。その時点で削除してよい。

### 注意事項

- **BIOS アップデートで挙動が変わる可能性がある。** メーカーがピン設定を修正した場合、このパッチは不要になる (害はない — pincfg の上書きが同じ意味になるだけ)。逆に BIOS 更新後に音が変になったら、まずこのパッチと新 BIOS の組み合わせを疑うこと。
- 録音テストの波形解析には「無音 (全ゼロ) / 浮き入力ノイズ (フルスケール DC + クリップ) / 実信号」の区別が有効だった。「録れない」と一括りにせず波形を見ると原因層が切り分けられる。
- 本件は Minisforum へのバグ報告、または `sound/pci/hda/patch_realtek.c` への quirk (subsystem id `0x1f4cb026`) 追加としてカーネルに上流報告する価値がある。

### 関連ファイル

| パス | 役割 |
|---|---|
| `/lib/firmware/hda-ms-s1max.fw` | ピン設定パッチ本体 |
| `/etc/modprobe.d/hda-ms-s1max.conf` | パッチをロードさせる modprobe 設定 |
| `/sys/class/sound/hwC1D0/` | ライブ再構成用 sysfs (user_pin_configs, reconfig) |
| `/etc/alsa/conf.d/{50,99}-pipewire*.conf` | ALSA default → PipeWire ブリッジ (シンボリックリンク) |
