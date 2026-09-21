#!/usr/bin/env bats
load helper
setup() { unit_setup; }
teardown() { unit_teardown; }

# ---------------------------------------------------------------- usernames
@test "username: valid simple" {
  valid_username demo;
}
@test "username: valid with digits, dash, underscore" {
  valid_username user_01-a;
}
@test "username: valid leading underscore" {
  valid_username _svc1;
}
@test "username: valid 32 chars" {
  valid_username "$(printf 'a%.0s' {1..32})";
}
@test "username: blank rejected" {
  ! valid_username "";
}
@test "username: too short rejected" {
  ! valid_username ab;
}
@test "username: too long (33) rejected" {
  ! valid_username "$(printf 'a%.0s' {1..33})";
}
@test "username: uppercase rejected" {
  ! valid_username Demo;
}
@test "username: leading digit rejected" {
  ! valid_username 1demo;
}
@test "username: leading dash rejected" {
  ! valid_username -demo;
}
@test "username: space rejected" {
  ! valid_username "de mo";
}
@test "username: semicolon rejected" {
  ! valid_username 'demo;id';
}
@test "username: pipe rejected" {
  ! valid_username 'demo|id';
}
@test "username: ampersand rejected" {
  ! valid_username 'demo&&id';
}
@test "username: command substitution rejected" {
  ! valid_username 'demo$(id)';
}
@test "username: backtick rejected" {
  ! valid_username 'demo`id`';
}
@test "username: dollar variable rejected" {
  ! valid_username '$HOME';
}
@test "username: newline injection rejected" {
  ! valid_username $'demo\nroot';
}
@test "username: trailing newline rejected" {
  ! valid_username $'demo\n';
}
@test "username: carriage return rejected" {
  ! valid_username $'demo\rx';
}
@test "username: control char rejected" {
  ! valid_username $'demo\x01';
}
@test "username: path traversal rejected" {
  ! valid_username '../etc';
}
@test "username: slash rejected" {
  ! valid_username 'a/b/c';
}
@test "username: colon rejected" {
  ! valid_username 'demo:x';
}
@test "username: reserved root rejected" {
  ! valid_username root;
}
@test "username: reserved admin rejected" {
  ! valid_username admin;
}
@test "username: reserved sshd rejected" {
  ! valid_username sshd;
}
@test "username: unicode rejected" {
  ! valid_username 'démo';
}

# ---------------------------------------------------------------- passwords
@test "password: valid mixed" {
  valid_password 'Abcd1234!x';
}
@test "password: valid 8 chars" {
  valid_password 'abcdefg1';
}
@test "password: valid 64 chars" {
  valid_password "$(printf 'a%.0s' {1..64})";
}
@test "password: 7 chars rejected" {
  ! valid_password 'abcdef1';
}
@test "password: 65 chars rejected" {
  ! valid_password "$(printf 'a%.0s' {1..65})";
}
@test "password: empty rejected" {
  ! valid_password '';
}
@test "password: space rejected" {
  ! valid_password 'abcd efgh1';
}
@test "password: colon rejected" {
  ! valid_password 'abcd:efgh1';
}
@test "password: at-sign rejected" {
  ! valid_password 'abcd@efgh1';
}
@test "password: quote rejected" {
  ! valid_password "abcd'efgh1";
}
@test "password: backslash rejected" {
  ! valid_password 'abcd\efgh1';
}
@test "password: dollar rejected" {
  ! valid_password 'abcd$efgh1';
}
@test "password: backtick rejected" {
  ! valid_password 'abcd`efgh1';
}
@test "password: newline rejected" {
  ! valid_password $'abcdefgh\nroot:x';
}
@test "password: tab rejected" {
  ! valid_password $'abcd\tefgh1';
}
@test "generated password is valid and 14 chars" {
  p="$(gen_password)"
  [ "${#p}" -eq 14 ]
  valid_password "$p"
}
@test "generated passwords differ" {
  [ "$(gen_password)" != "$(gen_password)" ];
}

# -------------------------------------------------------------------- ports
@test "port: 1 valid" {
  valid_port 1;
}
@test "port: 65535 valid" {
  valid_port 65535;
}
@test "port: 36712 valid" {
  valid_port 36712;
}
@test "port: 0 rejected" {
  ! valid_port 0;
}
@test "port: 65536 rejected" {
  ! valid_port 65536;
}
@test "port: negative rejected" {
  ! valid_port -1;
}
@test "port: letters rejected" {
  ! valid_port 22a;
}
@test "port: empty rejected" {
  ! valid_port "";
}
@test "port: leading zeros are decimal not octal" {
  valid_port 0080;
}
@test "port: huge number rejected" {
  ! valid_port 99999999999;
}
@test "port: injection rejected" {
  ! valid_port '22; id';
}
@test "port: newline rejected" {
  ! valid_port $'22\n23';
}

