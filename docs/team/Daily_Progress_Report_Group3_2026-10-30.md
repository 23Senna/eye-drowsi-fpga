# DAILY PROGRESS REPORT

## Training VLSI – Final Project: CNN on Basys3 FPGA

### Identification Details

| Item | Details |
|---|---|
| **Day / Date** | Friday, 30 October 2026 |
| **Group / Team Name** | Group 3 |
| **Members and Roles** | Michael Reynaldi Tamara (Reyn) — CNN core, FPGA implementation, and model training<br>Handy Jonarta — block diagram and CNN core<br>Karunia Muda Kurniawan (Karan) — dataset and GitHub environment<br>Nabil Karim Abdurrahman — CNN core, PPT, and GitHub<br>Bramantio Ananda (Tio) — CNN core and FPGA implementation |
| **Project Title / Design Revision** | CNN Implementation for Eye-Drowsiness Driver Detection in an ADAS Vehicle |

---

## A. Objectives and Work Plan

### Today's Target / Milestone

1. Menyelesaikan dan mengunci arsitektur CNN untuk klasifikasi mata terbuka/tertutup.
2. Mengintegrasikan CNN core ke top-level FPGA untuk Basys3.
3. Menyelesaikan block diagram dan bahan presentasi.
4. Memperbarui repository GitHub setelah integrasi.
5. Melakukan verifikasi simulasi dan uji langsung pada hardware Basys3.

### Priorities and Task Allocation

| Work item | Owner(s) | Output |
|---|---|---|
| CNN core dan FSM sequential one-MAC | Tio, Nabil, Handy, Reyn | `rtl/cnn_top.v`, ROM bobot, kontrol state dan akumulasi |
| FPGA implementation dan integrasi Basys3 | Tio, Reyn | `integration/rtl/drowsiness_top.v`, input/alert control, constraints, flow Vivado |
| Block diagram dan arsitektur | Handy | Diagram alur CNN, FSM, memori, dan interface board |
| PPT dan GitHub | Nabil | Dokumentasi presentasi, commit, dan sinkronisasi repository |
| Dataset, training, dan export parameter | Reyn, Karan | Model integer, file `.mem`, golden output, dan label pengujian |

### Start-of-Day Activities

- ☑ Independent planning
- ☑ Progress review
- ☑ Reference study
- ☑ Team discussion
- ☐ Mentor consultation
- ☑ Instructor briefing

### Key Technical Decisions / Guidance

- Menggunakan arsitektur CNN integer untuk input grayscale **24 × 24**:
  `Conv3×3×4 → ReLU/requantize → MaxPool2×2 → Conv3×3×8 → ReLU/requantize → MaxPool2×2 → FC 128→2 → argmax`.
- Menggunakan datapath **sequential one-MAC** pada `cnn_top.v` agar penggunaan multiplier dan logika paralel lebih rendah untuk FPGA Basys3.
- FSM CNN dibagi menjadi state `IDLE`, `LOAD`, `CONV1`, `CONV2`, `FC`, dan `DONE`, dengan ROM sinkron untuk bobot dan image.
- Clock sistem integrasi diturunkan menjadi **50 MHz** melalui MMCM karena jalur kritis CNN belum memenuhi timing pada 100 MHz.
- Klasifikasi menggunakan 16 image eye crop yang tersimpan di ROM; input kamera, face detection, dan eye localisation belum termasuk scope desain ini.

---

## B. Progress and Technical Evidence

### Modules / Subsystems Worked On

- **Reyn:** CNN core, FPGA implementation, model training, quantization, dan export bobot/golden output.
- **Handy:** block diagram, peninjauan arsitektur CNN, dan CNN core.
- **Tio:** CNN core, FSM, dan FPGA implementation.
- **Nabil:** CNN core, PPT, dokumentasi, dan GitHub.
- **Karan:** dataset, environment repository, serta sinkronisasi file pendukung.

