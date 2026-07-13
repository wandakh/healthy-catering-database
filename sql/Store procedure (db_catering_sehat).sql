use ddl_catering_sehat;

-- =========================================================================
-- tahap 1: pembuatan struktur logika (stored procedure & trigger)
-- =========================================================================

-- -------------------------------------------------------------------------
-- a. stored procedure
-- -------------------------------------------------------------------------

-- -------------------------------------------------------------------------
-- sp 1: kalkulasi dan penyimpanan target gizi otomatis berdasarkan fisik
-- -------------------------------------------------------------------------
drop procedure if exists sp_hitung_gizi_otomatis;
delimiter //
create procedure sp_hitung_gizi_otomatis(
    in p_id_user int,
    in p_id_ahli_gizi int
)
begin
    declare v_berat decimal(5,2);
    declare v_tinggi decimal(5,2);
    declare v_jk enum('l', 'p');
    declare v_umur int;
    declare v_kalori int;
    declare v_protein decimal(5,2);
    declare v_lemak decimal(5,2);
    declare v_karbo decimal(5,2);

    select berat_badan, tinggi_badan, jenis_kelamin, umur
    into v_berat, v_tinggi, v_jk, v_umur
    from user_biasa
    where id_user = p_id_user;

    if v_berat is null or v_tinggi is null or v_umur is null then
        signal sqlstate '45000'
        set message_text = 'gagal: data fisik belum lengkap untuk kalkulasi gizi!';
    end if;

    if v_jk = 'l' then
        set v_kalori = (10 * v_berat) + (6.25 * v_tinggi) - (5 * v_umur) + 5;
    else
        set v_kalori = (10 * v_berat) + (6.25 * v_tinggi) - (5 * v_umur) - 161;
    end if;

    set v_protein = (v_kalori * 0.15) / 4;
    set v_lemak = (v_kalori * 0.25) / 9;
    set v_karbo = (v_kalori * 0.60) / 4;

    insert into target_gizi (id_user, id_ahli_gizi, target_kalori, protein, lemak, karbo)
    values (p_id_user, p_id_ahli_gizi, v_kalori, v_protein, v_lemak, v_karbo)
    on duplicate key update
        id_ahli_gizi = p_id_ahli_gizi,
        target_kalori = v_kalori,
        protein = v_protein,
        lemak = v_lemak,
        karbo = v_karbo;
end //
delimiter ;

-- -------------------------------------------------------------------------
-- sp 2: pembuatan pesanan otomatis sekaligus penugasan kurir dan jadwal
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

    set transaction isolation level serializable;
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

    if v_harga_menu is null then
        signal sqlstate '45000' set message_text = 'transaksi ditolak: menu tidak ditemukan!';
    end if;

    set v_total_harga = v_harga_menu * p_jumlah_porsi;
    set v_kalori_tambahan = v_kalori_menu * p_jumlah_porsi;

    select count(*), max(target_kalori) into v_cek_target, v_target_kalori
    from target_gizi where id_user = p_id_user;

    if v_cek_target = 0 then
        signal sqlstate '45000'
        set message_text = 'transaksi ditolak: data gizi user belum dihitung! silakan hitung target gizi terlebih dahulu.';
    end if;

    select coalesce(sum(m.kalori_menu * p.jumlah_porsi), 0) into v_kalori_terjadwal
    from pemesanan p
    join jadwal_pengiriman j on p.id_pemesanan = j.id_pemesanan
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
    where not exists (
        select 1
        from detail_pengiriman dp
        join jadwal_pengiriman jp on dp.id_jadwal = jp.id_jadwal
        where dp.id_kurir = k.id_kurir
          and dp.status_pengiriman = 'sedang diantar'
          and jp.tanggal_hari = v_tanggal_kirim
    )
    order by k.id_kurir
    limit 1
    for update;

    if v_id_kurir is not null then
        insert into jadwal_pengiriman (id_user, id_menu, id_pemesanan, tanggal_hari)
        values (p_id_user, p_id_menu, v_id_pemesanan, v_tanggal_kirim);
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
-- sp 3: konfirmasi status pengiriman makanan selesai oleh kurir
-- -------------------------------------------------------------------------
drop procedure if exists sp_konfirmasi_makanan_diterima;
delimiter //
create procedure sp_konfirmasi_makanan_diterima(
    in p_id_jadwal int
)
begin
    declare v_cek_id int default 0;
    declare v_tanggal_kirim date;
    declare v_status_sekarang varchar(50);

    select count(*), max(j.tanggal_hari), max(dp.status_pengiriman)
    into v_cek_id, v_tanggal_kirim, v_status_sekarang
    from detail_pengiriman dp
    join jadwal_pengiriman j on dp.id_jadwal = j.id_jadwal
    where dp.id_jadwal = p_id_jadwal;

    if v_cek_id = 0 then
        signal sqlstate '45000' set message_text = 'gagal: id jadwal pengiriman tidak ditemukan atau salah ketik!';

    elseif v_tanggal_kirim > curdate() then
        signal sqlstate '45000' set message_text = 'gagal: pesanan dijadwalkan untuk esok hari! kurir tidak bisa menyelesaikan pengiriman hari ini.';

    elseif lower(v_status_sekarang) = 'selesai / diterima' then
        signal sqlstate '45000' set message_text = 'info: pengiriman ini sudah pernah dikonfirmasi selesai sebelumnya.';

    else
        update detail_pengiriman
        set status_pengiriman = 'selesai / diterima'
        where id_jadwal = p_id_jadwal;
    end if;