@test "portspec: single" {
  valid_port_spec 36712;
}
@test "portspec: range" {
  valid_port_spec 20000-50000;
}
@test "portspec: list" {
  valid_port_spec 53,123,7300;
}
@test "portspec: mixed list and range" {
  valid_port_spec 53,20000-30000,40000;
}
@test "portspec: reversed range rejected" {
  ! valid_port_spec 50000-20000;
}
@test "portspec: port 0 in range rejected" {
  ! valid_port_spec 0-100;
}
@test "portspec: >65535 rejected" {
  ! valid_port_spec 1-70000;
}
@test "portspec: empty rejected" {
  ! valid_port_spec "";
}
@test "portspec: trailing comma rejected" {
  ! valid_port_spec 53,;
}
@test "portspec: double comma rejected" {
  ! valid_port_spec 53,,123;
}
@test "portspec: leading comma rejected" {
  ! valid_port_spec ,53;
}
@test "portspec: spaces rejected" {
  ! valid_port_spec '53, 123';
}
@test "portspec: letters rejected" {
  ! valid_port_spec 53,abc;
}
@test "portspec: triple range rejected" {
  ! valid_port_spec 1-2-3;
}
@test "portspec: injection rejected" {
  ! valid_port_spec '53;reboot';
}
@test "portspec: newline rejected" {
  ! valid_port_spec $'53\n123';
}
@test "portspec: more than 64 items rejected" {
  ! valid_port_spec "$(seq -s, 1 65)";
}
@test "portspec: exactly 64 items accepted" {
  valid_port_spec "$(seq -s, 1 64)";
}

@test "ports_normalize: single range" {
  [ "$(ports_normalize 20000-50000)" = "20000-50000" ];
}
@test "ports_normalize: sorts" {
  [ "$(ports_normalize 300,100,200 | tr '\n' ' ')" = "100-100 200-200 300-300 " ];
}
@test "ports_normalize: merges overlaps" {
  [ "$(ports_normalize 1-10,5-20)" = "1-20" ];
}
@test "ports_normalize: merges adjacent" {
  [ "$(ports_normalize 1-10,11-20)" = "1-20" ];
}
@test "ports_normalize: keeps gaps" {
  [ "$(ports_normalize 1-10,12-20 | tr '\n' ' ')" = "1-10 12-20 " ];
}
@test "ports_normalize: duplicates collapse" {
  [ "$(ports_normalize 53,53,53)" = "53-53" ];
}
@test "ports_subtract: exclusion in the middle" {
  [ "$(ports_subtract "$(ports_normalize 1-100)" "$(ports_normalize 50)" | tr '\n' ' ')" = "1-49 51-100 " ]
}
@test "ports_subtract: exclusion at the edges" {
  [ "$(ports_subtract "$(ports_normalize 1-100)" "$(ports_normalize 1,100)" | tr '\n' ' ')" = "2-99 " ]
}
@test "ports_subtract: multiple exclusions" {
  [ "$(ports_subtract "$(ports_normalize 20000-50000)" "$(ports_normalize 53,123,7300,36712)" | ports_pretty)" = "20000-36711,36713-50000" ]
}
@test "ports_subtract: exclusion outside range changes nothing" {
  [ "$(ports_subtract "$(ports_normalize 20000-30000)" "$(ports_normalize 53)")" = "20000-30000" ]
}
@test "ports_subtract: everything excluded leaves nothing" {
  [ -z "$(ports_subtract "$(ports_normalize 10-20)" "$(ports_normalize 1-100)")" ]
}
@test "ports_subtract: exclusion range spanning several includes" {
  [ "$(ports_subtract "$(ports_normalize 1-10,20-30)" "$(ports_normalize 5-25)" | ports_pretty)" = "1-4,26-30" ]
}
@test "ports_count counts all ports" {
  [ "$(ports_normalize 1-10,20-30 | ports_count)" = "21" ];
}
@test "port_in_lines true and false" {
  L="$(ports_normalize 1-10,20-30)"
  port_in_lines 25 "$L"
  ! port_in_lines 15 "$L"
}
@test "protected ports are never redirected even if requested" {
  cfg_write_defaults
  cfg_set UDP_PORTS 1-65535
  cfg_set UDP_EXCLUDE ""
  udp_listening_ports() { :; }
  R="$(fw_effective_ranges)"
  for p in 53 67 68 123 443 500 4500 5353 51820 1194; do
    ! port_in_lines "$p" "$R"
  done
  port_in_lines 22222 "$R"
}
@test "listen port is excluded from the redirect range" {
  cfg_write_defaults
  udp_listening_ports() { :; }
  ! port_in_lines 36712 "$(fw_effective_ranges)"
}
@test "live UDP listeners inside the range are excluded automatically" {
  cfg_write_defaults
  udp_listening_ports() { echo 25000; }
  R="$(fw_effective_ranges)"
  ! port_in_lines 25000 "$R"
  port_in_lines 25001 "$R"
}

