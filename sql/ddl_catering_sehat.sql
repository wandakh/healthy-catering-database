create database if not exists ddl_catering_sehat;
use ddl_catering_sehat;

set foreign_key_checks = 0;

drop table if exists detail_pengiriman;
drop table if exists jadwal_pengiriman;
drop table if exists pemesanan;
drop table if exists resep_menu;
drop table if exists stok_bahan;
drop table if exists user_alergi;
drop table if exists target_gizi;
drop table if exists user_biasa;
drop table if exists menu;
drop table if exists kurir;
drop table if exists ahli_gizi;
drop table if exists admin;

-- -------------------------------------------------------------------------
-- tabel master tanpa dependensi
-- -------------------------------------------------------------------------

create table admin (
    id_admin int auto_increment,
    primary key (id_admin)
) engine=innodb;

create table ahli_gizi (
    id_ahli_gizi int auto_increment,
    primary key (id_ahli_gizi)
) engine=innodb;

create table kurir (
    id_kurir int auto_increment,
    nama_kurir varchar(100) not null,
    primary key (id_kurir)
) engine=innodb;

create table menu (
    id_menu int auto_increment,
    nama_menu varchar(100) not null,
    harga_menu int not null,
    kalori_menu int not null default 0,
    kategori_alergen varchar(100) null,
    bahan_isi_menu text not null,
    primary key (id_menu)
) engine=innodb;

create table user_biasa (
    id_user int auto_increment,
    nama varchar(100) not null,
    umur int not null,
    alamat varchar(255) not null,
    berat_badan decimal(5,2) not null,
    tinggi_badan decimal(5,2) not null,
    jenis_kelamin enum('l', 'p') not null,
    status_user enum('melihat-lihat', 'berlangganan') not null default 'melihat-lihat',
    primary key (id_user)
) engine=innodb;

-- -------------------------------------------------------------------------
-- tabel dengan dependensi ke tabel master di atas
-- -------------------------------------------------------------------------

create table target_gizi (
    id_user int not null,
    id_ahli_gizi int not null,
    target_kalori int not null,
    protein decimal(5,2) not null,
    lemak decimal(5,2) not null,
    karbo decimal(5,2) not null,
    primary key (id_user),
    constraint fk_target_gizi_user foreign key (id_user) references user_biasa (id_user) on delete cascade on update cascade,
    constraint fk_target_gizi_ahli_gizi foreign key (id_ahli_gizi) references ahli_gizi (id_ahli_gizi) on update cascade
) engine=innodb;

create table user_alergi (
    id_user_alergi int auto_increment,
    id_user int not null,
    nama_alergi varchar(100) not null,
    primary key (id_user_alergi),
    constraint fk_user_alergi_user foreign key (id_user) references user_biasa (id_user) on delete cascade on update cascade
) engine=innodb;

create table stok_bahan (
    id_stok int auto_increment,
    id_admin int not null,
    nama_bahan varchar(100) not null,
    satuan enum('kg', 'pcs') not null,
    jumlah_stok int not null default 0,
    sisa_gram int not null default 0,
    primary key (id_stok),
    constraint fk_stok_admin foreign key (id_admin) references admin (id_admin) on update cascade
) engine=innodb;

create table resep_menu (
    id_resep int auto_increment,
    id_menu int not null,
    id_stok int not null,
    kebutuhan_bahan int not null,
    primary key (id_resep),
    constraint fk_resep_menu foreign key (id_menu) references menu (id_menu) on delete cascade on update cascade,
    constraint fk_resep_stok foreign key (id_stok) references stok_bahan (id_stok) on delete cascade on update cascade
) engine=innodb;

create table pemesanan (
    id_pemesanan int auto_increment,
    id_user int not null,
    id_menu int not null,
    kategori_waktu enum('pagi', 'siang', 'malam') not null,
    jumlah_porsi int not null,
    tanggal_pesan datetime not null default current_timestamp,
    total_harga int not null,
    primary key (id_pemesanan),
    constraint fk_pemesanan_user foreign key (id_user) references user_biasa (id_user) on update cascade,
    constraint fk_pemesanan_menu foreign key (id_menu) references menu (id_menu) on update cascade,
    index idx_kategori_waktu (kategori_waktu)
) engine=innodb;

create table jadwal_pengiriman (
    id_jadwal int auto_increment,
    id_pemesanan int null,
    id_user int not null,
    id_menu int not null,
    id_kurir int null,
    tanggal_hari date not null,
    status_antar varchar(100) null,
    primary key (id_jadwal),
    constraint fk_jadwal_pemesanan foreign key (id_pemesanan) references pemesanan (id_pemesanan) on delete set null on update cascade,
    constraint fk_jadwal_user foreign key (id_user) references user_biasa (id_user) on update cascade,
    constraint fk_jadwal_menu foreign key (id_menu) references menu (id_menu) on update cascade,
    constraint fk_jadwal_kurir foreign key (id_kurir) references kurir (id_kurir) on update cascade
) engine=innodb;

create table detail_pengiriman (
    id_detail_kirim int auto_increment,
    id_jadwal int not null,
    id_kurir int not null,
    status_pengiriman varchar(50) not null default 'sedang diantar',
    status_pemesanan varchar(50) null,
    primary key (id_detail_kirim),
    constraint fk_detail_jadwal foreign key (id_jadwal) references jadwal_pengiriman (id_jadwal) on delete cascade on update cascade,
    constraint fk_detail_kurir foreign key (id_kurir) references kurir (id_kurir) on update cascade,
    index idx_status_kurir (status_pengiriman)
) engine=innodb;

set foreign_key_checks = 1;


insert into admin (id_admin) values (1), (2);
insert into ahli_gizi (id_ahli_gizi) values (1);
insert into kurir (nama_kurir) values ('bima saputra'), ('citra dewi');

insert into menu (nama_menu, harga_menu, kalori_menu, kategori_alergen, bahan_isi_menu) values
('ayam bakar beras merah', 35000, 450, null, 'dada ayam fillet, beras merah, bumbu bakar, kotak kemasan'),
('salmon panggang', 55000, 400, null, 'daging salmon segar, kotak kemasan'),
('nasi merah salmon bowl', 60000, 480, null, 'beras merah, daging salmon segar, kotak kemasan'),
('ayam kacang almond', 40000, 470, null, 'dada ayam fillet, beras merah, kacang almond, kotak kemasan');