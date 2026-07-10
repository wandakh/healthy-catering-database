-- =========================================================================
-- PATCH PERBAIKAN (revisi 2)
-- Berlaku untuk file yang sudah direstrukturisasi (tahap 1-4).
-- sp_hitung_gizi_otomatis TIDAK disertakan lagi karena sudah benar.
--
-- Cara pakai: jalankan file ini SETELAH seluruh "tahap 1" (create
-- procedure & trigger versi asli) dieksekusi. Untuk FIX #3, jalankan
-- SEBELUM baris "insert into detail_pengiriman" di tahap 2 -- atau
-- paling aman, ganti langsung urutan insert di file aslinya seperti
-- contoh di bagian bawah.
-- =========================================================================
use db_catering_sehat;

-- -------------------------------------------------------------------------
-- FIX #1: sp_buat_pesanan_otomatis_kurir
-- Masalah: v_target_kalori diam-diam tetap 0 kalau target_gizi belum
-- ada, sehingga pesan error yang muncul salah ("melebihi target kalori"
-- padahal harusnya "data gizi belum dihitung").
-- Perbaikan: tambah v_cek_target, validasi eksplisit sebelum lanjut.
-- -------------------------------------------------------------------------
drop procedure if exists sp_buat_pesanan_otomatis_kurir;
delimiter //
create procedure sp_buat_pesanan_otomatis_kurir(
    in p_id_user int,
    in p_id_menu int,
    in p_kategori_waktu varchar(20),
    in p_jumlah_porsi int
)
begin
    declare v_harga_menu int;
    declare v_kalori_menu int;
    declare v_total_harga int;
    declare v_id_pemesanan int;
    declare v_id_kurir int;
    declare v_id_jadwal int;
    declare v_tanggal_kirim date;
    declare v_cek_target int default 0;
    declare v_target_kalori int default 0;
    declare v_kalori_terjadwal int default 0;
    declare v_kalori_tambahan int;

    declare exit handler for sqlexception
    begin
        rollback;
        resignal;
    end;

    start transaction;

    if lower(p_kategori_waktu) = 'pagi' then
        if current_time() > '06:00:00' then set v_tanggal_kirim = curdate() + interval 1 day;
        else set v_tanggal_kirim = curdate(); end if;
    elseif lower(p_kategori_waktu) = 'siang' then
        if current_time() > '10:00:00' then set v_tanggal_kirim = curdate() + interval 1 day;
        else set v_tanggal_kirim = curdate(); end if;
    elseif lower(p_kategori_waktu) = 'malam' then
        if current_time() > '15:00:00' then set v_tanggal_kirim = curdate() + interval 1 day;
        else set v_tanggal_kirim = curdate(); end if;
    else
        signal sqlstate '45000' set message_text = 'transaksi ditolak: kategori_waktu harus pagi, siang, atau malam!';
    end if;

    select harga_menu, kalori_menu into v_harga_menu, v_kalori_menu from menu where id_menu = p_id_menu;
    set v_total_harga = v_harga_menu * p_jumlah_porsi;
    set v_kalori_tambahan = v_kalori_menu * p_jumlah_porsi;

    -- validasi eksplisit: pastikan target_gizi sudah pernah dihitung,
    -- sebelum v_target_kalori dipakai untuk perbandingan apapun
    select count(*), target_kalori into v_cek_target, v_target_kalori
    from target_gizi where id_user = p_id_user;

    if v_cek_target = 0 then
        signal sqlstate '45000'
        set message_text = 'transaksi ditolak: data gizi user belum dihitung! silakan hitung target gizi terlebih dahulu.';
    end if;

    select coalesce(sum(m.kalori_menu * p.jumlah_porsi), 0) into v_kalori_terjadwal
    from pemesanan p
    join jadwal_pengiriman j on p.id_pemesanan = j.id_jadwal
    join menu m on p.id_menu = m.id_menu
    where p.id_user = p_id_user and j.tanggal_hari = v_tanggal_kirim;

    if (v_kalori_terjadwal + v_kalori_tambahan) > v_target_kalori then
        signal sqlstate '45000' set message_text = 'transaksi ditolak: pesanan ini akan membuat asupan kalori anda melebihi batas target harian!';
    end if;

    insert into pemesanan (id_user, id_menu, kategori_waktu, jumlah_porsi, tanggal_pesan, total_harga)
    values (p_id_user, p_id_menu, p_kategori_waktu, p_jumlah_porsi, now(), v_total_harga);
    set v_id_pemesanan = last_insert_id();

    select k.id_kurir into v_id_kurir
    from kurir k
    where k.id_kurir not in (
        select dp.id_kurir
        from detail_pengiriman dp
        join jadwal_pengiriman jp on dp.id_jadwal = jp.id_jadwal
        where dp.status_pengiriman = 'sedang diantar'
          and jp.tanggal_hari = v_tanggal_kirim
    )
    limit 1;

    if v_id_kurir is not null then
        insert into jadwal_pengiriman (id_user, id_menu, tanggal_hari)
        values (p_id_user, p_id_menu, v_tanggal_kirim);
        set v_id_jadwal = last_insert_id();

        insert into detail_pengiriman (id_jadwal, id_kurir, status_pengiriman)
        values (v_id_jadwal, v_id_kurir, 'sedang diantar');

        commit;
    else
        signal sqlstate '45000' set message_text = 'maaf, semua armada kurir di slot tanggal ini sedang sibuk bertugas!';
    end if;
