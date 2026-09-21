# IOSDecryptHub 越狱插件
#
#   make deb              同时打 rootless + roothide
#   make deb-rootless
#   make deb-roothide
#   make verify-vendor    只校验包版本与 vendor 引擎是否同源（不需要 Xcode）

VERSION := 1.27.5

deb:
	@chmod +x build_deb.sh
	./build_deb.sh all

deb-rootless:
	@chmod +x build_deb.sh
	./build_deb.sh rootless

deb-roothide:
	@chmod +x build_deb.sh
	./build_deb.sh roothide

# 引擎漂移检查：VERSION 与 vendor/dylib/<variant>/decrypt_helper.dylib 必须同源，
# 否则会打出「自称新版、实际旧引擎」的包。build_deb.sh 打包前也会跑同一套校验。
verify-vendor:
	@chmod +x tools/verify_vendor.sh
	./tools/verify_vendor.sh

# 从已发布 release 拉取引擎成品并更新 vendor + manifest（详见 vendor/dylib/README.md）
#   make sync-engine TAG=v1.27.5
sync-engine:
	@chmod +x tools/sync_engine.sh
	./tools/sync_engine.sh $(TAG)

# 仿真回归测试：在 macOS 上把 daemon 跑成真机布局，用线上 release 走完整更新链路
test-updater:
	@chmod +x tests/updater_sim_test.sh
	./tests/updater_sim_test.sh

clean:
	rm -rf build/

.PHONY: deb deb-rootless deb-roothide verify-vendor sync-engine test-updater clean
