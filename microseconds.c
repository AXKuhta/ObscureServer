#include <stddef.h>
#include <stdint.h>
#include <sys/time.h>

uint64_t microseconds() {
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec*(uint64_t)1000000 + tv.tv_usec;
}