#include <time.h>

int http_time(char* memory, unsigned long epoch_time) {
	time_t t = (time_t)epoch_time;
	struct tm* parsed_time;
	
	parsed_time = gmtime(&t);
	
	return strftime(memory, 128, "%a, %d %b %Y %H:%M:%S GMT", parsed_time);
}
