#!/usr/bin/env ucode

'use strict';

import { popen, mkdir, unlink, writefile, open, stat, stdout } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';

function to_array(val) {
	let res =[];
	if (type(val) == 'array') {
		for (let i = 0; i < length(val); i++) {
			if (type(val[i]) == 'string') {
				let s = replace(val[i], /^\s+|\s+$/g, '');
				if (s != "") push(res, s);
			}
		}
	} else if (type(val) == 'string') {
		let parts = split(val, /[ \t\n]+/);
		for (let i = 0; i < length(parts); i++) {
			if (parts[i] != "") push(res, parts[i]);
		}
	}
	return res;
}

function exec_sys(cmd) {
	let p = popen(cmd + " 2>&1", "r");
	if (!p) return { code: -1, stdout: "" };
	let stdout = p.read("all");
	let code = p.close();
	if (type(stdout) == 'string') {
		stdout = replace(stdout, /^\s+|\s+$/g, '');
	}
	return { code: code, stdout: stdout || "" };
}

function logfile_path() {
	let uci_cursor = cursor();
	uci_cursor.load('mosdns');
	let configfile = uci_cursor.get('mosdns', 'config', 'configfile');
	let log_file = "";
	if (configfile === "/var/etc/mosdns.json" || !configfile) {
		log_file = uci_cursor.get('mosdns', 'config', 'log_file');
		return log_file || "";
	}
	let f = require("fs").open(configfile, "r");
	if (f) {
		let found_log = false;
		let is_error_or_warn = false;
		let log_file_tmp = null;
		let line;
		while ((line = f.read("line"))) {
			if (match(line, /^log:/)) {
				found_log = true;
				continue;
			}
			if (found_log) {
				if (match(line, /^[^ \t\r\n]/)) break;
				let m_level = match(line, /level:\s*['"]?([^'" \t\r\n]+)/);
				if (m_level) {
					if(m_level[1] === "error" || m_level[1] === "warn") {
						is_error_or_warn = true;
					}
				}
				let m_file = match(line, /file:\s*['"]?([^'" \t\r\n]+)/);
				if (m_file) {
					log_file_tmp = m_file[1];
				}
			}
		}
		f.close();
		if (!is_error_or_warn) {
			return log_file_tmp;
		}
		return "";
	}
	return null;
}

function interface_dns() {
	let uci_cursor = cursor();
	uci_cursor.load('mosdns');
	let dns_list =[];

	if (uci_cursor.get('mosdns', 'config', 'custom_local_dns') === '1') {
		dns_list = to_array(uci_cursor.get('mosdns', 'config', 'local_dns'));
	} else {
		uci_cursor.load('network');
		let peerdns = uci_cursor.get('network', 'wan', 'peerdns');
		let proto = uci_cursor.get('network', 'wan', 'proto');

		if (peerdns === '0' || proto === 'static') {
			dns_list = to_array(uci_cursor.get('network', 'wan', 'dns'));
		} else {
			let ubus_conn = connect();
			if (ubus_conn) {
				let status = ubus_conn.call('network.interface.wan', 'status');
				if (status && type(status['dns-server']) == 'array' && length(status['dns-server']) > 0) {
					dns_list = status['dns-server'];
				}
			}
		}
	}

	if (length(dns_list) === 0) {
		dns_list =['119.29.29.29', '223.5.5.5'];
	}
	print(join(" ", dns_list) + "\n");
}

function get_adlist() {
	let uci_cursor = cursor();
	uci_cursor.load('mosdns');
	let adblock = uci_cursor.get('mosdns', 'config', 'adblock');

	if (adblock !== '1') {
		mkdir('/etc/mosdns/rule', 0755);
		exec_sys('rm -rf /etc/mosdns/rule/adlist /etc/mosdns/rule/.ad_source');
		writefile('/var/mosdns/disable-ads.txt', '');
		print("/var/mosdns/disable-ads.txt\n");
		return;
	}

	mkdir('/etc/mosdns/rule/adlist', 0755);
	let ad_source = to_array(uci_cursor.get('mosdns', 'config', 'ad_source'));
	let adlist =[];

	for (let i = 0; i < length(ad_source); i++) {
		let url = ad_source[i];
		if (!url) continue;

		if (url === 'geosite.dat') {
			push(adlist, '/var/mosdns/geosite_category-ads-all.txt');
		} else if (index(url, 'file://') === 0) {
			push(adlist, substr(url, 7));
		} else {
			let parts = split(url, '/');
			let filename = parts[length(parts) - 1];
			let local_path = `/etc/mosdns/rule/adlist/${filename}`;
			if (!stat(local_path)) {
				writefile(local_path, '');
			}
			push(adlist, local_path);
		}
	}
	print(join("\n", adlist) + "\n");
}

function update_adlist() {
	let ad_updated = false;
	let uci_cursor = cursor();
	uci_cursor.load('mosdns');

	if (uci_cursor.get('mosdns', 'config', 'adblock') !== '1') {
		exec_sys('rm -rf /etc/mosdns/rule/adlist /etc/mosdns/rule/.ad_source');
		return true;
	}

	let ad_lock_file = '/var/lock/mosdns_ad_update.lock';
	let ad_source = to_array(uci_cursor.get('mosdns', 'config', 'ad_source'));
	let github_proxy = uci_cursor.get('mosdns', 'config', 'github_proxy') || '';
	if (length(ad_source) === 0) {
		return true;
	}


	let s = stat(ad_lock_file);
	if (s) {
		let now = time();
		if (now - s.mtime > 300) {
			print("\x1b[1;33m检测到过期的ad锁文件（已超过5分钟），强制解锁...\x1b[0m\n");
			stdout.flush();
			exec_sys('logger -t "mosdns" -p info "检测到过期的ad锁文件（已超过5分钟），强制解锁..."');
			unlink(ad_lock_file);
		} else {
			print("Adlist更新任务已在运行中，跳过。\n");
			stdout.flush();
			exec_sys('logger -t "mosdns" -p info "Adlist already running.Skip this!"');
			return false;
		}
	}

	mkdir('/etc/mosdns/rule', 0755);
	writefile('/etc/mosdns/rule/.ad_source', '');

	writefile(ad_lock_file, '');
	let tmp_res = exec_sys('mktemp -d');
	if (tmp_res.code !== 0) {
		print("Failed to create temp directory for adlist.\n");
		stdout.flush();
		unlink(ad_lock_file);
		return false;
	}
	let ad_tmpdir = tmp_res.stdout;

	for (let i = 0; i < length(ad_source); i++) {
		let url = ad_source[i];
		if (!url) continue;

		if (url !== 'geosite.dat' && index(url, 'file://') !== 0) {
			ad_updated = true;
			exec_sys(`echo "${url}" >> /etc/mosdns/rule/.ad_source`);

			let parts = split(url, '/');
			let filename = parts[length(parts) - 1];
			let mirror = "";

			if (match(url, /^https:\/\/raw\.githubusercontent\.com/)) {
				mirror = github_proxy ? github_proxy + '/' : '';
			}

			print(`Downloading ${mirror}${url}\n`);
			stdout.flush();
			let curl_res = exec_sys(`wget -T 30 -4 --no-check-certificate -O "${ad_tmpdir}/${filename}" "${mirror}${url}"`);
			if (curl_res.code !== 0) {
				exec_sys(`echo "failed: ${filename}" > "${ad_tmpdir}/${filename}.err"`);
			} else {
				exec_sys(`echo "success: ${filename}" > "${ad_tmpdir}/${filename}.status"`);
			}
		}
	}
	if (!ad_updated) {
		exec_sys(`rm -rf "${ad_tmpdir}"`);
		unlink(ad_lock_file);
		return false
	}
	const fs = require("fs");
	let error_count = length(fs.glob(`${ad_tmpdir}/*.err`)) || 0;
	if (error_count > 0) {
		print("\x1b[1;31mRules download failed.\x1b[0m\n");
		stdout.flush();
		exec_sys(`logger -t "mosdns" -p err "Adlist update failed! ${error_count} Rules download failed."`);
		exec_sys(`rm -rf "${ad_tmpdir}"`);
		unlink(ad_lock_file);
		return false;
	} else {
		exec_sys(`rm -rf "${ad_tmpdir}"/*.err "${ad_tmpdir}"/*.status`);
		let has_content = false;
		let files = fs.glob(`${ad_tmpdir}/*`);
		if (files && length(files) > 0) {
			for (let f in files) {
				if (system(`test -s "${f}"`) === 0) {
					has_content = true;
					break;
				}
			}
		}
		if (!has_content) {
			print("\x1b[1;31mRules download void.\x1b[0m\n");
			stdout.flush();
			exec_sys('logger -t "mosdns" -p err "Adlist Rules download void."');
			exec_sys(`rm -rf "${ad_tmpdir}"`);
			unlink(ad_lock_file);
			return false;
		}
	}
	mkdir('/etc/mosdns/rule/adlist', 0755);
	exec_sys('rm -rf /etc/mosdns/rule/adlist/*');
	exec_sys(`cp "${ad_tmpdir}"/* /etc/mosdns/rule/adlist/`);
	exec_sys('logger -t "mosdns" -p info "Adlist update successfully."');
	print("\x1b[1;32mAdlist update successfully.\x1b[0m\n");
	stdout.flush();
	exec_sys(`rm -rf "${ad_tmpdir}"`);
	unlink(ad_lock_file);
	return ad_updated;

}

function update_geodat() {
	let result = { geo_updated: false, geo_result: false };
	let uci_cursor = cursor();
	uci_cursor.load('mosdns');

	let geo_lock_file = '/var/lock/mosdns_geo_update.lock';
	let s = stat(geo_lock_file);
	if (s) {
		let now = time();
		if (now - s.mtime > 300) {
			print("\x1b[1;33m检测到过期的geo锁文件（已超过5分钟），强制解锁...\x1b[0m\n");
			stdout.flush();
			exec_sys('logger -t "mosdns" -p info "检测到过期的geo锁文件（已超过5分钟），强制解锁..."');
			unlink(geo_lock_file);
		} else {
			print("Geodata更新任务已在运行中，跳过。\n");
			stdout.flush();
			exec_sys('logger -t "mosdns" -p info "GeoDat already running.Skip this!"');
			return result;
		}
	}

	writefile(geo_lock_file, '');
	let github_proxy = uci_cursor.get('mosdns', 'config', 'github_proxy') || '';
	let mirror = github_proxy ? github_proxy + '/' : '';
	let geoip_type = uci_cursor.get('mosdns', 'config', 'geoip_type') || 'geoip-only-cn-private';
	let v2dat_dir = '/usr/share/v2ray';

	let tmp_res = exec_sys('mktemp -d');
	if (tmp_res.code !== 0) {
		print("Failed to create temp directory for geodat.\n");
		stdout.flush();
		unlink(geo_lock_file);
		return result;
	}
	let geo_tmpdir = tmp_res.stdout;
	exec_sys(`mkdir -p "${v2dat_dir}"`);

	let geoip_url = mirror + "https://github.com/Loyalsoldier/geoip/releases/latest/download/" + geoip_type + ".dat";

	print(`Downloading ${geoip_url}.sha256sum\n`);
	stdout.flush();
	if (exec_sys(`wget -T 30 -4 --no-check-certificate -O "${geo_tmpdir}/geoip.dat.sha256sum" "${geoip_url}.sha256sum"`).code !== 0) {
		print("\x1b[1;31mGeoip.dat Failed to download checksum file.\x1b[0m\n");
		stdout.flush();
		exec_sys('logger -t "mosdns" -p err "Geoip.dat Failed to download checksum file."');
		exec_sys(`rm -rf "${geo_tmpdir}"`);
		unlink(geo_lock_file);
		return result;
	}

	let geoip_sum_remote = split(exec_sys(`cat "${geo_tmpdir}/geoip.dat.sha256sum"`).stdout, /[ \t\n]+/)[0];
	let geoip_sum_local = "";
	if (stat(`${v2dat_dir}/geoip.dat`)) {
		geoip_sum_local = split(exec_sys(`sha256sum "${v2dat_dir}/geoip.dat"`).stdout, /[ \t\n]+/)[0];
	}

	if (geoip_sum_local === geoip_sum_remote) {
		exec_sys('logger -t "mosdns" -p info "Geoip.dat is up to date."');
		print("\x1b[1;32mGeoip.dat is up to date.\x1b[0m\n");
		stdout.flush();
	} else {
		print(`Downloading ${geoip_url}\n`);
		stdout.flush();
		if (exec_sys(`wget -T 30 -4 --no-check-certificate -O "${geo_tmpdir}/geoip.dat" "${geoip_url}"`).code !== 0) {
			print("\x1b[1;31mGeoip.dat download error.\x1b[0m\n");
			stdout.flush();
			exec_sys('logger -t "mosdns" -p err "Geoip.dat download error."');
			exec_sys(`rm -rf "${geo_tmpdir}"`);
			unlink(geo_lock_file);
			return result;
		}

		let sum_downloaded = split(exec_sys(`sha256sum "${geo_tmpdir}/geoip.dat"`).stdout, /[ \t\n]+/)[0];
		if (sum_downloaded !== geoip_sum_remote) {
			print("\x1b[1;31mGeoip.dat checksum error.\x1b[0m\n");
			stdout.flush();
			exec_sys('logger -t "mosdns" -p err "Geoip.dat checksum error."');
			exec_sys(`rm -rf "${geo_tmpdir}"`);
			unlink(geo_lock_file);
			return result;
		}
		exec_sys(`cp -a "${geo_tmpdir}/geoip.dat" "${v2dat_dir}/"`);
		exec_sys('logger -t "mosdns" -p info "Geoip update successfully."');
		print("\x1b[1;32mGeoip update successfully.\x1b[0m\n");
		stdout.flush();
		result.geo_updated = true;
	}

	let geosite_url = mirror + "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat";

	print(`Downloading ${geosite_url}.sha256sum\n`);
	stdout.flush();
	if (exec_sys(`wget -T 20 -4 --no-check-certificate -O "${geo_tmpdir}/geosite.dat.sha256sum" "${geosite_url}.sha256sum"`).code !== 0) {
		print("\x1b[1;31mGeosite.dat Failed to download checksum file.\x1b[0m\n");
		stdout.flush();
		exec_sys('logger -t "mosdns" -p err "Geosite.dat Failed to download checksum file."');
		exec_sys(`rm -rf "${geo_tmpdir}"`);
		unlink(geo_lock_file);
		return result;
	}

	let geosite_sum_remote = split(exec_sys(`cat "${geo_tmpdir}/geosite.dat.sha256sum"`).stdout, /[ \t\n]+/)[0];
	let geosite_sum_local = "";
	if (stat(`${v2dat_dir}/geosite.dat`)) {
		geosite_sum_local = split(exec_sys(`sha256sum "${v2dat_dir}/geosite.dat"`).stdout, /[ \t\n]+/)[0];
	}

	if (geosite_sum_local === geosite_sum_remote) {
		exec_sys('logger -t "mosdns" -p info "Geosite.dat is up to date."');
		print("\x1b[1;32mGeosite.dat is up to date.\x1b[0m\n");
		stdout.flush();
	} else {
		print(`Downloading ${geosite_url}\n`);
		stdout.flush();
		if (exec_sys(`wget -T 120 -4 --no-check-certificate -O "${geo_tmpdir}/geosite.dat" "${geosite_url}"`).code !== 0) {
			print("\x1b[1;31mGeosite.dat download error.\x1b[0m\n");
			stdout.flush();
			exec_sys('logger -t "mosdns" -p err "Geosite.dat download error."');
			exec_sys(`rm -rf "${geo_tmpdir}"`);
			unlink(geo_lock_file);
			return result;
		}

		let sum_downloaded = split(exec_sys(`sha256sum "${geo_tmpdir}/geosite.dat"`).stdout, /[ \t\n]+/)[0];
		if (sum_downloaded !== geosite_sum_remote) {
			print("\x1b[1;31mGeosite.dat checksum error.\x1b[0m\n");
			stdout.flush();
			exec_sys('logger -t "mosdns" -p err "Geosite.dat checksum error."');
			exec_sys(`rm -rf "${geo_tmpdir}"`);
			unlink(geo_lock_file);
			return result;
		}
		exec_sys(`cp -a "${geo_tmpdir}/geosite.dat" "${v2dat_dir}/"`);
		exec_sys('logger -t "mosdns" -p info "Geosite update successfully."');
		print("\x1b[1;32mGeosite update successfully.\x1b[0m\n");
		stdout.flush();
		result.geo_updated = true;
	}
	exec_sys(`rm -rf "${geo_tmpdir}"`);
	unlink(geo_lock_file);
	result.geo_result = true;
	return result;

}

function v2dat_dump() {
	let uci_cursor = cursor();
	uci_cursor.load('mosdns');
	let v2dat_dir = '/usr/share/v2ray';
	let configfile = uci_cursor.get('mosdns', 'config', 'configfile') || '/var/etc/mosdns.json';
	let adblock = uci_cursor.get('mosdns', 'config', 'adblock');
	let ad_source = uci_cursor.get('mosdns', 'config', 'ad_source') || "";
	let streaming_media = uci_cursor.get('mosdns', 'config', 'custom_stream_media_dns');

	mkdir('/var/mosdns', 0755);
	exec_sys('rm -f /var/mosdns/geo*.txt');
	let logfile = logfile_path();
	if (!logfile || logfile === "") {
		logfile = "/dev/null";
	}

	if (configfile === "/var/etc/mosdns.json") {
		exec_sys(`geo2txt geoip -f ${v2dat_dir}/geoip.dat -e cn -o /var/mosdns >> ${logfile} 2>&1`);
		exec_sys(`geo2txt geosite -f ${v2dat_dir}/geosite.dat -e cn -e apple -e 'geolocation-!cn' -o /var/mosdns >> ${logfile} 2>&1`);

		if (adblock === '1' && index(ad_source, 'geosite.dat') !== -1) {
			exec_sys(`geo2txt geosite -f ${v2dat_dir}/geosite.dat -e category-ads-all -o /var/mosdns >> ${logfile} 2>&1`);
		}

		if (streaming_media === '1') {
			exec_sys(`geo2txt geosite -f ${v2dat_dir}/geosite.dat -e netflix -e disney -e hulu -o /var/mosdns >> ${logfile} 2>&1`);
		} else {
			writefile('/var/mosdns/geosite_disney.txt', '');
			writefile('/var/mosdns/geosite_netflix.txt', '');
			writefile('/var/mosdns/geosite_hulu.txt', '');
		}
	} else {
		let geoip_tags = to_array(uci_cursor.get('mosdns', 'config', 'geoip_tags'));
		if (length(geoip_tags) > 0) {
			let tags_str = "-e '" + join("' -e '", geoip_tags) + "'";
			exec_sys(`geo2txt geoip -f ${v2dat_dir}/geoip.dat ${tags_str} -o /var/mosdns >> ${logfile} 2>&1`);
		}

		let geosite_tags = to_array(uci_cursor.get('mosdns', 'config', 'geosite_tags'));
		if (length(geosite_tags) > 0) {
			let tags_str = "-e '" + join("' -e '", geosite_tags) + "'";
			exec_sys(`geo2txt geosite -f ${v2dat_dir}/geosite.dat ${tags_str} -o /var/mosdns >> ${logfile} 2>&1`);
		}
	}
}

let action = ARGV[0];

switch (action) {
	case "interface_dns":
		interface_dns();
		break;
	case "get_adlist":
		get_adlist();
		break;
	case "update":
		let update_lock_file = '/var/lock/mosdns_update.lock';
		let s = stat(update_lock_file);
		if (s) {
			let now = time();
			if (now - s.mtime > 300) {
				print("\x1b[1;33m检测到过期的update锁文件（已超过5分钟），强制解锁...\x1b[0m\n");
				exec_sys('logger -t "mosdns" -p info "检测到过期的update锁文件（已超过5分钟），强制解锁..."');
				unlink(update_lock_file);
			} else {
				print("Another update is already in progress.\n");
				exec_sys('logger -t "mosdns" -p info "Update already running.Skip this!"');
				exit(0);
			}
		}
		writefile(update_lock_file, '');
		exec_sys('logger -t "mosdns" -p info "========================================GEO_DATA_UPDATE_TASK_STARTED========================================"');
		try {
			let geo_update_result = update_geodat();
			let adList_update_result = update_adlist();
			if (geo_update_result.geo_updated) {
				v2dat_dump();
			}
			if (geo_update_result.geo_result && adList_update_result) {
				print("UPDATE_FINISHED\n");
			} else {
				print("UPDATE_EXITED\n");
			}
			stdout.flush();
		} catch (e) {
			print("Update failed: " + e + "\n");
			print("UPDATE_EXITED\n");
			stdout.flush();
		}
		exec_sys('logger -t "mosdns" -p info "====================GEO_DATA_UPDATE_TASK_END===================="');
		unlink(update_lock_file);
		break;
	case "update_adlist":
		update_adlist();
		break;
	case "v2dat_dump":
		v2dat_dump();
		break;
	default:
		exit(0);
}
