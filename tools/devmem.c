/* devmem.c - minimal mmap-based /dev/mem register reader/writer
 * PTSP01 PL7223 bitbang 验证工具（云编译版，OpenWrt 工具链编译）
 * usage: devmem <addr> [width] [value]
 *   width: 8/16/32 (default 32)
 *   value present -> write; absent -> read
 * 注意：Linux 6.12 的 /dev/mem 对 MMIO 区只允许 mmap 访问（read() 会 EFAULT），
 *       必须走 mmap —— 这正是本工具存在的意义。
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/mman.h>

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: devmem <addr> [width] [value]\n");
		return 1;
	}
	unsigned long addr = strtoul(argv[1], 0, 0);
	int width = 32;
	unsigned long wval = 0;
	int wr = 0;
	if (argc >= 3)
		width = atoi(argv[2]);
	if (argc >= 4) {
		wr = 1;
		wval = strtoul(argv[3], 0, 0);
	}

	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}

	/* 16KB 对齐：兼容 4K 与 16K PAGE_SIZE 内核 */
	unsigned long page = addr & ~0x3fffUL;
	unsigned long off = addr & 0x3fffUL;
	void *m = mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, page);
	if (m == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return 1;
	}
	volatile void *p = (char *)m + off;

	if (wr) {
		switch (width) {
		case 8:
			*(volatile uint8_t *)p = (uint8_t)wval;
			break;
		case 16:
			*(volatile uint16_t *)p = (uint16_t)wval;
			break;
		default:
			*(volatile uint32_t *)p = (uint32_t)wval;
			break;
		}
	}

	unsigned int v;
	switch (width) {
	case 8:
		v = *(volatile uint8_t *)p;
		break;
	case 16:
		v = *(volatile uint16_t *)p;
		break;
	default:
		v = *(volatile uint32_t *)p;
		break;
	}
	printf("0x%08lx = 0x%08x (%u)\n", addr, v, v);

	munmap(m, 0x8000);
	close(fd);
	return 0;
}
