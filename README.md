# ZETX DROP

AirDrop gibi çalışan dosya aktarımı + sosyal medya indirici. Geliştirici: **Volkan Sezer** · volkan.sezer@outlook.com.tr · @zetxtv

- `windows/` — Windows programı (Go). PC ↔ telefon aktarımı ve medya indirme sunucusu.
- `ios/` — iPhone uygulaması (SwiftUI). iPhone ↔ iPhone (PC gerekmez), iPhone ↔ PC, gelenleri doğrudan galeriye kaydetme.

## iPhone uygulamasını TestFlight'a gönderme

Her `main` push'unda GitHub Actions uygulamayı Mac sunucusunda derler ve App Store Connect'e yükler.

### Bir kez yapılacaklar
1. **Bundle ID:** developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → App → Bundle ID: `om.zetx.drop` (Explicit) → Register.
2. **Uygulama kaydı:** appstoreconnect.apple.com → Uygulamalar → **+** → Yeni Uygulama → Platform iOS, Ad `ZETX DROP`, Dil Türkçe, Bundle ID `om.zetx.drop`, SKU `zetxdrop`.
3. **API anahtarı:** App Store Connect → Kullanıcılar ve Erişim → Entegrasyonlar → App Store Connect API → **+** → Ad `GitHub`, Erişim **Admin** → Oluştur → `.p8` dosyasını indir. **Issuer ID** ve **Key ID**'yi not al.
4. **Team ID:** developer.apple.com → Account → Membership details → Team ID.
5. **GitHub Secrets:** Bu repo → Settings → Secrets and variables → Actions → New repository secret:
   - `ASC_KEY_ID` — Key ID
   - `ASC_ISSUER_ID` — Issuer ID
   - `ASC_KEY_P8` — .p8 dosyasının **tüm içeriği** (Not Defteri ile açıp kopyala)
   - `APPLE_TEAM_ID` — Team ID
6. Actions → **iOS → TestFlight** → Run workflow.

Yükleme bitince App Store Connect → TestFlight'ta yapı 5-15 dk içinde görünür. iPhone'da **TestFlight** uygulamasından yükleyin.
