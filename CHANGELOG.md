# Changelog

## [1.6.0](https://github.com/junkyard-computing/junkyard-boot-img/compare/v1.5.1...v1.6.0) (2026-08-12)


### Features

* **provisioning:** PowerShell scripts, so the kit works on the contractor's Windows PC ([e040d28](https://github.com/junkyard-computing/junkyard-boot-img/commit/e040d28774634ea53c1b2143f7e92604c4fef70c))


### Bug Fixes

* **build:** a pristine kernel tree is not drift — it aborted every post-sync build ([ea79f84](https://github.com/junkyard-computing/junkyard-boot-img/commit/ea79f84d9af13023f7af3ec9fb396bd19b19e8da))
* **build:** the flake knew how to provide cargo and gave it to only one of three shells ([d4efffe](https://github.com/junkyard-computing/junkyard-boot-img/commit/d4efffe449a624f986284ec0395dba457ed53711))
* **provisioning:** a failed flash exited 0, and `erase super` ran before the image check ([f358446](https://github.com/junkyard-computing/junkyard-boot-img/commit/f358446bd581b3c619089458a001640b69a3ae24))

## [1.5.1](https://github.com/junkyard-computing/junkyard-boot-img/compare/v1.5.0...v1.5.1) (2026-08-05)


### Bug Fixes

* **build:** `clean` and `all` must cover super.img — it was silently stale ([e78e85b](https://github.com/junkyard-computing/junkyard-boot-img/commit/e78e85b2f9368030e0cdeb2bd4932acc1dd98328))

## [1.5.0](https://github.com/junkyard-computing/junkyard-boot-img/compare/v1.4.0...v1.5.0) (2026-08-05)


### Features

* **ab:** commit the slot when a rollback could not achieve anything ([37a1dcd](https://github.com/junkyard-computing/junkyard-boot-img/commit/37a1dcd67bc9257b8fe0998ed5ba0927b9207284))
* **ab:** full-flash super.img, and point flash-fastboot at it ([6b08778](https://github.com/junkyard-computing/junkyard-boot-img/commit/6b0877813a106d5098b793618bcb1e722d20eaf6))
* **ab:** make the flash hook handle both rootfs layouts ([7858bbb](https://github.com/junkyard-computing/junkyard-boot-img/commit/7858bbb810d6d05fa5bf77e0361300dfde68f3b3))
* **ab:** map the active rootfs slot out of super with dm-linear ([d24a71c](https://github.com/junkyard-computing/junkyard-boot-img/commit/d24a71cb78b8c7ecf51f2a763c995c8fd123a01a))
* **ab:** raise the retry budget once per install, never commit the slot ([43e6223](https://github.com/junkyard-computing/junkyard-boot-img/commit/43e62237c17c682119abdc8f15233f92187438c3))
* **build:** expose fleet_id through `just all` ([47606cd](https://github.com/junkyard-computing/junkyard-boot-img/commit/47606cda3cd6072832c10fdecf273c255c197a95))
* **debug:** put the kernel log on the debug UART ([4bcf68d](https://github.com/junkyard-computing/junkyard-boot-img/commit/4bcf68db9ae9fbdd5a9c83d447b66f6232b0c05b))
* **diag:** surface the previous boot's pstore and network state on UART ([b956704](https://github.com/junkyard-computing/junkyard-boot-img/commit/b956704cd1614a2535961ca1b31de892d7c4f0ce))
* **fleet:** dedicated deploy key, shared via age rather than handed around ([a94dede](https://github.com/junkyard-computing/junkyard-boot-img/commit/a94dede1420fbf482011b92bcafcbf79c89a53d4))
* **fleet:** exclusion list for the lab units — they are not shippable targets ([0ca41b1](https://github.com/junkyard-computing/junkyard-boot-img/commit/0ca41b103874965bb1e5de4ddd21287c3c6747aa))
* **fleet:** flash-nmap.sh — discover the fleet and OTA it in canaried waves ([4621a32](https://github.com/junkyard-computing/junkyard-boot-img/commit/4621a32182132a074e6c5943ae0a79fe67a5f051))
* **fleet:** stamp the image's target DEVICE and refuse cross-device flashes ([ec2215d](https://github.com/junkyard-computing/junkyard-boot-img/commit/ec2215db4e23db7c3065a1bb35c42cb8d5ee3e02))
* **image:** bake SSH authorized_keys in — the OTA was destroying its own access ([82ac55a](https://github.com/junkyard-computing/junkyard-boot-img/commit/82ac55ae3f3d78a3842d48194515deff699752e1))
* **kernel:** -dirty should mean uncommitted work, not "a patch was applied" ([21207ce](https://github.com/junkyard-computing/junkyard-boot-img/commit/21207ceeabe6726a60a8a34d29e0a5d73ce44675))
* **kernel:** build netconsole in, and bound the reboot watchdog ([f9615ec](https://github.com/junkyard-computing/junkyard-boot-img/commit/f9615ec9452c03156c7e88524c11e90fdd47013b))
* **kernel:** survive the add_uevent_var boot panic instead of dying on it ([239e02a](https://github.com/junkyard-computing/junkyard-boot-img/commit/239e02ad32a2654c2f6fc02c2f9298fe1cb274bd))
* **netcheck:** bounce the USB host role before resorting to a reboot ([2ef1e11](https://github.com/junkyard-computing/junkyard-boot-img/commit/2ef1e110db7aabcc4a1f65f33f5df1cf28564f5d))
* **net:** self-healing network recovery, NIC-guarded and bounded ([25561a3](https://github.com/junkyard-computing/junkyard-boot-img/commit/25561a37697d970f18443a068491addcf9273a13))
* **provisioning:** a self-contained kit for whoever flashes the phones ([cb1c3e7](https://github.com/junkyard-computing/junkyard-boot-img/commit/cb1c3e79fc4c03baf46c86607a07458dda32f8b0))
* **resilience:** make the image self-recovering for a headless, buttonless device ([6c2d7dd](https://github.com/junkyard-computing/junkyard-boot-img/commit/6c2d7dde52d0b76321893a909f0cb617580f8567))
* **thermal:** on-device thermal-thresholds knob for AOSP kernel ([faead6a](https://github.com/junkyard-computing/junkyard-boot-img/commit/faead6a17bd82b69ea26d602c132f4036d3cc058))
* **usb:** address usb0 and put a login console on the gadget's ACM port ([1274875](https://github.com/junkyard-computing/junkyard-boot-img/commit/12748759997ae6239a2e2d20524c3e9282f655c9))
* **usb:** recover a dongle that fails to re-attach after reboot ([d0af16e](https://github.com/junkyard-computing/junkyard-boot-img/commit/d0af16efa4cdbd7829bef04f1ce01f5d4b58f37b))
* **usb:** recover the host controller in 2s instead of rebooting ([8d520f2](https://github.com/junkyard-computing/junkyard-boot-img/commit/8d520f26b242ed0a0c7dcb75db32ed0af03416ff))
* **usb:** serve DHCP on the gadget link so the host needs no setup ([1ea23c9](https://github.com/junkyard-computing/junkyard-boot-img/commit/1ea23c93f51cbbf9db77e79135943061bb353e96))


### Bug Fixes

* **ab:** choose the flash target by SIZE, so migration is not refused ([6a50b4c](https://github.com/junkyard-computing/junkyard-boot-img/commit/6a50b4ca111b9ec31e1aa431a56f706dfd451817))
* **ab:** commit the slot early, or a reboot loop silently reverts the image ([2f8fcb5](https://github.com/junkyard-computing/junkyard-boot-img/commit/2f8fcb5436baff00c41a534f54f74f5336c5330b))
* **ab:** the larger retry budget is factory-only; our OTAs keep 7 ([4c01595](https://github.com/junkyard-computing/junkyard-boot-img/commit/4c0159582427382be67cb31327a0b0855c53636c))
* **boot:** bound shutdown and arm the gs201 hardware watchdog ([d6a8716](https://github.com/junkyard-computing/junkyard-boot-img/commit/d6a871612c9f40f9ac978ec5941542dc9d5f862e))
* **boot:** bound the intermittent multi-minute boot with udev.event_timeout=20 ([6d370c6](https://github.com/junkyard-computing/junkyard-boot-img/commit/6d370c64f8e227e0a67924b33a7c4ec855e9eccf))
* **boot:** drop deprecated udev-settle from banner units ([60b81ae](https://github.com/junkyard-computing/junkyard-boot-img/commit/60b81ae97dc87333f0d412a7734e7b2b65038e04))
* **boot:** drop st21nfc — a wedged NFC probe stalls the initramfs for minutes ([7b15bed](https://github.com/junkyard-computing/junkyard-boot-img/commit/7b15bed4ef1fef6ef63d6aff10ebb417d5a15b1b))
* **boot:** drop the hardware watchdog until it is verified on hardware ([77dd6d1](https://github.com/junkyard-computing/junkyard-boot-img/commit/77dd6d141b94b52503dd06a3ef8b9860c989ec0c))
* **boot:** keep the display stack out of the initramfs — it caused the boot stall ([1258fa6](https://github.com/junkyard-computing/junkyard-boot-img/commit/1258fa68aceda13241534a9fff034ef6249d9001))
* **boot:** omit the display drivers from the initramfs, don't just unforce them ([e8b25c1](https://github.com/junkyard-computing/junkyard-boot-img/commit/e8b25c1ce95c5679de0b3486f28471a5bb977274))
* **build:** actually remove retired overlay files from the sysroot ([12213aa](https://github.com/junkyard-computing/junkyard-boot-img/commit/12213aa6828fc54e4cb1aa27253e58c125467463))
* **build:** enable the non-free-firmware component for firmware-realtek ([f1a9a98](https://github.com/junkyard-computing/junkyard-boot-img/commit/f1a9a98429fe00545327cb634f537071f8caaedb))
* **build:** make the rootfs size actually take effect ([4e4186a](https://github.com/junkyard-computing/junkyard-boot-img/commit/4e4186ac93513d257b5a014d930e5e1330dcf9e6))
* **build:** overlay rsync must force root ownership ([a1accdf](https://github.com/junkyard-computing/junkyard-boot-img/commit/a1accdf512cc66f33a749c53624382f9407b8472))
* **build:** repair overlay ANCESTOR dir ownership, not just the leaves ([271e321](https://github.com/junkyard-computing/junkyard-boot-img/commit/271e321a010f7adc9a62e8d587f9e96369cb296c))
* **build:** repair the overlay ancestor-chown line ([2b7cf3f](https://github.com/junkyard-computing/junkyard-boot-img/commit/2b7cf3f6100acea7009a53fc9f79b9457c35ed14))
* **build:** vendor-firmware and ARM-blob rsyncs also need root ownership ([7336e49](https://github.com/junkyard-computing/junkyard-boot-img/commit/7336e49fbd3fc7582246a0b89beb9fd7f1724fec))
* **build:** wipe the unpack tree — dropping a module did not drop it from the image ([cc5ece3](https://github.com/junkyard-computing/junkyard-boot-img/commit/cc5ece3adbab9b7272372fdf44eea2366297a50f))
* **dockershell:** namespace the build image per checkout ([f4ee6dd](https://github.com/junkyard-computing/junkyard-boot-img/commit/f4ee6dd585674eb3a917da70c93bc396efc67155))
* **fastboot:** flash both slots and commit the flashed one ([59625ef](https://github.com/junkyard-computing/junkyard-boot-img/commit/59625ef703e108d989e2039fcca0c3643329bd3e))
* **flash:** require an explicit serial before flashing ([a47babe](https://github.com/junkyard-computing/junkyard-boot-img/commit/a47babe762aa4d30e82ef9b7f319bd3d64122e12))
* **fleet:** refuse to flash blind — a missing debugfs disarmed the canary ([bd8a87e](https://github.com/junkyard-computing/junkyard-boot-img/commit/bd8a87ebe7dacb25b5e579c5d1f3468afc8cf772))
* **initramfs:** reboot on dracut failure instead of hanging at a shell ([4d2b4ba](https://github.com/junkyard-computing/junkyard-boot-img/commit/4d2b4ba52fb73ace121bcae492625f1f10787222))
* **netcheck:** "nothing plugged in" must mean NO NIC, not "no address yet" ([8ad3288](https://github.com/junkyard-computing/junkyard-boot-img/commit/8ad32883f6caff0e2cedd6538656f3895109880d))
* **netcheck:** don't bounce the port while a host is attached to the gadget ([daa33e3](https://github.com/junkyard-computing/junkyard-boot-img/commit/daa33e30f12f3b7128ad5ca70f89e0bf81002cc5))
* **netcheck:** judge the RUNNING slot, not the one devinfo calls active ([51d8652](https://github.com/junkyard-computing/junkyard-boot-img/commit/51d86524131af20af90b50ef9d071d68d4e85652))
* **netcheck:** never roll back a slot that has already proven network ([96ac2db](https://github.com/junkyard-computing/junkyard-boot-img/commit/96ac2dbf350a0f72ee63401c9b2b6b82aee2feeb))
* **netcheck:** no wired NIC must never escalate, proven slot or not ([a860546](https://github.com/junkyard-computing/junkyard-boot-img/commit/a8605461b128f6793a5f7ae2f4b365c1c8d49da0))
* **netcheck:** probe a discovered target SET, not just the gateway ([d9fffee](https://github.com/junkyard-computing/junkyard-boot-img/commit/d9fffee007a47a1f5d386fc06fe3af098ff0b803))
* **netcheck:** probe reachability, not address presence ([788d4f9](https://github.com/junkyard-computing/junkyard-boot-img/commit/788d4f9f648db9c02af746da798e635af818b441))
* **netcheck:** the OTA inhibit must expire, or a dead flash locks us out ([d613f5c](https://github.com/junkyard-computing/junkyard-boot-img/commit/d613f5c74a83a6e33077f69a8d5cacedbb8d5c57))
* **net:** netcheck-recover's no-NIC guard never tripped; reboot-looped a device ([def9243](https://github.com/junkyard-computing/junkyard-boot-img/commit/def924353e8b079f5fb1979a4a5fd73ee20bbd88))
* **net:** ship the r8152 errata firmware and bound NetworkManager's startup ([7c6b856](https://github.com/junkyard-computing/junkyard-boot-img/commit/7c6b8566ecd48b6db20277cce447b277d331a4eb))
* **ota:** "cannot verify" must not silently mean "do nothing" ([4cf1dd8](https://github.com/junkyard-computing/junkyard-boot-img/commit/4cf1dd85f2fa1aaa303ff16614df279f217359a1))
* **ota:** flash-ssh silently skipped the rootfs half, and wrote it unverified ([73dfb46](https://github.com/junkyard-computing/junkyard-boot-img/commit/73dfb465208c11c4cef3cc0730ba12d95adbaf99))
* **ota:** netcheck-recover was rebooting devices in the middle of updates ([396c896](https://github.com/junkyard-computing/junkyard-boot-img/commit/396c896388c8ecc1976ee5f3084570fda9a868f1))
* **ota:** normalise the target slot's AVB flags, or the OTA silently rolls back ([504a312](https://github.com/junkyard-computing/junkyard-boot-img/commit/504a312e53f66daf87553920a154d40cb8901f02))
* **ota:** stage with O_DIRECT — the buffered write was resetting the device ([9864a96](https://github.com/junkyard-computing/junkyard-boot-img/commit/9864a9699e67c16609adada41bb615f52ae5dad8))
* **ota:** the updater could never update itself ([ab0bd5b](https://github.com/junkyard-computing/junkyard-boot-img/commit/ab0bd5b6baafd407758a333c16e4903b092a4c2b))
* **ota:** verify staged rootfs image before it overwrites super ([7cd9bea](https://github.com/junkyard-computing/junkyard-boot-img/commit/7cd9bea946ac1886cca987a5213f6af457a3a6f6))
* provisioning readme cleanup ([eff4a6f](https://github.com/junkyard-computing/junkyard-boot-img/commit/eff4a6fb3a7cd53623f6c841c12961c9649635fd))
* **rootfs-flash:** the digest self-test was measuring its own pipeline ([bd1606d](https://github.com/junkyard-computing/junkyard-boot-img/commit/bd1606d09d41ae3cb066e65fa618b51f4cbd3154))
* **udev:** don't call systemctl from RUN+= — it amplified a stall into a reset ([730550a](https://github.com/junkyard-computing/junkyard-boot-img/commit/730550a1e15b334745c3ad6b8c24a956298444cc))
* **usb:** disable USB autosuspend — it is what drops the dongle ([5da2729](https://github.com/junkyard-computing/junkyard-boot-img/commit/5da272959fce4614611fb26ed2c7f3407377a391))
* **usb:** don't bind the gadget in host mode — it was killing the dongle ([7d5a8a5](https://github.com/junkyard-computing/junkyard-boot-img/commit/7d5a8a53fa9d535fe18fe3c864da193e266adb98))
* **usb:** dongle-rehost must not tear down a gadget that is in use ([8f76ec2](https://github.com/junkyard-computing/junkyard-boot-img/commit/8f76ec24454918e9f16e52111efe3b3772225916))
* **usb:** drop soft_connect and the data_role gate — the toggle was the bug ([1b276a1](https://github.com/junkyard-computing/junkyard-boot-img/commit/1b276a148354dd71bc538847dcd0cab43a79d58b))
* **usb:** escalate past otg_id — it is a no-op on the shipping topology ([ddf334d](https://github.com/junkyard-computing/junkyard-boot-img/commit/ddf334dec65d8f10b62f942aa1c95aa33406eaf2))
* **usb:** make the gadget a condition-gated unit with hot-plug re-trigger ([2f93812](https://github.com/junkyard-computing/junkyard-boot-img/commit/2f9381244664b005fba3f135637b8f9d18d0917b))
* **usb:** NO_LPM quirk for the RTL8153 dongle — the wedge is USB3 link failure ([51abdae](https://github.com/junkyard-computing/junkyard-boot-img/commit/51abdae24f6bd6e683f500d65256935d9492fb9d))
* **usb:** run dnsmasq in its own unit; stop exiting early when already bound ([a8348b6](https://github.com/junkyard-computing/junkyard-boot-img/commit/a8348b664f0cbc665d01508722302a52941a6b5e))
* **usb:** trigger the gadget on Type-C partner attach, not just UDC add ([0e1090f](https://github.com/junkyard-computing/junkyard-boot-img/commit/0e1090f6b89c804730690210f071bc517f300ce0))
* **usb:** usb-host-recover must be executable ([00565f8](https://github.com/junkyard-computing/junkyard-boot-img/commit/00565f893fa10197bcc466f695782e1c403e4324))
* **watchdog:** 15s softdog was rebooting healthy devices ([c6cdc4d](https://github.com/junkyard-computing/junkyard-boot-img/commit/c6cdc4de1da428f8b03f498ff86b104a6ee86359))


### Build System

* **kernel:** stop blanking kernel_version, and carry DT patches across syncs ([efde423](https://github.com/junkyard-computing/junkyard-boot-img/commit/efde423ae306d47aa3883e64b1be3611e18d0bc0))


### Documentation

* **claude:** refresh CLAUDE.md — transports, sibling repos, on-device tools ([c8c931a](https://github.com/junkyard-computing/junkyard-boot-img/commit/c8c931a43237f7f08e45695a5096168ba572b3d9))
* correct the Debian mirror claim — the archive IS snapshot-pinned ([7bd2cd9](https://github.com/junkyard-computing/junkyard-boot-img/commit/7bd2cd9e028230e0087532d38e93fe9f0b338df5))
* describe rootfs A/B, and correct what this branch changed ([f03ab4a](https://github.com/junkyard-computing/junkyard-boot-img/commit/f03ab4a8eda6d9cb51febb1902cac1b4dded6dbc))
* **fleet:** document --expect-device in the usage header ([45431e9](https://github.com/junkyard-computing/junkyard-boot-img/commit/45431e9ebf9bd86dd146244bad04d798f933c248))
* record the AVB slot-flag normalisation and the --flash version anchor ([f876e51](https://github.com/junkyard-computing/junkyard-boot-img/commit/f876e512507642eddcd8c442fd5ed05b23ea1e82))
* rootfs cutover is a pre-mount hook, not a shutdown pivot ([84991ef](https://github.com/junkyard-computing/junkyard-boot-img/commit/84991ef50ae73c009b2184b8a3cd96694240e432))
* the build toolchains are split across two environments ([73ed038](https://github.com/junkyard-computing/junkyard-boot-img/commit/73ed0385148038c0886c07fae817716fefca94e1))


### Reverts

* **seclog:** the exclusion did not fix the add_uevent_var panic ([391197c](https://github.com/junkyard-computing/junkyard-boot-img/commit/391197c05579a63bbc189671537b71dd0ea230e9))

## [1.4.0](https://github.com/junkyard-computing/junkyard-boot-img/compare/v1.3.0...v1.4.0) (2026-06-25)


### Features

* **tools:** build & ship pixel-ota in the rootfs; bump pixel tools to rollback-safe slot switch ([94a88d6](https://github.com/junkyard-computing/junkyard-boot-img/commit/94a88d6f3ed0757d740fc5d268c757470ac067f8))


### Build System

* containerized rootfs/boot build env for the android track (no host sudo) ([61ac69a](https://github.com/junkyard-computing/junkyard-boot-img/commit/61ac69a72eb7da64023304d13d1a4b6f54946920))

## [1.3.0](https://github.com/junkyard-computing/junkyard-boot-img/compare/v1.2.0...v1.3.0) (2026-06-21)


### Features

* **gpu:** add encrypted ARM NDA Mali Vulkan/OpenCL blobs ([768745f](https://github.com/junkyard-computing/junkyard-boot-img/commit/768745f7a9694932bc9521d7e92f9213d7c07b2d))
* **gpu:** ARM NDA blob encryption pipeline + Mali Vulkan/OpenCL loaders ([236968f](https://github.com/junkyard-computing/junkyard-boot-img/commit/236968fd0ea5c320eb41893bf6fe0e83fd6e59aa))

## [1.2.0](https://github.com/junkyard-computing/junkyard-boot-img/compare/v1.1.0...v1.2.0) (2026-06-21)


### Features

* add flash-ssh.sh in-place OTA path; rename flash.sh -&gt; flash-fastboot.sh ([e239aac](https://github.com/junkyard-computing/junkyard-boot-img/commit/e239aacd45072aedf53858c26169f223b16188c4))
* **rootfs:** add 90rootfs-flash dracut module for in-place super reflash ([31c3bbb](https://github.com/junkyard-computing/junkyard-boot-img/commit/31c3bbb0e360c41c810ff0441d61ad02edb3b7ce))
* **rootfs:** replace pixel-devinfo with pixel-bootctl + pixel-ota; show boot slot on login ([b0998c0](https://github.com/junkyard-computing/junkyard-boot-img/commit/b0998c0f9b2e47667c39df0ffc9f9bff6fb60748))


### Documentation

* plan for kube + ceph cluster roles ([425d965](https://github.com/junkyard-computing/junkyard-boot-img/commit/425d9656502259bdf3883bfc2ba031ac19a722f3))
* plan for kube + garage cluster roles ([5c46510](https://github.com/junkyard-computing/junkyard-boot-img/commit/5c4651020ab4fb268108695b3705341c3bc62c05))
* switch cluster storage role from ceph to garage ([2ba9ae1](https://github.com/junkyard-computing/junkyard-boot-img/commit/2ba9ae1fe6638df5b92bcc4c8fec0bbf36baffb3))

## [1.1.0](https://github.com/junkyard-computing/junkyard-boot-img/compare/v1.0.0...v1.1.0) (2026-06-04)


### Features

* **rootfs:** truthful kernel-bound image version + dongle MAC on login ([afb9e10](https://github.com/junkyard-computing/junkyard-boot-img/commit/afb9e10c6cc0eab02609e832ac6cafadf17a5b1d))
* **rootfs:** truthful kernel-bound image version + dongle MAC on login ([db70af2](https://github.com/junkyard-computing/junkyard-boot-img/commit/db70af2cebb76390cb4ba0ce0596ac5659893d9a))

## 1.0.0 (2026-06-03)


### Features

* **build:** show image version on login + reproducible package/kernel pins ([e4b7034](https://github.com/junkyard-computing/junkyard-boot-img/commit/e4b70348e60d6012846f89ea91c8215a5a0ef6c2))
* fix some build errors and add gitignore ([64e8576](https://github.com/junkyard-computing/junkyard-boot-img/commit/64e8576e49eab41dc92604dd07d7479884f38563))
* flash felix dtbo, enable UART getty, expose USB NCM ([f797244](https://github.com/junkyard-computing/junkyard-boot-img/commit/f797244fc42346a6df24822457b64e0ee08edeb8))
* install vendor firmware to fix UART keystroke drops ([5388b06](https://github.com/junkyard-computing/junkyard-boot-img/commit/5388b06cba8bcd363b21332beeaac370429b0ab5))
* kube kernel modules are now built. ([3095279](https://github.com/junkyard-computing/junkyard-boot-img/commit/3095279b2d8700b5453b10820e80c0487fa39721))
* pull changes from Gabe's upstream repo.  Not all changes are pulled yet. ([2a474f3](https://github.com/junkyard-computing/junkyard-boot-img/commit/2a474f323fa34b3d288d21dd31317d138d1cce72))
* pull in some of Eric's changes as well. ([5ce9dd5](https://github.com/junkyard-computing/junkyard-boot-img/commit/5ce9dd573d10367cf9f8a8ebc3462eed80a546bf))
* **rootfs:** enlarge the kmscon console font ([349fb7b](https://github.com/junkyard-computing/junkyard-boot-img/commit/349fb7bdfacec616d850223f20ca9f05dd7f5490))
* **rootfs:** mark A/B slot successful on boot to stop fastboot fallback ([5af3aeb](https://github.com/junkyard-computing/junkyard-boot-img/commit/5af3aeb46be2f539a70c11cc3c2c2a874cd7ab7f))
* **rootfs:** mark A/B slot successful on boot to stop fastboot fallback ([3cdd7f8](https://github.com/junkyard-computing/junkyard-boot-img/commit/3cdd7f8de5310e8c48d486311067cf411bfe2cb5))
* **rootfs:** show battery status on the login banner ([10c4e50](https://github.com/junkyard-computing/junkyard-boot-img/commit/10c4e507f2e6c175d6f6396ec16327b9ece41bfb))


### Bug Fixes

* it appears as if aoc.bin is needed for boot. ([0ffa2a1](https://github.com/junkyard-computing/junkyard-boot-img/commit/0ffa2a1cc3ae33fa3f65e98794f2b369401b362f))
* **rootfs:** apply Copilot review — sysroot safety + unconditional rprivate ([714695b](https://github.com/junkyard-computing/junkyard-boot-img/commit/714695b2f2ce3c22a593ca3df97a0ec1ee32c7ac))
* **rootfs:** build pixel-devinfo as static aarch64-musl ([ae6ac36](https://github.com/junkyard-computing/junkyard-boot-img/commit/ae6ac3678232531b15ec53a5369a76f536b30568))
* **rootfs:** make os-release version stamping idempotent ([3052041](https://github.com/junkyard-computing/junkyard-boot-img/commit/30520415385f651a97b0270eddc8bab0f7ad46fe))
* **rootfs:** make sysroot mount private and fall back to lazy unmount ([b63dde6](https://github.com/junkyard-computing/junkyard-boot-img/commit/b63dde6e082ed8e3e156d160eac1169c71743722))
* **rootfs:** patch nixpkgs-patched debootstrap script post --foreign ([c9165af](https://github.com/junkyard-computing/junkyard-boot-img/commit/c9165af28447e4ba9d18f61b8014037c05ba0d12))
* **rootfs:** route nspawn through a wrapper for systemd 260 + NixOS ([07f9db9](https://github.com/junkyard-computing/junkyard-boot-img/commit/07f9db9d65ce336ebca0b9289d6a2cb7caa71fdf))


### Build System

* add `nix run .#build` one-command NixOS build ([b2d6f75](https://github.com/junkyard-computing/junkyard-boot-img/commit/b2d6f75dcafc6f356f6184902bb58a4f317d3143))
* kill stale bazel server (host ns) before the FHS build ([369a8df](https://github.com/junkyard-computing/junkyard-boot-img/commit/369a8df5215d6fe081aba33a7448627a02f54bfb))
* **rootfs:** stop the rootfs image growing unboundedly across builds ([349f69a](https://github.com/junkyard-computing/junkyard-boot-img/commit/349f69acb7258c7356f2cf077e128058d1b2a299))
* shut down stale bazel server before the FHS kernel build ([c2ee22a](https://github.com/junkyard-computing/junkyard-boot-img/commit/c2ee22a9c36ade32f92499dde9a70897f4f69b54))


### Documentation

* add CLAUDE.md ([dc73cd1](https://github.com/junkyard-computing/junkyard-boot-img/commit/dc73cd130902f896febf6f0f3dcd6a7d551c8b82))
* **rootfs:** correct stale ext2 comment in .create_image ([d5ba694](https://github.com/junkyard-computing/junkyard-boot-img/commit/d5ba694eef61e96053b18ae9ea6160fb40aaf679))
