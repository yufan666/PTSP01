/* spitest.c - 通过 spidev 发任意 SPI 事务（内核位带引擎驱动）
 *
 * 背景：/dev/mem 从用户态写 SPI 控制器 IOC 寄存器无效（实测），
 *       必须借内核 spi-ath79（spi_bitbang）来产生 CLK/MOSI 时序。
 *
 * 用法：
 *   spitest <dev> <speed_hz> <cmd> [cmd...]
 *     cmd = wAABBCC   发送十六进制字节，不回读
 *           rN        时钟 N 字节并回读（MOSI=0）
 *           RWxx..    发字节 + 同时回读（全双工）
 *
 * 所有 cmd 合成一个 SPI_IOC_MESSAGE，片选在整个消息期间保持有效
 * —— 这正是 PL7223「先发地址再连续时钟读数据」所需要的语义。
 *
 * 例：
 *   spitest /dev/spidev0.1 125000 w9F r3        # flash JEDEC ID
 *   spitest /dev/spidev0.1 125000 wC0,00 r2     # PL7223 复位序列
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/spi/spidev.h>

#define MAX_CHUNKS 16

static int hexval(int c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

/* "9F0000" -> bytes, 返回字节数 */
static int parse_hex(const char *s, uint8_t *out, int max)
{
	int n = 0, hi = -1;
	while (*s) {
		if (*s == ',' || *s == ':') { s++; continue; }
		int v = hexval((unsigned char)*s);
		if (v < 0) return -1;
		if (hi < 0) {
			hi = v;
		} else {
			if (n >= max) return -1;
			out[n++] = (uint8_t)((hi << 4) | v);
			hi = -1;
		}
		s++;
	}
	if (hi >= 0) return -1;
	return n;
}

int main(int argc, char **argv)
{
	if (argc < 4) {
		fprintf(stderr, "usage: %s <dev> <speed_hz> <cmd...>\n"
			"  cmd: wXXYY.. (write)  rN (read N)  RWxx.. (full duplex)\n"
			"  example: %s /dev/spidev0.1 125000 w9F r3\n", argv[0], argv[0]);
		return 1;
	}

	const char *dev = argv[1];
	uint32_t speed = (uint32_t)strtoul(argv[2], NULL, 0);

	int fd = open(dev, O_RDWR);
	if (fd < 0) {
		perror(dev);
		return 1;
	}

	uint8_t mode = SPI_MODE_0;
	uint8_t bits = 8;
	if (ioctl(fd, SPI_IOC_WR_MODE, &mode) < 0) { perror("SPI_IOC_WR_MODE"); return 1; }
	if (ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0) { perror("SPI_IOC_WR_BITS_PER_WORD"); return 1; }
	if (ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed) < 0) { perror("SPI_IOC_WR_MAX_SPEED_HZ"); return 1; }

	static uint8_t txbuf[256], rxbuf[256];
	static struct spi_ioc_transfer tr[MAX_CHUNKS];
	int nchunks = 0;
	int pos = 0;
	int rpos = 0;

	for (int i = 3; i < argc; i++) {
		const char *a = argv[i];
		if (a[0] == 'w') {
			int n = parse_hex(a + 1, txbuf + pos, 32);
			if (n <= 0) { fprintf(stderr, "bad write arg: %s\n", a); return 1; }
			if (nchunks >= MAX_CHUNKS) { fprintf(stderr, "too many chunks\n"); return 1; }
			memset(&tr[nchunks], 0, sizeof(tr[0]));
			tr[nchunks].tx_buf = (unsigned long)(txbuf + pos);
			tr[nchunks].len = n;
			tr[nchunks].speed_hz = speed;
			tr[nchunks].bits_per_word = 8;
			tr[nchunks].cs_change = 0;
			nchunks++;
			pos += n;
		} else if (a[0] == 'r') {
			int n = atoi(a + 1);
			if (n <= 0 || n > 64) { fprintf(stderr, "bad read arg: %s\n", a); return 1; }
			if (nchunks >= MAX_CHUNKS) { fprintf(stderr, "too many chunks\n"); return 1; }
			memset(txbuf + pos, 0, n);
			memset(rxbuf + rpos, 0, n);
			memset(&tr[nchunks], 0, sizeof(tr[0]));
			tr[nchunks].tx_buf = (unsigned long)(txbuf + pos);
			tr[nchunks].rx_buf = (unsigned long)(rxbuf + rpos);
			tr[nchunks].len = n;
			tr[nchunks].speed_hz = speed;
			tr[nchunks].bits_per_word = 8;
			tr[nchunks].cs_change = 0;
			nchunks++;
			pos += n;
			rpos += n;
		} else if (a[0] == 'R' && a[1] == 'W') {
			int n = parse_hex(a + 2, txbuf + pos, 32);
			if (n <= 0) { fprintf(stderr, "bad RW arg: %s\n", a); return 1; }
			if (nchunks >= MAX_CHUNKS) { fprintf(stderr, "too many chunks\n"); return 1; }
			memset(rxbuf + rpos, 0, n);
			memset(&tr[nchunks], 0, sizeof(tr[0]));
			tr[nchunks].tx_buf = (unsigned long)(txbuf + pos);
			tr[nchunks].rx_buf = (unsigned long)(rxbuf + rpos);
			tr[nchunks].len = n;
			tr[nchunks].speed_hz = speed;
			tr[nchunks].bits_per_word = 8;
			tr[nchunks].cs_change = 0;
			nchunks++;
			pos += n;
			rpos += n;
		} else {
			fprintf(stderr, "unknown cmd: %s\n", a);
			return 1;
		}
	}

	int ret = ioctl(fd, SPI_IOC_MESSAGE(nchunks), tr);
	if (ret < 0) {
		fprintf(stderr, "SPI_IOC_MESSAGE: %s\n", strerror(errno));
		close(fd);
		return 1;
	}

	printf("rx(%d):", rpos);
	for (int i = 0; i < rpos; i++)
		printf(" %02X", rxbuf[i]);
	printf("\n");
	close(fd);
	return 0;
}
