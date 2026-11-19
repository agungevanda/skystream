# Catatan Fase 0: Siapkan Dapur

Tanggal: 18 November 2026
Fork: https://github.com/agungevanda/skystream
Cabang: `fase-0-setup`

## Versi lingkungan

| Komponen | Versi / status |
|---|---|
| Flutter | 3.50.0 stable |
| Dart | 3.14.0 |
| Java sistem | Eclipse Temurin JDK 21.0.7 |
| Java Android | OpenJDK 25.0.4 dari Android Studio |
| Android SDK | `C:\Andro`, Platform API 37, Build-Tools 36.0.0 |
| Android Emulator | 37.2.13.0, AVD `Medium_Phone_API_37.0` / Android 17 API 37 |
| Android NDK | 29.0.14206865 |
| Android CMake | 3.22.1 |
| Visual Studio | Community 2022 17.14.45, workload C++ desktop terpasang |

## Hasil `flutter doctor -v`

- Flutter: siap.
- Android toolchain: siap; semua lisensi Android diterima.
- Perangkat Windows terdeteksi oleh Flutter.
- Visual Studio terdeteksi dengan C++ desktop, tetapi `flutter doctor -v` masih memperingatkan bahwa Windows 10 SDK tidak ditemukan.
- Peringatan Visual Studio tidak menghalangi build dan run Windows debug: `skystream.exe` berhasil dibangun dan dijalankan.

## Hasil build dan run

| Target | Hasil | Bukti / catatan |
|---|---|---|
| Android emulator | Berhasil | APK debug dibangun, dipasang, dan SkyStream berjalan pada `emulator-5554`. |
| Windows | Berhasil | `build\windows\x64\runner\Debug\skystream.exe` dibangun dan berjalan. Developer Mode diaktifkan agar Flutter dapat membuat symlink plugin. |

## Uji ekstensi CloudStream

Repository yang dipasang:

```text
https://raw.githubusercontent.com/TeKuma25/IndoStream/builds/repo.json
```

Semua plugin yang diuji pada tabel ini adalah ekstensi CloudStream. Tidak ada ekstensi format bawaan SkyStream yang diuji.

| Perangkat | Plugin | Jenis | Judul | Hasil | Pesan / bukti |
|---|---|---|---|---|---|
| Android emulator | Pencuri Movie by CloudStream | Film | Tikus! | Berhasil | Playback VLC tercatat lancar. |
| Android emulator | Nonton Drama by CloudStream | Series/drama | Tidak dicatat | Berhasil | Pemutaran berhasil menurut uji manual. |
| Android emulator | Layarkaca by CloudStream | Film/series | Tidak dicatat | Berhasil | Pemutaran berhasil menurut uji manual. |
| Android emulator | Moviebox | Film/series | Beberapa judul | Gagal sebagian | HTTP 427, Cloudflare Turnstile, timeout 15 detik, lalu `JsPluginException` pada `loadStreams`. |
| Windows | Layarkaca by CloudStream | Film/series | Snoopy Presents: 12 Days of Snoopy (2026) | Berhasil | `Playback: playback smooth (displayed=71 lost=0 corrupted=0 discontinuity=0)`. |
| Windows | Pencuri Movie by CloudStream | Film | Tikus! | Berhasil | `Playback: playback smooth (displayed=73 lost=0 corrupted=0 discontinuity=0)`; subtitle Melayu dan Inggris terdeteksi. |
| Windows | Anime Sail by CloudStream | Anime | Absolute Duo (2015) | Berhasil | Pemutaran berhasil menurut uji manual. |
| Windows | Layarkaca by CloudStream | Film/series | Apocalypse Z: New World (2026) | Gagal | `JsPluginException[UNKNOWN_ERROR]` pada `loadStreams`. |
| Windows | Idlix by CloudStream | Film/series | The Lord of the Rings: The Rings of Power | Gagal | `session/claim` mendapat HTTP 301, JSON gagal diparse, lalu `loadStreams` gagal. |
| Windows | Moviebox | Film/series | Beberapa judul | Tidak stabil | API katalog merespons sebagian dengan HTTP 200, sebagian terkena HTTP 429; tidak dicatat sebagai pemutaran berhasil. |

## Kesimpulan Fase 0

- Fork SkyStream berhasil dijalankan pada Android dan Windows.
- Ekstensi CloudStream dapat dipasang dan terbukti memutar video pada kedua platform.
- Keandalan tiap plugin/server tidak sama. Kegagalan Moviebox, Layarkaca pada judul tertentu, dan Idlix dicatat sebagai masalah sumber/plugin saat uji, bukan kegagalan build aplikasi.
- Baseline awal `flutter test` adalah 4.030 lulus, 6 dilewati, 34 gagal. Akar kegagalan terbesar di Windows ialah loader test QuickJS mencari `quickjs_c_bridge.dll`, sementara build aplikasi menyediakan `flutter_js_plugin.dll`.
- Loader Windows dan test yang sensitif terhadap path, jenis error filesystem, race async, izin `chmod`, serta akhir-baris diperbaiki tanpa melemahkan test keamanan. Verifikasi final Windows melalui `flutter test --machine`: **4.430/4.430 test sukses, 0 gagal**.
- Perbaikan baseline direkam dan dipush pada commit `4540a15f` (`test: fix Windows baseline suite`) di branch `fase-0-setup`.
- Lisensi `LICENSE` ada dan berisi GNU GPL v3.

**Status akhir:** Fase 0 selesai. Lingkungan, build Android/Windows, uji ekstensi CloudStream, dan baseline test Windows sudah terverifikasi. Fase 1 tetap ditahan sampai ada PRD baru.