end //
delimiter ;

-- -------------------------------------------------------------------------
-- sp 4: pengecekan dan pencetakan nota pesanan pelanggan yang selesai
-- -------------------------------------------------------------------------
drop procedure if exists sp_cek_nota_pelanggan;
delimiter //
create procedure sp_cek_nota_pelanggan(in p_id_user int)
begin
    declare v_status varchar(50);
    declare v_jumlah_pesanan int;

    select status_user into v_status from user_biasa where id_user = p_id_user;
    if v_status is null then
        signal sqlstate '45000' set message_text = 'gagal: id user tidak terdaftar!';

    elseif lower(v_status) = 'melihat-lihat' then
        signal sqlstate '45000' set message_text = 'maaf, anda belum berlangganan! silakan lakukan pemesanan & upgrade akun untuk melihat nota.';

    else
        select count(*) into v_jumlah_pesanan
        from pemesanan p
        join jadwal_pengiriman j on p.id_pemesanan = j.id_pemesanan
        join detail_pengiriman dp on j.id_jadwal = dp.id_jadwal
        where p.id_user = p_id_user
        and lower(dp.status_pengiriman) = 'selesai / diterima';

        if v_jumlah_pesanan = 0 then
            signal sqlstate '45000' set message_text = 'nota belum tersedia karena pesanan anda belum sampai/selesai.';
        else
            select
                p.id_pemesanan, u.nama as nama_pelanggan, m.nama_menu, p.total_harga
            from pemesanan p
            join user_biasa u on p.id_user = u.id_user
            join menu m on p.id_menu = m.id_menu
            join jadwal_pengiriman j on p.id_pemesanan = j.id_pemesanan
            join detail_pengiriman dp on j.id_jadwal = dp.id_jadwal
            where p.id_user = p_id_user
            and lower(dp.status_pengiriman) = 'selesai / diterima';
        end if;
    end if;
end //
delimiter ;

-- -------------------------------------------------------------------------
-- sp 5: rekapitulasi menu pesanan dengan harga di atas rata-rata
-- -------------------------------------------------------------------------
drop procedure if exists sp_rekap_menu_diatas_rata_rata;
delimiter //
create procedure sp_rekap_menu_diatas_rata_rata(in p_id_menu int)
begin
    declare v_cek_pesanan int;

    select count(*) into v_cek_pesanan from pemesanan where id_menu = p_id_menu;

    if v_cek_pesanan = 0 then
        signal sqlstate '45000' set message_text = 'belum ada yang pesan menu ini atau data tidak tersedia!';
    else
        select id_pemesanan, id_user, id_menu, total_harga
        from pemesanan
        where id_menu = p_id_menu
          and (select harga_menu from menu where id_menu = p_id_menu) > (select avg(harga_menu) from menu);
    end if;
end //
delimiter ;

