/* pl7223bb.c - PL7223 位带时序用户态验证工具（无内核驱动）
 *
 * 协议来源：07_文档/PL7223移植可行性_20261108.md（反汇编 spi-pl7223.ko 还原）
 *
 * SPI 控制器（ath79，与 flash 共用）物理基址 0x1f000000：
 *   FS   = +0x00  置 1 = 接管 SPI，置 0 = 归还
 *   IOC  = +0x04  （原厂空闲值 0x43）
 *   RDS  = +0x08  bit0 = MOSI，bit8 = 时钟
 *   DATA = +0x0c  读回的数据（>>24 取 1 字节）
 *
 * 写字节：for i=7..0: RDS=bit; udelay(4); RDS=bit|0x100; udelay(4)
 * 读字节：RDS 写 0x001/0x101 打 8 个时钟，然后 DATA>>24
 * 事务  ：FS=1; udelay(3); RDS=0; 发命令字节...
 *
 * 片选（低有效）：
 *   CS1 = PCA9554A P1 = sysfs gpio 543（SoC 基址 512，扩展口基址 542）
 *   CS2 = SoC GPIO1  = sysfs gpio 513
 *   CS3 = SoC GPIO26 = sysfs gpio 538
 *   RST = SoC GPIO14 = sysfs gpio 526（高=释放复位；换 CS 后需给高→低→高脉冲）
 *
 * 用法：
 *   pl7223bb info                    # 打印 SPI 寄存器空闲值
 *   pl7223bb rst 1|0|pulse           # RST 置高/置低/脉冲
 *   pl7223bb tx <cs> <seq...>        # 例: tx 2 wC0 w00 / tx 2 w40 w00 r2
 *                                    #   wXX=发送字节(十六进制)  rN=时钟读 N 字节
 *   pl7223bb init <cs>               # RST 释放 + FS 接管 + 复位序列(wC0 w00 重试32)
 *
 * 注意：会短暂接管与 flash 共用的 SPI 总线，退出时 FS=0 归还。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>

#define SPI_PHYS   0x1f000000UL
#define MAP_SIZE   0x8000UL
#define OFF_FS     0x00
#define OFF_IOC    0x04
#define OFF_RDS    0x08
#define OFF_DATA   0x0c

#define GPIO_SOC_BASE   512
#define GPIO_EXP_BASE   542
#define GPIO_RST        (GPIO_SOC_BASE + 14)   /* 526 */
#define GPIO_CS2        (GPIO_SOC_BASE + 1)    /* 513 */
#define GPIO_CS3        (GPIO_SOC_BASE + 26)   /* 538 */
#define GPIO_CS1        (GPIO_EXP_BASE + 1)    /* 543, PCA9554A P1 */

static volatile uint32_t *regs;
static uint32_t save_fs, save_ioc, save_rds;

static void udelay(long us)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	long start = ts.tv_sec * 1000000L + ts.tv_nsec / 1000;
	for (;;) {
		clock_gettime(CLOCK_MONOTONIC, &ts);
		long now = ts.tv_sec * 1000000L + ts.tv_nsec / 1000;
		if (now - start >= us)
			return;
	}
}

static void wr(unsigned off, uint32_t v) { regs[off / 4] = v; }
static uint32_t rd(unsigned off)         { return regs[off / 4]; }

/* ---- sysfs gpio ---- */
static int gpio_export(int n)
{
	char p[64], v[16];
	int fd;
	fd = open("/sys/class/gpio/export", O_WRONLY);
	if (fd < 0) return -1;
	snprintf(v, sizeof v, "%d", n);
	if (write(fd, v, strlen(v)) < 0) { /* 已导出会失败，忽略 */ }
	close(fd);
	snprintf(p, sizeof p, "/sys/class/gpio/gpio%d/direction", n);
	fd = open(p, O_WRONLY);
	if (fd < 0) { fprintf(stderr, "gpio%d: no direction\n", n); return -1; }
	write(fd, "out", 3);
	close(fd);
	return 0;
}

static int gpio_set(int n, int v)
{
	char p[64], c[2];
	snprintf(p, sizeof p, "/sys/class/gpio/gpio%d/value", n);
	int fd = open(p, O_WRONLY);
	if (fd < 0) { perror(p); return -1; }
	c[0] = v ? '1' : '0';
	c[1] = 0;
	if (write(fd, c, 1) < 1) { close(fd); return -1; }
	close(fd);
	return 0;
}

static int gpio_get(int n)
{
	char p[64], c[2] = {0};
	snprintf(p, sizeof p, "/sys/class/gpio/gpio%d/value", n);
	int fd = open(p, O_RDONLY);
	if (fd < 0) return -1;
	if (read(fd, c, 1) < 1) { close(fd); return -1; }
	close(fd);
	return c[0] - '0';
}

/* ---- 片选 ---- */
static int cs_gpio(int cs)
{
	switch (cs) {
	case 1: return GPIO_CS1;
	case 2: return GPIO_CS2;
	case 3: return GPIO_CS3;
	default: return -1;
	}
}

static int cs_select(int cs)  { return gpio_set(cs_gpio(cs), 0); }
static int cs_deselect(int cs){ return gpio_set(cs_gpio(cs), 1); }

static void rst_pulse(void)
{
	gpio_set(GPIO_RST, 1); udelay(20000);
	gpio_set(GPIO_RST, 0); udelay(20000);
	gpio_set(GPIO_RST, 1); udelay(20000);
}

/* ---- SPI 位带原语 ---- */
static void send_byte(uint8_t b)
{
	int i;
	for (i = 7; i >= 0; i--) {
		uint32_t bit = (b >> i) & 1;
		wr(OFF_RDS, bit);            udelay(4);
		wr(OFF_RDS, bit | 0x100);    udelay(4);
	}
}

