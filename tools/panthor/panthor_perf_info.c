// panthor_perf_info: query the panthor performance-counter interface (DEV_QUERY_PERF_INFO).
//
// Proves the out-of-tree perfcnt backport is live on the running kernel. Built against the
// kernel's own uapi header, so the query number is always right: it is 5 from 7.3 on (upstream
// took 4 for MMU_INFO) and was 4 on the 7.2 backport — tools that hard-coded 4 silently asked
// for MMU_INFO instead.
//
//   mkdir -p inc/drm && cp <kernel>/include/uapi/drm/panthor_drm.h inc/drm/
//   gcc -O2 -I inc -I /usr/include/drm -o panthor_perf_info panthor_perf_info.c  # drm.h: linux-libc-dev
#include <drm/drm.h>
#include <drm/panthor_drm.h>
#include <fcntl.h>
#include <glob.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(void)
{
	glob_t g;
	if (glob("/dev/dri/renderD*", 0, NULL, &g)) {
		fprintf(stderr, "no render nodes\n");
		return 1;
	}
	for (size_t i = 0; i < g.gl_pathc; i++) {
		int fd = open(g.gl_pathv[i], O_RDWR);
		if (fd < 0)
			continue;
		char name[32] = {0};
		struct drm_version v = { .name = name, .name_len = sizeof(name) - 1 };
		if (ioctl(fd, DRM_IOCTL_VERSION, &v) || strcmp(name, "panthor")) {
			close(fd);
			continue;
		}
		printf("%s: panthor %d.%d.%d, PERF_INFO = query %d\n", g.gl_pathv[i],
		       v.version_major, v.version_minor, v.version_patchlevel,
		       DRM_PANTHOR_DEV_QUERY_PERF_INFO);
		struct drm_panthor_perf_info pi = {0};
		struct drm_panthor_dev_query q = {
			.type = DRM_PANTHOR_DEV_QUERY_PERF_INFO,
			.size = sizeof(pi),
			.pointer = (__u64)(uintptr_t)&pi,
		};
		if (ioctl(fd, DRM_IOCTL_PANTHOR_DEV_QUERY, &q)) {
			perror("DEV_QUERY_PERF_INFO");
			return 1;
		}
		printf("counters_per_block=%u sample_size=%u sample_header=%u block_header=%u "
		       "fw_blocks=%u flags=%#x clocks=%#x\n", pi.counters_per_block, pi.sample_size,
		       pi.sample_header_size, pi.block_header_size, pi.fw_blocks, pi.flags,
		       pi.supported_clocks);
		return pi.sample_size ? 0 : 1;
	}
	fprintf(stderr, "no panthor render node\n");
	return 1;
}