-- -------------------------------------------------------------------------
-- sp 6: analisis pemenuhan dan surplus atau defisit kalori harian
-- -------------------------------------------------------------------------
drop procedure if exists sp_cek_pemenuhan_gizi_harian;
delimiter //
create procedure sp_cek_pemenuhan_gizi_harian(
    in p_id_user int,
    in p_tanggal date
)
begin
    declare v_target_kalori int;
    declare v_kalori_terpenuhi int default 0;
    declare v_selisih int;
    declare v_status varchar(150);

    select target_kalori into v_target_kalori from target_gizi where id_user = p_id_user;

    if v_target_kalori is null then
        signal sqlstate '45000' set message_text = 'gagal: user belum dihitung rekam target gizinya!';
    else
        select coalesce(sum(m.kalori_menu * p.jumlah_porsi), 0) into v_kalori_terpenuhi
        from pemesanan p
        join menu m on p.id_menu = m.id_menu
        join jadwal_pengiriman j on p.id_pemesanan = j.id_pemesanan
        where p.id_user = p_id_user and j.tanggal_hari = p_tanggal;

        set v_selisih = v_target_kalori - v_kalori_terpenuhi;

        if v_kalori_terpenuhi = 0 then
            set v_status = concat('belum ada asupan makanan untuk tanggal ', p_tanggal);
        elseif v_selisih > 150 then
            set v_status = concat('kurang gizi! kalori di tanggal ini kurang ', v_selisih, ' kkal dari target.');
        elseif v_selisih >= -150 and v_selisih <= 150 then
            set v_status = 'sempurna! jadwal kalori di tanggal ini sudah terpenuhi dengan aman.';
        else
            set v_status = concat('surplus kalori! makanan di tanggal ini kelebihan ', abs(v_selisih), ' kkal.');
        end if;

        select
            (select nama from user_biasa where id_user = p_id_user) as nama_pelanggan,
            v_target_kalori as target_kalori_harian,
            v_kalori_terpenuhi as total_kalori_terjadwal,
            p_tanggal as untuk_tanggal,
            v_status as analisis_gizi;
    end if;
end //
delimiter ;

-- -------------------------------------------------------------------------
-- sp 7: rekomendasi menu aman sesuai sisa kalori dan bebas alergen
-- -------------------------------------------------------------------------
drop procedure if exists sp_rekomendasi_menu_aman;
delimiter //
create procedure sp_rekomendasi_menu_aman(in p_id_user int)
begin
    declare v_cek_target int default 0;
    declare v_target_kalori int;
    declare v_kalori_terpenuhi int default 0;
    declare v_sisa_kalori int;

    select count(*), max(target_kalori) into v_cek_target, v_target_kalori
    from target_gizi
    where id_user = p_id_user;

    if v_cek_target = 0 then
        signal sqlstate '45000' set message_text = 'gagal: user belum memiliki rekam target kalori harian!';
    else
        select coalesce(sum(m.kalori_menu * p.jumlah_porsi), 0) into v_kalori_terpenuhi
        from pemesanan p
        join menu m on p.id_menu = m.id_menu
        join jadwal_pengiriman j on p.id_pemesanan = j.id_pemesanan
        where p.id_user = p_id_user and j.tanggal_hari = curdate();

        set v_sisa_kalori = v_target_kalori - v_kalori_terpenuhi;

        select
            u.nama as nama_pelanggan,
            v_target_kalori as target_harian,
            v_kalori_terpenuhi as kalori_terjadwal_hari_ini,
            v_sisa_kalori as sisa_kuota_kalori,
            m.nama_menu as menu_aman_rekomendasi,
            m.kalori_menu as kalori_porsi,
            m.harga_menu
        from target_gizi t
        join user_biasa u on t.id_user = u.id_user
        cross join menu m
        where t.id_user = p_id_user
          and m.id_menu not in (
              select m2.id_menu from menu m2
              join user_alergi ua on ua.id_user = p_id_user
              where (m2.kategori_alergen is not null and lower(ua.nama_alergi) like concat('%', lower(m2.kategori_alergen), '%'))
                 or lower(m2.bahan_isi_menu) like concat('%', lower(ua.nama_alergi), '%')
          )
          and m.kalori_menu <= v_sisa_kalori;
    end if;
end //
delimiter ;

-- -------------------------------------------------------------------------
-- b. trigger
-- -------------------------------------------------------------------------