# -------------------------------------------------------------------- dates
@test "date: valid" {
  valid_date 2026-10-21;
}
@test "date: leap day valid" {
  valid_date 2028-02-29;
}
@test "date: non-leap Feb 29 rejected" {
  ! valid_date 2027-02-29;
}
@test "date: month 13 rejected" {
  ! valid_date 2026-13-01;
}
@test "date: day 32 rejected" {
  ! valid_date 2026-01-32;
}
@test "date: wrong format rejected" {
  ! valid_date 21-10-2026;
}
@test "date: slashes rejected" {
  ! valid_date 2026/10/21;
}
@test "date: empty rejected" {
  ! valid_date "";
}
@test "date: words rejected" {
  ! valid_date tomorrow;
}
@test "date: relative expression rejected" {
  ! valid_date '2026-10-21 +1 day';
}
@test "date: injection rejected" {
  ! valid_date '2026-10-21;id';
}
@test "date: year before 2000 rejected" {
  ! valid_date 1999-12-31;
}
@test "days: 1 valid" {
  valid_days 1;
}
@test "days: 3650 valid" {
  valid_days 3650;
}
@test "days: 0 rejected" {
  ! valid_days 0;
}
@test "days: 3651 rejected" {
  ! valid_days 3651;
}
@test "days: negative rejected" {
  ! valid_days -5;
}
@test "days: text rejected" {
  ! valid_days ten;
}
@test "maxlogins: bounds" {
  valid_maxlogins 0
  valid_maxlogins 1000
  ! valid_maxlogins 1001
}
@test "date_add_days works across month end" {
  [ "$(date_add_days 2026-01-31 1)" = "2026-02-01" ];
}
@test "days_left computes remaining days" {
  SSHUDP_TODAY=2026-01-01
  [ "$(days_left 2026-01-11)" = "10" ]
}
@test "days_left is negative after expiry" {
  SSHUDP_TODAY=2026-01-11
  [ "$(days_left 2026-01-01)" = "-10" ]
}

# ------------------------------------------------------- hosts / misc values
@test "hostname: simple domain" {
  valid_hostname vpn.example.com;
}
@test "hostname: single label" {
  valid_hostname myserver;
}
@test "hostname: leading hyphen rejected" {
  ! valid_hostname -bad.example.com;
}
@test "hostname: underscore rejected" {
  ! valid_hostname bad_name.example.com;
}
@test "hostname: space rejected" {
  ! valid_hostname 'a b.example.com';
}
@test "hostname: injection rejected" {
  ! valid_hostname 'a.com;id';
}
@test "hostname: too long label rejected" {
  ! valid_hostname "$(printf 'a%.0s' {1..64}).com";
}
@test "hostname: empty rejected" {
  ! valid_hostname "";
}
@test "ipv4: valid" {
  valid_ipv4 203.0.113.10;
}
@test "ipv4: octet 256 rejected" {
  ! valid_ipv4 256.1.1.1;
}
@test "ipv4: 3 octets rejected" {
  ! valid_ipv4 1.2.3;
}
@test "ipv4: leading zero rejected" {
  ! valid_ipv4 01.2.3.4;
}
@test "ipv4: text rejected" {
  ! valid_ipv4 a.b.c.d;
}
@test "ipv6: valid" {
  valid_ipv6 2001:db8::1;
}
@test "ipv6: garbage rejected" {
  ! valid_ipv6 'zz::1';
}
@test "private ipv4 detection" {
  is_private_ipv4 10.1.2.3
  is_private_ipv4 192.168.0.5
  is_private_ipv4 172.16.0.1
  ! is_private_ipv4 203.0.113.10
  ! is_private_ipv4 172.32.0.1
}
@test "backup name: valid" {
  valid_backup_name sshudp-backup-20260101-120000.tar.gz;
}
@test "backup name: valid with tag" {
  valid_backup_name sshudp-backup-20260101-120000-preupdate.tar.gz;
}
@test "backup name: traversal rejected" {
  ! valid_backup_name ../sshudp-backup-20260101-120000.tar.gz;
}
@test "backup name: absolute rejected" {
  ! valid_backup_name /etc/passwd;
}
@test "backup name: wrong prefix rejected" {
  ! valid_backup_name evil-20260101-120000.tar.gz;
}
@test "backup name: wrong suffix rejected" {
  ! valid_backup_name sshudp-backup-20260101-120000.tar;
}
@test "valid_choice" {
  valid_choice a a b
  ! valid_choice c a b
}
@test "semver: valid and invalid" {
  valid_semver 1.2.3
  ! valid_semver 1.2
  ! valid_semver v1.2.3
  ! valid_semver 1.2.3-rc1
}
@test "semver_gt orders numerically not lexically" {
  semver_gt 1.10.0 1.9.0
  ! semver_gt 1.9.0 1.10.0
  ! semver_gt 1.0.0 1.0.0
}
@test "human_bytes formats" {
  [ "$(human_bytes 0)" = "0 B" ]
  [ "$(human_bytes 2048)" = "2.00 KiB" ]
  [ "$(human_bytes 5242880)" = "5.00 MiB" ]
}
@test "human_duration formats" {
  [ "$(human_duration 42)" = "42s" ]
  [ "$(human_duration 3700)" = "1h 01m" ]
  [ "$(human_duration 270000)" = "3d 03h" ]
}