end //
delimiter ;


-- -------------------------------------------------------------------------
-- FIX #2: urutan trigger BEFORE INSERT pada tabel pemesanan
-- Masalah: trg_cek_status_user dibuat TERAKHIR sehingga dieksekusi
-- terakhir. User yang belum berlangganan tetap kena cek alergi & stok
-- dulu sebelum akhirnya ditolak.
-- Perbaikan: drop ketiganya, create ulang dengan trg_cek_status_user
-- di urutan PERTAMA. Isi logic masing-masing trigger TIDAK diubah.
-- -------------------------------------------------------------------------
drop trigger if exists trg_cek_status_user;
drop trigger if exists trg_cek_alergi_insert;
drop trigger if exists trg_cek_stok_before_insert;

delimiter //
create trigger trg_cek_status_user
before insert on pemesanan
for each row
begin
    declare v_status varchar(50);
    declare v_cek_gizi int default 0;

    select status_user into v_status from user_biasa where id_user = new.id_user;

    if lower(v_status) != 'berlangganan' then
        signal sqlstate '45000'
        set message_text = 'transaksi ditolak: user belum berlangganan katering!';
    end if;

    select count(*) into v_cek_gizi from target_gizi where id_user = new.id_user;

    if v_cek_gizi = 0 then
        signal sqlstate '45000'
        set message_text = 'transaksi ditolak: data gizi user belum dihitung! silakan panggil staf gizi terlebih dahulu.';
    end if;
end //
delimiter ;

delimiter //
create trigger trg_cek_alergi_insert
before insert on pemesanan
for each row
begin
    declare v_is_alergi int default 0;
    select count(*) into v_is_alergi
    from user_alergi ua
    join menu m on m.id_menu = new.id_menu
    where ua.id_user = new.id_user
      and (
          (m.kategori_alergen is not null and lower(ua.nama_alergi) like concat('%', lower(m.kategori_alergen), '%'))
          or lower(m.bahan_isi_menu) like concat('%', lower(ua.nama_alergi), '%')
      );
    if v_is_alergi > 0 then
        signal sqlstate '45000'
        set message_text = 'transaksi ditolak! menu mengandung bahan pemicu riwayat alergi user!';
    end if;
end //
delimiter ;

delimiter //
create trigger trg_cek_stok_before_insert
before insert on pemesanan
for each row
begin
    declare v_stok_kurang int default 0;
    select count(*) into v_stok_kurang
    from resep_menu r
    join stok_bahan s on r.id_stok = s.id_stok
    where r.id_menu = new.id_menu
      and (
          (s.satuan = 'pcs' and s.jumlah_stok < (r.kebutuhan_bahan * new.jumlah_porsi))
          or
          (s.satuan = 'kg' and ((s.jumlah_stok * 1000) + s.sisa_gram) < (r.kebutuhan_bahan * new.jumlah_porsi))
      );
    if v_stok_kurang > 0 then
        signal sqlstate '45000'
        set message_text = 'transaksi ditolak: stok bahan di gudang tidak mencukupi untuk membuat menu ini!';
    end if;
end //
delimiter ;

-- trg_kurangi_stok_bahan (AFTER INSERT) tidak terpengaruh urutan BEFORE
-- INSERT di atas, jadi tidak perlu di-drop/create ulang.


-- -------------------------------------------------------------------------
-- FIX #3 (opsional): urutan insert di tahap 2 -- detail_pengiriman
-- mereferensikan id_jadwal 1 dan 2 padahal jadwal_pengiriman baru saja
-- di-TRUNCATE dan belum diisi ulang di titik itu -> FK violation.
--
-- Ganti blok "insert into detail_pengiriman" di file aslinya (yang
-- sekarang persis di bawah "update menu set kategori_alergen ...")
-- dengan urutan berikut: isi jadwal_pengiriman DULU, baru
-- detail_pengiriman. Auto_increment akan mulai dari 1 lagi karena
-- baru saja di-TRUNCATE, jadi id_jadwal yang dihasilkan otomatis 1 & 2.
-- -------------------------------------------------------------------------

-- ganti bagian ini:
--   insert into detail_pengiriman (id_jadwal, id_kurir, status_pengiriman) values
--   (1, 1, 'selesai / diterima'),
--   (2, 2, 'selesai / diterima');
--
-- menjadi:

insert into jadwal_pengiriman (id_user, id_menu, tanggal_hari) values
(1, 1, curdate() - interval 1 day),
(2, 2, curdate() - interval 1 day);

insert into detail_pengiriman (id_jadwal, id_kurir, status_pengiriman) values
(1, 1, 'selesai / diterima'),
(2, 2, 'selesai / diterima');