drop trigger if exists trg_cek_status_user;
drop trigger if exists trg_cek_alergi_insert;
drop trigger if exists trg_cek_stok_before_insert;
drop trigger if exists trg_kurangi_stok_bahan;

-- -------------------------------------------------------------------------
-- trigger 1: validasi status berlangganan dan rekam gizi sebelum transaksi
-- -------------------------------------------------------------------------
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

-- -------------------------------------------------------------------------
-- trigger 2: validasi dan penolakan pesanan yang mengandung alergen
-- -------------------------------------------------------------------------
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

-- -------------------------------------------------------------------------
-- trigger 3: validasi ketersediaan stok bahan baku sebelum pemesanan
-- -------------------------------------------------------------------------
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

-- -------------------------------------------------------------------------
-- trigger 4: pengurangan stok dan konversi gram ke kilogram otomatis
-- -------------------------------------------------------------------------
delimiter //
create trigger trg_kurangi_stok_bahan
after insert on pemesanan
for each row
begin
    update stok_bahan s
    join resep_menu r on s.id_stok = r.id_stok
    set
        s.jumlah_stok = case when s.satuan = 'pcs' then s.jumlah_stok - (r.kebutuhan_bahan * new.jumlah_porsi) else s.jumlah_stok end,
        s.sisa_gram = case when s.satuan = 'kg' then s.sisa_gram - (r.kebutuhan_bahan * new.jumlah_porsi) else s.sisa_gram end
    where r.id_menu = new.id_menu;

    update stok_bahan s
    join resep_menu r on s.id_stok = r.id_stok
    set
        s.jumlah_stok = s.jumlah_stok - ceil(abs(s.sisa_gram) / 1000),
        s.sisa_gram = s.sisa_gram + (ceil(abs(s.sisa_gram) / 1000) * 1000)
    where r.id_menu = new.id_menu and s.satuan = 'kg' and s.sisa_gram < 0;
end //
delimiter ;


-- =========================================================================
-- tahap 2: persiapan data (dml)
-- =========================================================================
set foreign_key_checks = 0;
truncate table detail_pengiriman;
truncate table jadwal_pengiriman;
truncate table pemesanan;
truncate table user_alergi;
truncate table target_gizi;
truncate table resep_menu;
truncate table stok_bahan;
truncate table user_biasa;
set foreign_key_checks = 1;

insert into user_biasa (nama, umur, alamat, jenis_kelamin, berat_badan, tinggi_badan, status_user) values
('rian wijaya', 25, 'jl. merdeka no. 10, jakarta', 'l', 72.50, 175.00, 'berlangganan'),
('aulia rahma', 22, 'jl. dago no. 45, bandung', 'p', 50.00, 160.00, 'melihat-lihat');

insert into stok_bahan (id_stok, id_admin, nama_bahan, satuan, jumlah_stok, sisa_gram) values
(1, 1, 'dada ayam fillet', 'kg', 150, 0),
(2, 1, 'beras merah cianjur', 'kg', 200, 0),
(3, 1, 'daging salmon segar', 'kg', 50, 0),
(4, 2, 'kotak kemasan eco-friendly', 'pcs', 1000, 0);

insert into resep_menu (id_menu, id_stok, kebutuhan_bahan) values
(1, 1, 200), (1, 2, 100), (1, 4, 1),
(2, 3, 150), (2, 4, 1),
(3, 2, 150), (3, 3, 100), (3, 4, 1),
(4, 1, 250), (4, 2, 100), (4, 4, 1);

update menu set kategori_alergen = 'seafood' where id_menu in (1, 2);
update menu set kategori_alergen = 'kacang' where id_menu = 4;
insert into user_alergi (id_user, nama_alergi) values (1, 'seafood');


call sp_hitung_gizi_otomatis(1, 1);

insert into pemesanan (id_user, id_menu, kategori_waktu, jumlah_porsi, tanggal_pesan, total_harga)
values (1, 3, 'siang', 1, now() - interval 2 day, (select harga_menu from menu where id_menu = 3));
set @v_id_pemesanan_1 = last_insert_id();

insert into jadwal_pengiriman (id_user, id_menu, id_pemesanan, tanggal_hari)
values (1, 3, @v_id_pemesanan_1, curdate() - interval 2 day);
set @v_id_jadwal_1 = last_insert_id();