### Verified Working Results

- Arsitektur CNN dan FSM sequential one-MAC telah dikunci pada [`rtl/cnn_top.v`](../../rtl/cnn_top.v).
- Simulasi core mencocokkan **16/16 pasangan logit** dengan golden model; prediksi yang benar adalah **14/16** karena image slot 0 dan 1 memang merupakan contoh miss dari model.
- Testbench unit untuk `conv_pe`, `relu_requant`, serta conv + ReLU + pooling dinyatakan lulus tanpa error.
- Integrasi real CNN dengan drowsiness top-level mencakup kontrol tombol, pemilihan image melalui `SW[3:0]`, display 7-segment, LED status, sequence mode, PERCLOS, DROWSY, dan MICROSLEEP.
- Latency CNN terukur **75.826 clock cycle/image**, atau sekitar **1,52 ms/image pada clock 50 MHz**.
- Uji langsung pada **Digilent Basys3** telah dilakukan setelah bitstream diprogram. Fungsi reset, start inference, pemilihan slot image, hasil `OPEn`/`CLSd`, LED status, sequence mode, dan alarm drowsiness berhasil diamati sesuai rancangan.

### Verification Evidence

| Evidence | Result / Reference |
|---|---|
| Golden model vs RTL | 16/16 pasangan logit identik; 14/16 kelas benar |
| Unit/integration simulation | Target regression: 7 testbench PASS, termasuk `tb_top_real` |
| Vivado implementation reference | Sekitar 5.063 LUT, 9.858 FF, 5 BRAM, 0 DSP pada laporan implementasi yang tersedia |
| Timing decision | Clock operasional integrasi ditetapkan 50 MHz; timing 100 MHz gagal pada jalur MAC/memory yang panjang |
| Hardware demo | Uji langsung Basys3 berhasil; hasil slot dan indikator board sesuai tabel pengujian |
| GitHub revision | `f8525f7` — merge integrasi top-level drowsiness; dasar integrasi berasal dari `e130eb9` dan testbench Vivado dari `12ade35` |

> Catatan: foto/video demo hardware belum disimpan sebagai file di repository. Hasil uji board pada laporan ini dicatat berdasarkan verifikasi langsung tim.

### Major Design / File Changes

- Memperbaiki dan menetapkan CNN core sequential one-MAC pada [`rtl/cnn_top.v`](../../rtl/cnn_top.v).
- Menambahkan/menyelaraskan ROM bobot dan image pada [`rtl/rom_weights.v`](../../rtl/rom_weights.v) serta file export di [`ml/export/`](../../ml/export/).
- Menambahkan top-level integrasi [`integration/rtl/drowsiness_top.v`](../../integration/rtl/drowsiness_top.v).
- Menambahkan modul `input_control`, `drowsy_fsm`, dan `alert_control` untuk tombol, debounce, sequence, PERCLOS, DROWSY, MICROSLEEP, 7-segment, dan LED.
- Menambahkan constraints Basys3, script pembuatan project Vivado, script build, dan testbench integrasi pada [`integration/`](../../integration/).
- Menambahkan panduan simulasi Vivado dan board pada [`integration/docs/VIVADO_SIM_GUIDE.md`](../../integration/docs/VIVADO_SIM_GUIDE.md) dan [`integration/docs/VIVADO_BOARD_GUIDE.md`](../../integration/docs/VIVADO_BOARD_GUIDE.md).

---

## C. Progress Review (14:00–15:00)

### Summary of Demonstration / Presentation

Tim mendemonstrasikan alur lengkap dari model integer hingga implementasi Basys3:

1. Menjelaskan block diagram preprocessing/export model, CNN core, FSM, ROM, dan output board.
2. Menunjukkan pemilihan image slot melalui `SW[3:0]` dan trigger inference melalui `btnC`.
3. Menunjukkan hasil klasifikasi pada 7-segment (`OPEn` atau `CLSd`) serta LED busy/eye-state.
4. Menunjukkan sequence mode, penghitung kondisi mata tertutup, indikator **DROWSY**, dan **MICROSLEEP**.
5. Menjelaskan alasan penggunaan clock 50 MHz dan trade-off latency versus resource dari datapath one-MAC.
6. Menyampaikan bahwa sistem saat ini menggunakan eye crop tersimpan, bukan input kamera real-time.

### Mentor / Peer Feedback

- Integrasi CNN core dan top-level drowsiness sudah cukup jelas untuk demo final.
- Bukti simulasi perlu disertakan bersama bukti hardware agar hasil RTL, bitstream, dan board dapat ditelusuri.
- Presentasi perlu menegaskan batasan sistem: input image masih tersimpan di ROM dan belum mencakup kamera/face detection.
- Timing 100 MHz perlu dijelaskan sebagai issue desain yang ditangani dengan penggunaan clock sistem 50 MHz.

### Decisions and Corrective Actions

- Mempertahankan `cnn_top` sequential one-MAC sebagai baseline final karena sudah bit-exact terhadap golden model.
- Menggunakan MMCM untuk menghasilkan clock 50 MHz pada integrasi Basys3.
- Menjadikan hasil hardware Basys3 sebagai verifikasi tambahan setelah simulasi, bukan menggantikan golden-model verification.
- Menyimpan referensi commit GitHub dan daftar file utama di laporan agar revisi dapat direproduksi.
- Untuk pengembangan berikutnya, jalur memory read atau hasil perkalian perlu diregister agar opsi operasi 100 MHz dapat dievaluasi kembali.

---

## D. Additional Work (Optional)

### Post-Review Activities and Outcomes

- Menjalankan `git pull` dan memperbarui working tree ke versi integrasi terbaru.
- Menggabungkan CNN team core dengan drowsiness top-level tanpa menyalin ulang core ke folder integrasi.
- Menambahkan dan meninjau testbench untuk input control, alert control, drowsy FSM, ROM, CNN control, top-level stub, dan top-level real CNN.
- Memprogram bitstream ke Basys3 dan mengecek hasil manual untuk image slot serta sequence mode.
- Memperbarui README, interface contract, dan board guide agar prosedur build, program board, serta ekspektasi output tercatat.

---

## E. Milestone Status and Issues

| Milestone item | Status | Evidence / Notes |
|---|---|---|
| Arsitektur CNN dan quantized model | **Complete** | Model integer, parameter `S1=10`, `S2=7`, bobot dan golden output tersedia di `ml/export/`. |
| CNN RTL core dan FSM | **Complete** | Sequential one-MAC pada `rtl/cnn_top.v`; 16/16 logit pair bit-exact. |
| Integrasi top-level Basys3 | **Complete** | `drowsiness_top`, input control, drowsy FSM, alert control, constraints, dan script Vivado tersedia. |
| Simulasi unit dan integrasi | **Complete** | Regression testbench dirancang untuk 7 PASS; `tb_top_real` memeriksa semua 16 slot terhadap golden output. |
| Synthesis / implementation | **Partial** | Resource tersedia dari laporan implementasi; timing 100 MHz gagal dan sistem memakai 50 MHz. |
| Uji hardware Basys3 | **Complete** | Bitstream telah diuji langsung; output klasifikasi dan fitur drowsiness sesuai rancangan. |
| PPT, block diagram, dan GitHub | **Complete** | Materi dan source terbaru telah disinkronkan pada commit `f8525f7`. |

### Technical / Non-Technical Blockers

- Jalur kritis pada CNN terlalu panjang untuk target 100 MHz, terutama akses memory/indeks dan operasi MAC.
- Latency inference cukup tinggi karena datapath memakai satu MAC secara sequential.
- Dataset dan evaluasi berasal dari subject yang terbatas; angka akurasi 98,1% pada test set perlu disampaikan dengan caveat.
- Bukti hardware berupa foto/video atau log serial belum diarsipkan di repository.
- Sistem belum menerima input kamera dan belum melakukan face/eye localisation.

