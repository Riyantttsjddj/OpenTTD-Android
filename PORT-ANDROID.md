# Port OpenTTD ke Android

Repository ini adalah port OpenTTD untuk Android, dibangun dari upstream OpenTTD
pada commit `787ded77135881e518533fb07c97dd31a6e225f8` (cabang master, tepat
setelah rilis kandidat `16.0-RC1`).

Port ini **memodifikasi** beberapa file upstream dan **menambahkan** lapisan
platform Android. Berikut rincian semua perubahan.

## Basis upstream

- Commit: `787ded77135881e518533fb07c97dd31a6e225f8`
- Halaman: <https://github.com/OpenTTD/OpenTTD/commit/787ded77135881e518533fb07c97dd31a6e225f8>

Versi engine dilaporkan sebagai `16.0` (development build setelah 16.0-RC1).
OpenTTD sendiri adalah GNU GPL v2; seluruh source di sini mengikuti lisensi itu.

## Yang ditambahkan oleh port ini

| Path | Tujuan |
| --- | --- |
| `cmake/Android.cmake` | Menyelaraskan build Android ke CMake OpenTTD: merelink game sebagai `libmain.so`, menghapus entry point desktop, menetapkan 16 KiB page alignment untuk arm64 |
| `src/os/android/android_main.cpp` | Entry point program yang dibutuhkan Android (Android memulai aplikasi lewat activity Java, bukan mengeksekusi biner) |
| `apk/AndroidManifest.xml` | Manifest aplikasi: id paket, label, ikon, izin |
| `apk/java/org/openttd/android/OpenTTD.java` | Activity: memberi game direktori home yang dapat ditulis dan membongkar data ter-bundle pada peluncuran pertama |
| `apk/res/` | Ikon peluncur dan nama aplikasi |
| `stage_assets.sh` | Merangkai semua yang dimuat di dalam APK |
| `assemble_apk.sh` | Mengompilasi resource & Java, dex, align, tanda tangan (multi-ABI) |
| `build_deps.sh` | Cross-compile dependensi untuk tiap ABI (arm64 & armv7) |
| `verify_apk.sh` | Memeriksa APK terhadap klaim halaman publik |
| `make_dist.sh` | Merangkai direktori unduhan itch.io |
| `PORT-ANDROID.md` | Dokumen ini |

## Yang dimodifikasi dari upstream

| File | Perubahan |
| --- | --- |
| `src/os/unix/unix.cpp` | Hand-off browser dilewatkan lewat activity alih-alih `execvp`-kan `xdg-open` |
| `CMakeLists.txt` | Menyertakan lapisan platform Android pada build Android |
| `.gitignore` | Pola untuk artefak build Android (apk/out, apk/assets, *.apk, dll.) |

## Perubahan perilaku yang disengaja

### 1. Perbaikan bug crash saat peluncuran kedua

Bug: membuka aplikasi untuk kedua kalinya (setelah ditutup) bisa langsung
crash. Penyebabnya entry point native keluar dengan cara yang tidak dikenali
runtime Android ketika aplikasi di-restart.

Perbaikan (`src/os/android/android_main.cpp`): proses keluar memakai
`std::_Exit(status)` yang menghentikan proses secara pasti, sehingga state lama
tidak membawa program ke kondisi tidak valid saat di-restart.

### 2. Identitas aplikasi tanpa label "unofficial"

Port ini menggunakan identitas yang bersih:

- Package id: `com.openttd.android`
- Label aplikasi: `OpenTTD`
- VersionName: `16.0`
- Nama file APK: `OpenTTD-16.0-android.apk`

### 3. Izin jaringan (multiplayer & unduh konten)

Untuk membuat seluruh fungsi game bekerja di Android, termasuk multiplayer
online dan layanan unduh konten dalam game, manifest menambahkan dua izin:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

- `INTERNET` mencakup koneksi keluar (klien) dan masuk (hosting server).
- `ACCESS_NETWORK_STATE` membiarkan game mendeteksi ketersediaan jaringan,
  alih-alih gagal menghubung dalam keadaan gelap.

Tidak ada izin lain (tidak ada pelacakan, iklan, lokasi, kamera, atau kontak).

### 4. Dukungan 32-bit (armeabi-v7a)

APK kini mengirim **dua arsitektur**:

- `arm64-v8a` (64-bit, wajib 16 KiB page aligned untuk perangkat Android 15+)
- `armeabi-v7a` (32-bit, tanpa persyaratan page 16 KiB)

`build_deps.sh` menerima argumen ABI (`arm64` atau `armv7`) dan menginstal
dependensi ke prefix per-ABI yang terpisah, sehingga kedua build tidak saling
menimpa. `assemble_apk.sh` me-stage native library untuk kedua ABI ke dalam
satu APK.

## Cara membangun

Lihat `BUILDING.md` di source upstream untuk prasyarat host, dan skrip build di
repo ini (`build_deps.sh`, `stage_assets.sh`, `assemble_apk.sh`) yang berisi
invokasi compiler/tool yang sebenarnya dipakai.

## Lisensi & hak cipta

OpenTTD dan semua data yang dibundel adalah GNU GPL v2 (OpenSFX juga tersedia
di bawah CC BY-SA 3.0 atau CDDL 1.1). Lihat `COPYING.md`, `CREDITS.md`, dan
`licenses/` di unduhan untuk teks lisensi lengkap.

Port ini tidak berafiliasi dengan atau didukung oleh proyek OpenTTD; nama
"OpenTTD" dipakai hanya untuk menyatakan program itu apa.