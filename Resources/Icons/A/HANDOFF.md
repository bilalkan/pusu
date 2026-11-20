# Pusu ikon seti v3: uygulama için teslim notu

Konsept: **Gözetleme Deliği**. İçeriden amber ışık sızan anahtar deliği, anlamı "içeride biri uyanık". Bu sürüm Fable jüri revizyonu uygulanmış hali.

## 1. Uygulama ikonu (`app/`)
- `Pusu.iconset/`: macOS'ta `iconutil -c icns app/Pusu.iconset -o Pusu.icns`. `Info.plist` içine `CFBundleIconFile = Pusu` ekle. SwiftPM ile paketleniyorsa `.icns` dosyasını `.app/Contents/Resources/` altına kopyala.
- Boyuta göre ayrı çizimler var, tek bir master'ı ölçekleme:
  - `svg/pusu-icon.svg`: 128 px ve üstü
  - `svg/pusu-icon-64.svg`: 64 px, ışık dökülmesi yok
  - `svg/pusu-icon-32.svg`: 32 px, düz dolgu, küçük çekirdek
  - `svg/pusu-icon-16.svg`: 16 px, düz dolgu, piksel ızgarasına oturuyor
  - iconset bu eşlemeyle üretildi. Örneğin `icon_16x16@2x` 32 px çizimden geliyor.
- `pusu-icon-1024.png`: sRGB profili gömülü, metin yok.

## 2. Menü çubuğu (`menubar/`)
Mimari iki katmanlı:
- **Glif:** template görsel, yani siyah ve alfa. `isTemplate = true`. Rengini sistem verir.
- **Amber nokta:** glifin üstünde ayrı, renkli bir katman (`PusuDotView`). Rengi status butonunun `effectiveAppearance` değerine göre seçilir:
  - Açık zemin: `#C77700`
  - Koyu zemin: `#FFC24A`
  - Sistem temasına değil butonun görünümüne bakılır, çünkü menü çubuğunun rengi duvar kâğıdına bağlı.
- Nokta boyutu: @2x'te r 1.5 pt (6 px), @1x'te r 2.0 pt (4 px). Merkez glif koordinatında (9, 7).
- Kontur kalınlığı 1.2 pt, glif boyutu 18×18 pt.

| Durum | Glif (`template/`) | Nokta |
|---|---|---|
| kapalı | `pusu-menubar-off-template` (boş kontur) | yok |
| uyanık | `pusu-menubar-awake-template` (kontur) | var |
| süreli | `pusu-menubar-timed-template`: baş çemberinde geçen süre saat 12'den saat yönünde %30 alfa. Dosya %40 geçmiş halin örneği; gerçek değer koddan çizilir | var |
| kapak kapalı | `pusu-menubar-lidclosed-template` (gövde dolu) | var |
| VNC kilit | `pusu-menubar-vnclock-template` (tüm glif dolu) | var |

- Pil eşiğinde kapanma için ayrı bir ikon durumu yok: bildirim gösterilir ve ikon kapalı durumuna döner.
- Animasyon yok: yanıp sönme ya da nefes efekti kullanılmayacak.
- `dot/`: nokta katmanları (light/dark, @1x/@2x).
- `onizleme/`: glif ve noktanın birleştirilmiş PNG'leri. Sadece referans ve test içindir; uygulamada katmanlar ayrı kalmalı.

## 3. Kod (`swift/PusuStatusIcon.swift`)
- `PusuIconState`: `.off`, `.awake`, `.timed(remaining:)`, `.lidClosed`, `.vncLock`
- `PusuGlyph.templateImage(for:)`: glif kodla çizilir, geometrisi SVG ile birebir aynı.
- `PusuStatusIcon(button:)` → `update(_:)`: template görseli ve nokta overlay'ini yönetir.
- Süreli modda `update(.timed(remaining:))` çağrısını yaklaşık 30 saniyede bir yapmak yeterli.
- **Dikkat:** kod Linux ortamında yazıldı, derlenmedi. İlk derlemede kontrol edilmesi gerekenler:
  - `appendArc` açıları (110.49° → 69.51°, flipped düzlemde, `clockwise: false`)
  - `NSStatusBarButton.cell?.imageRect(forBounds:)` ile noktanın konumlandırılması. Light/dark menü çubuğunda ve 1x/2x ekranda gözle doğrula.
- Erişilebilirlik etiketleri Türkçe ("Pusu: uyanık" vb.).

## 4. Renkler
- **Uygulama ikonu zemini:** `#3E4C70` → `#161C2C`
- **Işık:** radyal `#FFF4D6` → `#F8BE52` → `#D9861A`, çekirdek `#FFFBEF`, küçük boyutlarda düz `#F8BE52`
- **UI vurgu rengi (aktif durum):** açık zeminde `#C77700`, koyu zeminde `#FFC24A`
- **Font:** sistem fontu (SF Pro). Süre metni gösterilecekse monospaced digit kullan.

## 5. Kaynak
Jüri raporu özeti: uygulama ikonu 6/10 → hedef ~7,5; menü çubuğu 7/10 → hedef ~8. Tavanı belirleyen şey anahtar deliği metaforunun jenerikliği (şifre yöneticisi ve kasa uygulamalarıyla benzerlik). Yedek konsept: "aralık kapıdan sızan ışık".