### Attempted Solutions / Assistance Required

- Menurunkan clock sistem integrasi menjadi 50 MHz melalui MMCM; hasil ini digunakan saat uji Basys3.
- Menambahkan testbench dan golden comparison untuk memastikan perubahan integrasi tidak mengubah hasil CNN.
- Untuk peningkatan berikutnya, register read dari `a1_mem`/`img_mem` atau register hasil perkalian untuk memecah critical path.
- Menambahkan foto/video demo, nomor bitstream, dan laporan timing terbaru ke repository.
- Jika target akhir memerlukan kamera real-time, diperlukan modul camera input, preprocessing, dan eye localisation di luar scope CNN saat ini.

### Estimated Cumulative Progress

**90%**

Dasar CNN, integrasi FPGA, simulasi, dokumentasi, dan uji hardware telah selesai. Sisa pekerjaan utama adalah pengarsipan bukti demo, finalisasi presentasi, dan evaluasi timing/resource pada konfigurasi final yang terdokumentasi.

---

## F. Next-Day Plan

| Priority | Plan | Owner |
|---|---|---|
| 1 | Mengarsipkan foto/video uji Basys3 dan mencatat hasil setiap image slot serta sequence mode | Reyn, Tio |
| 2 | Menyelesaikan PPT, block diagram final, dan narasi batasan sistem | Handy, Nabil |
| 3 | Memastikan README, interface, testbench result, dan commit GitHub konsisten dengan bitstream final | Nabil, Karan |
| 4 | Meninjau critical path dan opsi register/pipeline untuk eksperimen 100 MHz | Tio, Reyn |

**Prepared by:** Nabil Karim Abdurrahman  
**Team:** Group 3

---

# DAILY REPORT – SHORT VERSION

| Item | Report |
|---|---|
| **Day / Date / Team** | Friday, 30/10/2026 — Group 3 |
| **1. Today's target** | Finalisasi CNN core dan FSM, integrasi FPGA Basys3, block diagram, PPT, GitHub, serta uji hardware. |
| **2. Main progress and evidence** | CNN sequential one-MAC dan FSM telah dikunci. Integrasi `drowsiness_top` selesai dengan input tombol/switch, 7-segment, LED, sequence mode, PERCLOS, DROWSY, dan MICROSLEEP. RTL cocok 16/16 golden logits; latency 75.826 cycle/image pada 50 MHz. Versi GitHub terbaru: commit `f8525f7`. Hardware Basys3 sudah diprogram dan diuji; output `OPEn`/`CLSd` serta indikator drowsiness berjalan sesuai rancangan. |
| **3. Feedback / decisions from progress review** | Sistem memakai clock 50 MHz karena jalur kritis CNN belum memenuhi timing 100 MHz. Presentasi harus mencantumkan trade-off latency/resource dan batasan bahwa input masih berupa 24×24 eye crop tersimpan, bukan kamera real-time. |
| **4. Milestone status** | ☑ Complete — CNN core, integrasi, simulasi, dan uji hardware.<br>☑ Partial — optimasi timing 100 MHz dan pengarsipan foto/video demo. |
| **5. Issues, attempted solutions, and assistance needed** | Critical path terlalu panjang untuk 100 MHz; diatasi sementara dengan MMCM 50 MHz. Latency tinggi karena one-MAC. Perlu bukti foto/video dan laporan timing final yang diarsipkan. |
| **6. Tomorrow's priorities and owners** | Foto/video Basys3 dan tabel hasil slot — Reyn/Tio. Final PPT dan block diagram — Handy/Nabil. Sinkronisasi dokumentasi dan GitHub — Nabil/Karan. Review opsi pipeline/register — Tio/Reyn. |