static uint8_t clock_byte(void)
{
	int i;
	for (i = 7; i >= 0; i--) {
		wr(OFF_RDS, 0x001); udelay(4);
		wr(OFF_RDS, 0x101); udelay(4);
	}
	return (rd(OFF_DATA) >> 24) & 0xff;
}

static int spi_open(void)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) { perror("/dev/mem"); return -1; }
	void *m = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, SPI_PHYS);
	close(fd);
	if (m == MAP_FAILED) { perror("mmap"); return -1; }
	regs = m;
	save_fs  = rd(OFF_FS);
	save_ioc = rd(OFF_IOC);
	save_rds = rd(OFF_RDS);
	return 0;
}

static void spi_restore(void)
{
	wr(OFF_RDS, save_rds);
	wr(OFF_IOC, save_ioc);
	wr(OFF_FS,  save_fs);
}

static int spi_take(void)
{
	wr(OFF_FS, 1); udelay(3);
	wr(OFF_RDS, 0); udelay(3);
	return 0;
}

static void spi_give(void)
{
	wr(OFF_FS, 0); udelay(3);
}

/* ---- 命令 ---- */
static void cmd_info(void)
{
	printf("FS=0x%08x IOC=0x%08x RDS=0x%08x DATA=0x%08x\n",
	       rd(OFF_FS), rd(OFF_IOC), rd(OFF_RDS), rd(OFF_DATA));
	printf("RST(gpio%d)=%d CS2(gpio%d)=%d CS3(gpio%d)=%d CS1(gpio%d)=%d\n",
	       GPIO_RST, gpio_get(GPIO_RST), GPIO_CS2, gpio_get(GPIO_CS2),
	       GPIO_CS3, gpio_get(GPIO_CS3), GPIO_CS1, gpio_get(GPIO_CS1));
}

static void cmd_rst(const char *arg)
{
	if (strcmp(arg, "pulse") == 0) {
		rst_pulse();
		printf("RST 脉冲完成, RST=%d\n", gpio_get(GPIO_RST));
	} else {
		int v = atoi(arg);
		gpio_set(GPIO_RST, v);
		printf("RST(gpio%d) = %d\n", GPIO_RST, gpio_get(GPIO_RST));
	}
}

/* 解析 'wXX' / 'rN' 序列并执行 */
static void cmd_tx(int cs, char **items, int nitems)
{
	int i, j;
	int sel = 0;
	if (gpio_export(cs_gpio(cs)) < 0) return;
	gpio_set(cs_gpio(cs), 1);           /* 默认先取消选中 */

	if (spi_open() < 0) return;
	printf("进入前: FS=0x%x RDS=0x%x\n", save_fs, save_rds);

	spi_take();
	cs_select(cs); sel = 1; udelay(3);

	for (i = 0; i < nitems; i++) {
		char *it = items[i];
		if (it[0] == 'w') {
			uint8_t b = (uint8_t)strtoul(it + 1, NULL, 16);
			send_byte(b);
			printf("w%02X 完成\n", b);
		} else if (it[0] == 'r') {
			int n = atoi(it + 1);
			printf("r%d:", n);
			for (j = 0; j < n; j++)
				printf(" %02X", clock_byte());
			printf("\n");
		} else {
			fprintf(stderr, "无法识别: %s\n", it);
		}
	}

	cs_deselect(cs); sel = 0;
	spi_give();
	spi_restore();
	printf("退出后: FS=0x%x RDS=0x%x DATA=0x%x\n",
	       rd(OFF_FS), rd(OFF_RDS), rd(OFF_DATA));
	(void)sel;
}

/* init：释放 RST + FS 接管 + 复位序列（0xC0 0x00，最多重试 32 次） */
static void cmd_init(int cs)
{
	int try_;
	if (gpio_export(GPIO_RST) < 0) return;
	gpio_set(GPIO_RST, 1); udelay(20000);
	printf("RST 释放 (gpio%d=1)\n", GPIO_RST);

	if (spi_open() < 0) return;
	spi_take();

	if (gpio_export(cs_gpio(cs)) < 0) return;
	gpio_set(cs_gpio(cs), 1);
	cs_select(cs);
	udelay(3);

	for (try_ = 0; try_ < 32; try_++) {
		send_byte(0xC0);
		send_byte(0x00);
		udelay(4);
		printf("复位尝试 %d, DATA=0x%08x\n", try_ + 1, rd(OFF_DATA));
	}

	cs_deselect(cs);
	spi_give();
	spi_restore();
	printf("init 完成\n");
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr,
			"usage:\n"
			"  pl7223bb info\n"
			"  pl7223bb rst 1|0|pulse\n"
			"  pl7223bb tx <cs> <wXX|rN>...\n"
			"  pl7223bb init <cs>\n");
		return 1;
	}

	if (strcmp(argv[1], "info") == 0) {
		if (spi_open() < 0) return 1;
		cmd_info();
		spi_restore();
		return 0;
	}
	if (strcmp(argv[1], "rst") == 0 && argc >= 3) {
		cmd_rst(argv[2]);
		return 0;
	}
	if (strcmp(argv[1], "tx") == 0 && argc >= 4) {
		cmd_tx(atoi(argv[2]), argv + 3, argc - 3);
		return 0;
	}
	if (strcmp(argv[1], "init") == 0 && argc >= 3) {
		cmd_init(atoi(argv[2]));
		return 0;
	}
	fprintf(stderr, "未知命令 %s\n", argv[1]);
	return 1;
}