insert into detail_pengiriman (id_jadwal, id_kurir, status_pengiriman)
values (@v_id_jadwal_1, 1, 'selesai / diterima');

insert into pemesanan (id_user, id_menu, kategori_waktu, jumlah_porsi, tanggal_pesan, total_harga)
values (1, 3, 'malam', 1, now() - interval 1 day, (select harga_menu from menu where id_menu = 3));
set @v_id_pemesanan_2 = last_insert_id();

insert into jadwal_pengiriman (id_user, id_menu, id_pemesanan, tanggal_hari)
values (1, 3, @v_id_pemesanan_2, curdate() - interval 1 day);
set @v_id_jadwal_2 = last_insert_id();

insert into detail_pengiriman (id_jadwal, id_kurir, status_pengiriman)
values (@v_id_jadwal_2, 2, 'selesai / diterima');


-- =========================================================================
-- tahap 3: data control language (dcl - hak akses)
-- =========================================================================

create user if not exists 'admin_utama'@'localhost' identified by 'passwordadminutama123!';
grant all privileges on ddl_catering_sehat.* to 'admin_utama'@'localhost';

create user if not exists 'kurir'@'localhost' identified by 'kurirkateringsehat2026!';

grant select on ddl_catering_sehat.jadwal_pengiriman to 'kurir'@'localhost';
grant select on ddl_catering_sehat.detail_pengiriman to 'kurir'@'localhost';
grant execute on procedure ddl_catering_sehat.sp_konfirmasi_makanan_diterima to 'kurir'@'localhost';

create user if not exists 'staf_gizi'@'localhost' identified by 'ahligizi2026!';
grant select on ddl_catering_sehat.user_biasa to 'staf_gizi'@'localhost';
grant select on ddl_catering_sehat.user_alergi to 'staf_gizi'@'localhost';
grant select, insert, update on ddl_catering_sehat.target_gizi to 'staf_gizi'@'localhost';
grant execute on procedure ddl_catering_sehat.sp_hitung_gizi_otomatis to 'staf_gizi'@'localhost';
grant execute on procedure ddl_catering_sehat.sp_rekomendasi_menu_aman to 'staf_gizi'@'localhost';
grant execute on procedure ddl_catering_sehat.sp_cek_pemenuhan_gizi_harian to 'staf_gizi'@'localhost';

create user if not exists 'staf_dapur'@'localhost' identified by 'dapurkatering2026!';
grant select on ddl_catering_sehat.pemesanan to 'staf_dapur'@'localhost';
grant select, insert, update on ddl_catering_sehat.menu to 'staf_dapur'@'localhost';
grant select, update on ddl_catering_sehat.stok_bahan to 'staf_dapur'@'localhost';
grant select, insert, update, delete on ddl_catering_sehat.resep_menu to 'staf_dapur'@'localhost';

create user if not exists 'staf_keuangan'@'localhost' identified by 'uangmasuk2026!';
grant select on ddl_catering_sehat.pemesanan to 'staf_keuangan'@'localhost';
grant select on ddl_catering_sehat.user_biasa to 'staf_keuangan'@'localhost';
grant execute on procedure ddl_catering_sehat.sp_cek_nota_pelanggan to 'staf_keuangan'@'localhost';
grant execute on procedure ddl_catering_sehat.sp_rekap_menu_diatas_rata_rata to 'staf_keuangan'@'localhost';

flush privileges;


-- =========================================================================
-- tahap 4: pengujian sistem (call sp & verifikasi)
-- =========================================================================

use ddl_catering_sehat;


call sp_hitung_gizi_otomatis(2, 1);
select * from target_gizi;

call sp_rekomendasi_menu_aman(2);

select current_time();
call sp_buat_pesanan_otomatis_kurir(2, 3, 'malam', 1);

select * from pemesanan;
select * from stok_bahan;
select * from jadwal_pengiriman;
select * from detail_pengiriman;

call sp_konfirmasi_makanan_diterima(1);

call sp_cek_nota_pelanggan(1);
call sp_rekap_menu_diatas_rata_rata(3);


call sp_cek_pemenuhan_gizi_harian(1, curdate());
call sp_cek_pemenuhan_gizi_harian(1, curdate() + interval 1 day);


update user_biasa set status_user = 'melihat-lihat' where id_user = 1;



show triggers from ddl_catering_sehat;
