# Pusu ikon seti: alternatif konsept "Aralık Kapı" (opsiyonel)

Ana öneri `pusu-ikon-v3` (Gözetleme Deliği). Bu paket isteğe bağlı bir alternatif; ikisini birlikte kullanma, birini seç.

Konsept: aralık kalmış bir kapının kenarından amber ışık sızıyor ve yere dökülüyor. Anlamı "içeride biri uyanık". Anahtar deliği konseptinden farkı, şifre yöneticisi, kasa ya da kilit uygulamalarını çağrıştırmaması.

## Uygulama ikonu (`app/`)
- `iconutil -c icns app/Pusu.iconset -o Pusu.icns`
- Boyuta göre ayrı çizimler var:
  - `pusu-kapi-icon.svg`: 128 px ve üstü, kapı panelleri ve ışık dökülmesi dahil
  - `-64`: sadeleştirilmiş, panel detayı ve ışık dökülmesi yok
  - `-32` ve `-16`: düz renkler, piksel ızgarasına oturuyor
- Renkler:
  - Zemin: `#3E4C70` → `#161C2C`
  - Kapı paneli: `#232C44` → `#121827`
  - Kasa çizgisi: `#6A7A9E`
  - Işık: `#F8BE52` / `#FFF4D6` / `#F0A63A`

## Menü çubuğu (`menubar/`)
- Glif template, ışık yarığı ise ayrı renkli katman. Yarığın rengi açık zeminde `#C77700`, koyu zeminde `#FFC24A`.
- Kontur 1.2 pt, glif boyutu 18×18 pt.

| Durum | Glif | Işık |
|---|---|---|
| kapalı | kapı kapalı (kasa + sağda kulp) | yok |
| uyanık | kapı aralık (kenar çizgisi + kulp) | yarık tam |
| süreli | uyanık ile aynı | yarık alttan yukarı kalan süre kadar dolu, geçen kısım %30 |
| kapak kapalı | kapı panelinin alt yarısı dolu | yarık tam |
| VNC kilit | tüm kapı dolu | yarık tam |

- `isik/` klasöründeki `*-timed60` dosyaları süreli durumun %60 kalan örneğidir. Gerçek değer koddan çizilir.
- `onizleme/` klasöründeki birleşik PNG'ler yalnızca referans içindir.

## Kod (`swift/PusuStatusIcon+Kapi.swift`)
- v3 ile **aynı API**: `PusuIconState`, `PusuStatusIcon(button:)`, `update(_:)`. Konsepti değiştirmek için v3'teki `PusuStatusIcon.swift` yerine bu dosyayı koymak yeterli. İkisi aynı tip adlarını kullandığı için birlikte derlenmez.
- Kod Linux ortamında yazıldı, derlenmedi. İlk derlemede yarığın butondaki konumunu (`layoutSlit`) açık/koyu menü çubuğunda ve 1x/2x ekranda gözle doğrula.
